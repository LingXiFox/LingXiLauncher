use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::layout::GameDataLayout;
use crate::paths::PathSafety;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum IdentityMode {
    #[serde(rename = "microsoft")]
    Microsoft,
    #[serde(rename = "licensed-offline")]
    LicensedOffline,
    #[serde(rename = "local-offline")]
    LocalOffline,
}

impl IdentityMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            IdentityMode::Microsoft => "microsoft",
            IdentityMode::LicensedOffline => "licensed-offline",
            IdentityMode::LocalOffline => "local-offline",
        }
    }
}

/// Reproducible Java selection record persisted inside `instance.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaRuntimeRecord {
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub major_version: u32,
    #[serde(default)]
    pub architecture: String,
    #[serde(default)]
    pub executable: String,
    #[serde(default)]
    pub vendor: Option<String>,
    #[serde(default)]
    pub checksum: Option<String>,
    #[serde(
        default = "default_java_source",
        deserialize_with = "deserialize_java_source"
    )]
    pub source: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub component: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artifact_sha1: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artifact_sha256: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub executable_sha256: Option<String>,
    #[serde(default = "Utc::now")]
    pub recorded_at: DateTime<Utc>,
}

fn default_java_source() -> String {
    "system".to_string()
}

fn deserialize_java_source<'de, D>(deserializer: D) -> std::result::Result<String, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Option::<String>::deserialize(deserializer)
        .map(|value| value.unwrap_or_else(default_java_source))
}

/// How the game window should be created.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum WindowMode {
    /// A resizable window sized to window_width x window_height.
    #[default]
    Windowed,
    /// Exclusive fullscreen, sized to the current display.
    Fullscreen,
    /// Windowed, sized to the primary display work area.
    Maximized,
}

impl WindowMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Windowed => "windowed",
            Self::Fullscreen => "fullscreen",
            Self::Maximized => "maximized",
        }
    }
}

/// OS scheduling priority applied to the game process right after spawn.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ProcessPriority {
    Low,
    BelowNormal,
    #[default]
    Normal,
    AboveNormal,
    High,
}

impl ProcessPriority {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Low => "low",
            Self::BelowNormal => "belowNormal",
            Self::Normal => "normal",
            Self::AboveNormal => "aboveNormal",
            Self::High => "high",
        }
    }
}

/// Which rendering backend the game should start with.
///
/// Minecraft 26.2 and newer ship a Vulkan backend selected through the
/// --graphicsBackend command line flag; older versions only have OpenGL, so the
/// setting is ignored there and reported as unsupported.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GraphicsApi {
    #[default]
    Auto,
    OpenGl,
    Vulkan,
}

impl GraphicsApi {
    /// Value understood by the game's --graphicsBackend flag.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "default",
            Self::OpenGl => "opengl",
            Self::Vulkan => "vulkan",
        }
    }
}

/// What the launcher window does once the game process is alive.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LauncherVisibility {
    /// Keep the launcher visible.
    #[default]
    Keep,
    /// Minimise the launcher while the game runs.
    Minimize,
    /// Close the launcher window entirely.
    Close,
    /// Hide the launcher and restore it when the game exits.
    Hide,
}

impl LauncherVisibility {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Keep => "keep",
            Self::Minimize => "minimize",
            Self::Close => "close",
            Self::Hide => "hide",
        }
    }
}

fn default_window_width() -> u32 {
    1280
}

fn default_window_height() -> u32 {
    720
}

/// Per-instance launch options.
///
/// Every field carries a serde default so instance files written by earlier
/// launcher builds keep loading unchanged.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstanceLaunchSettings {
    #[serde(default)]
    pub window_mode: WindowMode,
    #[serde(default = "default_window_width")]
    pub window_width: u32,
    #[serde(default = "default_window_height")]
    pub window_height: u32,
    #[serde(default)]
    pub process_priority: ProcessPriority,
    /// Extra environment variables handed to the JVM.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub environment: BTreeMap<String, String>,
    /// Shell command run before the JVM starts; a non-zero exit aborts.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pre_launch_command: Option<String>,
    /// Command prefix wrapped around the Java executable, e.g. prime-run.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wrapper_command: Option<String>,
    /// Shell command run once the game process exits.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub post_launch_command: Option<String>,
    #[serde(default)]
    pub graphics_api: GraphicsApi,
    /// Enable Vulkan validation layers (debug only).
    #[serde(default)]
    pub vulkan_validation: bool,
    /// Hash-check installed files before every launch.
    #[serde(default)]
    pub verify_before_launch: bool,
    #[serde(default)]
    pub launcher_visibility: LauncherVisibility,
}

