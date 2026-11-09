//! Installed mod management for a single instance.
//!
//! Enabled jars live in `<game directory>/mods`, disabled jars in
//! `<instance directory>/mods-disabled`. Metadata is kept in
//! `<instance directory>/mods.json`; jars without metadata are surfaced as
//! manual mods so a hand-copied file is never invisible to the UI.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::install::hashing::{sha1_file, sha512_file};
use crate::layout::{ensure_dir, GameDataLayout};
use crate::models::instance::Instance;
use crate::modrinth::{best_version, ModrinthClient, Version};
use crate::paths::PathSafety;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ModSource {
    Modrinth,
    #[default]
    #[serde(rename = "local", alias = "manual")]
    Manual,
    Modpack,
}

/// Persisted mod entry. Field names are camelCase on disk to match the Swift
/// launcher's schema.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstalledMod {
    #[serde(default, deserialize_with = "deserialize_string_or_default")]
    pub project_id: String,
    #[serde(default, deserialize_with = "deserialize_string_or_default")]
    pub slug: String,
    #[serde(default, deserialize_with = "deserialize_string_or_default")]
    pub title: String,
    #[serde(default, deserialize_with = "deserialize_string_or_default")]
    pub version_id: String,
    #[serde(default, deserialize_with = "deserialize_string_or_default")]
    pub version_number: String,
    #[serde(default, deserialize_with = "deserialize_string_or_default")]
    pub file_name: String,
    #[serde(default, deserialize_with = "deserialize_string_or_default")]
    pub sha1: String,
    #[serde(default, deserialize_with = "deserialize_string_or_default")]
    pub sha512: String,
    #[serde(default = "enabled_by_default")]
    pub enabled: bool,
    #[serde(default)]
    pub source: ModSource,
    #[serde(default, deserialize_with = "deserialize_string_or_default")]
    pub license: String,
    #[serde(default, deserialize_with = "deserialize_string_or_default")]
    pub icon_url: String,
    #[serde(default = "Utc::now")]
    pub installed_at: DateTime<Utc>,
}

impl InstalledMod {
    pub fn is_modrinth(&self) -> bool {
        self.source == ModSource::Modrinth && !self.project_id.is_empty()
    }
}

fn enabled_by_default() -> bool {
    true
}

fn deserialize_string_or_default<'de, D>(deserializer: D) -> std::result::Result<String, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Ok(Option::<String>::deserialize(deserializer)?.unwrap_or_default())
}

/// A newer version found by [`ModManager::check_updates`].
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModUpdate {
    pub project_id: String,
    pub current_version_id: String,
    pub latest_version: Version,
    #[serde(default)]
    pub latest_version_id: String,
    #[serde(default)]
    pub latest_version_number: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub icon_url: String,
    #[serde(default)]
    pub download_url: String,
    #[serde(default)]
    pub file_name: String,
}

pub struct ModManager {
    instance: Instance,
    layout: GameDataLayout,
    client: ModrinthClient,
}

impl ModManager {
    pub fn new(instance: Instance, layout: GameDataLayout) -> Result<Self> {
        let client = ModrinthClient::new()?;
        Ok(Self::with_client(instance, layout, client))
    }

    pub fn with_client(instance: Instance, layout: GameDataLayout, client: ModrinthClient) -> Self {
        Self {
            instance,
            layout,
            client,
        }
    }

    pub fn instance(&self) -> &Instance {
        &self.instance
    }

    pub fn layout(&self) -> &GameDataLayout {
        &self.layout
    }

    pub fn client(&self) -> &ModrinthClient {
        &self.client
    }

    /// Lists jars from both mod directories, merging metadata. Metadata whose
    /// file disappeared is omitted; jars without metadata become manual entries.
    pub fn list(&self) -> Result<Vec<InstalledMod>> {
        let mut entries = self.load_metadata()?;
        let mut index_by_name: HashMap<String, usize> = entries
            .iter()
            .enumerate()
            .filter(|(_, entry)| !entry.file_name.is_empty())
            .map(|(index, entry)| (entry.file_name.to_ascii_lowercase(), index))
            .collect();
        let mut found: HashSet<String> = HashSet::new();

        let directories = [
            (true, self.instance.mods_directory()),
            (false, self.instance.disabled_mods_directory()),
        ];
        for (enabled, directory) in directories {
            for path in jars_in(&directory)? {
                let file_name = file_name_of(&path)?;
                let key = file_name.to_ascii_lowercase();
                if !found.insert(key.clone()) {
                    continue;
                }
                if let Some(&index) = index_by_name.get(&key) {
                    entries[index].enabled = enabled;
                    entries[index].file_name = file_name;
                    continue;
                }
                let record = InstalledMod {
                    project_id: manual_project_id(&sha1_or_empty(&path), &file_name),
                    slug: String::new(),
                    title: title_from_file_name(&file_name),
                    version_id: String::new(),
                    version_number: String::new(),
                    file_name,
                    sha1: sha1_or_empty(&path),
                    sha512: sha512_or_empty(&path),
                    enabled,
                    source: ModSource::Manual,
                    license: String::new(),
                    icon_url: String::new(),
                    installed_at: installed_time(&path),
                };
                index_by_name.insert(key, entries.len());
                entries.push(record);
            }
        }

        entries.retain(|entry| found.contains(&entry.file_name.to_ascii_lowercase()));
        entries.sort_by(|left, right| {
            left.title
                .to_ascii_lowercase()
                .cmp(&right.title.to_ascii_lowercase())
                .then_with(|| left.file_name.cmp(&right.file_name))
        });
        Ok(entries)
    }

