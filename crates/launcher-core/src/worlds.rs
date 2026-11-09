//! World (single-player save) discovery, backup and restore.
//!
//! Minecraft stores one world per directory below `<gameDir>/saves`. The
//! metadata lives in `level.dat`, a gzipped NBT document. This module ships a
//! small, dependency-free gzip/DEFLATE decoder and enough NBT support to read
//! the `Data` compound; malformed saves degrade to directory-name metadata
//! instead of making the whole instance unusable.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};

use chrono::{DateTime, NaiveDateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::install::zip::extract_zip;
use crate::layout::{ensure_dir, GameDataLayout};
use crate::models::instance::Instance;
use crate::paths::PathSafety;
use sha2::{Digest, Sha256};
/// Size ceiling for `level.dat` after decompression. Vanilla files are a few
/// kilobytes; anything larger is treated as corrupt rather than expanded.
const MAX_LEVEL_DAT_BYTES: usize = 64 * 1024 * 1024;
const MAX_NBT_DEPTH: u32 = 64;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorldSummary {
    pub folder_name: String,
    pub name: String,
    /// Lowercase vanilla game mode: `survival`, `creative`, `adventure`,
    /// `spectator`, or `unknown` when `level.dat` could not be read.
    pub game_mode: String,
    #[serde(default)]
    pub last_played: Option<DateTime<Utc>>,
    #[serde(default)]
    pub version_name: Option<String>,
    pub size_bytes: u64,
    #[serde(default)]
    pub last_modified: Option<DateTime<Utc>>,
    #[serde(default)]
    pub hardcore: bool,
    #[serde(default)]
    pub allow_commands: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorldBackup {
    /// File name relative to `<dataRoot>/backups/<instance-id>/`.
    pub file_name: String,
    /// World folder encoded in the file name; used when restoring.
    pub world_folder: String,
    pub size_bytes: u64,
    #[serde(default)]
    pub created_at: Option<DateTime<Utc>>,
}

impl WorldBackup {
    fn from_zip(path: &Path) -> Option<Self> {
        let file_name = path.file_name()?.to_str()?.to_string();
        if !file_name.to_ascii_lowercase().ends_with(".zip") {
            return None;
        }
        let stem = file_name.strip_suffix(".zip")?;
        let (world_folder, _) = split_backup_stem(stem);
        let metadata = std::fs::symlink_metadata(path).ok()?;
        if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
            return None;
        }
        let created_at = metadata.modified().ok().map(DateTime::<Utc>::from);
        Some(Self {
            file_name,
            world_folder,
            size_bytes: metadata.len(),
            created_at,
        })
    }

    /// Reads a Swift-style directory backup: `<backup-id>/manifest.json` plus
    /// `<backup-id>/world/`. Legacy Rust zip backups remain supported.
    fn from_directory(path: &Path) -> Option<Self> {
        let file_name = path.file_name()?.to_str()?.to_string();
        let metadata = std::fs::symlink_metadata(path).ok()?;
        if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
            return None;
        }
        let manifest = read_backup_manifest(path).ok()?;
        Some(Self {
            file_name,
            world_folder: manifest.world_name,
            size_bytes: manifest.total_bytes,
            created_at: Some(manifest.created_at),
        })
    }

    fn from_entry(path: &Path) -> Option<Self> {
        Self::from_directory(path).or_else(|| Self::from_zip(path))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredBackupManifest {
    #[serde(default = "default_backup_schema")]
    schema_version: u32,
    #[serde(default)]
    id: String,
    #[serde(default, rename = "instanceID")]
    instance_id: String,
    #[serde(default)]
    world_name: String,
    created_at: DateTime<Utc>,
    #[serde(default)]
    file_count: u64,
    #[serde(default)]
    total_bytes: u64,
    #[serde(default)]
    files: Vec<StoredBackupFile>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredBackupFile {
    relative_path: String,
    byte_count: u64,
    sha256: String,
}

fn default_backup_schema() -> u32 {
    1
}

fn read_backup_manifest(directory: &Path) -> Result<StoredBackupManifest> {
    let path = directory.join("manifest.json");
    let bytes = std::fs::read(&path)
        .map_err(|_| Error::NotFound(format!("backup manifest {}", path.display())))?;
    let manifest: StoredBackupManifest = serde_json::from_slice(&bytes)?;
    let directory_name = directory
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    if manifest.id != directory_name {
        return Err(Error::InvalidMetadata(format!(
            "backup manifest id '{}' does not match directory '{}'",
            manifest.id, directory_name
        )));
    }
    Ok(manifest)
}

fn write_backup_manifest(directory: &Path, manifest: &StoredBackupManifest) -> Result<()> {
    let bytes = serde_json::to_vec_pretty(manifest)?;
    std::fs::write(directory.join("manifest.json"), bytes)?;
    Ok(())
}

fn sha256_file(path: &Path) -> Result<String> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn snapshot_directory(root: &Path) -> Result<Vec<StoredBackupFile>> {
    fn walk(root: &Path, current: &Path, files: &mut Vec<StoredBackupFile>) -> Result<()> {
        let mut entries: Vec<_> =
            std::fs::read_dir(current)?.collect::<std::result::Result<_, _>>()?;
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            let path = entry.path();
            let file_type = entry.file_type()?;
            if file_type.is_symlink() {
                return Err(Error::UnsafePath(format!(
                    "symbolic link inside world backup: {}",
                    path.display()
                )));
            }
            if file_type.is_dir() {
                walk(root, &path, files)?;
            } else if file_type.is_file() {
                let relative = path.strip_prefix(root).map_err(|_| {
                    Error::UnsafePath(format!("{} escapes the backup root", path.display()))
                })?;
                let relative_path = relative
                    .components()
                    .map(|component| component.as_os_str().to_string_lossy().into_owned())
                    .collect::<Vec<_>>()
                    .join("/");
                let metadata = entry.metadata()?;
                files.push(StoredBackupFile {
                    relative_path,
                    byte_count: metadata.len(),
                    sha256: sha256_file(&path)?,
                });
            }
        }
        Ok(())
    }

    let mut files = Vec::new();
    walk(root, root, &mut files)?;
    files.sort_by(|left, right| left.relative_path.cmp(&right.relative_path));
    Ok(files)
}

fn copy_directory_checked(source: &Path, destination: &Path) -> Result<()> {
    ensure_dir(destination)?;
    let mut entries: Vec<_> = std::fs::read_dir(source)?.collect::<std::result::Result<_, _>>()?;
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let path = entry.path();
        let file_type = entry.file_type()?;
        if file_type.is_symlink() {
            return Err(Error::UnsafePath(format!(
                "symbolic link inside world backup: {}",
                path.display()
            )));
        }
        let target = destination.join(entry.file_name());
        if file_type.is_dir() {
            copy_directory_checked(&path, &target)?;
        } else if file_type.is_file() {
            std::fs::copy(&path, &target)?;
        }
    }
    Ok(())
}
fn verify_backup_files(root: &Path, expected: &[StoredBackupFile]) -> Result<()> {
    let actual = snapshot_directory(root)?;
    if actual.len() != expected.len() {
        return Err(Error::InvalidMetadata(
            "backup file list does not match manifest".into(),
        ));
    }
    let expected: BTreeMap<&str, &StoredBackupFile> = expected
        .iter()
        .map(|file| (file.relative_path.as_str(), file))
        .collect();
    for file in &actual {
        let Some(wanted) = expected.get(file.relative_path.as_str()) else {
            return Err(Error::InvalidMetadata(format!(
                "backup file '{}' is not listed in manifest",
                file.relative_path
            )));
        };
        if wanted.byte_count != file.byte_count || wanted.sha256 != file.sha256 {
            return Err(Error::InvalidMetadata(format!(
                "backup file failed checksum: {}",
                file.relative_path
            )));
        }
    }
    Ok(())
}

/// Manages the saves and backups of one instance. The layout is stored so the
/// backup destination stays outside the game directory.
#[derive(Debug, Clone)]
pub struct WorldManager {
    layout: GameDataLayout,
}

impl WorldManager {
    pub fn new(layout: GameDataLayout) -> Self {
        Self { layout }
    }

    pub fn saves_directory(&self, instance: &Instance) -> PathBuf {
        instance.game_directory.join("saves")
    }

    /// `<dataRoot>/backups/<instance-id>`.
    pub fn backups_directory(&self, instance: &Instance) -> Result<PathBuf> {
        let id = PathSafety::validate_component(instance.id())?;
        Ok(self.layout.backups_directory().join(id))
    }

    /// Lists direct child directories of `saves`, newest world first. Missing
    /// save folders are an empty list, never an error.
    pub fn list(&self, instance: &Instance) -> Result<Vec<WorldSummary>> {
        let saves = self.saves_directory(instance);
        if !saves.is_dir() {
            return Ok(Vec::new());
        }
        let mut worlds = Vec::new();
        for entry in std::fs::read_dir(&saves)? {
            let entry = match entry {
                Ok(entry) => entry,
                Err(_) => continue,
            };
            let file_type = match entry.file_type() {
                Ok(file_type) => file_type,
                Err(_) => continue,
            };
            if !file_type.is_dir() || file_type.is_symlink() {
                continue;
            }
            let folder_name = match entry.file_name().into_string() {
                Ok(name) => name,
                Err(_) => continue,
            };
            if folder_name.starts_with('.') || PathSafety::validate_component(&folder_name).is_err()
            {
                continue;
            }
            worlds.push(read_world_summary(&entry.path(), &folder_name));
        }
        worlds.sort_by(|left, right| {
            right
                .last_played
                .cmp(&left.last_played)
                .then_with(|| left.folder_name.cmp(&right.folder_name))
        });
        Ok(worlds)
    }

    /// Zips one world into `<dataRoot>/backups/<instance-id>/<folder>-<timestamp>.zip`.
    /// Only regular files and directories inside the world folder are included;
    /// symlinks are skipped so an archive can never reference data outside it.
    pub fn backup(&self, instance: &Instance, folder_name: &str) -> Result<WorldBackup> {
        let folder = PathSafety::validate_component(folder_name)?.to_string();
        let saves = self.saves_directory(instance);
        let world_directory = PathSafety::safe_join(&saves, &folder)?;
        let metadata = std::fs::symlink_metadata(&world_directory)
            .map_err(|_| Error::NotFound(format!("world '{folder}' in {}", saves.display())))?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(Error::UnsafePath(format!(
                "world '{}' is not a plain directory",
                world_directory.display()
            )));
        }

        let backups = self.backups_directory(instance)?;
        ensure_dir(&backups)?;

        let created_at = Utc::now();
        let id = format!(
            "{}-{}",
            created_at.format("%Y%m%d-%H%M%S"),
            &uuid::Uuid::new_v4().simple().to_string()[..8]
        );
        let target = backups.join(&id);
        if target.exists() {
            return Err(Error::Other(format!(
                "backup '{}' already exists",
                target.display()
            )));
        }
        let temporary = backups.join(format!(".tmp-{}", uuid::Uuid::new_v4().simple()));
        let result = (|| -> Result<(u64, Vec<StoredBackupFile>)> {
            ensure_dir(&temporary)?;
            let copied_world = temporary.join("world");
            copy_directory_checked(&world_directory, &copied_world)?;
            let files = snapshot_directory(&copied_world)?;
            let total_bytes = files.iter().map(|file| file.byte_count).sum();
            let manifest = StoredBackupManifest {
                schema_version: 1,
                id: id.clone(),
                instance_id: instance.id().to_string(),
                world_name: folder.clone(),
                created_at,
                file_count: files.len() as u64,
                total_bytes,
                files,
            };
            write_backup_manifest(&temporary, &manifest)?;
            std::fs::rename(&temporary, &target)?;
            Ok((total_bytes, manifest.files))
        })();
        let (size_bytes, _) = match result {
            Ok(value) => value,
            Err(error) => {
                let _ = std::fs::remove_dir_all(&temporary);
                return Err(error);
            }
        };
        Ok(WorldBackup {
            file_name: id,
            world_folder: folder,
            size_bytes,
            created_at: Some(created_at),
        })
    }

    /// Backs up every valid world, returning one entry per archive.
    pub fn backup_all(&self, instance: &Instance) -> Result<Vec<WorldBackup>> {
        let mut backups = Vec::new();
        for world in self.list(instance)? {
            backups.push(self.backup(instance, &world.folder_name)?);
        }
        Ok(backups)
    }

    pub fn list_backups(&self, instance: &Instance) -> Result<Vec<WorldBackup>> {
        let directory = self.backups_directory(instance)?;
        if !directory.is_dir() {
            return Ok(Vec::new());
        }
        let mut backups = Vec::new();
        for entry in std::fs::read_dir(&directory)? {
            let entry = match entry {
                Ok(entry) => entry,
                Err(_) => continue,
            };
            if let Some(backup) = WorldBackup::from_entry(&entry.path()) {
                backups.push(backup);
            }
        }
        backups.sort_by(|left, right| {
            right
                .created_at
                .cmp(&left.created_at)
                .then_with(|| right.file_name.cmp(&left.file_name))
        });
        Ok(backups)
    }

    /// Extracts a backup into a staging directory and only then moves it into
    /// `saves`, so a failed restore never leaves a half-written world behind.
    /// An existing world with the same folder name is never overwritten.
    pub fn restore_backup(&self, instance: &Instance, file_name: &str) -> Result<WorldSummary> {
        let name = PathSafety::validate_component(file_name)?;
        let backups = self.backups_directory(instance)?;
        let archive = PathSafety::safe_join(&backups, name)?;
        let metadata = std::fs::symlink_metadata(&archive)
            .map_err(|_| Error::NotFound(format!("backup {}", archive.display())))?;
        if metadata.file_type().is_symlink() {
            return Err(Error::UnsafePath(format!(
                "backup {} is a symbolic link",
                archive.display()
            )));
        }
        if metadata.is_dir() {
            return self.restore_directory_backup(instance, &archive, name);
        }
        if !name.to_ascii_lowercase().ends_with(".zip") {
            return Err(Error::InvalidMetadata(format!("not a zip backup: {name}")));
        }
        if !metadata.is_file() {
            return Err(Error::UnsafePath(format!(
                "backup {} is not a regular file",
                archive.display()
            )));
        }

        let stem = name.strip_suffix(".zip").unwrap_or(name);
        let (folder, _) = split_backup_stem(stem);
        let folder = if folder.is_empty() {
            "restored-world".to_string()
        } else {
            folder
        };
        PathSafety::validate_component(&folder)?;

        let saves = self.saves_directory(instance);
        ensure_dir(&saves)?;
        let target = PathSafety::safe_join(&saves, &folder)?;
        if target.exists() {
            return Err(Error::Other(format!(
                "world '{folder}' already exists; delete it before restoring the backup"
            )));
        }

        let staging = saves.join(format!(".restore-{}", uuid::Uuid::new_v4().simple()));
        let result = (|| -> Result<()> {
            extract_zip(&archive, &staging, &[])?;
            if !staging.join("level.dat").is_file() {
                return Err(Error::InvalidMetadata(
                    "backup does not contain a level.dat at its root".into(),
                ));
            }
            std::fs::rename(&staging, &target)?;
            Ok(())
        })();
        if result.is_err() {
            let _ = std::fs::remove_dir_all(&staging);
        }
        result?;
        Ok(read_world_summary(&target, &folder))
    }

    /// Restores a Swift-format directory backup after verifying every file
    /// against `manifest.json`. The original world is never overwritten.
    fn restore_directory_backup(
        &self,
        instance: &Instance,
        backup_directory: &Path,
        backup_id: &str,
    ) -> Result<WorldSummary> {
        let manifest = read_backup_manifest(backup_directory)?;
        if !manifest.instance_id.is_empty() && manifest.instance_id != instance.id() {
            return Err(Error::InvalidMetadata(format!(
                "backup '{backup_id}' belongs to instance '{}'",
                manifest.instance_id
            )));
        }
        let world = backup_directory.join("world");
        if !world.is_dir() {
            return Err(Error::InvalidMetadata(
                "backup world directory is missing".into(),
            ));
        }
        verify_backup_files(&world, &manifest.files)?;

        let folder = manifest.world_name;
        PathSafety::validate_component(&folder)?;
        let saves = self.saves_directory(instance);
        ensure_dir(&saves)?;
        let target = PathSafety::safe_join(&saves, &folder)?;
        if target.exists() {
            return Err(Error::Other(format!(
                "world '{folder}' already exists; delete it before restoring the backup"
            )));
        }

        let staging = saves.join(format!(".restore-{}", uuid::Uuid::new_v4().simple()));
        let result = (|| -> Result<()> {
            copy_directory_checked(&world, &staging)?;
            verify_backup_files(&staging, &manifest.files)?;
            if !staging.join("level.dat").is_file() {
                return Err(Error::InvalidMetadata(
                    "backup does not contain a level.dat at its root".into(),
                ));
            }
            std::fs::rename(&staging, &target)?;
            Ok(())
        })();
        if result.is_err() {
            let _ = std::fs::remove_dir_all(&staging);
        }
        result?;
        Ok(read_world_summary(&target, &folder))
    }

    /// Removes a world. Only a direct, non-symlink child of `saves` is accepted.
    pub fn delete_world(&self, instance: &Instance, folder_name: &str) -> Result<()> {
        let folder = PathSafety::validate_component(folder_name)?;
        let saves = self.saves_directory(instance);
        let world = PathSafety::safe_join(&saves, folder)?;
        let metadata = std::fs::symlink_metadata(&world)
            .map_err(|_| Error::NotFound(format!("world '{}'", world.display())))?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(Error::UnsafePath(format!(
                "world '{}' is not a plain directory",
                world.display()
            )));
        }
        std::fs::remove_dir_all(&world)?;
        Ok(())
    }

    pub fn delete_backup(&self, instance: &Instance, file_name: &str) -> Result<()> {
        let name = PathSafety::validate_component(file_name)?;
        let directory = self.backups_directory(instance)?;
        let path = PathSafety::safe_join(&directory, name)?;
        let metadata = std::fs::symlink_metadata(&path)
            .map_err(|_| Error::NotFound(format!("backup '{}'", path.display())))?;
        if metadata.file_type().is_symlink() {
            return Err(Error::UnsafePath(format!(
                "backup '{}' is a symbolic link",
                path.display()
            )));
        }
        if metadata.is_dir() {
            let manifest = read_backup_manifest(&path)?;
            if !manifest.instance_id.is_empty() && manifest.instance_id != instance.id() {
                return Err(Error::InvalidMetadata(format!(
                    "backup '{}' belongs to instance '{}'",
                    name, manifest.instance_id
                )));
            }
            std::fs::remove_dir_all(&path)?;
            return Ok(());
        }
        if !name.to_ascii_lowercase().ends_with(".zip") {
            return Err(Error::InvalidMetadata(format!("not a zip backup: {name}")));
        }
        if !metadata.is_file() {
            return Err(Error::UnsafePath(format!(
                "backup '{}' is not a regular file",
                path.display()
            )));
        }
        std::fs::remove_file(&path)?;
        Ok(())
    }
}

