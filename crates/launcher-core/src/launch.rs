//! Dependency resolution, launch planning and game process control.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use chrono::Utc;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::broadcast;

use crate::error::{Error, Result};
use crate::layout::GameDataLayout;
use crate::models::instance::Instance;
use crate::models::launch::{
    ExitReason, GameExit, GameProcessEvent, LaunchDiagnostic, LaunchPlan, LaunchPreview,
    MissingDependency,
};
pub use crate::models::launch::{LaunchContext, LaunchIdentity};
use crate::models::version::{AssetIndex, Library};
use crate::platform::PlatformContext;
use crate::version::arguments::expand;
use crate::version::rules::is_allowed;
use crate::version::{ResolvedVersion, VersionResolver};

#[derive(Debug, Clone)]
pub struct ClasspathEntry {
    pub path: PathBuf,
    pub library: String,
}

#[derive(Debug, Clone, Default)]
pub struct DependencyResolution {
    pub classpath: Vec<ClasspathEntry>,
    pub native_jars: Vec<PathBuf>,
    pub natives_directory: PathBuf,
    pub client_jar: Option<PathBuf>,
    pub asset_index: Option<AssetIndex>,
    pub asset_index_path: Option<PathBuf>,
    pub log_config: Option<PathBuf>,
    pub java_major: u32,
    pub missing: Vec<MissingDependency>,
}

pub struct DependencyResolver;

impl DependencyResolver {
    pub fn resolve(
        version: &ResolvedVersion,
        layout: &GameDataLayout,
        platform: &PlatformContext,
    ) -> Result<DependencyResolution> {
        let mut resolution = DependencyResolution {
            java_major: version.java_requirement.major_version.unwrap_or(8),
            ..Default::default()
        };
        resolution.natives_directory = layout.natives_directory(
            &version.natives_version_id,
            platform.architecture.jvm_name(),
        )?;

        for library in &version.libraries {
            if !is_allowed(&library.rules, platform)? {
                continue;
            }
            if let Some(artifact) = library.effective_artifact()? {
                let path = layout.library_path(&artifact.relative_path)?;
                if path.is_file() {
                    resolution.classpath.push(ClasspathEntry {
                        path,
                        library: library.name.clone(),
                    });
                } else {
                    resolution.missing.push(MissingDependency {
                        name: library.name.clone(),
                        reason: "library jar is not installed".into(),
                        relative_path: Some(artifact.relative_path),
                    });
                }
            }
            if let Some(classifier) = library.natives_classifier(platform.os.as_str()) {
                if let Some(artifact) = native_artifact(library, &classifier, platform)? {
                    let path = layout.library_path(&artifact.relative_path)?;
                    if path.is_file() {
                        resolution.native_jars.push(path);
                    } else {
                        resolution.missing.push(MissingDependency {
                            name: format!("{}:{classifier}", library.name),
                            reason: "native library is not installed".into(),
                            relative_path: Some(artifact.relative_path),
                        });
                    }
                }
            }
        }

        let client_version = &version.client_jar_version_id;
        let client_path = layout.client_jar(client_version)?;
        if client_path.is_file() {
            resolution.classpath.push(ClasspathEntry {
                path: client_path.clone(),
                library: format!("{client_version}:client"),
            });
            resolution.client_jar = Some(client_path);
        } else {
            resolution.missing.push(MissingDependency {
                name: format!("{client_version}:client"),
                reason: "client jar is not installed".into(),
                relative_path: None,
            });
        }

        if let Some(index) = &version.asset_index {
            let path = layout.asset_index_path(&index.id)?;
            if path.is_file() {
                resolution.asset_index_path = Some(path);
            } else {
                resolution.missing.push(MissingDependency {
                    name: format!("assets:{}", index.id),
                    reason: "asset index is not installed".into(),
                    relative_path: None,
                });
            }
            resolution.asset_index = Some(index.clone());
        }

        if let Some(logging) = &version.client_logging {
            let path = layout.log_configs_directory().join(&logging.file.id);
            if path.is_file() {
                resolution.log_config = Some(path);
            } else {
                resolution.missing.push(MissingDependency {
                    name: format!("log_config:{}", logging.file.id),
                    reason: "client log configuration is not installed".into(),
                    relative_path: None,
                });
            }
        }
        Ok(resolution)
    }
}