    /// Downloads the primary file of a Modrinth version and records it.
    pub async fn install_version(&self, version: &Version) -> Result<InstalledMod> {
        let file = version.primary_file().ok_or_else(|| {
            Error::InvalidMetadata(format!("Modrinth version '{}' has no files", version.id))
        })?;
        if file.url.trim().is_empty() {
            return Err(Error::InvalidMetadata(format!(
                "Modrinth version '{}' has no download URL",
                version.id
            )));
        }
        if version.project_id.trim().is_empty() {
            return Err(Error::InvalidMetadata(format!(
                "Modrinth version '{}' has no project id",
                version.id
            )));
        }
        let project = self.client.project(&version.project_id).await?;

        let mut entries = self.load_metadata()?;
        let previous_index = entries.iter().position(|entry| {
            entry.source == ModSource::Modrinth && entry.project_id == version.project_id
        });
        let previous = previous_index.map(|index| entries[index].clone());
        let claimed: HashSet<String> = entries
            .iter()
            .enumerate()
            .filter(|(index, _)| Some(*index) != previous_index)
            .map(|(_, entry)| entry.file_name.to_ascii_lowercase())
            .collect();

        let desired = if file.filename.trim().is_empty() {
            format!("{}-{}.jar", project.slug, version.version_number)
        } else {
            file.filename.clone()
        };
        let desired = sanitize_mod_file_name(&desired)?;
        let enabled = previous.as_ref().map(|entry| entry.enabled).unwrap_or(true);
        let target_directory = if enabled {
            self.instance.mods_directory()
        } else {
            self.instance.disabled_mods_directory()
        };
        ensure_dir(&target_directory)?;

        let keep_existing_name = previous
            .as_ref()
            .is_some_and(|entry| entry.file_name.eq_ignore_ascii_case(&desired));
        let file_name = if keep_existing_name {
            desired
        } else {
            unique_file_name(
                &[
                    &self.instance.mods_directory(),
                    &self.instance.disabled_mods_directory(),
                ],
                &desired,
                &claimed,
            )?
        };
        let destination = PathSafety::safe_join(&target_directory, &file_name)?;

        self.client.download_file(file, &destination).await?;

        let record = InstalledMod {
            project_id: version.project_id.clone(),
            slug: project.slug.clone(),
            title: project.title.clone(),
            version_id: version.id.clone(),
            version_number: version.version_number.clone(),
            file_name: file_name.clone(),
            sha1: sha1_file(&destination)?,
            sha512: sha512_file(&destination)?,
            enabled,
            source: ModSource::Modrinth,
            license: project.license.display_name(),
            icon_url: project.icon_url.unwrap_or_default(),
            installed_at: Utc::now(),
        };

        if let Some(index) = previous_index {
            entries.remove(index);
        }
        if let Some(old) = previous {
            remove_stale_file(&self.instance, &old.file_name, &destination);
        }
        entries.push(record.clone());
        self.write_metadata(&entries)?;
        Ok(record)
    }

