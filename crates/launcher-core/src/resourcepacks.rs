//! Resource-pack discovery and management for one instance game directory.
//!
//! A pack is either a `.zip` below `<gameDir>/resourcepacks` or an unpacked
//! directory. Metadata comes from `pack.mcmeta`; the enabled list is the
//! `resourcePacks` JSON array in `options.txt`.

use std::collections::BTreeSet;
use std::io::Read;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::{Error, Result};
use crate::layout::ensure_dir;
use crate::models::instance::Instance;
use crate::paths::PathSafety;

const MAX_MCMETA_BYTES: u64 = 1024 * 1024;
const MAX_ICON_BYTES: u64 = 512 * 1024;
const MAX_PACK_DEPTH: u32 = 32;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResourcePackEntry {
    /// Direct child name: `foo.zip` or the pack directory name.
    pub file_name: String,
    /// Display title: archive stem or directory name.
    pub title: String,
    pub description: String,
    #[serde(default)]
    pub pack_format: Option<i32>,
    pub enabled: bool,
    pub size_bytes: u64,
    /// `data:image/png;base64,...` for an embedded `pack.png`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon_data_url: Option<String>,
}

#[derive(Debug, Clone, Default)]
struct PackMetadata {
    description: String,
    pack_format: Option<i32>,
    icon: Option<Vec<u8>>,
}

/// Manages the resource packs of one game directory. All mutating methods take
/// a direct child name, never a path, so callers cannot reach outside the pack
/// directory.
#[derive(Debug, Clone)]
pub struct ResourcePackManager {
    game_directory: PathBuf,
}

impl ResourcePackManager {
    pub fn new(game_directory: impl Into<PathBuf>) -> Self {
        Self {
            game_directory: game_directory.into(),
        }
    }

    pub fn for_instance(instance: &Instance) -> Self {
        Self::new(instance.game_directory.clone())
    }

    pub fn packs_directory(&self) -> PathBuf {
        self.game_directory.join("resourcepacks")
    }

    pub fn options_path(&self) -> PathBuf {
        self.game_directory.join("options.txt")
    }

    /// Lists `.zip` archives and unpacked directories, alphabetically by title.
    /// A pack with a missing or broken `pack.mcmeta` is still listed with
    /// default metadata so the user can inspect or delete it.
    pub fn list(&self) -> Result<Vec<ResourcePackEntry>> {
        let directory = self.packs_directory();
        if !directory.is_dir() {
            return Ok(Vec::new());
        }
        let enabled = self.read_enabled()?;
        let mut entries = Vec::new();
        for entry in std::fs::read_dir(&directory)? {
            let entry = match entry {
                Ok(entry) => entry,
                Err(_) => continue,
            };
            let file_type = match entry.file_type() {
                Ok(file_type) => file_type,
                Err(_) => continue,
            };
            if file_type.is_symlink() {
                continue;
            }
            let file_name = match entry.file_name().into_string() {
                Ok(name) => name,
                Err(_) => continue,
            };
            if file_name.starts_with('.') || PathSafety::validate_component(&file_name).is_err() {
                continue;
            }
            let is_zip = file_type.is_file() && file_name.to_ascii_lowercase().ends_with(".zip");
            if !file_type.is_dir() && !is_zip {
                continue;
            }
            if let Some(summary) =
                build_entry(&entry.path(), &file_name, enabled.contains(&file_name))
            {
                entries.push(summary);
            }
        }
        entries.sort_by(|left, right| {
            left.title
                .to_ascii_lowercase()
                .cmp(&right.title.to_ascii_lowercase())
                .then_with(|| left.file_name.cmp(&right.file_name))
        });
        Ok(entries)
    }

    /// Adds or removes the pack from the `resourcePacks` array, preserving
    /// every other line of `options.txt`.
    pub fn set_enabled(&self, file_name: &str, enabled: bool) -> Result<()> {
        let name = PathSafety::validate_component(file_name)?;
        self.require_pack(name)?;
        let mut packs = self.read_enabled()?;
        if enabled {
            packs.insert(name.to_string());
        } else {
            packs.remove(name);
        }
        self.write_enabled(&packs)
    }

