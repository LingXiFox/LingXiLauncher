//! Modrinth `.mrpack` modpack support: inspection, installation and updates.
//!
//! A modpack is installed into a normal launcher [`Instance`]. The pack's
//! `modrinth.index.json` drives file downloads (SHA-512 verified), while
//! `overrides/` and `client-overrides/` are extracted on top of the instance
//! game directory. The launcher-specific bookkeeping lives in
//! `<instance.directory>/modpack.json`.
//!
//! Loader installation is intentionally out of scope: the exact loader and
//! Minecraft versions are recorded in `modpack.json` (`dependencies` and
//! `loader`) so the caller can hand them to the loader installer.

use std::collections::{BTreeMap, HashSet};
use std::fs::File;
use std::io::Write;
use std::path::Path;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::install::hashing::sha512_file;
use crate::install::models::{CancelFlag, InstallProgressEvent, SharedProgress};
use crate::install::zip::read_entry;
use crate::layout::{ensure_dir, GameDataLayout};
use crate::models::instance::{Instance, InstanceRepository};
use crate::modrinth::{best_version, ModrinthClient, Version};
use crate::paths::PathSafety;

pub const MODRINTH_INDEX_FILE: &str = "modrinth.index.json";
pub const MODPACK_METADATA_FILE: &str = "modpack.json";

const MAX_INDEX_BYTES: u64 = 16 * 1024 * 1024;
const MAX_OVERRIDE_ENTRY_BYTES: u64 = 512 * 1024 * 1024;
const OVERRIDE_PREFIXES: [&str; 2] = ["overrides/", "client-overrides/"];

// ---------------------------------------------------------------------------
// Wire models
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct MrpackIndex {
    #[serde(default = "default_format_version")]
    pub format_version: u32,
    #[serde(default = "default_game")]
    pub game: String,
    #[serde(default)]
    pub version_id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub files: Vec<MrpackFile>,
    #[serde(default)]
    pub dependencies: BTreeMap<String, String>,
}

fn default_format_version() -> u32 {
    1
}

fn default_game() -> String {
    "minecraft".to_string()
}

