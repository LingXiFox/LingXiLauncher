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
    #[serde(default)]
    pub source: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstanceManifest {
    pub id: String,
    pub display_name: String,
    #[serde(default)]
    pub version_id: Option<String>,
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
}

impl InstanceManifest {
    pub fn new(id: impl Into<String>, display_name: impl Into<String>, version_id: Option<String>) -> Self {
        Self {
            id: id.into(),
            display_name: display_name.into(),
            version_id,
            created_at: Utc::now(),
            last_launched_at: None,
            last_identity_mode: None,
            memory_mib: None,
            java_runtime: None,
            jvm_arguments: None,
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
        self.directory.join("logs")
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
    let output = std::process::Command::new("sysctl").arg("-n").arg("hw.memsize").output().ok()?;
    let text = String::from_utf8(output.stdout).ok()?;
    let bytes: u64 = text.trim().parse().ok()?;
    Some((bytes / 1024 / 1024) as u32)
}

#[cfg(target_os = "windows")]
fn physical_memory_mib() -> Option<u32> {
    None
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn physical_memory_mib() -> Option<u32> {
    let text = std::fs::read_to_string("/proc/meminfo").ok()?;
    let kb: u64 = text.lines().find(|l| l.starts_with("MemTotal:"))?.split_whitespace().nth(1)?.parse().ok()?;
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

    pub fn create(&self, id: &str, display_name: &str, version_id: Option<&str>) -> Result<Instance> {
        let component = PathSafety::validate_component(id)?;
        let directory = self.layout.instance_directory(component)?;
        if directory.exists() {
            return Err(Error::Other(format!("instance '{component}' already exists at {}", directory.display())));
        }
        if let Some(version) = version_id {
            PathSafety::validate_component(version)?;
        }
        let manifest = InstanceManifest::new(component, display_name, version_id.map(str::to_string));
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
            .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '-' })
            .collect();
        let base = base.trim_matches('-');
        let base = if base.is_empty() { "instance".to_string() } else { base.to_ascii_lowercase() };
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
            return Err(Error::NotFound(format!("instance '{component}' at {}", directory.display())));
        }
        let data = std::fs::read(&manifest_path)?;
        let manifest: InstanceManifest = serde_json::from_slice(&data)
            .map_err(|e| Error::InvalidMetadata(format!("corrupted instance manifest {}: {e}", manifest_path.display())))?;
        if manifest.id != component {
            return Err(Error::InvalidMetadata(format!(
                "instance manifest id '{}' does not match directory '{component}'",
                manifest.id
            )));
        }
        let game_directory = self.layout.instance_game_directory(component)?;
        crate::layout::ensure_dir(&game_directory)?;
        crate::layout::ensure_dir(&directory.join("logs"))?;
        Ok(Instance { manifest, directory, game_directory })
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
        Ok(names.iter().filter_map(|name| self.load(name).ok()).collect())
    }

    pub fn save(&self, manifest: &InstanceManifest) -> Result<()> {
        let directory = self.layout.instance_directory(&manifest.id)?;
        self.write_manifest(manifest, &directory)
    }

    fn write_manifest(&self, manifest: &InstanceManifest, directory: &std::path::Path) -> Result<()> {
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

    pub fn set_performance(
        &self,
        instance: &Instance,
        memory_mib: Option<u32>,
        jvm_arguments: Vec<String>,
    ) -> Result<Instance> {
        for argument in &jvm_arguments {
            if argument.contains('\n') || argument.contains('\0') {
                return Err(Error::InvalidMetadata("JVM argument contains control characters".into()));
            }
            if argument.starts_with("-Xmx") || argument.starts_with("-Xms") {
                return Err(Error::InvalidMetadata("-Xmx/-Xms are managed by the memory setting".into()));
            }
        }
        let mut manifest = instance.manifest.clone();
        manifest.memory_mib = memory_mib.map(InstanceMemory::validate).transpose()?;
        manifest.jvm_arguments = if jvm_arguments.is_empty() { None } else { Some(jvm_arguments) };
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
    }

    #[test]
    fn memory_bounds() {
        assert!(InstanceMemory::validate(128).is_err());
        assert!(InstanceMemory::validate(2048).is_ok());
    }
}
