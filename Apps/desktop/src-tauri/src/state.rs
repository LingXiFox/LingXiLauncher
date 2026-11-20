use std::collections::HashMap;
use std::fs::File;
use std::io;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use launcher_auth::{AuthConfig, MicrosoftAuthService};
use launcher_core::install::models::{DownloadSourcePolicy, TrustedMirrorConfiguration};
use launcher_core::install::InstallStateMap;
use launcher_core::java::JavaManager;
use launcher_core::launch::GameControl;
use launcher_core::manifest::ManifestService;
use launcher_core::models::instance::{InstanceRepository, MemoryMode};
use launcher_core::{GameDataLayout, PlatformContext, Runtime};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UpdateChannel {
    Beta,
    Rc,
    Stable,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub java_path: Option<String>,
    pub source: String,
    pub mirror_config_path: Option<String>,
    pub default_memory_mib: u32,
    pub memory_mode: MemoryMode,
    pub appearance: String,
    pub language: String,
    pub accent: String,
    pub background_image: Option<String>,
    pub proxy_mode: String,
    pub proxy_url: Option<String>,
    pub game_root: Option<String>,
    pub log_window_on_start: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub update_channel: Option<UpdateChannel>,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            java_path: None,
            source: "auto".to_string(),
            mirror_config_path: None,
            default_memory_mib: 2048,
            memory_mode: MemoryMode::Auto,
            appearance: "dark".to_string(),
            language: "zh-CN".to_string(),
            accent: "orange".to_string(),
            background_image: None,
            proxy_mode: "system".to_string(),
            proxy_url: None,
            game_root: None,
            log_window_on_start: false,
            update_channel: None,
        }
    }
}

impl Settings {
    pub fn effective_update_channel(&self) -> UpdateChannel {
        self.update_channel
            .unwrap_or_else(|| match env!("CARGO_PKG_VERSION_PRE").split_once('.') {
                Some(("beta", _)) => UpdateChannel::Beta,
                Some(("rc", _)) => UpdateChannel::Rc,
                _ => UpdateChannel::Stable,
            })
    }

    pub fn policy(&self) -> DownloadSourcePolicy {
        DownloadSourcePolicy::parse(&self.source).unwrap_or(DownloadSourcePolicy::Auto)
    }

    pub fn mirror(&self) -> Option<TrustedMirrorConfiguration> {
        let path = self.mirror_config_path.as_ref().map(PathBuf::from)?;
        TrustedMirrorConfiguration::load(&path).ok()
    }

    /// Resolves the effective Minecraft root. A custom game root that no longer
    /// exists falls back to the detected one so the launcher still starts.
    pub fn resolved_game_root(&self, fallback: PathBuf) -> PathBuf {
        match self.game_root.as_ref().map(PathBuf::from) {
            Some(path) if path.is_dir() => path,
            _ => fallback,
        }
    }

    /// Heap the launcher uses for instances without their own override.
    /// `None` means "size it from the detected hardware", which keeps the
    /// launch builder on [`InstanceMemory::automatic_mib`].
    pub fn resolved_memory_mib(&self) -> Option<u32> {
        match self.memory_mode {
            MemoryMode::Auto => None,
            MemoryMode::Fixed => Some(self.default_memory_mib),
        }
    }
}

pub struct RunningGameHandle {
    pub instance_id: String,
    pub process_id: u32,
    pub started_at: chrono::DateTime<chrono::Utc>,
    pub control: GameControl,
}

/// One in-flight install task. Tasks are keyed by version id; the cancel
/// flag is shared with the downloader so a GUI click reaches the transfer
/// loops directly (P1-5).
#[derive(Clone)]
#[allow(dead_code)] // version_id/started_at reserved for diagnostics
pub struct InstallTask {
    /// Stable registry key, e.g. `version:1.21.4` or `loader:<instance-id>`.
    pub key: String,
    pub version_id: String,
    pub instance_id: Option<String>,
    pub started_at: chrono::DateTime<chrono::Utc>,
    pub cancel: launcher_core::install::CancelFlag,
}