fn read_world_summary(directory: &Path, folder_name: &str) -> WorldSummary {
    let metadata = std::fs::symlink_metadata(directory).ok();
    let last_modified = metadata
        .as_ref()
        .and_then(|meta| meta.modified().ok())
        .map(DateTime::<Utc>::from);

    let level_dat = directory.join("level.dat");
    let level_dat_modified = std::fs::metadata(&level_dat)
        .ok()
        .and_then(|meta| meta.modified().ok())
        .map(DateTime::<Utc>::from);

    let mut summary = WorldSummary {
        folder_name: folder_name.to_string(),
        name: folder_name.to_string(),
        game_mode: "unknown".to_string(),
        last_played: None,
        version_name: None,
        size_bytes: 0,
        last_modified: level_dat_modified.or(last_modified),
        hardcore: false,
        allow_commands: false,
    };

    let data =
        read_level_data(&level_dat).or_else(|| read_level_data(&directory.join("level.dat_old")));
    if let Some(data) = data {
        if let Some(name) = data.get("LevelName").and_then(NbtValue::as_str) {
            if !name.trim().is_empty() {
                summary.name = name.to_string();
            }
        }
        if let Some(game_type) = data.get("GameType").and_then(NbtValue::as_i64) {
            summary.game_mode = game_mode_name(game_type).to_string();
        }
        if let Some(last_played) = data.get("LastPlayed").and_then(NbtValue::as_i64) {
            summary.last_played = DateTime::<Utc>::from_timestamp_millis(last_played);
        }
        summary.version_name = data.get("Version").and_then(|version| match version {
            NbtValue::Compound(map) => map
                .get("Name")
                .and_then(NbtValue::as_str)
                .map(str::to_string),
            NbtValue::String(name) => Some(name.clone()),
            _ => None,
        });
        summary.hardcore = data
            .get("hardcore")
            .and_then(NbtValue::as_bool)
            .unwrap_or(false);
        summary.allow_commands = data
            .get("allowCommands")
            .and_then(NbtValue::as_bool)
            .unwrap_or(false);
    }

    summary.size_bytes = directory_size(directory, 0);
    summary
}

