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
        let data = serde_json::to_vec_pretty(settings)
            .map_err(|e| launcher_core::Error::Other(e.to_string()))?;
        let path = self.layout.settings_file();
        if let Some(parent) = path.parent() {
            launcher_core::layout::ensure_dir(parent)?;
        }
        let temporary = path.with_extension("json.part");
        std::fs::write(&temporary, data)?;
        std::fs::rename(&temporary, &path)?;
        *self.settings.lock().expect("settings lock") = settings.clone();
        Ok(())
    }
}

fn load_settings(layout: &GameDataLayout) -> Settings {
    std::fs::read(layout.settings_file())
        .ok()
        .and_then(|data| serde_json::from_slice(&data).ok())
        .unwrap_or_default()
}