pub(crate) fn native_artifact(
    library: &Library,
    classifier: &str,
    platform: &PlatformContext,
) -> Result<Option<crate::models::version::EffectiveArtifact>> {
    // 1. downloads.classifiers[key]
    if let Some(artifact) = library
        .downloads
        .as_ref()
        .and_then(|d| d.classifiers.as_ref())
        .and_then(|c| c.get(classifier))
    {
        if artifact.url.is_empty() {
            return Ok(None);
        }
        let relative = artifact.path.clone().unwrap_or_else(|| {
            library
                .maven()
                .map(|mut m| {
                    m.classifier = Some(classifier.to_string());
                    m.relative_path()
                })
                .unwrap_or_default()
        });
        return Ok(Some(crate::models::version::EffectiveArtifact {
            url: artifact.url.clone(),
            relative_path: relative,
            sha1: artifact.sha1.clone(),
            size: artifact.size,
        }));
    }
    // 2. Name-based classifier (`natives-macos-arm64`) using the library host.
    let mut maven = library.maven()?;
    maven.classifier = Some(classifier.to_string());
    let base = library
        .url
        .clone()
        .unwrap_or_else(|| "https://libraries.minecraft.net/".to_string());
    let base = if base.ends_with('/') {
        base
    } else {
        format!("{base}/")
    };
    let relative = maven.relative_path();
    let _ = platform;
    Ok(Some(crate::models::version::EffectiveArtifact {
        url: format!("{base}{relative}"),
        relative_path: relative,
        sha1: None,
        size: None,
    }))
}

pub struct LaunchPlanBuilder;

impl LaunchPlanBuilder {
    pub fn resolve(version_id: &str, layout: &GameDataLayout) -> Result<ResolvedVersion> {
        VersionResolver.resolve(version_id, &layout.game_root)
    }

    pub fn preview(
        instance: &Instance,
        version: &ResolvedVersion,
        layout: &GameDataLayout,
        context: &LaunchContext,
    ) -> Result<LaunchPreview> {
        let resolution = DependencyResolver::resolve(version, layout, &context.platform)?;
        let diagnostics = diagnostics(instance, version, context, &resolution);
        let variables = base_variables(instance, version, layout, context, &resolution);
        let sensitive = ["auth_access_token", "auth_session"];
        let jvm_arguments = expand(
            &version.jvm_arguments,
            &context.platform,
            &variables,
            &sensitive,
        )?;
        let game_arguments = expand(
            &version.game_arguments,
            &context.platform,
            &variables,
            &sensitive,
        )?;
        Ok(LaunchPreview {
            identity_mode: context.identity.mode,
            identity_display_name: context.identity.display_name(),
            version_id: version.id.clone(),
            java_executable: context.java_executable.clone(),
            main_class: version.main_class.clone(),
            classpath_entry_count: resolution.classpath.len(),
            classpath_entries: resolution
                .classpath
                .iter()
                .map(|c| c.path.display().to_string())
                .collect(),
            game_directory: context.game_directory.clone(),
            jvm_arguments,
            game_arguments,
            missing_dependencies: resolution.missing.clone(),
            diagnostics,
        })
    }

