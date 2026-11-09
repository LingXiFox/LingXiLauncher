//! Shader-pack discovery and management for one instance game directory.
//!
//! Minecraft stores the active pack in `options.txt` as `shaderPack:<name>`
//! and older versions kept a `shaderPacks:["..."]` list. Both are read; writes
//! keep the single-selection key and the legacy list in sync.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::layout::ensure_dir;
use crate::models::instance::Instance;
use crate::paths::PathSafety;

const MAX_PACK_DEPTH: u32 = 32;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShaderPackEntry {
    /// Direct child name: `foo.zip` or the pack directory name.
    pub file_name: String,
    /// Display name: archive stem or directory name.
    pub name: String,
    pub enabled: bool,
    pub size_bytes: u64,
}

#[derive(Debug, Clone, Default)]
struct ShaderOptions {
    /// `shaderPack` value; `None` means disabled/empty.
    selected: Option<String>,
    /// Legacy `shaderPacks` list.
    legacy: BTreeSet<String>,
}

impl ShaderOptions {
    fn is_enabled(&self, file_name: &str) -> bool {
        self.selected.as_deref() == Some(file_name) || self.legacy.contains(file_name)
    }
}

/// Manages the shader packs of one game directory. Mutating methods accept a
/// direct child name only, never a path.
#[derive(Debug, Clone)]
pub struct ShaderPackManager {
    game_directory: PathBuf,
}

impl ShaderPackManager {
    pub fn new(game_directory: impl Into<PathBuf>) -> Self {
        Self {
            game_directory: game_directory.into(),
        }
    }

    pub fn for_instance(instance: &Instance) -> Self {
        Self::new(instance.game_directory.clone())
    }

    pub fn packs_directory(&self) -> PathBuf {
        self.game_directory.join("shaderpacks")
    }

    pub fn options_path(&self) -> PathBuf {
        self.game_directory.join("options.txt")
    }