fn game_mode_name(value: i64) -> &'static str {
    match value {
        0 => "survival",
        1 => "creative",
        2 => "adventure",
        3 => "spectator",
        _ => "unknown",
    }
}

/// Recursively sums regular file sizes, skipping symlinks and bounding depth.
fn directory_size(directory: &Path, depth: u32) -> u64 {
    if depth > 32 {
        return 0;
    }
    let entries = match std::fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(_) => return 0,
    };
    let mut total = 0u64;
    for entry in entries.flatten() {
        let file_type = match entry.file_type() {
            Ok(file_type) => file_type,
            Err(_) => continue,
        };
        if file_type.is_symlink() {
            continue;
        }
        if file_type.is_dir() {
            total = total.saturating_add(directory_size(&entry.path(), depth + 1));
        } else if file_type.is_file() {
            if let Ok(metadata) = entry.metadata() {
                total = total.saturating_add(metadata.len());
            }
        }
    }
    total
}

/// Splits `<folder>-<yyyymmdd>-<hhmmssmmm>` into folder and timestamp.
fn split_backup_stem(stem: &str) -> (String, Option<NaiveDateTime>) {
    let parts: Vec<&str> = stem.rsplitn(3, '-').collect();
    if parts.len() == 3 && parts[1].len() == 8 && parts[0].len() == 9 {
        let timestamp = format!("{}-{}", parts[1], parts[0]);
        if let Ok(parsed) = NaiveDateTime::parse_from_str(&timestamp, "%Y%m%d-%H%M%S%3f") {
            return (parts[2].to_string(), Some(parsed));
        }
    }
    (stem.to_string(), None)
}