    pub fn build(
        instance: &Instance,
        version: &ResolvedVersion,
        layout: &GameDataLayout,
        context: &LaunchContext,
    ) -> Result<LaunchPlan> {
        let resolution = DependencyResolver::resolve(version, layout, &context.platform)?;
        if !resolution.missing.is_empty() {
            let names = resolution
                .missing
                .iter()
                .take(5)
                .map(|m| m.name.as_str())
                .collect::<Vec<_>>()
                .join(", ");
            return Err(Error::MissingInput(format!(
                "{} dependencies are missing ({names}); install the version first",
                resolution.missing.len()
            )));
        }
        if !context.java_executable.is_file() {
            return Err(Error::JavaUnusable(format!(
                "java executable not found: {}",
                context.java_executable.display()
            )));
        }

        let mut variables = base_variables(instance, version, layout, context, &resolution);
        let classpath = resolution
            .classpath
            .iter()
            .map(|c| c.path.display().to_string())
            .collect::<Vec<_>>()
            .join(classpath_separator());
        variables.insert("classpath".into(), classpath);
        variables.insert(
            "classpath_separator".into(),
            classpath_separator().to_string(),
        );
        variables.insert(
            "library_directory".into(),
            layout.libraries_directory().display().to_string(),
        );
        variables.insert(
            "natives_directory".into(),
            resolution.natives_directory.display().to_string(),
        );

        let sensitive = ["auth_access_token", "auth_session"];
        let mut arguments = Vec::new();
        arguments.push(format!(
            "-Xmx{}M",
            instance
                .manifest
                .memory_mib
                .unwrap_or_else(|| { crate::models::instance::InstanceMemory::automatic_mib() })
        ));
        if let Some(extra) = &instance.manifest.jvm_arguments {
            arguments.extend(extra.iter().cloned());
        }
        arguments.extend(context.additional_jvm_arguments.iter().cloned());
        arguments.push(format!(
            "-Djava.library.path={}",
            resolution.natives_directory.display()
        ));
        if let Some(log_config) = &resolution.log_config {
            if let Some(logging) = &version.client_logging {
                arguments.push(
                    logging
                        .argument
                        .replace("${path}", &log_config.display().to_string()),
                );
            }
        }
        arguments.extend(expand(
            &version.jvm_arguments,
            &context.platform,
            &variables,
            &sensitive,
        )?);
        arguments.push(version.main_class.clone());
        arguments.extend(expand(
            &version.game_arguments,
            &context.platform,
            &variables,
            &sensitive,
        )?);

        let mut redacted_variables = variables.clone();
        for key in sensitive {
            if let Some(value) = redacted_variables.get_mut(key) {
                *value = crate::models::launch::REDACTION_PLACEHOLDER.into();
            }
        }
        let mut redacted = Vec::new();
        redacted.push(arguments.first().cloned().unwrap_or_default());
        redacted.extend(expand(
            &version.jvm_arguments,
            &context.platform,
            &redacted_variables,
            &sensitive,
        )?);
        redacted.push(version.main_class.clone());
        redacted.extend(expand(
            &version.game_arguments,
            &context.platform,
            &redacted_variables,
            &sensitive,
        )?);

        let mut environment_overrides = BTreeMap::new();
        environment_overrides.insert("LINGXI_INSTANCE_ID".into(), instance.manifest.id.clone());
        Ok(LaunchPlan {
            java_executable: context.java_executable.clone(),
            arguments,
            redacted_arguments: redacted,
            working_directory: context.game_directory.clone(),
            environment_overrides,
            version_id: version.id.clone(),
            identity_mode: context.identity.mode,
        })
    }
}

fn classpath_separator() -> &'static str {
    if cfg!(windows) {
        ";"
    } else {
        ":"
    }
}