    /// Imports a jar that was not downloaded through Modrinth. The source file
    /// is copied, hashes are computed locally, and an enabled record is written.
    pub fn install_file(&self, path: &Path, source: ModSource) -> Result<InstalledMod> {
        if !path.is_file() {
            return Err(Error::NotFound(format!("mod file {}", path.display())));
        }
        let original_name = file_name_of(path)?;
        let sha1 = sha1_file(path)?;
        let sha512 = sha512_file(path)?;

        let mut entries = self.load_metadata()?;
        if !sha512.is_empty() {
            if let Some(existing) = entries
                .iter()
                .find(|entry| entry.sha512.eq_ignore_ascii_case(&sha512))
            {
                if self.locate_mod(existing).is_ok() {
                    return Ok(existing.clone());
                }
            }
        }

        let desired = sanitize_mod_file_name(&original_name)?;
        let claimed: HashSet<String> = entries
            .iter()
            .map(|entry| entry.file_name.to_ascii_lowercase())
            .collect();
        let target_directory = self.instance.mods_directory();
        ensure_dir(&target_directory)?;
        let file_name = unique_file_name(
            &[
                &self.instance.mods_directory(),
                &self.instance.disabled_mods_directory(),
            ],
            &desired,
            &claimed,
        )?;
        let destination = PathSafety::safe_join(&target_directory, &file_name)?;
        if !same_file(path, &destination) {
            std::fs::copy(path, &destination).map_err(|e| {
                Error::Io(std::io::Error::new(
                    e.kind(),
                    format!("copy {}: {e}", path.display()),
                ))
            })?;
        }

        let record = InstalledMod {
            project_id: manual_project_id(&sha1, &file_name),
            slug: String::new(),
            title: title_from_file_name(&file_name),
            version_id: String::new(),
            version_number: String::new(),
            file_name,
            sha1,
            sha512,
            enabled: true,
            source,
            license: String::new(),
            icon_url: String::new(),
            installed_at: Utc::now(),
        };
        entries.push(record.clone());
        self.write_metadata(&entries)?;
        Ok(record)
    }

    /// Moves a mod between `mods/` and `mods-disabled/`.
    pub fn set_enabled(&self, project_id: &str, enabled: bool) -> Result<InstalledMod> {
        let mut entries = self.load_metadata()?;
        let index = entries
            .iter()
            .position(|entry| entry.project_id == project_id)
            .ok_or_else(|| Error::NotFound(format!("mod '{project_id}'")))?;
        let record = entries[index].clone();
        let source_path = self.locate_mod(&record)?;
        let target_directory = if enabled {
            self.instance.mods_directory()
        } else {
            self.instance.disabled_mods_directory()
        };
        ensure_dir(&target_directory)?;

        if source_path.parent() == Some(target_directory.as_path()) {
            entries[index].enabled = enabled;
            entries[index].file_name = file_name_of(&source_path)?;
            self.write_metadata(&entries)?;
            return Ok(entries[index].clone());
        }

        let claimed: HashSet<String> = entries
            .iter()
            .enumerate()
            .filter(|(other, _)| *other != index)
            .map(|(_, entry)| entry.file_name.to_ascii_lowercase())
            .collect();
        let desired = sanitize_file_name(&record.file_name)?;
        let target = PathSafety::safe_join(&target_directory, &desired)?;
        let file_name = if target.exists() || claimed.contains(&desired.to_ascii_lowercase()) {
            unique_file_name(&[&target_directory], &desired, &claimed)?
        } else {
            desired
        };
        let destination = PathSafety::safe_join(&target_directory, &file_name)?;
        move_file(&source_path, &destination)?;

        entries[index].enabled = enabled;
        entries[index].file_name = file_name;
        let updated = entries[index].clone();
        self.write_metadata(&entries)?;
        Ok(updated)
    }