    pub fn toggle(&self, file_name: &str) -> Result<bool> {
        let name = PathSafety::validate_component(file_name)?;
        self.require_pack(name)?;
        let mut packs = self.read_enabled()?;
        let next = if packs.contains(name) {
            packs.remove(name);
            false
        } else {
            packs.insert(name.to_string());
            true
        };
        self.write_enabled(&packs)?;
        Ok(next)
    }

    /// Copies a zip from an arbitrary path into the pack directory, using a
    /// unique name when the destination already exists.
    pub fn import(&self, source: &Path) -> Result<ResourcePackEntry> {
        let extension = source
            .extension()
            .and_then(|ext| ext.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        if extension != "zip" {
            return Err(Error::InvalidMetadata(format!(
                "resource pack '{}' is not a .zip archive",
                source.display()
            )));
        }
        let metadata = std::fs::metadata(source)?;
        if !metadata.is_file() {
            return Err(Error::InvalidMetadata(format!(
                "resource pack '{}' is not a regular file",
                source.display()
            )));
        }
        // Opening the archive is the integrity check; a corrupt zip must not
        // be copied into the instance.
        let file = std::fs::File::open(source)?;
        zip::ZipArchive::new(file)?;

        let directory = self.packs_directory();
        ensure_dir(&directory)?;
        let source_name = source
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| Error::InvalidMetadata("resource pack has no file name".into()))?;
        PathSafety::validate_component(source_name)?;

        // Importing a pack that already lives in this directory is a no-op.
        if let (Ok(canonical_source), Ok(canonical_directory)) =
            (source.canonicalize(), directory.canonicalize())
        {
            if canonical_source.parent() == Some(canonical_directory.as_path()) {
                return self
                    .entry_for(source_name)
                    .ok_or_else(|| Error::Other("imported resource pack disappeared".into()));
            }
        }

        let target_name = unique_child_name(&directory, source_name);
        let target = PathSafety::safe_join(&directory, &target_name)?;
        std::fs::copy(source, &target)?;
        self.entry_for(&target_name)
            .ok_or_else(|| Error::Other("imported resource pack could not be read".into()))
    }

    /// Deletes one direct child of the resource-pack directory.
    pub fn delete(&self, file_name: &str) -> Result<()> {
        let name = PathSafety::validate_component(file_name)?;
        let directory = self.packs_directory();
        let path = PathSafety::safe_join(&directory, name)?;
        let metadata = std::fs::symlink_metadata(&path)
            .map_err(|_| Error::NotFound(format!("resource pack '{}'", path.display())))?;
        if metadata.file_type().is_symlink() {
            return Err(Error::UnsafePath(format!(
                "resource pack '{}' is a symlink",
                path.display()
            )));
        }
        if metadata.is_dir() {
            std::fs::remove_dir_all(&path)?;
        } else if metadata.is_file() {
            std::fs::remove_file(&path)?;
        } else {
            return Err(Error::UnsafePath(format!(
                "resource pack '{}' is not a file or directory",
                path.display()
            )));
        }
        Ok(())
    }

    fn require_pack(&self, file_name: &str) -> Result<()> {
        let path = PathSafety::safe_join(&self.packs_directory(), file_name)?;
        let metadata = std::fs::symlink_metadata(&path)
            .map_err(|_| Error::NotFound(format!("resource pack '{}'", path.display())))?;
        if metadata.file_type().is_symlink() || (!metadata.is_dir() && !metadata.is_file()) {
            return Err(Error::UnsafePath(format!(
                "resource pack '{}' is not a regular file or directory",
                path.display()
            )));
        }
        Ok(())
    }

    fn entry_for(&self, file_name: &str) -> Option<ResourcePackEntry> {
        let enabled = self.read_enabled().ok()?;
        let path = self.packs_directory().join(file_name);
        build_entry(&path, file_name, enabled.contains(file_name))
    }

