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
use crate::models::instance::{GraphicsApi, InstanceLaunchSettings, ProcessPriority, WindowMode};
use crate::models::launch::{
    ExitReason, GameExit, GameProcessEvent, LaunchDiagnostic, LaunchHooks, LaunchPlan,
    LaunchPreview, MissingDependency,
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

/// Result of a pre-launch integrity check. Size and SHA-1 of every library and
/// of the client jar are compared against the version metadata so a truncated
/// or half-written file is caught before the JVM starts and prints a confusing
/// `NoClassDefFoundError` instead.
#[derive(Debug, Clone, Default)]
pub struct VerificationReport {
    pub checked: usize,
    pub problems: Vec<MissingDependency>,
}

impl VerificationReport {
    pub fn is_clean(&self) -> bool {
        self.problems.is_empty()
    }
}

/// Verifies the installed files a launch depends on. Only hashes files that
/// declare a digest; anything without one is still size checked.
pub fn verify_installation(
    version: &ResolvedVersion,
    layout: &GameDataLayout,
    platform: &PlatformContext,
) -> Result<VerificationReport> {
    let mut report = VerificationReport::default();
    for library in &version.libraries {
        if !is_allowed(&library.rules, platform)? {
            continue;
        }
        let Some(artifact) = library.effective_artifact()? else {
            continue;
        };
        let path = layout.library_path(&artifact.relative_path)?;
        report.checked += 1;
        if !crate::install::verify_file(&path, artifact.sha1.as_deref(), artifact.size)? {
            report.problems.push(MissingDependency {
                name: library.name.clone(),
                reason: "library jar failed verification".into(),
                relative_path: Some(artifact.relative_path),
            });
        }
    }
    if let Some(client) = &version.client_jar {
        let path = layout.client_jar(&version.client_jar_version_id)?;
        report.checked += 1;
        let sha1 = client.sha1.as_deref().filter(|value| !value.is_empty());
        let size = client.size.filter(|value| *value > 0);
        if !crate::install::verify_file(&path, sha1, size)? {
            report.problems.push(MissingDependency {
                name: "client jar".into(),
                reason: "client jar failed verification".into(),
                relative_path: None,
            });
        }
    }
    Ok(report)
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
        instance.manifest.launch.validate()?;
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
        let settings = &instance.manifest.launch;
        settings.validate()?;
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
        // Requirement 7: an explicit memory value pins both heap bounds, while
        // automatic memory scales with the machine and keeps the initial heap
        // smaller so a quarter of RAM is not reserved up front.
        let memory_mib = instance
            .manifest
            .memory_mib
            .unwrap_or_else(crate::models::instance::InstanceMemory::automatic_mib);
        let memory_arguments = vec![
            format!("-Xms{}M", (memory_mib / 2).max(256).min(memory_mib)),
            format!("-Xmx{memory_mib}M"),
        ];
        let mut arguments = memory_arguments.clone();
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
        // Window mode and renderer switches are launcher owned: vanilla only
        // emits --width/--height behind has_custom_resolution.
        let extra_game = launcher_game_arguments(settings, version, context);
        arguments.extend(extra_game.iter().cloned());

        let mut redacted_variables = variables.clone();
        for key in sensitive {
            if let Some(value) = redacted_variables.get_mut(key) {
                *value = crate::models::launch::REDACTION_PLACEHOLDER.into();
            }
        }
        let mut redacted = Vec::new();
        redacted.extend(memory_arguments.iter().cloned());
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
        redacted.extend(extra_game.iter().cloned());

        let mut environment_overrides = BTreeMap::new();
        environment_overrides.insert("LINGXI_INSTANCE_ID".into(), instance.manifest.id.clone());
        environment_overrides.insert(
            "LINGXI_INSTANCE_DIR".into(),
            instance.directory.display().to_string(),
        );
        for (key, value) in &settings.environment {
            environment_overrides.insert(key.clone(), value.clone());
        }
        Ok(LaunchPlan {
            java_executable: context.java_executable.clone(),
            arguments,
            redacted_arguments: redacted,
            working_directory: context.game_directory.clone(),
            environment_overrides,
            version_id: version.id.clone(),
            identity_mode: context.identity.mode,
            process_priority: settings.process_priority,
            wrapper_command: settings.wrapper_command.clone(),
            hooks: LaunchHooks {
                pre_launch_command: settings.pre_launch_command.clone(),
                post_launch_command: settings.post_launch_command.clone(),
            },
        })
    }
}