    /// Deletes the jar and its metadata entry.
    pub fn remove(&self, project_id: &str) -> Result<()> {
        let mut entries = self.load_metadata()?;
        let index = entries
            .iter()
            .position(|entry| entry.project_id == project_id)
            .ok_or_else(|| Error::NotFound(format!("mod '{project_id}'")))?;
        let record = entries.remove(index);

        for directory in [
            self.instance.mods_directory(),
            self.instance.disabled_mods_directory(),
        ] {
            let path = PathSafety::safe_join(&directory, &record.file_name)?;
            match std::fs::remove_file(&path) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => {
                    return Err(Error::Io(std::io::Error::new(
                        error.kind(),
                        format!("remove {}: {error}", path.display()),
                    )))
                }
            }
        }
        self.write_metadata(&entries)?;
        Ok(())
    }

    /// Queries Modrinth for every Modrinth-sourced mod. Network errors abort the
    /// scan; missing projects are skipped.
    pub async fn check_updates(&self) -> Result<Vec<ModUpdate>> {
        let entries = self.load_metadata()?;
        let game_version = self.instance.manifest.version_id.clone();
        let mut updates = Vec::new();

        for entry in entries.iter().filter(|entry| entry.is_modrinth()) {
            let versions = match self.client.versions(&entry.project_id, &[], &[]).await {
                Ok(versions) => versions,
                Err(Error::NotFound(_)) => continue,
                Err(error) => return Err(error),
            };
            let latest = best_version(&versions, game_version.as_deref(), None)
                .or_else(|| best_version(&versions, None, None));
            let Some(latest) = latest else { continue };
            if latest.id == entry.version_id {
                continue;
            }
            let Some(file) = latest.primary_file() else {
                continue;
            };
            updates.push(ModUpdate {
                project_id: entry.project_id.clone(),
                current_version_id: entry.version_id.clone(),
                latest_version: latest.clone(),
                latest_version_id: latest.id.clone(),
                latest_version_number: latest.version_number.clone(),
                title: if entry.title.is_empty() {
                    entry.file_name.clone()
                } else {
                    entry.title.clone()
                },
                icon_url: entry.icon_url.clone(),
                download_url: file.url.clone(),
                file_name: file.filename.clone(),
            });
        }
        updates.sort_by(|left, right| {
            left.title
                .to_ascii_lowercase()
                .cmp(&right.title.to_ascii_lowercase())
        });
        Ok(updates)
    }

    /// Downloads and installs the version carried by an update record.
    pub async fn apply_update(&self, update: &ModUpdate) -> Result<InstalledMod> {
        self.install_version(&update.latest_version).await
    }

    fn load_metadata(&self) -> Result<Vec<InstalledMod>> {
        let path = self.instance.mods_metadata();
        if !path.is_file() {
            return Ok(Vec::new());
        }
        let data = std::fs::read(&path).map_err(|e| {
            Error::Io(std::io::Error::new(
                e.kind(),
                format!("read {}: {e}", path.display()),
            ))
        })?;
        if data.iter().all(u8::is_ascii_whitespace) {
            return Ok(Vec::new());
        }
        serde_json::from_slice(&data).map_err(|e| {
            Error::InvalidMetadata(format!("corrupted mod metadata {}: {e}", path.display()))
        })
    }

    fn write_metadata(&self, entries: &[InstalledMod]) -> Result<()> {
        ensure_dir(&self.instance.directory)?;
        let target = self.instance.mods_metadata();
        let temporary = target.with_extension("json.tmp");
        let data = serde_json::to_vec_pretty(entries)?;
        std::fs::write(&temporary, data).map_err(|e| {
            Error::Io(std::io::Error::new(
                e.kind(),
                format!("write {}: {e}", temporary.display()),
            ))
        })?;
        std::fs::rename(&temporary, &target).map_err(|e| {
            Error::Io(std::io::Error::new(
                e.kind(),
                format!("replace {}: {e}", target.display()),
            ))
        })?;
        Ok(())
    }

    fn locate_mod(&self, entry: &InstalledMod) -> Result<PathBuf> {
        let file_name = sanitize_file_name(&entry.file_name)?;
        for directory in [
            self.instance.mods_directory(),
            self.instance.disabled_mods_directory(),
        ] {
            let path = PathSafety::safe_join(&directory, &file_name)?;
            if path.is_file() {
                return Ok(path);
            }
        }
        Err(Error::NotFound(format!("mod file '{}'", entry.file_name)))
    }
}

fn jars_in(directory: &Path) -> Result<Vec<PathBuf>> {
    if !directory.is_dir() {
        return Ok(Vec::new());
    }
    let mut jars = Vec::new();
    for entry in std::fs::read_dir(directory)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_file()
            && path
                .extension()
                .and_then(|extension| extension.to_str())
                .is_some_and(|extension| extension.eq_ignore_ascii_case("jar"))
        {
            jars.push(path);
        }
    }
    jars.sort();
    Ok(jars)
}

fn file_name_of(path: &Path) -> Result<String> {
    path.file_name()
        .and_then(|name| name.to_str())
        .map(str::to_string)
        .ok_or_else(|| {
            Error::InvalidMetadata(format!("path has no usable file name: {}", path.display()))
        })
}

/// Rejects separators and traversal, replaces characters that are illegal on
/// Windows, and validates the result as a single path component.
pub fn sanitize_file_name(name: &str) -> Result<String> {
    let name = name.trim();
    if name.is_empty() {
        return Err(Error::UnsafePath("empty mod file name".into()));
    }
    if name.contains('/') || name.contains('\\') {
        return Err(Error::UnsafePath(format!(
            "mod file name contains a separator: {name}"
        )));
    }
    let mut cleaned = String::with_capacity(name.len());
    for character in name.chars() {
        if character.is_control() || matches!(character, ':' | '*' | '?' | '"' | '<' | '>' | '|') {
            cleaned.push('_');
        } else {
            cleaned.push(character);
        }
    }
    let cleaned = cleaned.trim().trim_end_matches(['.', ' ']);
    if cleaned.is_empty() || cleaned == "." || cleaned == ".." {
        return Err(Error::UnsafePath(format!("unusable mod file name: {name}")));
    }
    PathSafety::validate_component(cleaned)?;
    Ok(cleaned.to_string())
}

