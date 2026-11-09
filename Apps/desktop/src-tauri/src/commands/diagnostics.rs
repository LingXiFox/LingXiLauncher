use launcher_core::diagnostics::{
    latest_crash_summary, CrashDiagnosticSeverity, CrashDiagnosticsService, CrashReportSummary,
};
use launcher_core::models::account::ActiveAccountStore;
use launcher_core::performance::SystemProfile;
use serde::Serialize;
use tauri::State;

use crate::commands::{command_error, CommandResult};
use crate::state::AppState;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticCheckView {
    pub id: String,
    pub label: String,
    pub status: String,
    pub detail: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticsReportView {
    pub checks: Vec<DiagnosticCheckView>,
    pub summary: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CrashReportView {
    pub id: Option<String>,
    pub occurred_at: Option<chrono::DateTime<chrono::Utc>>,
    pub reason: Option<String>,
    pub description: Option<String>,
    pub stack_trace: Option<String>,
    pub file_path: Option<String>,
    pub instance_id: Option<String>,
}

impl From<CrashReportSummary> for CrashReportView {
    fn from(summary: CrashReportSummary) -> Self {
        Self {
            id: Some(summary.id),
            occurred_at: summary.occurred_at,
            reason: Some(summary.reason),
            description: Some(summary.description),
            stack_trace: summary.stack_trace,
            file_path: summary.file_path,
            instance_id: Some(summary.instance_id),
        }
    }
}

fn pass(id: &str, label: &str, detail: Option<String>) -> DiagnosticCheckView {
    DiagnosticCheckView {
        id: id.into(),
        label: label.into(),
        status: "pass".into(),
        detail,
    }
}

fn warn(id: &str, label: &str, detail: impl Into<String>) -> DiagnosticCheckView {
    DiagnosticCheckView {
        id: id.into(),
        label: label.into(),
        status: "warn".into(),
        detail: Some(detail.into()),
    }
}

fn fail(id: &str, label: &str, detail: impl Into<String>) -> DiagnosticCheckView {
    DiagnosticCheckView {
        id: id.into(),
        label: label.into(),
        status: "fail".into(),
        detail: Some(detail.into()),
    }
}

fn check_java(
    state: &AppState,
    instance: &launcher_core::models::instance::Instance,
) -> DiagnosticCheckView {
    if let Some(runtime) = &instance.manifest.java_runtime {
        let path = std::path::Path::new(&runtime.executable);
        if path.is_file() {
            return pass(
                "java",
                "Java 运行时",
                Some(format!(
                    "{} {} ({})",
                    runtime.vendor.as_deref().unwrap_or("Java"),
                    runtime.version,
                    runtime.executable
                )),
            );
        }
        return fail(
            "java",
            "Java 运行时",
            format!("实例记录的 Java 已不存在：{}", runtime.executable),
        );
    }
    let settings = state.settings_snapshot();
    if let Some(path) = settings
        .java_path
        .as_deref()
        .filter(|value| !value.trim().is_empty())
    {
        if std::path::Path::new(path).is_file() {
            return pass(
                "java",
                "Java 运行时",
                Some(format!("使用偏好设置中的 Java：{path}")),
            );
        }
        return fail(
            "java",
            "Java 运行时",
            format!("偏好设置中的 Java 不存在：{path}"),
        );
    }
    let mut runtimes = state.java.discover();
    if runtimes.is_empty() {
        return fail(
            "java",
            "Java 运行时",
            "未检测到可用的 Java，请先在设置中安装或指定 Java。",
        );
    }
    runtimes.sort_by_key(|runtime| std::cmp::Reverse(runtime.major_version));
    let runtime = &runtimes[0];
    pass(
        "java",
        "Java 运行时",
        Some(format!(
            "使用 Java {} ({})",
            runtime.version_string,
            runtime.executable.display()
        )),
    )
}

fn check_game_files(
    state: &AppState,
    instance: &launcher_core::models::instance::Instance,
) -> DiagnosticCheckView {
    let Some(version_id) = instance
        .manifest
        .version_id
        .as_deref()
        .filter(|value| !value.trim().is_empty())
    else {
        return fail("game-files", "游戏文件", "实例尚未绑定 Minecraft 版本。");
    };
    let json = match state.layout.version_json(version_id) {
        Ok(path) => path,
        Err(error) => return fail("game-files", "游戏文件", command_error(error)),
    };
    let jar = match state.layout.client_jar(version_id) {
        Ok(path) => path,
        Err(error) => return fail("game-files", "游戏文件", command_error(error)),
    };
    let missing_json = !json.is_file();
    let missing_jar = !jar.is_file();
    match (missing_json, missing_jar) {
        (false, false) => pass(
            "game-files",
            "游戏文件",
            Some(format!("版本 {version_id} 已完整下载")),
        ),
        (true, false) => fail(
            "game-files",
            "游戏文件",
            format!("缺少版本 JSON：{}", json.display()),
        ),
        (false, true) => fail(
            "game-files",
            "游戏文件",
            format!("缺少客户端 JAR：{}", jar.display()),
        ),
        (true, true) => fail(
            "game-files",
            "游戏文件",
            format!("版本 {version_id} 尚未安装完整"),
        ),
    }
}

fn check_memory(
    state: &AppState,
    instance: &launcher_core::models::instance::Instance,
) -> DiagnosticCheckView {
    let settings = state.settings_snapshot();
    let memory = instance
        .manifest
        .memory_mib
        .unwrap_or(settings.default_memory_mib);
    let profile = SystemProfile::detect(&state.layout.data_root);
    if memory < 512 {
        return fail(
            "memory",
            "内存分配",
            format!("仅分配 {memory} MiB，低于游戏可运行的下限。"),
        );
    }
    if profile.physical_memory_mib > 0 && memory as u64 > profile.physical_memory_mib * 4 / 5 {
        return warn(
            "memory",
            "内存分配",
            format!(
                "分配 {memory} MiB，超过物理内存 {} MiB 的 80%。",
                profile.physical_memory_mib
            ),
        );
    }
    pass(
        "memory",
        "内存分配",
        Some(format!(
            "分配 {memory} MiB，物理内存 {} MiB",
            profile.physical_memory_mib
        )),
    )
}

fn check_disk(state: &AppState) -> DiagnosticCheckView {
    let profile = SystemProfile::detect(&state.layout.data_root);
    if profile.disk_free_mib < 4096 {
        warn(
            "disk",
            "磁盘空间",
            format!("数据目录所在磁盘仅剩 {} MiB", profile.disk_free_mib),
        )
    } else {
        pass(
            "disk",
            "磁盘空间",
            Some(format!("剩余 {} MiB", profile.disk_free_mib)),
        )
    }
}

fn check_account(state: &AppState) -> DiagnosticCheckView {
    match ActiveAccountStore::new(state.layout.clone()).load() {
        Some(reference) => pass(
            "account",
            "账户",
            Some(format!(
                "当前账户：{} / {}",
                reference.kind.as_str(),
                reference.identifier
            )),
        ),
        None => warn(
            "account",
            "账户",
            "尚未选择正版账户，离线启动将使用本地用户名。",
        ),
    }
}

fn check_logs(
    state: &AppState,
    instance: &launcher_core::models::instance::Instance,
) -> DiagnosticCheckView {
    let service = CrashDiagnosticsService::new(state.layout.clone());
    let report = match service.collect_with_exit(instance.id(), None) {
        Ok(report) => report,
        Err(error) => return warn("logs", "日志分析", command_error(error)),
    };
    if let Some(root) = report.root_cause() {
        let detail = format!("{}：{}", root.category.display_name(), root.explanation);
        return match root.severity {
            CrashDiagnosticSeverity::Critical | CrashDiagnosticSeverity::Error => {
                fail("logs", "日志分析", detail)
            }
            _ => warn("logs", "日志分析", detail),
        };
    }
    if let Some(crash) = latest_crash_summary(instance).ok().flatten() {
        return warn("logs", "日志分析", crash.reason);
    }
    pass(
        "logs",
        "日志分析",
        Some("最近日志中未发现已知崩溃特征".into()),
    )
}

#[tauri::command]
pub fn diagnose(
    state: State<'_, AppState>,
    instance_id: String,
) -> CommandResult<DiagnosticsReportView> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let checks = vec![
        check_java(&state, &instance),
        check_game_files(&state, &instance),
        check_memory(&state, &instance),
        check_disk(&state),
        check_account(&state),
        check_logs(&state, &instance),
    ];
    let failed = checks.iter().filter(|check| check.status == "fail").count();
    let warned = checks.iter().filter(|check| check.status == "warn").count();
    let passed = checks.iter().filter(|check| check.status == "pass").count();
    let summary = if failed > 0 {
        format!("{failed} 项异常、{warned} 项提醒、{passed} 项通过")
    } else if warned > 0 {
        format!("{warned} 项提醒、{passed} 项通过")
    } else {
        format!("全部 {passed} 项检查通过")
    };
    Ok(DiagnosticsReportView {
        checks,
        summary: Some(summary),
    })
}

#[tauri::command]
pub fn latest_crash_report(
    state: State<'_, AppState>,
    instance_id: String,
) -> CommandResult<Option<CrashReportView>> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    Ok(latest_crash_summary(&instance)
        .map_err(command_error)?
        .map(CrashReportView::from))
}