fn base_variables(
    instance: &Instance,
    version: &ResolvedVersion,
    layout: &GameDataLayout,
    context: &LaunchContext,
    resolution: &DependencyResolution,
) -> BTreeMap<String, String> {
    let mut variables = BTreeMap::new();
    let identity = &context.identity;
    variables.insert("auth_player_name".into(), identity.player_name.clone());
    variables.insert("version_name".into(), version.id.clone());
    variables.insert(
        "game_directory".into(),
        context.game_directory.display().to_string(),
    );
    variables.insert(
        "assets_root".into(),
        layout.assets_directory().display().to_string(),
    );
    variables.insert(
        "game_assets".into(),
        layout
            .assets_directory()
            .join("virtual/legacy")
            .display()
            .to_string(),
    );
    variables.insert("assets_index_name".into(), version.asset_index_id.clone());
    variables.insert("auth_uuid".into(), identity.uuid_argument());
    variables.insert(
        "auth_access_token".into(),
        identity.access_token.clone().unwrap_or_else(|| "0".into()),
    );
    variables.insert(
        "auth_session".into(),
        identity.access_token.clone().unwrap_or_else(|| "-".into()),
    );
    variables.insert(
        "auth_xuid".into(),
        identity.xuid.clone().unwrap_or_else(|| "0".into()),
    );
    variables.insert("clientid".into(), String::new());
    variables.insert("user_type".into(), identity.user_type.clone());
    variables.insert(
        "version_type".into(),
        version
            .version_type
            .map(|t| format!("{t:?}").to_lowercase())
            .unwrap_or_else(|| "unknown".into()),
    );
    variables.insert("user_properties".into(), "{}".into());
    variables.insert("launcher_name".into(), context.launcher_name.clone());
    variables.insert("launcher_version".into(), context.launcher_version.clone());
    variables.insert("resolution_width".into(), "1280".into());
    variables.insert("resolution_height".into(), "720".into());
    variables.insert(
        "natives_directory".into(),
        resolution.natives_directory.display().to_string(),
    );
    variables.insert(
        "library_directory".into(),
        layout.libraries_directory().display().to_string(),
    );
    variables.insert(
        "classpath_separator".into(),
        classpath_separator().to_string(),
    );
    variables.insert(
        "classpath".into(),
        resolution
            .classpath
            .iter()
            .map(|entry| entry.path.display().to_string())
            .collect::<Vec<_>>()
            .join(classpath_separator()),
    );
    variables.insert("instance_id".into(), instance.manifest.id.clone());
    if let Some(world) = &context.quick_play_singleplayer {
        variables.insert("quickPlaySingleplayer".into(), world.clone());
    }
    variables
}

fn diagnostics(
    instance: &Instance,
    version: &ResolvedVersion,
    context: &LaunchContext,
    resolution: &DependencyResolution,
) -> Vec<LaunchDiagnostic> {
    let mut out = Vec::new();
    if !context.game_directory.is_dir() {
        out.push(LaunchDiagnostic {
            severity: "error".into(),
            message: "instance game directory is missing".into(),
        });
    }
    if !context.java_executable.is_file() {
        out.push(LaunchDiagnostic {
            severity: "error".into(),
            message: "Java executable is missing".into(),
        });
    }
    if let Some(required) = version.java_requirement.major_version {
        if let Ok(runtime) = crate::java::JavaManager::new(GameDataLayout::new(
            instance.directory.clone(),
            instance.directory.clone(),
        ))
        .inspect(&context.java_executable)
        {
            if runtime.major_version < required {
                out.push(LaunchDiagnostic {
                    severity: "error".into(),
                    message: format!(
                        "version {} requires Java {required}, selected runtime is Java {}",
                        version.id, runtime.major_version
                    ),
                });
            }
        }
    }
    if !resolution.missing.is_empty() {
        out.push(LaunchDiagnostic {
            severity: "error".into(),
            message: format!("{} dependencies are missing", resolution.missing.len()),
        });
    }
    if instance.manifest.memory_mib.unwrap_or(0) > 16384 {
        out.push(LaunchDiagnostic {
            severity: "warning".into(),
            message: "allocated memory is above 16 GiB; the JVM may fail to start".into(),
        });
    }
    out
}

#[derive(Clone)]
pub struct GameControl {
    process_id: u32,
    child: Arc<Mutex<Option<tokio::process::Child>>>,
    stopped: Arc<AtomicBool>,
}

impl GameControl {
    pub fn process_id(&self) -> u32 {
        self.process_id
    }

    pub fn stop(&self) {
        self.stopped.store(true, Ordering::SeqCst);
        if let Ok(mut guard) = self.child.lock() {
            if let Some(child) = guard.as_mut() {
                let _ = child.start_kill();
            }
        }
    }

    pub fn was_stopped(&self) -> bool {
        self.stopped.load(Ordering::SeqCst)
    }
}

pub struct RunningGame {
    pub process_id: u32,
    pub events: broadcast::Receiver<GameProcessEvent>,
    pub control: GameControl,
    pub started_at: chrono::DateTime<Utc>,
}