/// Window mode and renderer switches are owned by the launcher: vanilla only
/// emits `--width`/`--height` behind `has_custom_resolution`, so per instance
/// window settings would otherwise never reach the game.
fn launcher_game_arguments(
    settings: &InstanceLaunchSettings,
    version: &ResolvedVersion,
    context: &LaunchContext,
) -> Vec<String> {
    let mut arguments = Vec::new();
    // The launcher only passes window flags to versions whose metadata knows
    // about them; older releases parse arguments strictly and would abort.
    let window_flags = supports_window_arguments(version);
    match settings.window_mode {
        WindowMode::Windowed if !window_flags => {}
        WindowMode::Windowed => {
            arguments.push("--width".into());
            arguments.push(settings.window_width.to_string());
            arguments.push("--height".into());
            arguments.push(settings.window_height.to_string());
        }
        // Vanilla has no --maximized switch; sizing the window to the display
        // work area is the closest a launcher can get without touching the
        // game window after it appears.
        WindowMode::Maximized if !window_flags => {}
        WindowMode::Maximized => {
            let (width, height) = context
                .display_size
                .filter(|(width, height)| *width >= 320 && *height >= 240)
                .unwrap_or((settings.window_width, settings.window_height));
            arguments.push("--width".into());
            arguments.push(width.to_string());
            arguments.push("--height".into());
            arguments.push(height.to_string());
        }
        WindowMode::Fullscreen if !window_flags => {}
        WindowMode::Fullscreen => {
            arguments.push("--fullscreen".into());
            // Keep a sane windowed size so leaving fullscreen restores it.
            arguments.push("--width".into());
            arguments.push(settings.window_width.to_string());
            arguments.push("--height".into());
            arguments.push(settings.window_height.to_string());
        }
    }
    if settings.graphics_api != GraphicsApi::Auto && supports_graphics_backend(&version.id) {
        arguments.push("--graphicsBackend".into());
        arguments.push(settings.graphics_api.as_str().into());
        if settings.graphics_api == GraphicsApi::Vulkan && settings.vulkan_validation {
            arguments.push("--vulkanValidation".into());
        }
    }
    arguments
}

/// Vanilla metadata only carries `--width`/`--height` when it defines a
/// `has_custom_resolution` rule; versions without those templates reject the
/// flags outright, so the launcher must check before adding them.
fn supports_window_arguments(version: &ResolvedVersion) -> bool {
    fn mentions(entries: &[crate::models::version::ArgumentEntry]) -> bool {
        entries.iter().any(|entry| match entry {
            crate::models::version::ArgumentEntry::Plain(value) => {
                value == "--width" || value.contains("${resolution_width}")
            }
            crate::models::version::ArgumentEntry::Conditional { values, .. } => values
                .iter()
                .any(|value| value == "--width" || value.contains("${resolution_width}")),
        })
    }
    mentions(&version.game_arguments)
}

/// `--graphicsBackend` landed in Minecraft 26.2 (snapshots included). Older
/// versions reject the option, so the launcher must not pass it there.
fn supports_graphics_backend(version_id: &str) -> bool {
    let mut parts = version_id
        .split(['.', '-'])
        .filter_map(|part| part.parse::<u32>().ok());
    let Some(major) = parts.next() else {
        return false;
    };
    let minor = parts.next().unwrap_or(0);
    major > 26 || (major == 26 && minor >= 2)
}

/// Builds the command that actually starts the JVM. A wrapper command (for
/// example `gamemoderun` or `prime-run`) is prefixed to the java invocation so
/// the game runs under it while the launcher keeps tracking the real process.
fn launch_command(plan: &LaunchPlan) -> Result<tokio::process::Command> {
    let command = match plan.wrapper_command.as_deref() {
        Some(wrapper) => {
            let mut words = split_command(wrapper)?;
            if words.is_empty() {
                return Err(Error::InvalidMetadata("empty wrapper command".into()));
            }
            let program = words.remove(0);
            let mut command = tokio::process::Command::new(program);
            command.args(words);
            command.arg(&plan.java_executable).args(&plan.arguments);
            command
        }
        None => {
            let mut command = tokio::process::Command::new(&plan.java_executable);
            command.args(&plan.arguments);
            command
        }
    };
    Ok(command)
}