    fn read_enabled(&self) -> Result<BTreeSet<String>> {
        let path = self.options_path();
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(BTreeSet::new())
            }
            Err(error) => return Err(error.into()),
        };
        for line in text.lines() {
            if let Some(rest) = line.trim_start().strip_prefix("resourcePacks:") {
                if let Ok(list) = serde_json::from_str::<Vec<String>>(rest.trim()) {
                    return Ok(list.into_iter().collect());
                }
            }
        }
        Ok(BTreeSet::new())
    }

    fn write_enabled(&self, packs: &BTreeSet<String>) -> Result<()> {
        ensure_dir(&self.game_directory)?;
        let path = self.options_path();
        let content = std::fs::read_to_string(&path).unwrap_or_default();
        let mut lines: Vec<String> = content.split('\n').map(str::to_string).collect();
        let ordered: Vec<&String> = packs.iter().collect();
        let value = serde_json::to_string(&ordered)?;
        let new_line = format!("resourcePacks:{value}");
        let mut replaced = false;
        for line in lines.iter_mut() {
            if line.trim_start().starts_with("resourcePacks:") {
                *line = new_line.clone();
                replaced = true;
                break;
            }
        }
        if !replaced {
            let insert_at = if lines.last().map(String::is_empty).unwrap_or(false) {
                lines.len().saturating_sub(1)
            } else {
                lines.len()
            };
            lines.insert(insert_at, new_line);
        }
        write_atomic(&path, lines.join("\n").as_bytes())
    }
}

fn build_entry(path: &Path, file_name: &str, enabled: bool) -> Option<ResourcePackEntry> {
    let metadata = std::fs::symlink_metadata(path).ok()?;
    if metadata.file_type().is_symlink() {
        return None;
    }
    let title = if metadata.is_dir() {
        file_name.to_string()
    } else {
        file_name
            .strip_suffix(".zip")
            .or_else(|| file_name.strip_suffix(".ZIP"))
            .unwrap_or(file_name)
            .to_string()
    };
    let size_bytes = if metadata.is_dir() {
        directory_size(path, 0)
    } else {
        metadata.len()
    };
    let pack_metadata = if metadata.is_dir() {
        read_directory_metadata(path)
    } else {
        read_zip_metadata(path)
    };
    Some(ResourcePackEntry {
        file_name: file_name.to_string(),
        title,
        description: pack_metadata.description,
        pack_format: pack_metadata.pack_format,
        enabled,
        size_bytes,
        icon_data_url: pack_metadata.icon.as_deref().map(icon_data_url),
    })
}

fn read_directory_metadata(directory: &Path) -> PackMetadata {
    let mut metadata = PackMetadata::default();
    let mcmeta = directory.join("pack.mcmeta");
    if let Ok(meta) = std::fs::metadata(&mcmeta) {
        if meta.is_file() && meta.len() <= MAX_MCMETA_BYTES {
            if let Ok(bytes) = std::fs::read(&mcmeta) {
                metadata = parse_mcmeta(&bytes);
            }
        }
    }
    let icon = directory.join("pack.png");
    if let Ok(meta) = std::fs::metadata(&icon) {
        if meta.is_file() && meta.len() <= MAX_ICON_BYTES {
            metadata.icon = std::fs::read(&icon).ok();
        }
    }
    metadata
}

fn read_zip_metadata(path: &Path) -> PackMetadata {
    let mut metadata = PackMetadata::default();
    let file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(_) => return metadata,
    };
    let mut archive = match zip::ZipArchive::new(file) {
        Ok(archive) => archive,
        Err(_) => return metadata,
    };
    if let Ok(mut entry) = archive.by_name("pack.mcmeta") {
        if entry.size() <= MAX_MCMETA_BYTES {
            let mut bytes = Vec::new();
            if entry.read_to_end(&mut bytes).is_ok() {
                metadata = parse_mcmeta(&bytes);
            }
        }
    }
    if let Ok(mut entry) = archive.by_name("pack.png") {
        if entry.size() <= MAX_ICON_BYTES {
            let mut bytes = Vec::new();
            if entry.read_to_end(&mut bytes).is_ok() {
                metadata.icon = Some(bytes);
            }
        }
    }
    metadata
}