impl Default for InstanceLaunchSettings {
    fn default() -> Self {
        Self {
            window_mode: WindowMode::default(),
            window_width: default_window_width(),
            window_height: default_window_height(),
            process_priority: ProcessPriority::default(),
            environment: BTreeMap::new(),
            pre_launch_command: None,
            wrapper_command: None,
            post_launch_command: None,
            graphics_api: GraphicsApi::default(),
            vulkan_validation: false,
            verify_before_launch: false,
            launcher_visibility: LauncherVisibility::default(),
        }
    }
}

impl InstanceLaunchSettings {
    /// Rejects values the JVM or the game would choke on.
    pub fn validate(&self) -> Result<()> {
        if !(320..=7680).contains(&self.window_width) || !(240..=4320).contains(&self.window_height)
        {
            return Err(Error::InvalidMetadata(format!(
                "window size {}x{} outside 320x240..7680x4320",
                self.window_width, self.window_height
            )));
        }
        for (key, value) in &self.environment {
            if key.is_empty()
                || key.contains('=')
                || key.contains(char::from(0))
                || value.contains(char::from(0))
            {
                return Err(Error::InvalidMetadata(format!(
                    "invalid environment variable {key:?}"
                )));
            }
        }
        for command in [
            self.pre_launch_command.as_deref(),
            self.wrapper_command.as_deref(),
            self.post_launch_command.as_deref(),
        ]
        .into_iter()
        .flatten()
        {
            if command.trim().is_empty() || command.contains(char::from(0)) {
                return Err(Error::InvalidMetadata("empty or invalid command".into()));
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstanceManifest {
    pub id: String,
    pub display_name: String,
    #[serde(default)]
    pub version_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub game_version: Option<String>,
    pub created_at: DateTime<Utc>,
    #[serde(default)]
    pub last_launched_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub last_identity_mode: Option<IdentityMode>,
    #[serde(default)]
    pub memory_mib: Option<u32>,
    #[serde(default)]
    pub java_runtime: Option<JavaRuntimeRecord>,
    #[serde(default)]
    pub jvm_arguments: Option<Vec<String>>,
    /// Window, priority, hooks and GPU options added in 0.10.
    #[serde(default)]
    pub launch: InstanceLaunchSettings,
}

impl InstanceManifest {
    pub fn new(
        id: impl Into<String>,
        display_name: impl Into<String>,
        version_id: Option<String>,
    ) -> Self {
        Self {
            id: id.into(),
            display_name: display_name.into(),
            version_id,
            game_version: None,
            created_at: Utc::now(),
            last_launched_at: None,
            last_identity_mode: None,
            memory_mib: None,
            java_runtime: None,
            jvm_arguments: None,
            launch: InstanceLaunchSettings::default(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Instance {
    pub manifest: InstanceManifest,
    pub directory: std::path::PathBuf,
    pub game_directory: std::path::PathBuf,
}

impl Instance {
    pub fn id(&self) -> &str {
        &self.manifest.id
    }

    pub fn mods_directory(&self) -> std::path::PathBuf {
        self.game_directory.join("mods")
    }

    pub fn disabled_mods_directory(&self) -> std::path::PathBuf {
        self.directory.join("mods-disabled")
    }

    pub fn mods_metadata(&self) -> std::path::PathBuf {
        self.directory.join("mods.json")
    }

    pub fn logs_directory(&self) -> std::path::PathBuf {
        self.game_directory.join("logs")
    }
}

pub const MIN_MEMORY_MIB: u32 = 256;
pub const MAX_MEMORY_MIB: u32 = 65536;

/// Memory policy shared by the GUI slider and the CLI tuner.
pub struct InstanceMemory;

impl InstanceMemory {
    /// Automatic allocation: 1/4 of physical memory, clamped to 2 GiB..8 GiB.
    pub fn automatic_mib() -> u32 {
        let total = physical_memory_mib().unwrap_or(8192);
        (total / 4).clamp(2048, 8192)
    }

    pub fn validate(mib: u32) -> Result<u32> {
        if !(MIN_MEMORY_MIB..=MAX_MEMORY_MIB).contains(&mib) {
            return Err(Error::InvalidMetadata(format!(
                "memory {mib} MiB outside {MIN_MEMORY_MIB}..{MAX_MEMORY_MIB}"
            )));
        }
        Ok(mib)
    }
}

#[cfg(target_os = "macos")]
fn physical_memory_mib() -> Option<u32> {
    let output = std::process::Command::new("sysctl")
        .arg("-n")
        .arg("hw.memsize")
        .output()
        .ok()?;
    let text = String::from_utf8(output.stdout).ok()?;
    let bytes: u64 = text.trim().parse().ok()?;
    Some((bytes / 1024 / 1024) as u32)
}

#[cfg(target_os = "windows")]
fn physical_memory_mib() -> Option<u32> {
    fn parse_bytes(text: &str) -> Option<u64> {
        text.lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .find_map(|line| {
                let value = line.rsplit('=').next().unwrap_or(line).trim();
                value.parse::<u64>().ok()
            })
    }

    fn run(program: &str, args: &[&str]) -> Option<u64> {
        let output = std::process::Command::new(program)
            .args(args)
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        parse_bytes(&String::from_utf8_lossy(&output.stdout))
    }

    let bytes = run(
        "powershell",
        &[
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory",
        ],
    )
    .or_else(|| {
        run(
            "wmic",
            &["computersystem", "get", "TotalPhysicalMemory", "/value"],
        )
    })
    .or_else(|| {
        run(
            "powershell",
            &[
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "(Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize",
            ],
        )
        .map(|kib| kib.saturating_mul(1024))
    })?;
    let mib = bytes / 1024 / 1024;
    (mib > 0).then_some(mib.min(u32::MAX as u64) as u32)
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn physical_memory_mib() -> Option<u32> {
    let text = std::fs::read_to_string("/proc/meminfo").ok()?;
    let kb: u64 = text
        .lines()
        .find(|l| l.starts_with("MemTotal:"))?
        .split_whitespace()
        .nth(1)?
        .parse()
        .ok()?;
    Some((kb / 1024) as u32)
}

/// Creates, loads and lists instances under `<dataRoot>/instances`.
pub struct InstanceRepository {
    pub layout: GameDataLayout,
}

impl InstanceRepository {
    pub fn new(layout: GameDataLayout) -> Self {
        Self { layout }
    }

    pub fn create(
        &self,
        id: &str,
        display_name: &str,
        version_id: Option<&str>,
    ) -> Result<Instance> {
        let component = PathSafety::validate_component(id)?;
        let directory = self.layout.instance_directory(component)?;
        if directory.exists() {
            return Err(Error::Other(format!(
                "instance '{component}' already exists at {}",
                directory.display()
            )));
        }
        if let Some(version) = version_id {
            PathSafety::validate_component(version)?;
        }
        let manifest =
            InstanceManifest::new(component, display_name, version_id.map(str::to_string));
        let instance = Instance {
            manifest,
            directory,
            game_directory: self.layout.instance_game_directory(component)?,
        };
        crate::layout::ensure_dir(&instance.directory)?;
        crate::layout::ensure_dir(&instance.game_directory)?;
        crate::layout::ensure_dir(&instance.logs_directory())?;
        self.write_manifest(&instance.manifest, &instance.directory)?;
        Ok(instance)
    }

    pub fn create_with_generated_id(&self, display_name: &str) -> Result<Instance> {
        let base: String = display_name
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                    c
                } else {
                    '-'
                }
            })
            .collect();
        let base = base.trim_matches('-');
        let base = if base.is_empty() {
            "instance".to_string()
        } else {
            base.to_ascii_lowercase()
        };
        let id = if self.layout.instance_directory(&base)?.exists() {
            format!("{base}-{}", &uuid::Uuid::new_v4().simple().to_string()[..6])
        } else {
            base
        };
        self.create(&id, display_name, None)
    }

    pub fn load(&self, id: &str) -> Result<Instance> {
        let component = PathSafety::validate_component(id)?;
        let directory = self.layout.instance_directory(component)?;
        let manifest_path = self.layout.instance_manifest(component)?;
        if !manifest_path.exists() {
            return Err(Error::NotFound(format!(
                "instance '{component}' at {}",
                directory.display()
            )));
        }
        let data = std::fs::read(&manifest_path)?;
        let manifest: InstanceManifest = serde_json::from_slice(&data).map_err(|e| {
            Error::InvalidMetadata(format!(
                "corrupted instance manifest {}: {e}",
                manifest_path.display()
            ))
        })?;
        if manifest.id != component {
            return Err(Error::InvalidMetadata(format!(
                "instance manifest id '{}' does not match directory '{component}'",
                manifest.id
            )));
        }
        let game_directory = self.layout.instance_game_directory(component)?;
        crate::layout::ensure_dir(&game_directory)?;
        crate::layout::ensure_dir(&game_directory.join("logs"))?;
        Ok(Instance {
            manifest,
            directory,
            game_directory,
        })
    }

    pub fn list(&self) -> Result<Vec<Instance>> {
        let root = self.layout.instances_directory();
        if !root.is_dir() {
            return Ok(Vec::new());
        }
        let mut names: Vec<String> = std::fs::read_dir(&root)?
            .filter_map(|e| e.ok())
            .filter(|e| e.path().is_dir())
            .filter_map(|e| e.file_name().to_str().map(str::to_string))
            .collect();
        names.sort();
        Ok(names
            .iter()
            .filter_map(|name| self.load(name).ok())
            .collect())
    }

    pub fn save(&self, manifest: &InstanceManifest) -> Result<()> {
        let directory = self.layout.instance_directory(&manifest.id)?;
        self.write_manifest(manifest, &directory)
    }

    fn write_manifest(
        &self,
        manifest: &InstanceManifest,
        directory: &std::path::Path,
    ) -> Result<()> {
        crate::layout::ensure_dir(directory)?;
        let data = serde_json::to_vec_pretty(manifest)?;
        let target = directory.join("instance.json");
        let temporary = directory.join("instance.json.tmp");
        std::fs::write(&temporary, data)?;
        std::fs::rename(&temporary, &target)?;
        Ok(())
    }

    pub fn assign_version(&self, instance: &Instance, version_id: &str) -> Result<Instance> {
        PathSafety::validate_component(version_id)?;
        let mut manifest = instance.manifest.clone();
        manifest.version_id = Some(version_id.to_string());
        self.save(&manifest)?;
        let mut next = instance.clone();
        next.manifest = manifest;
        Ok(next)
    }

    pub fn set_game_version(&self, instance: &Instance, game_version: &str) -> Result<()> {
        let mut manifest = instance.manifest.clone();
        manifest.game_version = Some(game_version.to_string());
        self.save(&manifest)
    }

    pub fn set_performance(
        &self,
        instance: &Instance,
        memory_mib: Option<u32>,
        jvm_arguments: Vec<String>,
    ) -> Result<Instance> {
        for argument in &jvm_arguments {
            if argument.contains('\n') || argument.contains('\0') {
                return Err(Error::InvalidMetadata(
                    "JVM argument contains control characters".into(),
                ));
            }
            if argument.starts_with("-Xmx") || argument.starts_with("-Xms") {
                return Err(Error::InvalidMetadata(
                    "-Xmx/-Xms are managed by the memory setting".into(),
                ));
            }
        }
        let mut manifest = instance.manifest.clone();
        manifest.memory_mib = memory_mib.map(InstanceMemory::validate).transpose()?;
        manifest.jvm_arguments = if jvm_arguments.is_empty() {
            None
        } else {
            Some(jvm_arguments)
        };
        self.save(&manifest)?;
        let mut next = instance.clone();
        next.manifest = manifest;
        Ok(next)
    }

    pub fn set_memory(&self, instance: &Instance, memory_mib: Option<u32>) -> Result<Instance> {
        let args = instance.manifest.jvm_arguments.clone().unwrap_or_default();
        self.set_performance(instance, memory_mib, args)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_roundtrip_is_camel_case() {
        let manifest = InstanceManifest::new("a", "A", Some("1.21.1".into()));
        let text = serde_json::to_string(&manifest).unwrap();
        assert!(text.contains("displayName"));
        let back: InstanceManifest = serde_json::from_str(&text).unwrap();
        assert_eq!(back.id, "a");
        assert!(back.game_version.is_none());
    }

    #[test]
    fn game_version_roundtrip_is_camel_case() {
        let mut manifest =
            InstanceManifest::new("a", "A", Some("fabric-loader-0.16.9-1.21.11".into()));
        manifest.game_version = Some("1.21.11".into());
        let text = serde_json::to_string(&manifest).unwrap();
        assert!(text.contains("gameVersion"));
        let back: InstanceManifest = serde_json::from_str(&text).unwrap();
        assert_eq!(back.game_version.as_deref(), Some("1.21.11"));
    }

    #[test]
    fn memory_bounds() {
        assert!(InstanceMemory::validate(128).is_err());
        assert!(InstanceMemory::validate(2048).is_ok());
    }
}