pub struct LaunchService;

impl LaunchService {
    pub async fn launch(plan: &LaunchPlan, log_path: Option<PathBuf>) -> Result<RunningGame> {
        let mut command = tokio::process::Command::new(&plan.java_executable);
        command
            .args(&plan.arguments)
            .current_dir(&plan.working_directory)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .stdin(std::process::Stdio::null());
        for (key, value) in &plan.environment_overrides {
            command.env(key, value);
        }
        let mut child = command
            .spawn()
            .map_err(|e| Error::JavaUnusable(format!("cannot start Java: {e}")))?;
        let process_id = child.id().unwrap_or_default();
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        let (sender, receiver) = broadcast::channel(2048);

        let log_file = log_path.map(|path| {
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            Arc::new(Mutex::new(std::fs::File::create(path).ok()))
        });
        if let Some(stdout) = stdout {
            spawn_reader(stdout, sender.clone(), log_file.clone(), false);
        }
        if let Some(stderr) = stderr {
            spawn_reader(stderr, sender.clone(), log_file.clone(), true);
        }

        let child_slot = Arc::new(Mutex::new(Some(child)));
        let stopped = Arc::new(AtomicBool::new(false));
        let control = GameControl {
            process_id,
            child: child_slot.clone(),
            stopped: stopped.clone(),
        };
        let waiter_sender = sender.clone();
        tokio::spawn(async move {
            let exit = loop {
                let status = {
                    let mut guard = child_slot.lock().expect("child lock");
                    match guard.as_mut() {
                        Some(child) => child.try_wait().ok().flatten(),
                        None => None,
                    }
                };
                if let Some(status) = status {
                    break status;
                }
                tokio::time::sleep(std::time::Duration::from_millis(150)).await;
            };
            let cancelled = stopped.load(Ordering::SeqCst);
            let exit = GameExit {
                code: exit.code(),
                reason: if cancelled {
                    ExitReason::Cancelled
                } else if exit.code().is_some() {
                    ExitReason::Exited
                } else {
                    ExitReason::Signalled
                },
                signal: None,
                is_success: exit.success() && !cancelled,
            };
            let _ = waiter_sender.send(GameProcessEvent::Exited { exit });
        });

        Ok(RunningGame {
            process_id,
            events: receiver,
            control,
            started_at: Utc::now(),
        })
    }
}

fn spawn_reader<R>(
    reader: R,
    sender: broadcast::Sender<GameProcessEvent>,
    log_file: Option<Arc<Mutex<Option<std::fs::File>>>>,
    is_stderr: bool,
) where
    R: tokio::io::AsyncRead + Unpin + Send + 'static,
{
    tokio::spawn(async move {
        let mut lines = BufReader::new(reader).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if let Some(file) = &log_file {
                if let Ok(mut guard) = file.lock() {
                    if let Some(file) = guard.as_mut() {
                        use std::io::Write;
                        let _ = writeln!(file, "{line}");
                    }
                }
            }
            let event = if is_stderr {
                GameProcessEvent::Stderr { line }
            } else {
                GameProcessEvent::Stdout { line }
            };
            let _ = sender.send(event);
        }
    });
}

/// Resolves the newest log file created for an instance.
pub fn latest_game_log(instance: &Instance) -> Option<PathBuf> {
    let directory = instance.logs_directory();
    let mut entries: Vec<_> = std::fs::read_dir(directory)
        .ok()?
        .flatten()
        .filter(|e| e.path().extension().map(|x| x == "log").unwrap_or(false))
        .collect();
    entries.sort_by_key(|e| e.metadata().ok().and_then(|m| m.modified().ok()));
    entries.pop().map(|e| e.path())
}

/// Reads the tail of a file without loading the whole file.
pub fn read_tail(path: &Path, max_lines: usize) -> Result<String> {
    let text = std::fs::read_to_string(path)?;
    let lines: Vec<&str> = text.lines().collect();
    let start = lines.len().saturating_sub(max_lines);
    Ok(lines[start..].join("\n"))
}