fn parse_mcmeta(bytes: &[u8]) -> PackMetadata {
    let bytes = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(bytes);
    let value: Value = match serde_json::from_slice(bytes) {
        Ok(value) => value,
        Err(_) => return PackMetadata::default(),
    };
    let pack = value.get("pack");
    let description = pack
        .and_then(|pack| pack.get("description"))
        .map(flatten_chat_component)
        .unwrap_or_default();
    let pack_format = pack
        .and_then(|pack| pack.get("pack_format"))
        .and_then(Value::as_i64)
        .and_then(|value| i32::try_from(value).ok());
    PackMetadata {
        description,
        pack_format,
        icon: None,
    }
}

/// Flattens a chat component (string, object or array) into plain text.
fn flatten_chat_component(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Array(parts) => parts
            .iter()
            .map(flatten_chat_component)
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join(""),
        Value::Object(map) => {
            let mut out = String::new();
            if let Some(text) = map.get("text").and_then(Value::as_str) {
                out.push_str(text);
            } else if let Some(key) = map.get("translate").and_then(Value::as_str) {
                out.push_str(key);
            }
            if let Some(with) = map.get("with") {
                let rendered = flatten_chat_component(with);
                if !rendered.is_empty() {
                    out.push_str(&rendered);
                }
            }
            if let Some(extra) = map.get("extra") {
                out.push_str(&flatten_chat_component(extra));
            }
            out
        }
        Value::Number(number) => number.to_string(),
        Value::Bool(value) => value.to_string(),
        Value::Null => String::new(),
    }
}

fn directory_size(directory: &Path, depth: u32) -> u64 {
    if depth > MAX_PACK_DEPTH {
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
            total = total.saturating_add(entry.metadata().map(|meta| meta.len()).unwrap_or(0));
        }
    }
    total
}

fn unique_child_name(directory: &Path, file_name: &str) -> String {
    let path = Path::new(file_name);
    let stem = path
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("pack");
    let extension = path.extension().and_then(|ext| ext.to_str()).unwrap_or("");
    for index in 0..10_000usize {
        let candidate = if index == 0 {
            file_name.to_string()
        } else if extension.is_empty() {
            format!("{stem}-{index}")
        } else {
            format!("{stem}-{index}.{extension}")
        };
        if !directory.join(&candidate).exists() {
            return candidate;
        }
    }
    format!("{stem}-{}.{extension}", uuid::Uuid::new_v4().simple())
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        ensure_dir(parent)?;
    }
    let temporary = path.with_file_name(format!(
        ".{}.tmp-{}",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("options"),
        uuid::Uuid::new_v4().simple()
    ));
    std::fs::write(&temporary, bytes)?;
    if let Err(error) = std::fs::rename(&temporary, path) {
        let _ = std::fs::remove_file(&temporary);
        return Err(error.into());
    }
    Ok(())
}

fn icon_data_url(bytes: &[u8]) -> String {
    format!("data:image/png;base64,{}", base64_encode(bytes))
}

fn base64_encode(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut output = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let first = chunk[0] as u32;
        let second = chunk.get(1).copied().unwrap_or(0) as u32;
        let third = chunk.get(2).copied().unwrap_or(0) as u32;
        let value = (first << 16) | (second << 8) | third;
        output.push(TABLE[((value >> 18) & 63) as usize] as char);
        output.push(TABLE[((value >> 12) & 63) as usize] as char);
        if chunk.len() > 1 {
            output.push(TABLE[((value >> 6) & 63) as usize] as char);
        } else {
            output.push('=');
        }
        if chunk.len() > 2 {
            output.push(TABLE[(value & 63) as usize] as char);
        } else {
            output.push('=');
        }
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn chat_components_flatten() {
        let value = json!({"text": "Hello ", "extra": [{"text": "world"}, "!"]});
        assert_eq!(flatten_chat_component(&value), "Hello world!");
        assert_eq!(flatten_chat_component(&json!(["a", {"text": "b"}])), "ab");
    }

    #[test]
    fn base64_padding() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
    }
}