// ---------------------------------------------------------------------------
// Minimal NBT reader
// ---------------------------------------------------------------------------

#[allow(dead_code)]
#[derive(Debug, Clone)]
enum NbtValue {
    Byte(i8),
    Short(i16),
    Int(i32),
    Long(i64),
    Float(f32),
    Double(f64),
    Bytes(Vec<u8>),
    String(String),
    List(Vec<NbtValue>),
    Compound(BTreeMap<String, NbtValue>),
    IntArray(Vec<i32>),
    LongArray(Vec<i64>),
}

impl NbtValue {
    fn as_i64(&self) -> Option<i64> {
        match self {
            NbtValue::Byte(value) => Some(*value as i64),
            NbtValue::Short(value) => Some(*value as i64),
            NbtValue::Int(value) => Some(*value as i64),
            NbtValue::Long(value) => Some(*value),
            NbtValue::Float(value) => Some(*value as i64),
            NbtValue::Double(value) => Some(*value as i64),
            _ => None,
        }
    }

    fn as_bool(&self) -> Option<bool> {
        self.as_i64().map(|value| value != 0)
    }

    fn as_str(&self) -> Option<&str> {
        match self {
            NbtValue::String(value) => Some(value),
            _ => None,
        }
    }
}

struct NbtCursor<'a> {
    data: &'a [u8],
    position: usize,
}

