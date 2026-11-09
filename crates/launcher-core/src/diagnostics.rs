//! Deterministic Minecraft crash diagnostics.
//!
//! Collects instance-scoped logs (latest.log, crash reports, launcher logs), matches
//! known failure signatures and exports a redacted report. No LLM or network calls.

use std::cmp::Reverse;
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::SystemTime;

use chrono::{DateTime, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::{Error, Result};
use crate::layout::GameDataLayout;
use crate::models::instance::{Instance, InstanceRepository};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CrashDiagnosticCategory {
    JavaVersion,
    JavaArchitecture,
    MinecraftVersion,
    LoaderVersion,
    MissingRequiredMod,
    ModVersionConflict,
    ModInitialization,
    LwjglNative,
    OpenGl,
    IrisShader,
    OutOfMemory,
    MissingOrCorruptFiles,
    Unknown,
}

impl CrashDiagnosticCategory {
    pub fn display_name(self) -> &'static str {
        match self {
            Self::JavaVersion => "Java 版本不匹配",
            Self::JavaArchitecture => "Java 架构不匹配",
            Self::MinecraftVersion => "Minecraft 版本不兼容",
            Self::LoaderVersion => "Mod Loader 版本错误",
            Self::MissingRequiredMod => "缺少必需模组",
            Self::ModVersionConflict => "模组版本冲突",
            Self::ModInitialization => "模组初始化异常",
            Self::LwjglNative => "LWJGL / Native Library 错误",
            Self::OpenGl => "OpenGL 初始化失败",
            Self::IrisShader => "Iris 光影编译异常",
            Self::OutOfMemory => "内存不足",
            Self::MissingOrCorruptFiles => "游戏文件缺失或损坏",
            Self::Unknown => "未知原因",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CrashDiagnosticSeverity {
    Info,
    Warning,
    Error,
    Critical,
}

impl CrashDiagnosticSeverity {
    fn rank(self) -> u8 {
        match self {
            Self::Info => 0,
            Self::Warning => 1,
            Self::Error => 2,
            Self::Critical => 3,
        }
    }

    fn display_name(self) -> &'static str {
        match self {
            Self::Info => "信息",
            Self::Warning => "警告",
            Self::Error => "错误",
            Self::Critical => "严重",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CrashDiagnosticConfidence {
    Low,
    Medium,
    High,
}

impl CrashDiagnosticConfidence {
    fn rank(self) -> u8 {
        match self {
            Self::Low => 0,
            Self::Medium => 1,
            Self::High => 2,
        }
    }

    fn display_name(self) -> &'static str {
        match self {
            Self::Low => "低",
            Self::Medium => "中",
            Self::High => "高",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CrashLogKind {
    LatestLog,
    CrashReport,
    LauncherLog,
    GameOutput,
}

impl CrashLogKind {
    fn display_name(self) -> &'static str {
        match self {
            Self::LatestLog => "游戏 latest.log",
            Self::CrashReport => "Minecraft crash-report",
            Self::LauncherLog => "启动器日志",
            Self::GameOutput => "Java 输出",
        }
    }

    fn priority(self) -> u8 {
        match self {
            Self::CrashReport => 0,
            Self::LatestLog => 1,
            Self::LauncherLog => 2,
            Self::GameOutput => 3,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticLogReference {
    pub id: String,
    pub kind: CrashLogKind,
    pub name: String,
    pub path: PathBuf,
    pub byte_count: u64,
    pub modified_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CrashLogText {
    pub kind: CrashLogKind,
    pub name: String,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticEvidence {
    pub source: String,
    pub line: Option<usize>,
    pub excerpt: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CrashDiagnostic {
    pub id: String,
    pub category: CrashDiagnosticCategory,
    pub severity: CrashDiagnosticSeverity,
    pub confidence: CrashDiagnosticConfidence,
    pub evidence: Vec<DiagnosticEvidence>,
    pub affected_components: Vec<String>,
    pub explanation: String,
    pub recommendations: Vec<String>,
    pub is_root_cause: bool,
    pub is_secondary: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CrashDiagnosticReport {
    pub id: String,
    pub instance_id: String,
    pub generated_at: DateTime<Utc>,
    pub exit_code: Option<i32>,
    pub abnormal_exit: bool,
    pub summary: String,
    pub diagnostics: Vec<CrashDiagnostic>,
    pub root_cause_id: Option<String>,
    pub logs: Vec<DiagnosticLogReference>,
    pub log_texts: Vec<CrashLogText>,
}

impl CrashDiagnosticReport {
    pub fn root_cause(&self) -> Option<&CrashDiagnostic> {
        let id = self.root_cause_id.as_ref()?;
        self.diagnostics
            .iter()
            .find(|diagnostic| &diagnostic.id == id)
    }
}

struct RuleDef {
    category: CrashDiagnosticCategory,
    severity: CrashDiagnosticSeverity,
    confidence: CrashDiagnosticConfidence,
    patterns: &'static [&'static str],
    priority: u8,
    explanation: &'static str,
    recommendations: &'static [&'static str],
}

struct CompiledRule {
    def: &'static RuleDef,
    patterns: Vec<Regex>,
}

const RULES: &[RuleDef] = &[
    RuleDef {
        category: CrashDiagnosticCategory::OutOfMemory,
        severity: CrashDiagnosticSeverity::Critical,
        confidence: CrashDiagnosticConfidence::High,
        patterns: &[
            r"java\.lang\.OutOfMemoryError",
            r"Java heap space",
            r"GC overhead limit exceeded",
            r"Could not reserve enough space for .* object heap",
        ],
        priority: 100,
        explanation: "Java 虚拟机无法获得足够的内存，通常是实例内存上限过低或模组/光影占用过高。",
        recommendations: &["降低渲染距离或光影质量", "提高实例内存上限并重启游戏", "检查是否安装了过多大型模组"],
    },
    RuleDef {
        category: CrashDiagnosticCategory::JavaVersion,
        severity: CrashDiagnosticSeverity::Critical,
        confidence: CrashDiagnosticConfidence::High,
        patterns: &[
            r"UnsupportedClassVersionError",
            r"class file version",
            r"requires Java [0-9]+",
            r"Java [0-9]+.*(is required|required)",
            r"Unsupported Java",
        ],
        priority: 98,
        explanation: "当前 Java 版本低于游戏或 Mod Loader 要求，字节码无法被加载。",
        recommendations: &["在实例设置或安装向导中选择兼容的 Java 版本", "重新启动启动器后再试"],
    },
    RuleDef {
        category: CrashDiagnosticCategory::JavaArchitecture,
        severity: CrashDiagnosticSeverity::Critical,
        confidence: CrashDiagnosticConfidence::High,
        patterns: &[
            r"wrong ELF class",
            r"incompatible architecture",
            r"Mach-O.*(x86_64|arm64)",
            r"(x86_64.*arm64|arm64.*x86_64)",
            r"Bad CPU type in executable",
        ],
        priority: 97,
        explanation: "Java 或 Native Library 的 CPU 架构与当前系统不匹配。Apple Silicon 上应使用 arm64 或通用 Java。",
        recommendations: &["安装 arm64 或 universal Java 21", "删除实例中不兼容的 native 模组并重新安装"],
    },
    RuleDef {
        category: CrashDiagnosticCategory::MissingOrCorruptFiles,
        severity: CrashDiagnosticSeverity::Critical,
        confidence: CrashDiagnosticConfidence::High,
        patterns: &[
            r"FileNotFoundException",
            r"NoSuchFileException",
            r"ZipException",
            r"invalid LOC header",
            r"invalid stored block lengths",
            r"corrupt",
            r"Failed to download .* (404|403)",
        ],
        priority: 92,
        explanation: "启动所需的游戏文件、libraries 或模组 JAR 缺失/损坏，加载过程被中断。",
        recommendations: &["在实例管理中运行完整性检查", "重新安装对应模组或验证游戏文件", "不要手动删除 libraries 目录"],
    },
    RuleDef {
        category: CrashDiagnosticCategory::LoaderVersion,
        severity: CrashDiagnosticSeverity::Error,
        confidence: CrashDiagnosticConfidence::High,
        patterns: &[
            r"Fabric Loader .* requires",
            r"NeoForge .* requires",
            r"Unsupported loader",
            r"Loader version .* is not supported",
            r"requires Fabric Loader",
            r"requires NeoForge",
        ],
        priority: 86,
        explanation: "Mod Loader 版本与模组或游戏版本不兼容。",
        recommendations: &["安装向导中选择匹配的 Fabric/NeoForge 版本", "确认 Minecraft 版本与 Loader 主版本一致"],
    },
    RuleDef {
        category: CrashDiagnosticCategory::MinecraftVersion,
        severity: CrashDiagnosticSeverity::Error,
        confidence: CrashDiagnosticConfidence::Medium,
        patterns: &[
            r"Minecraft version .* is not supported",
            r"requires Minecraft .* but",
            r"Incompatible Minecraft version",
            r"Minecraft .* is required",
            r"does not support Minecraft",
        ],
        priority: 82,
        explanation: "模组或 Loader 声明支持的 Minecraft 版本与实例版本不一致。",
        recommendations: &["切换到实例对应的 Minecraft 版本", "安装该版本兼容的模组版本"],
    },
    RuleDef {
        category: CrashDiagnosticCategory::MissingRequiredMod,
        severity: CrashDiagnosticSeverity::Error,
        confidence: CrashDiagnosticConfidence::High,
        patterns: &[
            r"fabric-api.*(missing|not installed|requires)",
            r"Missing or unsupported mandatory dependencies",
            r"requires .* which is not installed",
            r"requires .* not installed",
            r"Mod .* requires .* (missing|not found)",
        ],
        priority: 76,
        explanation: "某个模组的前置依赖没有安装，Loader 在初始化前就停止了加载。",
        recommendations: &["打开模组管理，安装日志中列出的前置模组", "确认前置模组与当前 Loader 和 Minecraft 版本兼容"],
    },
    RuleDef {
        category: CrashDiagnosticCategory::ModVersionConflict,
        severity: CrashDiagnosticSeverity::Error,
        confidence: CrashDiagnosticConfidence::High,
        patterns: &[
            r"incompatible mods",
            r"Mod resolution",
            r"duplicate mods",
            r"multiple versions of",
            r"conflicting mod",
            r"Conflicting versions",
        ],
        priority: 72,
        explanation: "两个或多个模组声明了互相冲突的版本、ID 或依赖范围，Loader 无法完成解析。",
        recommendations: &["检查模组管理中的重复模组", "只保留与当前 Minecraft 版本兼容的同名模组", "查看日志中列出的冲突模组后逐个禁用测试"],
    },
    RuleDef {
        category: CrashDiagnosticCategory::LwjglNative,
        severity: CrashDiagnosticSeverity::Error,
        confidence: CrashDiagnosticConfidence::High,
        patterns: &[
            r"UnsatisfiedLinkError",
            r"NoClassDefFoundError: org/lwjgl",
            r"Failed to load.*(lwjgl|native)",
            r"native library.*(failed|not found)",
            r"org\.lwjgl\..*(Exception|Error)",
        ],
        priority: 66,
        explanation: "LWJGL 或本地 Native Library 加载失败，常见于架构错误、文件损坏或系统库缺失。",
        recommendations: &["运行游戏文件完整性检查", "确认 Java 架构与系统一致", "删除损坏的 libraries 后重新安装游戏"],
    },
    RuleDef {
        category: CrashDiagnosticCategory::OpenGl,
        severity: CrashDiagnosticSeverity::Error,
        confidence: CrashDiagnosticConfidence::High,
        patterns: &[
            r"GLFW error",
            r"OpenGL.*(failed|error|unsupported)",
            r"Could not create (window|OpenGL context)",
            r"Pixel format not accelerated",
            r"GL_INVALID",
        ],
        priority: 62,
        explanation: "OpenGL 上下文或窗口创建失败。macOS 通过 Metal 兼容层提供 OpenGL 4.1，部分驱动/远程桌面/虚拟机环境会限制该能力。",
        recommendations: &["确认当前不是无 GPU 的虚拟机或远程会话", "更新系统与显卡驱动", "降低光影或关闭高级图形选项后重试"],
    },
    RuleDef {
        category: CrashDiagnosticCategory::ModInitialization,
        severity: CrashDiagnosticSeverity::Error,
        confidence: CrashDiagnosticConfidence::Medium,
        patterns: &[
            r"Exception during mod initialization",
            r"Failed to (load|initialize) mod",
            r"ModInitializer.*(Exception|Error)",
            r"Caused by:.*mod",
        ],
        priority: 56,
        explanation: "某个模组在初始化阶段抛出了异常。日志中的 Caused by 堆栈通常能指出具体模组。",
        recommendations: &["根据日志中的模组 ID 禁用最近安装的模组", "更新该模组到支持当前 Minecraft/Loader 的版本"],
    },
    RuleDef {
        category: CrashDiagnosticCategory::IrisShader,
        severity: CrashDiagnosticSeverity::Warning,
        confidence: CrashDiagnosticConfidence::Medium,
        patterns: &[
            r"Iris.*(shader|compile).*(error|failed|exception)",
            r"shader.*(compilation|compile).*(failed|error)",
            r"Failed to compile shader",
            r"Shader compilation failed",
        ],
        priority: 42,
        explanation: "Iris 在编译光影程序时失败，可能是光影版本、驱动或模组组合不兼容。",
        recommendations: &["切换到其他光影或更新 Iris/Sodium", "确认光影支持当前 Minecraft 版本", "尝试关闭光影后启动以确认问题来源"],
    },
];

fn compiled_rules() -> &'static [CompiledRule] {
    static RULES_CACHE: OnceLock<Vec<CompiledRule>> = OnceLock::new();
    RULES_CACHE.get_or_init(|| {
        RULES
            .iter()
            .map(|def| CompiledRule {
                def,
                patterns: def
                    .patterns
                    .iter()
                    .filter_map(|pattern| Regex::new(&format!("(?i){pattern}")).ok())
                    .collect(),
            })
            .collect()
    })
}

fn component_pattern() -> &'static Regex {
    static PATTERN: OnceLock<Regex> = OnceLock::new();
    PATTERN.get_or_init(|| Regex::new(r"(?i)([A-Za-z0-9_.+\-]+\.jar)").expect("component regex"))
}

fn exit_code_pattern() -> &'static Regex {
    static PATTERN: OnceLock<Regex> = OnceLock::new();
    PATTERN.get_or_init(|| {
        Regex::new(r"(?i)\[launcher\] exited code=(-?[0-9]+)").expect("exit code regex")
    })
}

pub struct CrashDiagnosticsService {
    layout: GameDataLayout,
    repository: InstanceRepository,
}

impl CrashDiagnosticsService {
    pub fn new(layout: GameDataLayout) -> Self {
        Self {
            repository: InstanceRepository::new(layout.clone()),
            layout,
        }
    }

    pub fn collect(&self, instance_id: &str) -> Result<CrashDiagnosticReport> {
        self.collect_with_exit(instance_id, None)
    }

    pub fn collect_with_exit(
        &self,
        instance_id: &str,
        exit_code: Option<i32>,
    ) -> Result<CrashDiagnosticReport> {
        let instance = self.repository.load(instance_id)?;
        let mut logs = Vec::new();
        let mut texts = Vec::new();
        let game_directory = &instance.game_directory;

        let latest = game_directory.join("logs").join("latest.log");
        if let Some(text) = read_log(&latest, 4 * 1024 * 1024) {
            logs.push(make_reference(CrashLogKind::LatestLog, &latest, &text));
            texts.push(CrashLogText {
                kind: CrashLogKind::LatestLog,
                name: "latest.log".into(),
                text,
            });
        }

        let crash_directory = game_directory.join("crash-reports");
        for path in newest_files(&crash_directory, "txt", 6) {
            if let Some(text) = read_log(&path, 8 * 1024 * 1024) {
                logs.push(make_reference(CrashLogKind::CrashReport, &path, &text));
                texts.push(CrashLogText {
                    kind: CrashLogKind::CrashReport,
                    name: file_name(&path),
                    text,
                });
            }
        }

        let launcher_logs = self.layout.logs_directory();
        let mut matched = 0;
        for path in newest_files(&launcher_logs, "log", 32) {
            if matched >= 8 {
                break;
            }
            let Some(text) = read_log(&path, 4 * 1024 * 1024) else {
                continue;
            };
            if !belongs_to(&text, instance_id) {
                continue;
            }
            logs.push(make_reference(CrashLogKind::LauncherLog, &path, &text));
            texts.push(CrashLogText {
                kind: CrashLogKind::LauncherLog,
                name: file_name(&path),
                text,
            });
            matched += 1;
        }

        let parsed_exit = exit_code.or_else(|| exit_code_from(&texts));
        let abnormal = parsed_exit.map(|code| code != 0).unwrap_or(false)
            || logs.iter().any(|log| log.kind == CrashLogKind::CrashReport);
        Ok(self.analyze_with_references(instance_id, texts, parsed_exit, abnormal, logs))
    }

    pub fn analyze(
        &self,
        instance_id: &str,
        logs: Vec<CrashLogText>,
        exit_code: Option<i32>,
    ) -> CrashDiagnosticReport {
        let abnormal = exit_code.map(|code| code != 0).unwrap_or(false);
        self.analyze_with_references(instance_id, logs, exit_code, abnormal, Vec::new())
    }

    fn analyze_with_references(
        &self,
        instance_id: &str,
        mut logs: Vec<CrashLogText>,
        exit_code: Option<i32>,
        abnormal_exit: bool,
        references: Vec<DiagnosticLogReference>,
    ) -> CrashDiagnosticReport {
        logs.sort_by_key(|log| log.kind.priority());
        let mut candidates: HashMap<CrashDiagnosticCategory, Candidate> = HashMap::new();
        let rules = compiled_rules();
        for log in &logs {
            for (index, line) in log.text.lines().enumerate() {
                for rule in rules {
                    if !rule.patterns.iter().any(|pattern| pattern.is_match(line)) {
                        continue;
                    }
                    let evidence = DiagnosticEvidence {
                        source: format!("{}/{}", log.kind.display_name(), log.name),
                        line: Some(index + 1),
                        excerpt: truncate(line.trim(), 500),
                    };
                    let entry = candidates
                        .entry(rule.def.category)
                        .or_insert_with(|| Candidate {
                            severity: rule.def.severity,
                            confidence: rule.def.confidence,
                            priority: rule.def.priority,
                            evidence: Vec::new(),
                            explanation: rule.def.explanation.to_string(),
                            recommendations: rule
                                .def
                                .recommendations
                                .iter()
                                .map(|value| (*value).to_string())
                                .collect(),
                            components: BTreeSet::new(),
                        });
                    if entry.evidence.len() < 3 {
                        entry.evidence.push(evidence);
                    }
                    if rule.def.severity.rank() > entry.severity.rank() {
                        entry.severity = rule.def.severity;
                    }
                    if rule.def.confidence.rank() > entry.confidence.rank() {
                        entry.confidence = rule.def.confidence;
                    }
                    entry.components.extend(components_in(line));
                }
            }
        }

        let mut ordered: Vec<(CrashDiagnosticCategory, Candidate)> =
            candidates.into_iter().collect();
        ordered.sort_by(|(category_a, a), (category_b, b)| {
            b.priority
                .cmp(&a.priority)
                .then_with(|| format!("{category_a:?}").cmp(&format!("{category_b:?}")))
        });

        if ordered.is_empty() {
            let unknown = CrashDiagnostic {
                id: Uuid::new_v4().to_string(),
                category: CrashDiagnosticCategory::Unknown,
                severity: if abnormal_exit {
                    CrashDiagnosticSeverity::Warning
                } else {
                    CrashDiagnosticSeverity::Info
                },
                confidence: CrashDiagnosticConfidence::Low,
                evidence: Vec::new(),
                affected_components: Vec::new(),
                explanation: if abnormal_exit {
                    "检测到游戏异常退出，但日志中没有匹配到已知崩溃模式，因此无法可靠判断具体原因。"
                        .into()
                } else {
                    "最近一次启动没有发现已知崩溃模式。".into()
                },
                recommendations: if abnormal_exit {
                    vec![
                        "查看原始日志中的最后 100 行".into(),
                        "关闭最近安装的模组后重试".into(),
                        "导出报告以便进一步排查".into(),
                    ]
                } else {
                    Vec::new()
                },
                is_root_cause: abnormal_exit,
                is_secondary: false,
            };
            let root_cause_id = abnormal_exit.then(|| unknown.id.clone());
            return CrashDiagnosticReport {
                id: Uuid::new_v4().to_string(),
                instance_id: instance_id.to_string(),
                generated_at: Utc::now(),
                exit_code,
                abnormal_exit,
                summary: if abnormal_exit {
                    "启动异常，原因未知"
                } else {
                    "未发现已知崩溃模式"
                }
                .into(),
                diagnostics: vec![unknown],
                root_cause_id,
                logs: references,
                log_texts: logs,
            };
        }

        let mut diagnostics = Vec::new();
        let total = ordered.len();
        for (index, (category, candidate)) in ordered.into_iter().enumerate() {
            diagnostics.push(CrashDiagnostic {
                id: Uuid::new_v4().to_string(),
                category,
                severity: candidate.severity,
                confidence: candidate.confidence,
                evidence: candidate.evidence,
                affected_components: candidate.components.into_iter().collect(),
                explanation: candidate.explanation,
                recommendations: candidate.recommendations,
                is_root_cause: index == 0,
                is_secondary: total > 1 && index > 0,
            });
        }
        let root = &diagnostics[0];
        let summary = format!("{}：{}", root.category.display_name(), root.explanation);
        let root_cause_id = Some(root.id.clone());
        CrashDiagnosticReport {
            id: Uuid::new_v4().to_string(),
            instance_id: instance_id.to_string(),
            generated_at: Utc::now(),
            exit_code,
            abnormal_exit,
            summary,
            diagnostics,
            root_cause_id,
            logs: references,
            log_texts: logs,
        }
    }
}

struct Candidate {
    severity: CrashDiagnosticSeverity,
    confidence: CrashDiagnosticConfidence,
    priority: u8,
    evidence: Vec<DiagnosticEvidence>,
    explanation: String,
    recommendations: Vec<String>,
    components: BTreeSet<String>,
}

fn read_log(path: &Path, max_bytes: u64) -> Option<String> {
    let metadata = std::fs::symlink_metadata(path).ok()?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return None;
    }
    let length = metadata.len();
    let mut data = std::fs::read(path).ok()?;
    if length > max_bytes {
        let cut = data.len().saturating_sub(max_bytes as usize);
        data.drain(..cut);
    }
    Some(String::from_utf8_lossy(&data).into_owned())
}

fn make_reference(kind: CrashLogKind, path: &Path, text: &str) -> DiagnosticLogReference {
    let metadata = std::fs::metadata(path).ok();
    let modified_at = metadata
        .as_ref()
        .and_then(|meta| meta.modified().ok())
        .and_then(system_time);
    DiagnosticLogReference {
        id: format!("{}:{}", kind_name(kind), path.display()),
        kind,
        name: file_name(path),
        path: path.to_path_buf(),
        byte_count: metadata.map(|meta| meta.len()).unwrap_or(text.len() as u64),
        modified_at,
    }
}

fn kind_name(kind: CrashLogKind) -> &'static str {
    match kind {
        CrashLogKind::LatestLog => "latestLog",
        CrashLogKind::CrashReport => "crashReport",
        CrashLogKind::LauncherLog => "launcherLog",
        CrashLogKind::GameOutput => "gameOutput",
    }
}

fn system_time(time: SystemTime) -> Option<DateTime<Utc>> {
    Some(DateTime::<Utc>::from(time))
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn newest_files(directory: &Path, extension: &str, limit: usize) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return Vec::new();
    };
    let mut files: Vec<(SystemTime, PathBuf)> = entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            let is_extension = path
                .extension()
                .and_then(|value| value.to_str())
                .map(|value| value.eq_ignore_ascii_case(extension))
                .unwrap_or(false);
            if !is_extension {
                return None;
            }
            let metadata = entry.metadata().ok()?;
            if !metadata.is_file() {
                return None;
            }
            Some((metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH), path))
        })
        .collect();
    files.sort_by_key(|item| Reverse(item.0));
    files
        .into_iter()
        .take(limit)
        .map(|(_, path)| path)
        .collect()
}

fn belongs_to(text: &str, instance_id: &str) -> bool {
    text.contains(&format!("# instance: {instance_id}\n"))
        || text.contains(&format!("# instance: {instance_id}\r\n"))
}

fn exit_code_from(logs: &[CrashLogText]) -> Option<i32> {
    for log in logs {
        let mut last = None;
        for captures in exit_code_pattern().captures_iter(&log.text) {
            if let Some(value) = captures
                .get(1)
                .and_then(|value| value.as_str().parse::<i32>().ok())
            {
                last = Some(value);
            }
        }
        if last.is_some() {
            return last;
        }
    }
    None
}

fn components_in(line: &str) -> BTreeSet<String> {
    let mut values = BTreeSet::new();
    for captures in component_pattern().captures_iter(line) {
        if let Some(value) = captures.get(1) {
            let path = Path::new(value.as_str());
            if let Some(name) = path.file_name() {
                values.insert(name.to_string_lossy().into_owned());
            }
        }
    }
    let lower = line.to_lowercase();
    for name in [
        "fabric-api",
        "fabric loader",
        "neoforge",
        "iris",
        "sodium",
        "minecraft",
        "lwjgl",
        "opengl",
    ] {
        if lower.contains(name) {
            values.insert(name.to_string());
        }
    }
    values
}

fn truncate(text: &str, max_chars: usize) -> String {
    text.chars().take(max_chars).collect()
}

/* ----------------------------- redaction + export ----------------------------- */

pub struct DiagnosticRedactor;

impl DiagnosticRedactor {
    pub fn redact(text: &str) -> String {
        let patterns: &[(&str, &str)] = &[
            (r"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+", "Bearer <redacted>"),
            (
                r"(?i)(access[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret|authorization|password|secret)\s*[:=]\s*[^\s,;]+",
                "$1=<redacted>",
            ),
            (
                r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b",
                "<redacted-jwt>",
            ),
            (r"(/Users/)[^/\s]+", "$1<redacted>"),
            (r"(/home/)[^/\s]+", "$1<redacted>"),
            (
                r"(?i)(?:file://)?(?:/[^\s:]+)?/\.minecraft/versions/[^/\s]+",
                "<GAME_INSTANCE>",
            ),
        ];
        let mut output = text.to_string();
        for (pattern, replacement) in patterns {
            if let Ok(regex) = Regex::new(pattern) {
                output = regex.replace_all(&output, *replacement).into_owned();
            }
        }
        if let Some(home) = dirs_home() {
            output = output.replace(&home, "~");
        }
        output
    }

    pub fn redact_report(report: &CrashDiagnosticReport) -> CrashDiagnosticReport {
        let mut safe = report.clone();
        safe.summary = Self::redact(&safe.summary);
        for diagnostic in &mut safe.diagnostics {
            diagnostic.explanation = Self::redact(&diagnostic.explanation);
            diagnostic.evidence = diagnostic
                .evidence
                .iter()
                .map(|evidence| DiagnosticEvidence {
                    source: Self::redact(&evidence.source),
                    line: evidence.line,
                    excerpt: Self::redact(&evidence.excerpt),
                })
                .collect();
            diagnostic.affected_components = diagnostic
                .affected_components
                .iter()
                .map(|value| Self::redact(value))
                .collect();
        }
        for log in &mut safe.log_texts {
            log.text = Self::redact(&log.text);
        }
        safe
    }
}

fn dirs_home() -> Option<String> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(|value| value.to_string_lossy().into_owned())
        .filter(|value| !value.is_empty())
}

pub struct CrashReportExporter;

impl CrashReportExporter {
    pub fn markdown(report: &CrashDiagnosticReport, include_logs: bool) -> String {
        let safe = DiagnosticRedactor::redact_report(report);
        let mut lines = vec![
            "# LingXi Launcher 崩溃诊断报告".to_string(),
            String::new(),
            format!("- 实例：{}", safe.instance_id),
            format!("- 生成时间：{}", safe.generated_at.to_rfc3339()),
            format!(
                "- 退出码：{}",
                safe.exit_code
                    .map(|code| code.to_string())
                    .unwrap_or_else(|| "未知".into())
            ),
            format!(
                "- 异常退出：{}",
                if safe.abnormal_exit { "是" } else { "否" }
            ),
            format!("- 结论：{}", safe.summary),
            String::new(),
            "> 报告由确定性规则生成，不调用 LLM。无法识别的日志会明确标记为未知原因。".to_string(),
            String::new(),
        ];
        for (index, diagnostic) in safe.diagnostics.iter().enumerate() {
            lines.push(format!(
                "## {}. {}",
                index + 1,
                diagnostic.category.display_name()
            ));
            lines.push(String::new());
            lines.push(format!(
                "- 严重程度：{}",
                diagnostic.severity.display_name()
            ));
            lines.push(format!(
                "- 置信程度：{}",
                diagnostic.confidence.display_name()
            ));
            lines.push(format!(
                "- 根因：{}",
                if diagnostic.is_root_cause {
                    "是"
                } else {
                    "否"
                }
            ));
            if !diagnostic.affected_components.is_empty() {
                lines.push(format!(
                    "- 涉及组件：{}",
                    diagnostic.affected_components.join(", ")
                ));
            }
            lines.push(String::new());
            lines.push(diagnostic.explanation.clone());
            if !diagnostic.recommendations.is_empty() {
                lines.push(String::new());
                lines.push("### 建议".to_string());
                for recommendation in &diagnostic.recommendations {
                    lines.push(format!("- {recommendation}"));
                }
            }
            if !diagnostic.evidence.is_empty() {
                lines.push(String::new());
                lines.push("### 关键证据".to_string());
                for evidence in &diagnostic.evidence {
                    let line = evidence
                        .line
                        .map(|line| format!(":{line}"))
                        .unwrap_or_default();
                    lines.push(format!(
                        "- {}{} — {}",
                        evidence.source, line, evidence.excerpt
                    ));
                }
            }
            lines.push(String::new());
        }
        if include_logs {
            for log in &safe.log_texts {
                lines.push(format!("### {} / {}", log.kind.display_name(), log.name));
                lines.push("~~~text".into());
                let tail: String = log
                    .text
                    .chars()
                    .rev()
                    .take(12_000)
                    .collect::<String>()
                    .chars()
                    .rev()
                    .collect();
                lines.push(tail);
                lines.push("~~~".into());
                lines.push(String::new());
            }
        }
        lines.join("\n")
    }

    pub fn json(report: &CrashDiagnosticReport) -> Result<String> {
        serde_json::to_string_pretty(&DiagnosticRedactor::redact_report(report))
            .map_err(Error::from)
    }
}

/// A compact crash view used by the desktop UI.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CrashReportSummary {
    pub id: String,
    pub occurred_at: Option<DateTime<Utc>>,
    pub reason: String,
    pub description: String,
    pub stack_trace: Option<String>,
    pub file_path: Option<String>,
    pub instance_id: String,
}