impl MrpackIndex {
    /// Loader declared by this pack, if any.
    pub fn loader(&self) -> Option<ModpackLoader> {
        resolve_loader(&self.dependencies)
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct MrpackFile {
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub hashes: MrpackHashes,
    #[serde(default)]
    pub env: Option<MrpackEnvironment>,
    #[serde(default)]
    pub downloads: Vec<String>,
    #[serde(default)]
    pub file_size: u64,
}

impl MrpackFile {
    /// A file is downloaded unless the pack explicitly marks the client side
    /// as unsupported.
    pub fn is_client_relevant(&self) -> bool {
        match &self.env {
            Some(environment) => !environment
                .client
                .as_deref()
                .is_some_and(|side| side.eq_ignore_ascii_case("unsupported")),
            None => true,
        }
    }

    /// First HTTP(S) mirror, falling back to the first declared URL.
    pub fn primary_download(&self) -> Option<&str> {
        self.downloads
            .iter()
            .map(String::as_str)
            .find(|url| {
                let url = url.to_ascii_lowercase();
                url.starts_with("https://") || url.starts_with("http://")
            })
            .or_else(|| self.downloads.first().map(String::as_str))
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct MrpackHashes {
    #[serde(default)]
    pub sha1: String,
    #[serde(default)]
    pub sha512: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct MrpackEnvironment {
    #[serde(default)]
    pub client: Option<String>,
    #[serde(default)]
    pub server: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct MrpackSummary {
    pub name: String,
    pub version_id: String,
    pub summary: String,
    pub file_count: usize,
    pub dependencies: BTreeMap<String, String>,
    pub total_size: u64,
}

// ---------------------------------------------------------------------------
// Loader resolution
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ModpackLoaderKind {
    Fabric,
    Quilt,
    Forge,
    NeoForge,
}

impl ModpackLoaderKind {
    pub fn modrinth_loader(self) -> &'static str {
        match self {
            Self::Fabric => "fabric",
            Self::Quilt => "quilt",
            Self::Forge => "forge",
            Self::NeoForge => "neoforge",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModpackLoader {
    pub kind: ModpackLoaderKind,
    pub version: String,
    pub minecraft: String,
}

/// Resolves the loader dependency map from a pack index.
pub fn resolve_loader(dependencies: &BTreeMap<String, String>) -> Option<ModpackLoader> {
    let minecraft = dependencies.get("minecraft").cloned().unwrap_or_default();
    let candidates = [
        ("fabric-loader", ModpackLoaderKind::Fabric),
        ("quilt-loader", ModpackLoaderKind::Quilt),
        ("neoforge", ModpackLoaderKind::NeoForge),
        ("forge", ModpackLoaderKind::Forge),
    ];
    for (key, kind) in candidates {
        if let Some(version) = dependencies
            .get(key)
            .map(|value| value.trim())
            .filter(|value| !value.is_empty())
        {
            return Some(ModpackLoader {
                kind,
                version: version.to_string(),
                minecraft,
            });
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Launcher-side bookkeeping
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct InstalledModpackFile {
    pub path: String,
    #[serde(default)]
    pub sha1: String,
    #[serde(default)]
    pub sha512: String,
    #[serde(default)]
    pub file_size: u64,
}

/// Contents of `<instance.directory>/modpack.json`.
///
/// `files` only records files materialized from `modrinth.index.json`; override
/// files are deliberately not listed, so an update never deletes user-editable
/// configs that happened to come from `overrides/`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModpackManifest {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub version_id: String,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub files: Vec<InstalledModpackFile>,
    #[serde(default = "Utc::now")]
    pub installed_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    #[serde(default)]
    pub dependencies: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub loader: Option<ModpackLoader>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModpackUpdate {
    #[serde(default)]
    pub project_id: String,
    #[serde(default)]
    pub current_version_id: String,
    pub latest_version: Version,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub download_url: String,
    #[serde(default)]
    pub file_name: String,
    #[serde(default)]
    pub file_size: u64,
    #[serde(default)]
    pub sha1: String,
    #[serde(default)]
    pub sha512: String,
}

impl ModpackUpdate {
    pub fn latest_version_id(&self) -> &str {
        &self.latest_version.id
    }

    pub fn latest_version_number(&self) -> &str {
        &self.latest_version.version_number
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Reads `modrinth.index.json` without touching the filesystem.
pub fn inspect(archive: &Path) -> Result<MrpackSummary> {
    let index = read_index(archive)?;
    let file_count = index.files.len();
    let total_size = index
        .files
        .iter()
        .fold(0u64, |total, file| total.saturating_add(file.file_size));
    let name = pack_display_name(&index, archive, "");
    Ok(MrpackSummary {
        name,
        version_id: index.version_id,
        summary: index.summary,
        file_count,
        dependencies: index.dependencies,
        total_size,
    })
}

/// Installs a `.mrpack` as a new instance.
///
/// The returned instance has `version_id` set to the pack's Minecraft version.
/// Loader details are available through [`read_manifest`] (`dependencies` and
/// `loader`); actual loader installation belongs to another module.
pub async fn install(
    archive: &Path,
    display_name: &str,
    layout: &GameDataLayout,
    progress: Option<SharedProgress>,
    cancel: Option<&CancelFlag>,
) -> Result<Instance> {
    check_cancel(cancel)?;
    let index = read_index(archive)?;
    let game_version = minecraft_version(&index)?.to_string();
    PathSafety::validate_component(&game_version)?;

    let display_name = pack_display_name(&index, archive, display_name);
    let repository = InstanceRepository::new(layout.clone());
    let instance = repository.create_with_generated_id(&display_name)?;
    ensure_dir(&instance.game_directory)?;

    emit(
        progress.as_ref(),
        InstallProgressEvent::Phase {
            phase: "prepare".into(),
            message: format!("正在安装整合包「{}」", display_name),
        },
    );

    let client = ModrinthClient::new()?;
    let files = download_index_files(&instance, &index, &client, progress.as_ref(), cancel).await?;

    emit(
        progress.as_ref(),
        InstallProgressEvent::Phase {
            phase: "overrides".into(),
            message: "正在应用整合包覆盖文件".into(),
        },
    );
    apply_overrides(archive, &instance.game_directory, cancel)?;

    let manifest = ModpackManifest {
        name: if index.name.trim().is_empty() {
            display_name
        } else {
            index.name.clone()
        },
        version_id: index.version_id.clone(),
        summary: index.summary.clone(),
        files,
        installed_at: Utc::now(),
        project_id: None,
        dependencies: index.dependencies.clone(),
        loader: index.loader(),
    };
    write_manifest(&instance, &manifest)?;

    let instance = repository.assign_version(&instance, &game_version)?;
    emit(
        progress.as_ref(),
        InstallProgressEvent::Phase {
            phase: "complete".into(),
            message: "整合包安装完成".into(),
        },
    );
    Ok(instance)
}

/// Checks whether a Modrinth-hosted modpack has a newer version.
///
/// Returns `Ok(None)` when the instance has no recorded `projectId`, when the
/// project no longer exists, or when the recorded version is already latest.
pub async fn check_update(
    instance: &Instance,
    client: &ModrinthClient,
) -> Result<Option<ModpackUpdate>> {
    let manifest = read_manifest(instance)?;
    let Some(project_id) = manifest
        .project_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return Ok(None);
    };

    let versions = match client.versions(project_id, &[], &[]).await {
        Ok(versions) => versions,
        Err(Error::NotFound(_)) => return Ok(None),
        Err(error) => return Err(error),
    };

    let game_version = manifest
        .dependencies
        .get("minecraft")
        .map(|value| value.trim())
        .filter(|value| !value.is_empty());
    let loader = manifest
        .loader
        .as_ref()
        .map(|loader| loader.kind)
        .or_else(|| resolve_loader(&manifest.dependencies).map(|loader| loader.kind));
    let loader_name = loader.map(ModpackLoaderKind::modrinth_loader);

    let latest = best_version(&versions, game_version, loader_name)
        .or_else(|| best_version(&versions, game_version, None))
        .or_else(|| best_version(&versions, None, None));
    let Some(latest) = latest else {
        return Ok(None);
    };
    if latest.id == manifest.version_id {
        return Ok(None);
    }

    let file = latest
        .primary_file()
        .ok_or_else(|| Error::InvalidMetadata(format!("Modrinth 版本 '{}' 没有文件", latest.id)))?;
    if file.url.trim().is_empty() {
        return Err(Error::InvalidMetadata(format!(
            "Modrinth 版本 '{}' 的下载地址为空",
            latest.id
        )));
    }
    let name = if latest.name.trim().is_empty() {
        latest.version_number.clone()
    } else {
        latest.name.clone()
    };
    Ok(Some(ModpackUpdate {
        project_id: project_id.to_string(),
        current_version_id: manifest.version_id.clone(),
        latest_version: latest.clone(),
        name,
        summary: manifest.summary.clone(),
        download_url: file.url.clone(),
        file_name: file.filename.clone(),
        file_size: file.size,
        sha1: file.hashes.sha1.clone(),
        sha512: file.hashes.sha512.clone(),
    }))
}

/// Applies a Modrinth modpack update.
///
/// The new `.mrpack` is downloaded into the instance directory, its index is
/// read, changed files are downloaded with SHA-512 verification, overrides are
/// applied, and files recorded by the old manifest but absent from the new pack
/// are removed (only when their content still matches the recorded hash).
pub async fn apply_update(
    instance: &Instance,
    layout: &GameDataLayout,
    update: &ModpackUpdate,
    progress: Option<SharedProgress>,
    cancel: Option<&CancelFlag>,
) -> Result<Instance> {
    check_cancel(cancel)?;
    let old_manifest = read_manifest(instance)?;
    if old_manifest.version_id == update.latest_version.id {
        return Ok(instance.clone());
    }
    if let Some(old_project) = old_manifest
        .project_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        let new_project = update.project_id.trim();
        if !new_project.is_empty() && old_project != new_project {
            return Err(Error::InvalidMetadata(
                "整合包更新属于另一个 Modrinth 项目".into(),
            ));
        }
    }

    let file = update.latest_version.primary_file().ok_or_else(|| {
        Error::InvalidMetadata(format!(
            "Modrinth 版本 '{}' 没有文件",
            update.latest_version.id
        ))
    })?;
    let url = if update.download_url.trim().is_empty() {
        file.url.as_str()
    } else {
        update.download_url.as_str()
    };
    let sha512 = if !update.sha512.trim().is_empty() {
        Some(update.sha512.as_str())
    } else if !file.hashes.sha512.trim().is_empty() {
        Some(file.hashes.sha512.as_str())
    } else {
        None
    };
    let sha512 =
        sha512.ok_or_else(|| Error::InvalidMetadata("整合包更新文件缺少 SHA-512 校验值".into()))?;
    let size = if update.file_size > 0 {
        Some(update.file_size)
    } else if file.size > 0 {
        Some(file.size)
    } else {
        None
    };

    ensure_dir(&instance.directory)?;
    let archive = instance.directory.join(format!(
        ".modpack-update-{}.mrpack",
        uuid::Uuid::new_v4().simple()
    ));
    prepare_destination(&instance.directory, &archive)?;

    emit(
        progress.as_ref(),
        InstallProgressEvent::Phase {
            phase: "update".into(),
            message: format!("正在下载整合包更新「{}」", update.name),
        },
    );
    let client = ModrinthClient::new()?;
    client
        .download_verified(url, &archive, Some(sha512), size, progress.as_ref(), cancel)
        .await?;

    let outcome = apply_update_archive(
        instance,
        layout,
        &old_manifest,
        update,
        &archive,
        &client,
        progress.as_ref(),
        cancel,
    )
    .await;
    let _ = std::fs::remove_file(&archive);
    outcome
}

/// Reads the launcher's modpack bookkeeping for an instance.
pub fn read_manifest(instance: &Instance) -> Result<ModpackManifest> {
    let path = instance.directory.join(MODPACK_METADATA_FILE);
    if !path.is_file() {
        return Err(Error::NotFound(format!(
            "instance '{}' has no modpack manifest",
            instance.id()
        )));
    }
    let data = std::fs::read(&path).map_err(|error| {
        Error::Io(std::io::Error::new(
            error.kind(),
            format!("read {}: {error}", path.display()),
        ))
    })?;
    let value: serde_json::Value = serde_json::from_slice(&data).map_err(|error| {
        Error::InvalidMetadata(format!(
            "corrupted modpack manifest {}: {error}",
            path.display()
        ))
    })?;
    if value.get("schemaVersion").is_some() && value.get("versionID").is_some() {
        let legacy: LegacyModpackRecord = serde_json::from_value(value).map_err(|error| {
            Error::InvalidMetadata(format!(
                "corrupted Swift modpack manifest {}: {error}",
                path.display()
            ))
        })?;
        return Ok(legacy.into_manifest(instance));
    }
    serde_json::from_value(value).map_err(|error| {
        Error::InvalidMetadata(format!(
            "corrupted modpack manifest {}: {error}",
            path.display()
        ))
    })
}

/// Swift launcher's `ModpackRecord` (schemaVersion 1). It is read-only here:
/// converting it keeps all files visible without rewriting the user's
/// `modpack.json` and without enabling updates based on a guessed project id.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyModpackRecord {
    #[serde(default, rename = "versionID")]
    version_id: String,
    #[serde(default, rename = "packVersionID")]
    pack_version_id: Option<String>,
    #[serde(default, rename = "minecraftVersion")]
    minecraft_version: String,
    #[serde(default, rename = "loaderKind")]
    loader_kind: String,
    #[serde(default, rename = "loaderVersion")]
    loader_version: Option<String>,
    #[serde(default)]
    installed_at: Option<DateTime<Utc>>,
    #[serde(default)]
    files: Vec<LegacyModpackFile>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyModpackFile {
    path: String,
    #[serde(default)]
    sha1: String,
    #[serde(default)]
    sha512: String,
    #[serde(default, rename = "byteCount")]
    byte_count: u64,
}

impl LegacyModpackRecord {
    fn into_manifest(self, instance: &Instance) -> ModpackManifest {
        let loader = match self.loader_kind.as_str() {
            "fabric" => Some(ModpackLoaderKind::Fabric),
            "quilt" => Some(ModpackLoaderKind::Quilt),
            "forge" => Some(ModpackLoaderKind::Forge),
            "neoforge" => Some(ModpackLoaderKind::NeoForge),
            _ => None,
        }
        .map(|kind| ModpackLoader {
            kind,
            version: self.loader_version.unwrap_or_default(),
            minecraft: self.minecraft_version.clone(),
        });
        let mut dependencies = BTreeMap::new();
        if !self.minecraft_version.is_empty() {
            dependencies.insert("minecraft".into(), self.minecraft_version);
        }
        if let Some(loader) = &loader {
            dependencies.insert(
                format!("{}-loader", loader.kind.modrinth_loader()),
                loader.version.clone(),
            );
        }
        ModpackManifest {
            name: instance.manifest.display_name.clone(),
            version_id: self.pack_version_id.unwrap_or(self.version_id),
            summary: String::new(),
            files: self
                .files
                .into_iter()
                .map(|file| InstalledModpackFile {
                    path: file.path,
                    sha1: file.sha1,
                    sha512: file.sha512,
                    file_size: file.byte_count,
                })
                .collect(),
            installed_at: self.installed_at.unwrap_or_else(Utc::now),
            project_id: None,
            dependencies,
            loader,
        }
    }
}

/// Associates an installed pack with a Modrinth project so updates can be
/// checked. Passing an empty id clears the association.
pub fn set_project_id(instance: &Instance, project_id: &str) -> Result<()> {
    let project_id = project_id.trim();
    if project_id
        .chars()
        .any(|character| character.is_control() || character == '/' || character == '\\')
    {
        return Err(Error::UnsafePath("invalid Modrinth project id".into()));
    }
    let mut manifest = read_manifest(instance)?;
    manifest.project_id = if project_id.is_empty() {
        None
    } else {
        Some(project_id.to_string())
    };
    write_manifest(instance, &manifest)
}

// ---------------------------------------------------------------------------
// Installation internals
// ---------------------------------------------------------------------------

async fn download_index_files(
    instance: &Instance,
    index: &MrpackIndex,
    client: &ModrinthClient,
    progress: Option<&SharedProgress>,
    cancel: Option<&CancelFlag>,
) -> Result<Vec<InstalledModpackFile>> {
    let relevant: Vec<&MrpackFile> = index
        .files
        .iter()
        .filter(|file| file.is_client_relevant())
        .collect();
    let total_bytes = relevant
        .iter()
        .fold(0u64, |total, file| total.saturating_add(file.file_size));
    emit(
        progress,
        InstallProgressEvent::Plan {
            total_files: relevant.len(),
            total_bytes,
            cache_hits: 0,
        },
    );

    let mut installed = Vec::with_capacity(relevant.len());
    let mut seen = HashSet::new();
    for file in relevant {
        check_cancel(cancel)?;
        let key = normalize_path_key(&file.path);
        if key.is_empty() {
            return Err(Error::UnsafePath(
                "modpack contains an empty file path".into(),
            ));
        }
        if !seen.insert(key) {
            return Err(Error::InvalidMetadata(format!(
                "duplicate modpack file path '{}'",
                file.path
            )));
        }
        let url = file.primary_download().ok_or_else(|| {
            Error::InvalidMetadata(format!("modpack file '{}' has no download URL", file.path))
        })?;
        if file.hashes.sha512.trim().is_empty() {
            return Err(Error::InvalidMetadata(format!(
                "modpack file '{}' has no SHA-512 hash",
                file.path
            )));
        }
        let destination =
            PathSafety::safe_join(&instance.game_directory, &file.path).map_err(|error| {
                Error::UnsafePath(format!("unsafe modpack path '{}': {error}", file.path))
            })?;
        prepare_destination(&instance.game_directory, &destination)?;

        emit(
            progress,
            InstallProgressEvent::FileStarted {
                path: file.path.clone(),
                size: file.file_size,
            },
        );
        let result = client
            .download_verified(
                url,
                &destination,
                Some(file.hashes.sha512.as_str()),
                (file.file_size > 0).then_some(file.file_size),
                progress,
                cancel,
            )
            .await;
        if let Err(error) = result {
            emit(
                progress,
                InstallProgressEvent::FileFailed {
                    path: file.path.clone(),
                    message: error.to_string(),
                },
            );
            return Err(error);
        }
        let actual_size = std::fs::metadata(&destination)
            .map(|metadata| metadata.len())
            .unwrap_or(file.file_size);
        emit(
            progress,
            InstallProgressEvent::FileFinished {
                path: file.path.clone(),
                bytes: actual_size,
                source: "modrinth".into(),
            },
        );
        installed.push(InstalledModpackFile {
            path: file.path.clone(),
            sha1: file.hashes.sha1.clone(),
            sha512: file.hashes.sha512.clone(),
            file_size: actual_size,
        });
    }
    Ok(installed)
}

#[allow(clippy::too_many_arguments)]
async fn apply_update_archive(
    instance: &Instance,
    layout: &GameDataLayout,
    old_manifest: &ModpackManifest,
    update: &ModpackUpdate,
    archive: &Path,
    client: &ModrinthClient,
    progress: Option<&SharedProgress>,
    cancel: Option<&CancelFlag>,
) -> Result<Instance> {
    check_cancel(cancel)?;
    let index = read_index(archive)?;
    let game_version = minecraft_version(&index)?.to_string();
    PathSafety::validate_component(&game_version)?;

    let files = download_index_files(instance, &index, client, progress, cancel).await?;

    emit(
        progress,
        InstallProgressEvent::Phase {
            phase: "overrides".into(),
            message: "正在应用整合包更新覆盖文件".into(),
        },
    );
    let override_paths = apply_overrides(archive, &instance.game_directory, cancel)?;
    let removed = remove_obsolete_files(instance, old_manifest, &index, &override_paths)?;
    if removed > 0 {
        tracing::info!(removed, "removed obsolete modpack files");
    }

    let project_id = old_manifest.project_id.clone().or_else(|| {
        let value = update.project_id.trim();
        (!value.is_empty()).then(|| value.to_string())
    });
    let manifest = ModpackManifest {
        name: if index.name.trim().is_empty() {
            old_manifest.name.clone()
        } else {
            index.name.clone()
        },
        version_id: index.version_id.clone(),
        summary: if index.summary.trim().is_empty() {
            old_manifest.summary.clone()
        } else {
            index.summary.clone()
        },
        files,
        installed_at: Utc::now(),
        project_id,
        dependencies: index.dependencies.clone(),
        loader: index.loader(),
    };
    write_manifest(instance, &manifest)?;

    let updated = if instance.manifest.version_id.as_deref() != Some(game_version.as_str()) {
        InstanceRepository::new(layout.clone()).assign_version(instance, &game_version)?
    } else {
        instance.clone()
    };
    emit(
        progress,
        InstallProgressEvent::Phase {
            phase: "complete".into(),
            message: "整合包更新完成".into(),
        },
    );
    Ok(updated)
}

fn apply_overrides(
    archive: &Path,
    destination: &Path,
    cancel: Option<&CancelFlag>,
) -> Result<HashSet<String>> {
    let mut paths = HashSet::new();
    for prefix in OVERRIDE_PREFIXES {
        paths.extend(extract_override_prefix(
            archive,
            destination,
            prefix,
            cancel,
        )?);
    }
    Ok(paths)
}

fn extract_override_prefix(
    archive: &Path,
    destination: &Path,
    prefix: &str,
    cancel: Option<&CancelFlag>,
) -> Result<HashSet<String>> {
    let file = File::open(archive).map_err(|error| {
        Error::Io(std::io::Error::new(
            error.kind(),
            format!("open {}: {error}", archive.display()),
        ))
    })?;
    let mut zip = zip::ZipArchive::new(file)?;
    let mut extracted = HashSet::new();

    for index in 0..zip.len() {
        check_cancel(cancel)?;
        let mut entry = zip.by_index(index)?;
        let name = entry.name().to_string();
        let Some(relative) = name.strip_prefix(prefix) else {
            continue;
        };
        let relative = relative.trim_end_matches('/');
        if relative.is_empty() {
            continue;
        }
        let target = PathSafety::safe_join(destination, relative)?;

        if entry.is_dir() {
            prepare_destination(destination, &target)?;
            ensure_dir(&target)?;
            continue;
        }
        if entry
            .unix_mode()
            .is_some_and(|mode| mode & 0o170000 == 0o120000)
        {
            return Err(Error::UnsafePath(format!(
                "modpack overrides contain a symlink: {name}"
            )));
        }
        if entry.size() > MAX_OVERRIDE_ENTRY_BYTES {
            return Err(Error::InvalidMetadata(format!(
                "modpack override entry is too large: {name}"
            )));
        }
        PathSafety::validate_archive_entry(relative)?;
        prepare_destination(destination, &target)?;

        let mut output = File::create(&target).map_err(|error| {
            Error::Io(std::io::Error::new(
                error.kind(),
                format!("create {}: {error}", target.display()),
            ))
        })?;
        std::io::copy(&mut entry, &mut output)?;
        output.flush()?;
        extracted.insert(normalize_path_key(relative));
    }
    Ok(extracted)
}

fn remove_obsolete_files(
    instance: &Instance,
    old_manifest: &ModpackManifest,
    index: &MrpackIndex,
    override_paths: &HashSet<String>,
) -> Result<usize> {
    let new_paths: HashSet<String> = index
        .files
        .iter()
        .filter(|file| file.is_client_relevant())
        .map(|file| normalize_path_key(&file.path))
        .collect();
    let mut removed = 0usize;
    let mut seen = HashSet::new();

    for file in &old_manifest.files {
        let key = normalize_path_key(&file.path);
        if key.is_empty() || !seen.insert(key.clone()) {
            continue;
        }
        if new_paths.contains(&key) || override_paths.contains(&key) {
            continue;
        }
        let path = match PathSafety::safe_join(&instance.game_directory, &file.path) {
            Ok(path) => path,
            Err(_) => continue,
        };
        if !existing_parent_within(&instance.game_directory, &path)? {
            tracing::warn!(path = %path.display(), "skipping obsolete modpack file outside instance");
            continue;
        }
        let metadata = match std::fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(Error::Io(error)),
        };
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            continue;
        }
        if !file.sha512.is_empty() {
            let actual = sha512_file(&path).unwrap_or_default();
            if !actual.eq_ignore_ascii_case(&file.sha512) {
                tracing::warn!(path = %path.display(), "not removing modified obsolete modpack file");
                continue;
            }
        }
        std::fs::remove_file(&path).map_err(|error| {
            Error::Io(std::io::Error::new(
                error.kind(),
                format!("remove {}: {error}", path.display()),
            ))
        })?;
        removed += 1;
    }
    Ok(removed)
}

fn write_manifest(instance: &Instance, manifest: &ModpackManifest) -> Result<()> {
    ensure_dir(&instance.directory)?;
    let target = instance.directory.join(MODPACK_METADATA_FILE);
    let temporary = instance.directory.join("modpack.json.tmp");
    let data = serde_json::to_vec_pretty(manifest)?;
    std::fs::write(&temporary, data).map_err(|error| {
        Error::Io(std::io::Error::new(
            error.kind(),
            format!("write {}: {error}", temporary.display()),
        ))
    })?;
    std::fs::rename(&temporary, &target).map_err(|error| {
        Error::Io(std::io::Error::new(
            error.kind(),
            format!("replace {}: {error}", target.display()),
        ))
    })?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Validation and path safety
// ---------------------------------------------------------------------------

fn read_index(archive: &Path) -> Result<MrpackIndex> {
    if !archive.is_file() {
        return Err(Error::NotFound(format!("modpack {}", archive.display())));
    }
    let data = read_entry(archive, MODRINTH_INDEX_FILE, MAX_INDEX_BYTES).map_err(|error| {
        Error::InvalidMetadata(format!("cannot read {MODRINTH_INDEX_FILE}: {error}"))
    })?;
    let index: MrpackIndex = serde_json::from_slice(&data).map_err(|error| {
        Error::InvalidMetadata(format!("invalid {MODRINTH_INDEX_FILE}: {error}"))
    })?;
    validate_index(&index)?;
    Ok(index)
}

fn validate_index(index: &MrpackIndex) -> Result<()> {
    if index.format_version != 1 {
        return Err(Error::UnsupportedVersion(format!(
            "unsupported mrpack formatVersion {}",
            index.format_version
        )));
    }
    if !index.game.is_empty() && !index.game.eq_ignore_ascii_case("minecraft") {
        return Err(Error::UnsupportedVersion(format!(
            "unsupported mrpack game '{}'",
            index.game
        )));
    }

    let mut seen = HashSet::new();
    for file in &index.files {
        if file.path.trim().is_empty() {
            return Err(Error::InvalidMetadata(
                "modpack contains an empty file path".into(),
            ));
        }
        PathSafety::validate_archive_entry(&file.path)?;
        let key = normalize_path_key(&file.path);
        if key.is_empty() {
            return Err(Error::UnsafePath(format!(
                "modpack contains an unusable path '{}'",
                file.path
            )));
        }
        if !seen.insert(key) {
            return Err(Error::InvalidMetadata(format!(
                "duplicate modpack file path '{}'",
                file.path
            )));
        }
        if file.is_client_relevant() {
            if file.hashes.sha512.trim().is_empty() {
                return Err(Error::InvalidMetadata(format!(
                    "modpack file '{}' has no SHA-512 hash",
                    file.path
                )));
            }
            if file.primary_download().is_none() {
                return Err(Error::InvalidMetadata(format!(
                    "modpack file '{}' has no download URL",
                    file.path
                )));
            }
        }
    }
    Ok(())
}

fn minecraft_version(index: &MrpackIndex) -> Result<&str> {
    index
        .dependencies
        .get("minecraft")
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| Error::MissingInput("整合包缺少 minecraft 版本依赖".into()))
}

/// Canonicalises the destination's parent and refuses a path that escapes
/// `base` through `..`, symlinks, or a pre-existing symlink file.
fn prepare_destination(base: &Path, target: &Path) -> Result<()> {
    ensure_dir(base)?;
    let base = std::fs::canonicalize(base).map_err(|error| {
        Error::Io(std::io::Error::new(
            error.kind(),
            format!("resolve {}: {error}", base.display()),
        ))
    })?;
    let parent = target
        .parent()
        .ok_or_else(|| Error::UnsafePath(format!("path has no parent: {}", target.display())))?;
    ensure_dir(parent)?;
    let parent = std::fs::canonicalize(parent).map_err(|error| {
        Error::Io(std::io::Error::new(
            error.kind(),
            format!("resolve {}: {error}", parent.display()),
        ))
    })?;
    if !parent.starts_with(&base) {
        return Err(Error::UnsafePath(format!(
            "path escapes the instance directory: {}",
            target.display()
        )));
    }
    match std::fs::symlink_metadata(target) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(Error::UnsafePath(format!(
            "refusing to write through a symlink: {}",
            target.display()
        ))),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(Error::Io(error)),
    }
}

fn existing_parent_within(base: &Path, target: &Path) -> Result<bool> {
    let base = std::fs::canonicalize(base).map_err(|error| {
        Error::Io(std::io::Error::new(
            error.kind(),
            format!("resolve {}: {error}", base.display()),
        ))
    })?;
    let Some(parent) = target.parent() else {
        return Ok(false);
    };
    match std::fs::canonicalize(parent) {
        Ok(parent) => Ok(parent.starts_with(&base)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(Error::Io(error)),
    }
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn emit(progress: Option<&SharedProgress>, event: InstallProgressEvent) {
    if let Some(progress) = progress {
        progress.emit(event);
    }
}

fn check_cancel(cancel: Option<&CancelFlag>) -> Result<()> {
    if cancel.is_some_and(|flag| flag.is_cancelled()) {
        Err(Error::Cancelled)
    } else {
        Ok(())
    }
}

fn pack_display_name(index: &MrpackIndex, archive: &Path, requested: &str) -> String {
    let requested = requested.trim();
    if !requested.is_empty() {
        return requested.to_string();
    }
    let name = index.name.trim();
    if !name.is_empty() {
        return name.to_string();
    }
    archive
        .file_stem()
        .and_then(|stem| stem.to_str())
        .map(str::to_string)
        .unwrap_or_else(|| "Modpack".to_string())
}

fn normalize_path_key(path: &str) -> String {
    path.replace('\\', "/")
        .trim_start_matches("./")
        .trim_end_matches('/')
        .to_ascii_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_fabric_loader() {
        let mut dependencies = BTreeMap::new();
        dependencies.insert("minecraft".to_string(), "1.20.1".to_string());
        dependencies.insert("fabric-loader".to_string(), "0.15.0".to_string());
        let loader = resolve_loader(&dependencies).unwrap();
        assert_eq!(loader.kind, ModpackLoaderKind::Fabric);
        assert_eq!(loader.version, "0.15.0");
        assert_eq!(loader.minecraft, "1.20.1");
        assert_eq!(loader.kind.modrinth_loader(), "fabric");
    }

    #[test]
    fn prefers_neoforge_over_forge() {
        let mut dependencies = BTreeMap::new();
        dependencies.insert("minecraft".to_string(), "1.20.4".to_string());
        dependencies.insert("forge".to_string(), "49.0.0".to_string());
        dependencies.insert("neoforge".to_string(), "20.4.100".to_string());
        assert_eq!(
            resolve_loader(&dependencies).map(|loader| loader.kind),
            Some(ModpackLoaderKind::NeoForge)
        );
    }

    #[test]
    fn filters_unsupported_client_files() {
        let file = MrpackFile {
            env: Some(MrpackEnvironment {
                client: Some("unsupported".to_string()),
                server: Some("required".to_string()),
            }),
            ..MrpackFile::default()
        };
        assert!(!file.is_client_relevant());

        let optional = MrpackFile {
            env: Some(MrpackEnvironment {
                client: Some("optional".to_string()),
                server: None,
            }),
            ..MrpackFile::default()
        };
        assert!(optional.is_client_relevant());
    }

    #[test]
    fn normalizes_paths_for_comparison() {
        assert_eq!(normalize_path_key("./mods\\Sodium.JAR"), "mods/sodium.jar");
        assert_eq!(normalize_path_key("mods/sodium.jar/"), "mods/sodium.jar");
    }

    #[test]
    fn reads_swift_pack_record_without_rewriting() {
        use crate::layout::GameDataLayout;
        use crate::models::instance::InstanceRepository;

        let root =
            std::env::temp_dir().join(format!("lingxi-modpack-legacy-{}", uuid::Uuid::new_v4()));
        let layout = GameDataLayout::new(root.join("minecraft"), root.clone());
        let repository = InstanceRepository::new(layout);
        let instance = repository
            .create("legacy", "Legacy Pack", Some("1.20.1"))
            .unwrap();
        let manifest_path = instance.directory.join(MODPACK_METADATA_FILE);
        let payload = r#"{
            "schemaVersion": 1,
            "projectID": "legacy-pack",
            "versionID": "pack-1",
            "packVersionID": "pv-1",
            "modrinthProjectID": "proj",
            "modrinthVersionID": "ver",
            "minecraftVersion": "1.20.1",
            "loaderKind": "fabric",
            "loaderVersion": "0.15.0",
            "installedAt": "2025-01-02T03:04:05Z",
            "files": [
                { "path": "mods/a.jar", "sha1": "aa", "sha512": "bb", "byteCount": 123 }
            ]
        }"#;
        std::fs::write(&manifest_path, payload).unwrap();

        let manifest = read_manifest(&instance).unwrap();
        assert_eq!(manifest.name, "Legacy Pack");
        assert_eq!(manifest.version_id, "pv-1");
        assert_eq!(manifest.files.len(), 1);
        assert_eq!(manifest.files[0].file_size, 123);
        assert_eq!(
            manifest.loader.as_ref().map(|loader| loader.kind),
            Some(ModpackLoaderKind::Fabric)
        );
        assert_eq!(
            manifest
                .dependencies
                .get("fabric-loader")
                .map(String::as_str),
            Some("0.15.0")
        );
        assert!(manifest.project_id.is_none());
        assert_eq!(std::fs::read_to_string(&manifest_path).unwrap(), payload);
        let _ = std::fs::remove_dir_all(&root);
    }
}