impl<'a> NbtCursor<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, position: 0 }
    }

    fn remaining(&self) -> usize {
        self.data.len().saturating_sub(self.position)
    }

    fn take(&mut self, length: usize) -> Option<&'a [u8]> {
        let end = self.position.checked_add(length)?;
        let bytes = self.data.get(self.position..end)?;
        self.position = end;
        Some(bytes)
    }

    fn u8(&mut self) -> Option<u8> {
        Some(*self.take(1)?.first()?)
    }

    fn i8(&mut self) -> Option<i8> {
        Some(self.u8()? as i8)
    }

    fn u16(&mut self) -> Option<u16> {
        let bytes = self.take(2)?;
        Some(u16::from_be_bytes([bytes[0], bytes[1]]))
    }

    fn i16(&mut self) -> Option<i16> {
        Some(self.u16()? as i16)
    }

    fn i32(&mut self) -> Option<i32> {
        let bytes = self.take(4)?;
        Some(i32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
    }

    fn i64(&mut self) -> Option<i64> {
        let bytes = self.take(8)?;
        Some(i64::from_be_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ]))
    }

    fn f32(&mut self) -> Option<f32> {
        Some(f32::from_bits(self.i32()? as u32))
    }

    fn f64(&mut self) -> Option<f64> {
        Some(f64::from_bits(self.i64()? as u64))
    }

    fn string(&mut self) -> Option<String> {
        let length = self.u16()? as usize;
        let bytes = self.take(length)?;
        Some(String::from_utf8_lossy(bytes).into_owned())
    }

    fn payload(&mut self, tag: u8, depth: u32) -> Option<NbtValue> {
        if depth > MAX_NBT_DEPTH {
            return None;
        }
        match tag {
            1 => Some(NbtValue::Byte(self.i8()?)),
            2 => Some(NbtValue::Short(self.i16()?)),
            3 => Some(NbtValue::Int(self.i32()?)),
            4 => Some(NbtValue::Long(self.i64()?)),
            5 => Some(NbtValue::Float(self.f32()?)),
            6 => Some(NbtValue::Double(self.f64()?)),
            7 => {
                let length = self.i32()?;
                if length < 0 {
                    return None;
                }
                Some(NbtValue::Bytes(self.take(length as usize)?.to_vec()))
            }
            8 => Some(NbtValue::String(self.string()?)),
            9 => {
                let element_tag = self.u8()?;
                let length = self.i32()?;
                if length < 0 || (element_tag == 0 && length > 0) {
                    return None;
                }
                let length = length as usize;
                if length > self.remaining().max(1) {
                    return None;
                }
                let mut values = Vec::with_capacity(length.min(4096));
                for _ in 0..length {
                    values.push(self.payload(element_tag, depth + 1)?);
                }
                Some(NbtValue::List(values))
            }
            10 => Some(NbtValue::Compound(self.compound(depth + 1)?)),
            11 => {
                let length = self.i32()?;
                if length < 0 {
                    return None;
                }
                let length = length as usize;
                if length > self.remaining() / 4 {
                    return None;
                }
                let mut values = Vec::with_capacity(length);
                for _ in 0..length {
                    values.push(self.i32()?);
                }
                Some(NbtValue::IntArray(values))
            }
            12 => {
                let length = self.i32()?;
                if length < 0 {
                    return None;
                }
                let length = length as usize;
                if length > self.remaining() / 8 {
                    return None;
                }
                let mut values = Vec::with_capacity(length);
                for _ in 0..length {
                    values.push(self.i64()?);
                }
                Some(NbtValue::LongArray(values))
            }
            _ => None,
        }
    }

    fn compound(&mut self, depth: u32) -> Option<BTreeMap<String, NbtValue>> {
        if depth > MAX_NBT_DEPTH {
            return None;
        }
        let mut values = BTreeMap::new();
        loop {
            let tag = self.u8()?;
            if tag == 0 {
                break;
            }
            let name = self.string()?;
            let value = self.payload(tag, depth)?;
            values.insert(name, value);
        }
        Some(values)
    }
}

