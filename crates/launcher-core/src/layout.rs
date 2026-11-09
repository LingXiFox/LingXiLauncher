use std::path::{Path, PathBuf};

use crate::error::{Error, Result};
use crate::paths::PathSafety;

/// Canonical on-disk layout shared by the GUI and CLI. Every path is derived
/// here so the two front-ends can never disagree about where data lives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GameDataLayout {
    pub game_root: PathBuf,
    pub data_root: PathBuf,
}

impl GameDataLayout {
    pub fn new(game_root: impl Into<PathBuf>, data_root: impl Into<PathBuf>) -> Self {
        Self { game_root: game_root.into(), data_root: data_root.into() }
    }

    pub fn default_data_root() -> PathBuf {
        dirs_data_root()
    }

    /// `~/Library/Application Support/minecraft` on macOS, `%APPDATA%\.minecraft` on Windows.
    pub fn official_minecraft_root() -> PathBuf {
        dirs_minecraft_root()
    }

    pub fn from_environment() -> Self {
        let data_root = std::env::var_os("LINGXI_DATA_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(Self::default_data_root);
        let game_root = std::env::var_os("LINGXI_GAME_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                let official = Self::official_minecraft_root();
                if official.is_dir() {
                    official
                } else {
                    data_root.join("minecraft")
                }
            });
        Self::new(game_root, data_root)
    }

    pub fn versions_directory(&self) -> PathBuf {
        self.game_root.join("versions")
    }

    pub fn version_directory(&self, version_id: &str) -> Result<PathBuf> {
        PathSafety::validate_component(version_id)?;
        Ok(self.versions_directory().join(version_id))
    }

    pub fn version_json(&self, version_id: &str) -> Result<PathBuf> {
        Ok(self.version_directory(version_id)?.join(format!("{version_id}.json")))
    }

    pub fn client_jar(&self, version_id: &str) -> Result<PathBuf> {
        Ok(self.version_directory(version_id)?.join(format!("{version_id}.jar")))
    }

    pub fn libraries_directory(&self) -> PathBuf {
        self.game_root.join("libraries")
    }

    pub fn library_path(&self, relative: &str) -> Result<PathBuf> {
        PathSafety::safe_join(&self.libraries_directory(), relative)
    }

    pub fn assets_directory(&self) -> PathBuf {
        self.game_root.join("assets")
    }

    pub fn asset_indexes_directory(&self) -> PathBuf {
        self.assets_directory().join("indexes")
    }

    pub fn asset_index_path(&self, id: &str) -> Result<PathBuf> {
        Ok(self.asset_indexes_directory().join(format!("{}.json", PathSafety::validate_component(id)?)))
    }

    pub fn asset_objects_directory(&self) -> PathBuf {
        self.assets_directory().join("objects")
    }

    pub fn asset_object_path(&self, hash: &str) -> Result<PathBuf> {
        if hash.len() < 2 || !hash.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(Error::InvalidMetadata(format!("bad asset hash {hash}")));
        }
        Ok(self.asset_objects_directory().join(&hash[0..2]).join(hash))
    }

    pub fn log_configs_directory(&self) -> PathBuf {
        self.assets_directory().join("log_configs")
    }

    pub fn natives_directory(&self, version_id: &str, architecture: &str) -> Result<PathBuf> {
        Ok(self
            .data_root
            .join("natives")
            .join(PathSafety::validate_component(version_id)?)
            .join(PathSafety::validate_component(architecture)?))
    }

    pub fn instances_directory(&self) -> PathBuf {
        self.data_root.join("instances")
    }

    pub fn instance_directory(&self, instance_id: &str) -> Result<PathBuf> {
        Ok(self.instances_directory().join(PathSafety::validate_component(instance_id)?))
    }

    pub fn instance_manifest(&self, instance_id: &str) -> Result<PathBuf> {
        Ok(self.instance_directory(instance_id)?.join("instance.json"))
    }

    /// Isolated game directory: `<dataRoot>/.minecraft/versions/<instance-id>`.
    pub fn instance_game_directory(&self, instance_id: &str) -> Result<PathBuf> {
        Ok(self
            .data_root
            .join(".minecraft")
            .join("versions")
            .join(PathSafety::validate_component(instance_id)?))
    }

    pub fn instance_logs_directory(&self, instance_id: &str) -> Result<PathBuf> {
        Ok(self.instance_directory(instance_id)?.join("logs"))
    }

    pub fn accounts_directory(&self) -> PathBuf {
        self.data_root.join("accounts")
    }

    pub fn local_accounts_directory(&self) -> PathBuf {
        self.accounts_directory().join("local")
    }

    pub fn microsoft_accounts_directory(&self) -> PathBuf {
        self.accounts_directory().join("microsoft")
    }

    pub fn cache_directory(&self) -> PathBuf {
        self.data_root.join("cache")
    }

    pub fn manifests_cache_directory(&self) -> PathBuf {
        self.cache_directory().join("manifests")
    }

    pub fn downloads_cache_directory(&self) -> PathBuf {
        self.cache_directory().join("downloads")
    }

    pub fn logs_directory(&self) -> PathBuf {
        self.data_root.join("logs").join("launcher")
    }

    pub fn backups_directory(&self) -> PathBuf {
        self.data_root.join("backups")
    }

    pub fn settings_file(&self) -> PathBuf {
        self.data_root.join("settings.json")
    }

    pub fn java_directory(&self) -> PathBuf {
        self.data_root.join("java")
    }
}

#[cfg(target_os = "macos")]
fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default()
}

#[cfg(target_os = "windows")]
fn home() -> PathBuf {
    std::env::var_os("USERPROFILE").map(PathBuf::from).unwrap_or_default()
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default()
}

fn dirs_data_root() -> PathBuf {
    if cfg!(target_os = "macos") {
        home().join("Library").join("Application Support").join("LingXiLauncher")
    } else if cfg!(target_os = "windows") {
        std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(home)
            .join("LingXiLauncher")
    } else {
        std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home().join(".local").join("share"))
            .join("lingxi-launcher")
    }
}

fn dirs_minecraft_root() -> PathBuf {
    if cfg!(target_os = "windows") {
        std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_else(home).join(".minecraft")
    } else if cfg!(target_os = "macos") {
        home().join("Library").join("Application Support").join("minecraft")
    } else {
        home().join(".minecraft")
    }
}

pub fn ensure_dir(path: &Path) -> Result<()> {
    std::fs::create_dir_all(path).map_err(|e| Error::Io(std::io::Error::new(e.kind(), format!("create {}: {e}", path.display()))))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_are_isolated() {
        let layout = GameDataLayout::new("/tmp/game", "/tmp/data");
        assert_eq!(layout.instance_game_directory("abc").unwrap(), PathBuf::from("/tmp/data/.minecraft/versions/abc"));
        assert_eq!(layout.asset_object_path("abcdef").unwrap(), PathBuf::from("/tmp/game/assets/objects/ab/abcdef"));
        assert!(layout.instance_directory("../x").is_err());
    }
}