impl InstallTask {
    /// The GUI may cancel by task key, version id or instance id; all three
    /// identify the same in-flight install.
    pub fn matches(&self, id: &str) -> bool {
        self.key == id || self.version_id == id || self.instance_id.as_deref() == Some(id)
    }
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
    pub installs: Mutex<HashMap<String, InstallTask>>,
    /// Identifies this launch in the install-state file; see
    /// [`AppState::load_install_state`].
    session: String,
    _instance_lock: InstanceLock,
    install_state_lock: Mutex<()>,
}

impl AppState {
    pub fn new() -> launcher_core::Result<Self> {
        let mut layout = GameDataLayout::from_environment();
        let instance_lock = InstanceLock::acquire(&layout.data_root)?;
        let settings = load_settings(&layout);
        // A custom Minecraft root only moves the shared game files; instances,
        // settings and runtimes stay under the launcher data directory.
        layout.game_root = settings.resolved_game_root(layout.game_root.clone());

        // Apply the persisted proxy choice before any HTTP client is built.
        crate::commands::settings::apply_saved_proxy(&settings);

        let (platform, runtime) = launcher_platform::native_runtime(layout.accounts_directory())?;
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
            installs: Mutex::new(HashMap::new()),
            session: new_session_id(),
            _instance_lock: instance_lock,
            install_state_lock: Mutex::new(()),
        })
    }

    /// Loads the persistent install state and settles records that belong to
    /// another process. A crash, force quit or power loss leaves an
    /// `installing` record behind; only a later launch can tell it apart from
    /// a run that is still in flight, and it must not stay "installing"
    /// forever because the GUI offers repair installs from that status.
    pub fn load_install_state(&self) -> InstallStateMap {
        let _lock = self.install_state_lock.lock().expect("install state lock");
        let mut state = InstallStateMap::load(&self.layout);
        if state.settle(&self.session) {
            if let Err(error) = state.save(&self.layout) {
                eprintln!("failed to persist settled install state: {error}");
            }
        }
        state
    }

    pub fn update_install_state(
        &self,
        update: impl FnOnce(&mut InstallStateMap, &str) -> launcher_core::Result<()>,
    ) -> launcher_core::Result<()> {
        let _lock = self.install_state_lock.lock().expect("install state lock");
        let mut state = InstallStateMap::load(&self.layout);
        state.settle(&self.session);
        update(&mut state, &self.session)?;
        state.save(&self.layout)
    }

    pub fn settings_snapshot(&self) -> Settings {
        self.settings.lock().expect("settings lock").clone()
    }

    pub fn save_settings(&self, settings: &Settings) -> launcher_core::Result<()> {
        let mut current = self.settings.lock().expect("settings lock");
        write_settings_file(&self.layout, settings)?;
        *current = settings.clone();
        Ok(())
    }
}

struct InstanceLock {
    _file: File,
}

impl InstanceLock {
    fn acquire(data_root: &std::path::Path) -> io::Result<Self> {
        std::fs::create_dir_all(data_root)?;
        let path = data_root.join(".launcher.lock");
        let file = open_lock_file(&path)?;
        lock_file(&file)?;
        Ok(Self { _file: file })
    }
}

#[cfg(unix)]
fn open_lock_file(path: &std::path::Path) -> io::Result<File> {
    std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(path)
}

#[cfg(unix)]
fn lock_file(file: &File) -> io::Result<()> {
    use std::os::fd::AsRawFd;

    const LOCK_EX: i32 = 2;
    const LOCK_NB: i32 = 4;

    unsafe extern "C" {
        fn flock(fd: i32, operation: i32) -> i32;
    }

    if unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(windows)]
fn open_lock_file(path: &std::path::Path) -> io::Result<File> {
    use std::os::windows::ffi::OsStrExt;
    use std::ptr::null_mut;

    const GENERIC_READ: u32 = 0x8000_0000;
    const GENERIC_WRITE: u32 = 0x4000_0000;
    const OPEN_ALWAYS: u32 = 4;
    const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;

    unsafe extern "system" {
        fn CreateFileW(
            file_name: *const u16,
            desired_access: u32,
            share_mode: u32,
            security_attributes: *mut std::ffi::c_void,
            creation_disposition: u32,
            flags_and_attributes: u32,
            template_file: *mut std::ffi::c_void,
        ) -> *mut std::ffi::c_void;
    }

    let mut path = path.as_os_str().encode_wide().collect::<Vec<_>>();
    path.push(0);
    let handle = unsafe {
        CreateFileW(
            path.as_ptr(),
            GENERIC_READ | GENERIC_WRITE,
            0,
            null_mut(),
            OPEN_ALWAYS,
            FILE_ATTRIBUTE_NORMAL,
            null_mut(),
        )
    };
    if handle == (-1isize) as *mut std::ffi::c_void {
        return Err(io::Error::last_os_error());
    }

    use std::os::windows::io::FromRawHandle;
    Ok(unsafe { File::from_raw_handle(handle) })
}