fn parse_nbt(data: &[u8]) -> Option<BTreeMap<String, NbtValue>> {
    let mut cursor = NbtCursor::new(data);
    if cursor.u8()? != 10 {
        return None;
    }
    let _root_name = cursor.string()?;
    match cursor.payload(10, 0)? {
        NbtValue::Compound(root) => Some(root),
        _ => None,
    }
}

fn read_level_data(path: &Path) -> Option<BTreeMap<String, NbtValue>> {
    let metadata = std::fs::metadata(path).ok()?;
    if !metadata.is_file() || metadata.len() > MAX_LEVEL_DAT_BYTES as u64 {
        return None;
    }
    let raw = std::fs::read(path).ok()?;
    let data = if raw.starts_with(&[0x1f, 0x8b]) {
        gunzip(&raw, MAX_LEVEL_DAT_BYTES)?
    } else {
        raw
    };
    let mut root = parse_nbt(&data)?;
    match root.remove("Data")? {
        NbtValue::Compound(data) => Some(data),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// gzip / DEFLATE decoder (RFC 1951 and RFC 1952, no external crates)
// ---------------------------------------------------------------------------

fn gunzip(data: &[u8], max_output: usize) -> Option<Vec<u8>> {
    if data.len() < 18 || data[0] != 0x1f || data[1] != 0x8b || data[2] != 8 {
        return None;
    }
    let flags = data[3];
    if flags & 0xe0 != 0 {
        return None;
    }
    let mut position = 10usize;
    if flags & 0x04 != 0 {
        let xlen = u16::from_le_bytes([*data.get(position)?, *data.get(position + 1)?]) as usize;
        position = position.checked_add(2 + xlen)?;
        if position > data.len() {
            return None;
        }
    }
    if flags & 0x08 != 0 {
        while *data.get(position)? != 0 {
            position += 1;
        }
        position += 1;
    }
    if flags & 0x10 != 0 {
        while *data.get(position)? != 0 {
            position += 1;
        }
        position += 1;
    }
    if flags & 0x02 != 0 {
        position = position.checked_add(2)?;
    }
    if position >= data.len() {
        return None;
    }
    inflate(&data[position..], max_output)
}

struct BitReader<'a> {
    data: &'a [u8],
    byte: usize,
    bit: u32,
}

impl<'a> BitReader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self {
            data,
            byte: 0,
            bit: 0,
        }
    }

    fn bits(&mut self, count: u8) -> Option<u32> {
        let mut value = 0u32;
        for index in 0..count {
            let byte = *self.data.get(self.byte)?;
            value |= (((byte >> self.bit) & 1) as u32) << index;
            self.bit += 1;
            if self.bit == 8 {
                self.bit = 0;
                self.byte += 1;
            }
        }
        Some(value)
    }

    fn align(&mut self) {
        if self.bit != 0 {
            self.bit = 0;
            self.byte += 1;
        }
    }

    fn take_aligned(&mut self, length: usize) -> Option<&'a [u8]> {
        let end = self.byte.checked_add(length)?;
        let bytes = self.data.get(self.byte..end)?;
        self.byte = end;
        Some(bytes)
    }
}