/// Splits a command line on whitespace while honouring single and double
/// quotes, which is all the launcher needs for wrapper and hook commands.
fn split_command(command: &str) -> Result<Vec<String>> {
    let mut words = Vec::new();
    let mut current = String::new();
    let mut quote: Option<char> = None;
    let mut has_word = false;
    for character in command.chars() {
        match quote {
            Some(open) => {
                if character == open {
                    quote = None;
                } else {
                    current.push(character);
                }
            }
            None if character == '"' || character == '\'' => {
                quote = Some(character);
                has_word = true;
            }
            None if character.is_whitespace() => {
                if has_word {
                    words.push(std::mem::take(&mut current));
                    has_word = false;
                }
            }
            None => {
                current.push(character);
                has_word = true;
            }
        }
    }
    if quote.is_some() {
        return Err(Error::InvalidMetadata(format!(
            "unterminated quote in command {command:?}"
        )));
    }
    if has_word {
        words.push(current);
    }
    Ok(words)
}

/// Runs a pre- or post-launch hook. Pre-launch failures abort the launch so a
/// half-prepared environment is never handed to the game; post-launch failures
/// are only logged by the caller.
async fn run_hook(label: &str, command: Option<&str>, directory: &Path) -> Result<()> {
    let Some(command) = command else {
        return Ok(());
    };
    let mut words = split_command(command)?;
    if words.is_empty() {
        return Ok(());
    }
    let program = words.remove(0);
    let status = tokio::process::Command::new(&program)
        .args(words)
        .current_dir(directory)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await
        .map_err(|error| Error::Other(format!("{label} command failed to start: {error}")))?;
    if !status.success() {
        return Err(Error::Other(format!(
            "{label} command exited with {status}"
        )));
    }
    Ok(())
}