pub fn latest_crash_summary(instance: &Instance) -> Result<Option<CrashReportSummary>> {
    let directory = instance.game_directory.join("crash-reports");
    let Some(path) = newest_files(&directory, "txt", 1).into_iter().next() else {
        return Ok(None);
    };
    let text = read_log(&path, 8 * 1024 * 1024).unwrap_or_default();
    let reason = text
        .lines()
        .find(|line| line.contains("Description:"))
        .map(|line| line.trim_start_matches(['#', ' ']).trim().to_string())
        .or_else(|| {
            text.lines()
                .find(|line| {
                    let lower = line.to_lowercase();
                    lower.contains("exception") || lower.contains("error")
                })
                .map(|line| truncate(line.trim(), 300))
        })
        .unwrap_or_else(|| "Minecraft 崩溃报告".into());
    let description = text.lines().take(40).collect::<Vec<_>>().join("\n");
    let stack_trace: String = text
        .chars()
        .rev()
        .take(8000)
        .collect::<String>()
        .chars()
        .rev()
        .collect();
    let metadata = std::fs::metadata(&path).ok();
    Ok(Some(CrashReportSummary {
        id: Uuid::new_v4().to_string(),
        occurred_at: metadata
            .and_then(|meta| meta.modified().ok())
            .and_then(system_time),
        reason,
        description,
        stack_trace: Some(stack_trace),
        file_path: Some(path.display().to_string()),
        instance_id: instance.id().to_string(),
    }))
}
