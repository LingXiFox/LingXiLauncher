use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use launcher_auth::{AuthConfig, MicrosoftAuthService};
use launcher_core::install::models::{DownloadSourcePolicy, TrustedMirrorConfiguration};
use launcher_core::java::JavaManager;
use launcher_core::launch::GameControl;
use launcher_core::manifest::ManifestService;
use launcher_core::models::instance::InstanceRepository;
use launcher_core::{GameDataLayout, PlatformContext, Runtime};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub java_path: Option<String>,
    pub source: String,
    pub mirror_config_path: Option<String>,
    pub default_memory_mib: u32,
    pub appearance: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            java_path: None,
            source: "auto".to_string(),
            mirror_config_path: None,
            default_memory_mib: 2048,
            appearance: "dark".to_string(),
        }
    }
}

impl Settings {
    pub fn policy(&self) -> DownloadSourcePolicy {
        DownloadSourcePolicy::parse(&self.source).unwrap_or(DownloadSourcePolicy::Auto)
    }

    pub fn mirror(&self) -> Option<TrustedMirrorConfiguration> {
        let path = self.mirror_config_path.as_ref().map(PathBuf::from)?;
        TrustedMirrorConfiguration::load(&path).ok()
    }
}

pub struct RunningGameHandle {
    pub instance_id: String,
    pub process_id: u32,
    pub started_at: chrono::DateTime<chrono::Utc>,
    pub control: GameControl,
}

pub struct AppState {
    pub layout: GameDataLayout,
    pub platform: PlatformContext,
    pub runtime: Runtime,
    pub settings: Mutex<Settings>,
    pub instances: InstanceRepository,
    pub manifest: ManifestService,
    pub java: JavaManager,
    pub auth: Arc<MicrosoftAuthService>,
    pub running: Mutex<Option<RunningGameHandle>>,
    pub auth_cancel: Mutex<Option<tokio::sync::watch::Sender<bool>>>,
}

impl AppState {
    pub fn new() -> launcher_core::Result<Self> {
        let layout = GameDataLayout::from_environment();
        let (platform, runtime) = launcher_platform::native_runtime(layout.accounts_directory())?;

        let settings = load_settings(&layout);
        let auth = MicrosoftAuthService::new(
            AuthConfig::default(),
            layout.clone(),
            runtime.secrets.clone(),
        )?;

        Ok(Self {
            instances: InstanceRepository::new(layout.clone()),
            manifest: ManifestService::new(layout.clone())?,
            java: JavaManager::new(layout.clone()),
            layout,
            platform,
            runtime,
            settings: Mutex::new(settings),
            auth: Arc::new(auth),
            running: Mutex::new(None),
            auth_cancel: Mutex::new(None),
        })
    }

    pub fn settings_snapshot(&self) -> Settings {
        self.settings.lock().expect("settings lock").clone()
    }

    pub fn save_settings(&self, settings: &Settings) -> launcher_core::Result<()> {
        write_settings_file(&self.layout, settings)?;
        *self.settings.lock().expect("settings lock") = settings.clone();
        Ok(())
    }
}

fn settings_file_contents(settings: &Settings) -> launcher_core::Result<Vec<u8>> {
    serde_json::to_vec_pretty(settings).map_err(|e| launcher_core::Error::Other(e.to_string()))
}

fn write_settings_file(layout: &GameDataLayout, settings: &Settings) -> launcher_core::Result<()> {
    let data = settings_file_contents(settings)?;
    let path = layout.settings_file();
    if let Some(parent) = path.parent() {
        launcher_core::layout::ensure_dir(parent)?;
    }
    let temporary = path.with_extension("json.part");
    std::fs::write(&temporary, data)?;
    std::fs::rename(&temporary, &path)?;
    Ok(())
}

fn load_settings(layout: &GameDataLayout) -> Settings {
    let path = layout.settings_file();
    if let Ok(data) = std::fs::read(&path) {
        if let Ok(settings) = serde_json::from_slice(&data) {
            return settings;
        }
        // A malformed settings file belongs to the user. Keep it untouched and
        // fall back to defaults instead of rewriting or migrating over it.
        return Settings::default();
    }

    #[cfg(target_os = "macos")]
    if let Some(settings) = legacy_macos_settings() {
        // Best effort: the in-memory settings are still usable if persistence
        // fails (for example when the data directory is read-only).
        let _ = write_settings_file(layout, &settings);
        return settings;
    }

    Settings::default()
}

/// Reads the subset of settings that the Swift launcher stored in
/// UserDefaults under the shared bundle identifier. Only called when no
/// Rust settings file exists, so a user who already configured the Rust build
/// never gets their choices overwritten.
#[cfg(target_os = "macos")]
fn legacy_macos_settings() -> Option<Settings> {
    const DOMAIN: &str = "com.lingxifox.LingXiLauncher";

    fn read(key: &str) -> Option<String> {
        let output = std::process::Command::new("/usr/bin/defaults")
            .args(["read", DOMAIN, key])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let value = String::from_utf8(output.stdout).ok()?;
        let value = value.trim();
        if value.is_empty() {
            None
        } else {
            Some(value.to_string())
        }
    }

    let java_path = read("lingxi.javaPath");
    let source = read("lingxi.source");
    let mirror_config_path = read("lingxi.mirrorConfigPath");
    let memory = read("lingxi.defaultMemoryMiB").and_then(|value| value.parse::<u32>().ok());
    let appearance = read("lingxi.appearance");

    if java_path.is_none()
        && source.is_none()
        && mirror_config_path.is_none()
        && memory.is_none()
        && appearance.is_none()
    {
        return None;
    }

    let mut settings = Settings {
        java_path: java_path.filter(|value| !value.is_empty()),
        mirror_config_path: mirror_config_path.filter(|value| !value.is_empty()),
        ..Settings::default()
    };
    if let Some(source) = source {
        if matches!(
            source.as_str(),
            "official" | "mirror" | "auto" | "local-cache-only"
        ) {
            settings.source = source;
        }
    }
    if let Some(memory) = memory.filter(|value| *value > 0) {
        settings.default_memory_mib = memory;
    }
    if let Some(appearance) = appearance {
        if matches!(appearance.as_str(), "dark" | "light" | "system") {
            settings.appearance = appearance;
        }
    }
    Some(settings)
}