fn sanitize_mod_file_name(name: &str) -> Result<String> {
    let mut name = sanitize_file_name(name)?;
    if Path::new(&name).extension().is_none() {
        name.push_str(".jar");
    }
    Ok(name)
}

fn unique_file_name(
    directories: &[&Path],
    desired: &str,
    claimed: &HashSet<String>,
) -> Result<String> {
    let path = Path::new(desired);
    let stem = path
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("mod");
    let extension = path.extension().and_then(|extension| extension.to_str());
    for attempt in 1..=10000u32 {
        let candidate = if attempt == 1 {
            desired.to_string()
        } else {
            match extension {
                Some(extension) => format!("{stem}-{attempt}.{extension}"),
                None => format!("{stem}-{attempt}"),
            }
        };
        if claimed.contains(&candidate.to_ascii_lowercase()) {
            continue;
        }
        if directories
            .iter()
            .any(|directory| directory.join(&candidate).exists())
        {
            continue;
        }
        return Ok(candidate);
    }
    Err(Error::Other(format!(
        "cannot find a free file name for '{desired}'"
    )))
}

fn manual_project_id(sha1: &str, file_name: &str) -> String {
    if sha1.len() >= 12 {
        format!("manual:{}", &sha1[..12])
    } else {
        format!("manual:{file_name}")
    }
}

fn title_from_file_name(file_name: &str) -> String {
    let stem = Path::new(file_name)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or(file_name);
    let title: String = stem
        .chars()
        .map(|character| {
            if character == '_' || character == '-' {
                ' '
            } else {
                character
            }
        })
        .collect();
    let title = title.trim();
    if title.is_empty() {
        file_name.to_string()
    } else {
        title.to_string()
    }
}

fn installed_time(path: &Path) -> DateTime<Utc> {
    std::fs::metadata(path)
        .and_then(|metadata| metadata.modified())
        .map(DateTime::<Utc>::from)
        .unwrap_or_else(|_| Utc::now())
}

fn sha1_or_empty(path: &Path) -> String {
    sha1_file(path).unwrap_or_default()
}

fn sha512_or_empty(path: &Path) -> String {
    sha512_file(path).unwrap_or_default()
}

fn remove_stale_file(instance: &Instance, old_name: &str, keep: &Path) {
    if old_name.is_empty() {
        return;
    }
    for directory in [
        instance.mods_directory(),
        instance.disabled_mods_directory(),
    ] {
        if let Ok(path) = PathSafety::safe_join(&directory, old_name) {
            if path != keep {
                let _ = std::fs::remove_file(path);
            }
        }
    }
}

fn move_file(source: &Path, destination: &Path) -> Result<()> {
    if let Some(parent) = destination.parent() {
        ensure_dir(parent)?;
    }
    match std::fs::rename(source, destination) {
        Ok(()) => Ok(()),
        Err(_) => {
            std::fs::copy(source, destination).map_err(|e| {
                Error::Io(std::io::Error::new(
                    e.kind(),
                    format!(
                        "copy {} to {}: {e}",
                        source.display(),
                        destination.display()
                    ),
                ))
            })?;
            std::fs::remove_file(source)?;
            Ok(())
        }
    }
}

fn same_file(left: &Path, right: &Path) -> bool {
    match (std::fs::canonicalize(left), std::fs::canonicalize(right)) {
        (Ok(left), Ok(right)) => left == right,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizes_unsafe_names() {
        assert_eq!(sanitize_file_name("Cool Mod.jar").unwrap(), "Cool Mod.jar");
        assert_eq!(sanitize_file_name("a:b?.jar").unwrap(), "a_b_.jar");
        assert!(sanitize_file_name("../evil.jar").is_err());
        assert!(sanitize_file_name("dir/evil.jar").is_err());
        assert!(sanitize_file_name("...").is_err());
    }

    #[test]
    fn unique_names_avoid_claims() {
        let directory = std::env::temp_dir();
        let mut claimed = HashSet::new();
        claimed.insert("mod.jar".to_string());
        let name = unique_file_name(&[&directory], "mod.jar", &claimed).unwrap();
        assert_eq!(name, "mod-2.jar");
    }

    #[test]
    fn manual_ids_are_stable() {
        assert_eq!(
            manual_project_id("0123456789abcdef", "x.jar"),
            "manual:0123456789ab"
        );
        assert_eq!(manual_project_id("", "x.jar"), "manual:x.jar");
    }
}