#[derive(Debug)]
struct Huffman {
    codes: BTreeMap<(u8, u32), u16>,
    max_length: u8,
}

impl Huffman {
    fn from_lengths(lengths: &[u8]) -> Option<Self> {
        let mut counts = [0u16; 16];
        for &length in lengths {
            if length > 15 {
                return None;
            }
            if length > 0 {
                counts[length as usize] = counts[length as usize].saturating_add(1);
            }
        }
        let mut next_code = [0u32; 16];
        let mut code = 0u32;
        for bits in 1..=15 {
            code = (code + counts[bits - 1] as u32) << 1;
            next_code[bits] = code;
        }
        let mut codes = BTreeMap::new();
        let mut max_length = 0u8;
        for (symbol, &length) in lengths.iter().enumerate() {
            if length == 0 {
                continue;
            }
            let entry = next_code[length as usize];
            next_code[length as usize] = entry.saturating_add(1);
            codes.insert((length, entry), symbol as u16);
            max_length = max_length.max(length);
        }
        Some(Self { codes, max_length })
    }

    fn decode(&self, bits: &mut BitReader<'_>) -> Option<u16> {
        if self.max_length == 0 {
            return None;
        }
        let mut code = 0u32;
        for length in 1..=self.max_length {
            code = (code << 1) | bits.bits(1)?;
            if let Some(symbol) = self.codes.get(&(length, code)) {
                return Some(*symbol);
            }
        }
        None
    }
}

const LENGTH_BASE: [u16; 29] = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131,
    163, 195, 227, 258,
];
const LENGTH_EXTRA: [u8; 29] = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
];
const DISTANCE_BASE: [u16; 30] = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
    2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
];
const DISTANCE_EXTRA: [u8; 30] = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13,
    13,
];

fn inflate(data: &[u8], max_output: usize) -> Option<Vec<u8>> {
    let mut bits = BitReader::new(data);
    let mut output = Vec::new();
    loop {
        let final_block = bits.bits(1)? == 1;
        let block_type = bits.bits(2)?;
        match block_type {
            0 => {
                bits.align();
                let length = {
                    let bytes = bits.take_aligned(2)?;
                    u16::from_le_bytes([bytes[0], bytes[1]]) as usize
                };
                let complement = {
                    let bytes = bits.take_aligned(2)?;
                    u16::from_le_bytes([bytes[0], bytes[1]]) as usize
                };
                if length != (!complement & 0xffff) {
                    return None;
                }
                if output.len().saturating_add(length) > max_output {
                    return None;
                }
                let bytes = bits.take_aligned(length)?;
                output.extend_from_slice(bytes);
            }
            1 => {
                let (literal, distance) = fixed_tables()?;
                inflate_block(&mut bits, &mut output, &literal, &distance, max_output)?;
            }
            2 => {
                let (literal, distance) = dynamic_tables(&mut bits)?;
                inflate_block(&mut bits, &mut output, &literal, &distance, max_output)?;
            }
            _ => return None,
        }
        if output.len() > max_output {
            return None;
        }
        if final_block {
            break;
        }
    }
    Some(output)
}

fn inflate_block(
    bits: &mut BitReader<'_>,
    output: &mut Vec<u8>,
    literal: &Huffman,
    distance: &Huffman,
    max_output: usize,
) -> Option<()> {
    loop {
        let symbol = literal.decode(bits)?;
        if symbol < 256 {
            if output.len() >= max_output {
                return None;
            }
            output.push(symbol as u8);
            continue;
        }
        if symbol == 256 {
            return Some(());
        }
        let index = symbol.saturating_sub(257) as usize;
        if index >= LENGTH_BASE.len() {
            return None;
        }
        let length = LENGTH_BASE[index] as usize + bits.bits(LENGTH_EXTRA[index])? as usize;

        let distance_symbol = distance.decode(bits)? as usize;
        if distance_symbol >= DISTANCE_BASE.len() {
            return None;
        }
        let distance_value = DISTANCE_BASE[distance_symbol] as usize
            + bits.bits(DISTANCE_EXTRA[distance_symbol])? as usize;
        if distance_value == 0 || distance_value > output.len() {
            return None;
        }
        if output.len().saturating_add(length) > max_output {
            return None;
        }
        let start = output.len() - distance_value;
        for index in 0..length {
            let byte = output[start + index];
            output.push(byte);
        }
    }
}