    /// Lists `.zip` packs and unpacked directories.
    pub fn list(&self) -> Result<Vec<ShaderPackEntry>> {
        let directory = self.packs_directory();
        if !directory.is_dir() {
            return Ok(Vec::new());
        }
        let state = self.read_options()?;
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
            let size_bytes = if file_type.is_dir() {
                directory_size(&entry.path(), 0)
            } else {
                entry.metadata().map(|meta| meta.len()).unwrap_or(0)
            };
            let name = if file_type.is_dir() {
                file_name.clone()
            } else {
                file_name
                    .strip_suffix(".zip")
                    .or_else(|| file_name.strip_suffix(".ZIP"))
                    .unwrap_or(&file_name)
                    .to_string()
            };
            entries.push(ShaderPackEntry {
                enabled: state.is_enabled(&file_name),
                file_name,
                name,
                size_bytes,
            });
        }
        entries.sort_by(|left, right| {
            right
                .enabled
                .cmp(&left.enabled)
                .then_with(|| {
                    left.name
                        .to_ascii_lowercase()
                        .cmp(&right.name.to_ascii_lowercase())
                })
                .then_with(|| left.file_name.cmp(&right.file_name))
        });
        Ok(entries)
    }

    /// Enables a pack as the single active shader, or clears the selection.
    /// Enabling one pack always disables the previous one.
    pub fn set_enabled(&self, file_name: &str, enabled: bool) -> Result<()> {
        let name = PathSafety::validate_component(file_name)?;
        self.require_pack(name)?;
        let mut state = self.read_options()?;
        if enabled {
            state.selected = Some(name.to_string());
            state.legacy.clear();
            state.legacy.insert(name.to_string());
        } else {
            if state.selected.as_deref() == Some(name) {
                state.selected = None;
            }
            state.legacy.remove(name);
        }
        self.write_options(&state)
    }

    pub fn toggle(&self, file_name: &str) -> Result<bool> {
        let name = PathSafety::validate_component(file_name)?;
        self.require_pack(name)?;
        let state = self.read_options()?;
        let next = !state.is_enabled(name);
        self.set_enabled(name, next)?;
        Ok(next)
    }

    /// Copies a shader-pack zip from an arbitrary path into the pack directory.
    pub fn import(&self, source: &Path) -> Result<ShaderPackEntry> {
        let extension = source
            .extension()
            .and_then(|ext| ext.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        if extension != "zip" {
            return Err(Error::InvalidMetadata(format!(
                "shader pack '{}' is not a .zip archive",
                source.display()
            )));
        }
        let metadata = std::fs::metadata(source)?;
        if !metadata.is_file() {
            return Err(Error::InvalidMetadata(format!(
                "shader pack '{}' is not a regular file",
                source.display()
            )));
        }
        let file = std::fs::File::open(source)?;
        zip::ZipArchive::new(file)?;

        let directory = self.packs_directory();
        ensure_dir(&directory)?;
        let source_name = source
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| Error::InvalidMetadata("shader pack has no file name".into()))?;
        PathSafety::validate_component(source_name)?;

        if let (Ok(canonical_source), Ok(canonical_directory)) =
            (source.canonicalize(), directory.canonicalize())
        {
            if canonical_source.parent() == Some(canonical_directory.as_path()) {
                return self
                    .entry_for(source_name)
                    .ok_or_else(|| Error::Other("imported shader pack disappeared".into()));
            }
        }

        let target_name = unique_child_name(&directory, source_name);
        let target = PathSafety::safe_join(&directory, &target_name)?;
        std::fs::copy(source, &target)?;
        self.entry_for(&target_name)
            .ok_or_else(|| Error::Other("imported shader pack could not be read".into()))
    }

    /// Deletes one direct child of the shader-pack directory and clears it
    /// from the options when it was active.
    pub fn delete(&self, file_name: &str) -> Result<()> {
        let name = PathSafety::validate_component(file_name)?;
        let directory = self.packs_directory();
        let path = PathSafety::safe_join(&directory, name)?;
        let metadata = std::fs::symlink_metadata(&path)
            .map_err(|_| Error::NotFound(format!("shader pack '{}'", path.display())))?;
        if metadata.file_type().is_symlink() {
            return Err(Error::UnsafePath(format!(
                "shader pack '{}' is a symlink",
                path.display()
            )));
        }
        if metadata.is_dir() {
            std::fs::remove_dir_all(&path)?;
        } else if metadata.is_file() {
            std::fs::remove_file(&path)?;
        } else {
            return Err(Error::UnsafePath(format!(
                "shader pack '{}' is not a file or directory",
                path.display()
            )));
        }
        if self.read_options()?.is_enabled(name) {
            self.set_enabled(name, false).or_else(|error| match error {
                Error::NotFound(_) => Ok(()),
                other => Err(other),
            })?;
        }
        Ok(())
    }

    fn require_pack(&self, file_name: &str) -> Result<()> {
        let path = PathSafety::safe_join(&self.packs_directory(), file_name)?;
        let metadata = std::fs::symlink_metadata(&path)
            .map_err(|_| Error::NotFound(format!("shader pack '{}'", path.display())))?;
        if metadata.file_type().is_symlink() || (!metadata.is_dir() && !metadata.is_file()) {
            return Err(Error::UnsafePath(format!(
                "shader pack '{}' is not a regular file or directory",
                path.display()
            )));
        }
        Ok(())
    }

    fn entry_for(&self, file_name: &str) -> Option<ShaderPackEntry> {
        let state = self.read_options().ok()?;
        let path = self.packs_directory().join(file_name);
        let metadata = std::fs::symlink_metadata(&path).ok()?;
        if metadata.file_type().is_symlink() {
            return None;
        }
        let name = if metadata.is_dir() {
            file_name.to_string()
        } else {
            file_name
                .strip_suffix(".zip")
                .or_else(|| file_name.strip_suffix(".ZIP"))
                .unwrap_or(file_name)
                .to_string()
        };
        let size_bytes = if metadata.is_dir() {
            directory_size(&path, 0)
        } else {
            metadata.len()
        };
        Some(ShaderPackEntry {
            file_name: file_name.to_string(),
            name,
            enabled: state.is_enabled(file_name),
            size_bytes,
        })
    }

    fn read_options(&self) -> Result<ShaderOptions> {
        let path = self.options_path();
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(ShaderOptions::default())
            }
            Err(error) => return Err(error.into()),
        };
        let mut state = ShaderOptions::default();
        for line in text.lines() {
            let line = line.trim_start();
            if let Some(rest) = line.strip_prefix("shaderPack:") {
                state.selected = normalize_selection(rest.trim());
            } else if let Some(rest) = line.strip_prefix("shaderPacks:") {
                if let Ok(list) = serde_json::from_str::<Vec<String>>(rest.trim()) {
                    state.legacy = list.into_iter().collect();
                }
            }
        }
        // `shaderPack` wins over a stale legacy entry when both are present.
        if let Some(selected) = state.selected.as_deref() {
            state.legacy.insert(selected.to_string());
        }
        Ok(state)
    }

    fn write_options(&self, state: &ShaderOptions) -> Result<()> {
        ensure_dir(&self.game_directory)?;
        let path = self.options_path();
        let content = std::fs::read_to_string(&path).unwrap_or_default();
        let mut lines: Vec<String> = content.split('\n').map(str::to_string).collect();

        let selected_line = match state.selected.as_deref() {
            Some(name) => format!("shaderPack:{name}"),
            None => "shaderPack:".to_string(),
        };
        let legacy: Vec<&String> = state.legacy.iter().collect();
        let legacy_line = format!("shaderPacks:{}", serde_json::to_string(&legacy)?);

        let mut saw_selected = false;
        let mut saw_legacy = false;
        let mut output = Vec::with_capacity(lines.len() + 2);
        for line in lines.drain(..) {
            let trimmed = line.trim_start();
            if trimmed.starts_with("shaderPack:") {
                if !saw_selected {
                    output.push(selected_line.clone());
                    saw_selected = true;
                }
                continue;
            }
            if trimmed.starts_with("shaderPacks:") {
                if !saw_legacy {
                    output.push(legacy_line.clone());
                    saw_legacy = true;
                }
                continue;
            }
            output.push(line);
        }
        let trailing_newline = output.last().map(String::is_empty).unwrap_or(false);
        if trailing_newline {
            output.pop();
        }
        if !saw_selected {
            output.push(selected_line);
        }
        if !saw_legacy {
            output.push(legacy_line);
        }
        if trailing_newline {
            output.push(String::new());
        }
        write_atomic(&path, output.join("\n").as_bytes())
    }
}

fn normalize_selection(value: &str) -> Option<String> {
    let value = value.trim();
    if value.is_empty() {
        return None;
    }
    let unquoted = value
        .strip_prefix('"')
        .and_then(|inner| inner.strip_suffix('"'))
        .unwrap_or(value);
    let lowered = unquoted.to_ascii_lowercase();
    if lowered == "off" || lowered == "none" || lowered == "(disabled)" {
        None
    } else {
        Some(unquoted.to_string())
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_selection_is_disabled() {
        assert_eq!(normalize_selection(""), None);
        assert_eq!(normalize_selection("  OFF "), None);
        assert_eq!(
            normalize_selection("\"Complementary.zip\""),
            Some("Complementary.zip".into())
        );
    }
}