#[cfg(windows)]
fn lock_file(file: &File) -> io::Result<()> {
    use std::os::windows::io::AsRawHandle;

    const LOCKFILE_FAIL_IMMEDIATELY: u32 = 1;
    const LOCKFILE_EXCLUSIVE_LOCK: u32 = 2;
    const MAX_LOCK_LENGTH: u32 = u32::MAX;

    #[repr(C)]
    struct Overlapped {
        internal: usize,
        internal_high: usize,
        offset: u32,
        offset_high: u32,
        event: *mut std::ffi::c_void,
    }

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn LockFileEx(
            file: *mut std::ffi::c_void,
            flags: u32,
            reserved: u32,
            bytes_to_lock_low: u32,
            bytes_to_lock_high: u32,
            overlapped: *mut Overlapped,
        ) -> i32;
    }

    let mut overlapped = Overlapped {
        internal: 0,
        internal_high: 0,
        offset: 0,
        offset_high: 0,
        event: std::ptr::null_mut(),
    };
    let locked = unsafe {
        LockFileEx(
            file.as_raw_handle().cast(),
            LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
            0,
            MAX_LOCK_LENGTH,
            MAX_LOCK_LENGTH,
            &mut overlapped,
        )
    };

    if locked != 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
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
        // The legacy launcher had no auto mode: a stored number was the pin.
        settings.default_memory_mib = memory;
        settings.memory_mode = MemoryMode::Fixed;
    }
    if let Some(appearance) = appearance {
        if matches!(appearance.as_str(), "dark" | "light" | "system") {
            settings.appearance = appearance;
        }
    }
    Some(settings)
}

/// Session token for the install-state file: process id plus a monotonic
/// timestamp is enough to distinguish this launch from any earlier one, and
/// needs no extra dependency or persisted counter.
fn new_session_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_nanos())
        .unwrap_or_default();
    format!("{}-{nanos}", std::process::id())
}

#[cfg(test)]
mod instance_lock_tests {
    use super::InstanceLock;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn instance_lock_is_exclusive_until_drop() {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "lingxi-launcher-instance-lock-{}-{suffix}",
            std::process::id()
        ));
        let first = InstanceLock::acquire(&directory).expect("first lock");
        assert!(InstanceLock::acquire(&directory).is_err());
        drop(first);
        let second = InstanceLock::acquire(&directory).expect("lock after drop");
        drop(second);
        std::fs::remove_dir_all(directory).expect("remove test directory");
    }
}

#[cfg(test)]
mod memory_mode_tests {
    use super::Settings;
    use launcher_core::models::instance::MemoryMode;

    #[test]
    fn legacy_settings_without_mode_default_to_auto() {
        let settings: Settings =
            serde_json::from_str(r#"{"defaultMemoryMib":6144}"#).expect("legacy settings");
        assert_eq!(settings.memory_mode, MemoryMode::Auto);
        assert_eq!(settings.default_memory_mib, 6144);
        assert_eq!(settings.resolved_memory_mib(), None);
    }

    #[test]
    fn fixed_mode_round_trips_and_pins_value() {
        let settings: Settings =
            serde_json::from_str(r#"{"memoryMode":"fixed","defaultMemoryMib":8192}"#)
                .expect("fixed settings");
        assert_eq!(settings.memory_mode, MemoryMode::Fixed);
        assert_eq!(settings.resolved_memory_mib(), Some(8192));

        let json = serde_json::to_string(&settings).expect("serialize settings");
        assert!(json.contains("\"memoryMode\":\"fixed\""), "{json}");
        // The frontend reads this exact key; serde camelCases `_mib` to `Mib`.
        assert!(json.contains("\"defaultMemoryMib\":8192"), "{json}");
    }
}