fn fixed_tables() -> Option<(Huffman, Huffman)> {
    let mut literal_lengths = vec![0u8; 288];
    for (index, length) in literal_lengths.iter_mut().enumerate() {
        *length = match index {
            0..=143 => 8,
            144..=255 => 9,
            256..=279 => 7,
            _ => 8,
        };
    }
    let distance_lengths = vec![5u8; 32];
    Some((
        Huffman::from_lengths(&literal_lengths)?,
        Huffman::from_lengths(&distance_lengths)?,
    ))
}

fn dynamic_tables(bits: &mut BitReader<'_>) -> Option<(Huffman, Huffman)> {
    let literal_count = bits.bits(5)? as usize + 257;
    let distance_count = bits.bits(5)? as usize + 1;
    let code_length_count = bits.bits(4)? as usize + 4;
    if literal_count > 286 || distance_count > 30 {
        return None;
    }
    const ORDER: [usize; 19] = [
        16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
    ];
    let mut code_lengths = vec![0u8; 19];
    for index in 0..code_length_count {
        code_lengths[ORDER[index]] = bits.bits(3)? as u8;
    }
    let code_length_table = Huffman::from_lengths(&code_lengths)?;

    let total = literal_count + distance_count;
    let mut lengths = Vec::with_capacity(total);
    while lengths.len() < total {
        let symbol = code_length_table.decode(bits)?;
        match symbol {
            0..=15 => lengths.push(symbol as u8),
            16 => {
                let previous = *lengths.last()?;
                let repeat = bits.bits(2)? as usize + 3;
                if lengths.len().saturating_add(repeat) > total {
                    return None;
                }
                for _ in 0..repeat {
                    lengths.push(previous);
                }
            }
            17 => {
                let repeat = bits.bits(3)? as usize + 3;
                if lengths.len().saturating_add(repeat) > total {
                    return None;
                }
                lengths.resize(lengths.len() + repeat, 0);
            }
            18 => {
                let repeat = bits.bits(7)? as usize + 11;
                if lengths.len().saturating_add(repeat) > total {
                    return None;
                }
                lengths.resize(lengths.len() + repeat, 0);
            }
            _ => return None,
        }
    }
    let literal = Huffman::from_lengths(&lengths[..literal_count])?;
    let distance = Huffman::from_lengths(&lengths[literal_count..])?;
    Some((literal, distance))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backup_name_roundtrip() {
        let (folder, timestamp) = split_backup_stem("my-world-20260102-030405123");
        assert_eq!(folder, "my-world");
        assert!(timestamp.is_some());
    }

    #[test]
    fn game_modes() {
        assert_eq!(game_mode_name(0), "survival");
        assert_eq!(game_mode_name(1), "creative");
        assert_eq!(game_mode_name(99), "unknown");
    }

    #[test]
    fn directory_backup_roundtrip() {
        use crate::models::instance::InstanceRepository;

        let root =
            std::env::temp_dir().join(format!("lingxi-worlds-{}", uuid::Uuid::new_v4().simple()));
        let layout = GameDataLayout::new(root.join("minecraft"), root.join("data"));
        let repository = InstanceRepository::new(layout.clone());
        let instance = repository
            .create("test-instance", "Test Instance", Some("1.20.1"))
            .expect("create instance");
        let world = instance.game_directory.join("saves").join("TestWorld");
        std::fs::create_dir_all(world.join("region")).expect("create world");
        std::fs::write(world.join("level.dat"), b"not really nbt").expect("level.dat");
        std::fs::write(world.join("region").join("r.0.0.mca"), b"chunk bytes").expect("region");

        let manager = WorldManager::new(layout);
        let backup = manager.backup(&instance, "TestWorld").expect("backup");
        assert!(manager
            .backups_directory(&instance)
            .unwrap()
            .join(&backup.file_name)
            .join("manifest.json")
            .is_file());
        let listed = manager.list_backups(&instance).expect("list backups");
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].world_folder, "TestWorld");

        std::fs::remove_dir_all(&world).expect("remove original world");
        let restored = manager
            .restore_backup(&instance, &backup.file_name)
            .expect("restore");
        assert_eq!(restored.folder_name, "TestWorld");
        assert_eq!(
            std::fs::read(world.join("region").join("r.0.0.mca")).expect("restored region"),
            b"chunk bytes"
        );

        manager
            .delete_backup(&instance, &backup.file_name)
            .expect("delete backup");
        assert!(manager.list_backups(&instance).unwrap().is_empty());
        std::fs::remove_dir_all(&root).ok();
    }
}