/// Applies the requested scheduling priority to a freshly spawned process.
/// Neither std nor tokio expose this portably without extra crates, so the
/// launcher shells out to the platform tools it already depends on and treats
/// a failure as a warning: the game still runs at the default priority.
fn apply_process_priority(process_id: u32, priority: ProcessPriority) {
    if priority == ProcessPriority::Normal || process_id == 0 {
        return;
    }
    let result = if cfg!(windows) {
        let class = match priority {
            ProcessPriority::Low => "Idle",
            ProcessPriority::BelowNormal => "BelowNormal",
            ProcessPriority::Normal => "Normal",
            ProcessPriority::AboveNormal => "AboveNormal",
            ProcessPriority::High => "High",
        };
        std::process::Command::new("powershell")
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-WindowStyle",
                "Hidden",
                "-Command",
            ])
            .arg(format!(
                "(Get-Process -Id {process_id}).PriorityClass = '{class}'"
            ))
            .status()
    } else {
        let nice = match priority {
            ProcessPriority::Low => 20_i32,
            ProcessPriority::BelowNormal => 10,
            ProcessPriority::Normal => 0,
            ProcessPriority::AboveNormal => -5,
            ProcessPriority::High => -10,
        };
        std::process::Command::new("renice")
            .args(["-n", &nice.to_string(), "-p", &process_id.to_string()])
            .status()
    };
    match result {
        Ok(status) if status.success() => {}
        Ok(status) => tracing::warn!(
            process_id,
            priority = priority.as_str(),
            "could not change process priority ({status})"
        ),
        Err(error) => tracing::warn!(
            process_id,
            priority = priority.as_str(),
            %error,
            "could not change process priority"
        ),
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
        run_hook(
            "pre-launch",
            plan.hooks.pre_launch_command.as_deref(),
            &plan.working_directory,
        )
        .await?;
        let mut command = launch_command(plan)?;
        command
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
        apply_process_priority(process_id, plan.process_priority);
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
        let post_launch = plan.hooks.post_launch_command.clone();
        let post_directory = plan.working_directory.clone();
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
            if let Err(error) =
                run_hook("post-launch", post_launch.as_deref(), &post_directory).await
            {
                tracing::warn!(error = %error, "post-launch command failed");
            }
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
///
/// P2-15: Minecraft logs grow into the tens of megabytes. Reading the file in
/// one `read_to_string` allocated the whole log plus a line index even when the
/// caller only wanted the last few hundred lines. This walks backwards from the
/// end in fixed-size chunks and stops as soon as it has enough line breaks, so
/// peak memory is bounded by the chunk buffer and the returned tail.
pub fn read_tail(path: &Path, max_lines: usize) -> Result<String> {
    use std::io::{Read, Seek, SeekFrom};

    if max_lines == 0 {
        return Ok(String::new());
    }
    const CHUNK: u64 = 64 * 1024;

    let mut file = std::fs::File::open(path)?;
    let mut position = file.metadata()?.len();
    let mut chunks: Vec<Vec<u8>> = Vec::new();
    let mut newlines = 0usize;
    let mut buffer = vec![0u8; CHUNK as usize];

    while position > 0 {
        let size = CHUNK.min(position) as usize;
        position -= size as u64;
        file.seek(SeekFrom::Start(position))?;
        file.read_exact(&mut buffer[..size])?;
        let chunk = buffer[..size].to_vec();
        // One extra line break guarantees the wanted tail is fully covered
        // even when the file ends with a newline.
        newlines += chunk.iter().filter(|byte| **byte == b'\n').count();
        chunks.push(chunk);
        if newlines > max_lines {
            break;
        }
    }
    chunks.reverse();

    let bytes: Vec<u8> = chunks.into_iter().flatten().collect();
    let text = String::from_utf8_lossy(&bytes);
    let mut lines: Vec<&str> = text.lines().collect();
    // The scan stopped before the start of the file, so the first line is a
    // fragment of a longer line: drop it and only ever return whole lines.
    if position > 0 && bytes.first() != Some(&b'\n') && !lines.is_empty() {
        lines.remove(0);
    }
    let start = lines.len().saturating_sub(max_lines);
    Ok(lines[start..].join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::instance::InstanceManifest;
    use std::time::Duration;

    fn scratch_dir(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "lingxi-launch-{label}-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn instance_at(root: &Path) -> Instance {
        Instance {
            manifest: InstanceManifest {
                id: "test".into(),
                display_name: "Test".into(),
                version_id: Some("1.21.11".into()),
                game_version: Some("1.21.11".into()),
                created_at: Utc::now(),
                last_launched_at: None,
                last_identity_mode: None,
                memory_mib: None,
                java_runtime: None,
                jvm_arguments: None,
                launch: Default::default(),
            },
            directory: root.join("instance"),
            game_directory: root.join("instance").join("minecraft"),
        }
    }

    #[test]
    fn read_tail_returns_the_last_lines() {
        let root = scratch_dir("tail");
        let log = root.join("game.log");
        std::fs::write(&log, "one\ntwo\nthree\nfour\nfive\n").unwrap();
        assert_eq!(read_tail(&log, 2).unwrap(), "four\nfive");
        assert_eq!(read_tail(&log, 50).unwrap(), "one\ntwo\nthree\nfour\nfive");
        assert_eq!(read_tail(&log, 0).unwrap(), "");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn read_tail_reads_large_logs_across_chunk_boundaries() {
        let root = scratch_dir("tail-large");
        let log = root.join("big.log");
        // ~400 KB, far beyond a single 64 KiB chunk.
        let mut text = String::new();
        for index in 0..20_000 {
            text.push_str(&format!("line {index} {}\n", "x".repeat(8)));
        }
        std::fs::write(&log, &text).unwrap();
        let tail = read_tail(&log, 3).unwrap();
        assert_eq!(
            tail,
            "line 19997 xxxxxxxx\nline 19998 xxxxxxxx\nline 19999 xxxxxxxx"
        );
        // Cutting the file mid-line must not return a partial first line.
        let cut = read_tail(&log, 1).unwrap();
        assert_eq!(cut, "line 19999 xxxxxxxx");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn read_tail_reports_unreadable_files() {
        let root = scratch_dir("missing");
        assert!(read_tail(&root.join("nope.log"), 10).is_err());
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn classpath_separator_matches_the_platform() {
        let expected = if cfg!(windows) { ";" } else { ":" };
        assert_eq!(classpath_separator(), expected);
    }

    #[test]
    fn latest_game_log_picks_the_newest_log_file() {
        let root = scratch_dir("logs");
        let instance = instance_at(&root);
        assert!(latest_game_log(&instance).is_none());
        let logs = instance.logs_directory();
        std::fs::create_dir_all(&logs).unwrap();
        std::fs::write(logs.join("2026-01-01-1.log"), "old").unwrap();
        std::thread::sleep(Duration::from_millis(20));
        std::fs::write(logs.join("2026-01-01-2.log"), "new").unwrap();
        std::fs::write(logs.join("notes.txt"), "ignore me").unwrap();
        assert_eq!(
            latest_game_log(&instance).unwrap().file_name().unwrap(),
            "2026-01-01-2.log"
        );
        std::fs::remove_dir_all(&root).ok();
    }
}
