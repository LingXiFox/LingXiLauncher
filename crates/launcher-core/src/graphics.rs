//! Safe reader/writer for the subset of Minecraft's `options.txt` exposed by
//! the launcher's graphics panel. Unknown keys and unrelated lines are kept
//! untouched, and every write is atomic with a one-generation backup.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};

pub const MIN_DISTANCE: u32 = 2;
pub const MAX_DISTANCE: u32 = 32;
pub const MAX_FPS: u32 = 1000;
pub const MAX_GUI_SCALE: u32 = 4;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct GraphicsSettings {
    /// `fast`, `fancy` or `fabulous`.
    pub preset: String,
    pub render_distance: u32,
    pub simulation_distance: u32,
    pub max_fps: u32,
    /// `0` means automatic.
    pub gui_scale: u32,
    /// `all`, `decreased` or `minimal`.
    pub particles: String,
    pub clouds: bool,
    pub entity_shadows: bool,
    pub ambient_occlusion: bool,
    pub vsync: bool,
    pub fullscreen: bool,
}

impl Default for GraphicsSettings {
    fn default() -> Self {
        Self {
            preset: "fancy".into(),
            render_distance: 12,
            simulation_distance: 12,
            max_fps: 120,
            gui_scale: 0,
            particles: "all".into(),
            clouds: true,
            entity_shadows: true,
            ambient_occlusion: true,
            vsync: true,
            fullscreen: false,
        }
    }
}

impl GraphicsSettings {
    pub fn validate(&self) -> Result<()> {
        if !matches!(self.preset.as_str(), "fast" | "fancy" | "fabulous") {
            return Err(Error::InvalidMetadata(format!(
                "unknown graphics preset '{}'",
                self.preset
            )));
        }
        if !(MIN_DISTANCE..=MAX_DISTANCE).contains(&self.render_distance) {
            return Err(Error::InvalidMetadata(format!(
                "render distance {} is outside {}..={}",
                self.render_distance, MIN_DISTANCE, MAX_DISTANCE
            )));
        }
        if !(MIN_DISTANCE..=MAX_DISTANCE).contains(&self.simulation_distance) {
            return Err(Error::InvalidMetadata(format!(
                "simulation distance {} is outside {}..={}",
                self.simulation_distance, MIN_DISTANCE, MAX_DISTANCE
            )));
        }
        if !(1..=MAX_FPS).contains(&self.max_fps) {
            return Err(Error::InvalidMetadata(format!(
                "max FPS {} is outside 1..={}",
                self.max_fps, MAX_FPS
            )));
        }
        if self.gui_scale > MAX_GUI_SCALE {
            return Err(Error::InvalidMetadata(format!(
                "GUI scale {} is outside 0..={}",
                self.gui_scale, MAX_GUI_SCALE
            )));
        }
        if !matches!(self.particles.as_str(), "all" | "decreased" | "minimal") {
            return Err(Error::InvalidMetadata(format!(
                "unknown particle mode '{}'",
                self.particles
            )));
        }
        Ok(())
    }
}

/// Parsed view returned to the UI. `path` is always the options file that
/// would be edited, even when it does not exist yet.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GraphicsSnapshot {
    pub path: String,
    pub exists: bool,
    pub settings: GraphicsSettings,
}

pub fn options_path(game_directory: &Path) -> PathBuf {
    game_directory.join("options.txt")
}

pub fn read(game_directory: &Path) -> Result<GraphicsSnapshot> {
    let path = options_path(game_directory);
    if !path.is_file() {
        return Ok(GraphicsSnapshot {
            path: path.display().to_string(),
            exists: false,
            settings: GraphicsSettings::default(),
        });
    }
    let text = std::fs::read_to_string(&path)?;
    Ok(GraphicsSnapshot {
        path: path.display().to_string(),
        exists: true,
        settings: GraphicsSettings::from_options(&text),
    })
}

/// Writes the settings and returns the state that was actually persisted.
/// A single backup is kept next to the file as `options.txt.bak`.
pub fn write(game_directory: &Path, settings: &GraphicsSettings) -> Result<GraphicsSnapshot> {
    settings.validate()?;
    let path = options_path(game_directory);
    let content = std::fs::read_to_string(&path).unwrap_or_default();
    let updated = settings.apply_to_options(&content);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if path.is_file() {
        std::fs::copy(&path, path.with_extension("txt.bak"))?;
    }
    write_atomic(&path, updated.as_bytes())?;
    Ok(GraphicsSnapshot {
        path: path.display().to_string(),
        exists: true,
        settings: settings.clone(),
    })
}

impl GraphicsSettings {
    fn from_options(text: &str) -> Self {
        let mut settings = Self::default();
        for line in text.lines() {
            let line = line.trim_end_matches('\r');
            let Some((key, value)) = line.split_once(':') else {
                continue;
            };
            let value = value.trim();
            match key {
                "graphics" => {
                    settings.preset = match value {
                        "0" | "fast" => "fast",
                        "2" | "fabulous" => "fabulous",
                        _ => "fancy",
                    }
                    .into()
                }
                "renderDistance" => {
                    settings.render_distance = parse_u32(value)
                        .unwrap_or(settings.render_distance)
                        .clamp(MIN_DISTANCE, MAX_DISTANCE)
                }
                "simulationDistance" => {
                    settings.simulation_distance = parse_u32(value)
                        .unwrap_or(settings.simulation_distance)
                        .clamp(MIN_DISTANCE, MAX_DISTANCE)
                }
                "maxFps" => {
                    settings.max_fps = parse_u32(value)
                        .unwrap_or(settings.max_fps)
                        .clamp(1, MAX_FPS)
                }
                "guiScale" => {
                    settings.gui_scale = parse_u32(value)
                        .unwrap_or(settings.gui_scale)
                        .min(MAX_GUI_SCALE)
                }
                "particles" => {
                    settings.particles = match value {
                        "0" | "all" => "all",
                        "2" | "minimal" => "minimal",
                        _ => "decreased",
                    }
                    .into()
                }
                "clouds" => settings.clouds = parse_bool(value).unwrap_or(settings.clouds),
                "entityShadows" => {
                    settings.entity_shadows = parse_bool(value).unwrap_or(settings.entity_shadows)
                }
                "ao" => {
                    settings.ambient_occlusion =
                        parse_bool(value).unwrap_or(settings.ambient_occlusion)
                }
                "enableVsync" => settings.vsync = parse_bool(value).unwrap_or(settings.vsync),
                "fullscreen" => {
                    settings.fullscreen = parse_bool(value).unwrap_or(settings.fullscreen)
                }
                _ => {}
            }
        }
        settings
    }

    fn apply_to_options(&self, text: &str) -> String {
        let preset = match self.preset.as_str() {
            "fast" => "0",
            "fabulous" => "2",
            _ => "1",
        };
        let particles = match self.particles.as_str() {
            "all" => "0",
            "minimal" => "2",
            _ => "1",
        };
        let values = [
            ("graphics", preset.to_string()),
            ("renderDistance", self.render_distance.to_string()),
            ("simulationDistance", self.simulation_distance.to_string()),
            ("maxFps", self.max_fps.to_string()),
            ("guiScale", self.gui_scale.to_string()),
            ("particles", particles.to_string()),
            ("clouds", self.clouds.to_string()),
            ("entityShadows", self.entity_shadows.to_string()),
            ("ao", self.ambient_occlusion.to_string()),
            ("enableVsync", self.vsync.to_string()),
            ("fullscreen", self.fullscreen.to_string()),
        ];
        set_values(text, &values)
    }
}

fn set_values(text: &str, values: &[(&str, String)]) -> String {
    let mut seen = vec![false; values.len()];
    let mut output = Vec::with_capacity(text.lines().count() + values.len());
    for line in text.lines() {
        let trimmed = line.trim_end_matches('\r').trim_start();
        let key = trimmed.split_once(':').map(|(key, _)| key);
        match key.and_then(|key| values.iter().position(|(candidate, _)| *candidate == key)) {
            Some(index) => {
                if !seen[index] {
                    output.push(format!("{}:{}", values[index].0, values[index].1));
                    seen[index] = true;
                }
            }
            None => output.push(line.to_string()),
        }
    }
    for (index, (key, value)) in values.iter().enumerate() {
        if !seen[index] {
            output.push(format!("{key}:{value}"));
        }
    }
    let mut result = output.join("\n");
    if text.ends_with('\n') || text.is_empty() {
        result.push('\n');
    }
    result
}

fn parse_u32(value: &str) -> Option<u32> {
    value.parse().ok()
}

fn parse_bool(value: &str) -> Option<bool> {
    match value {
        "true" | "1" => Some(true),
        "false" | "0" => Some(false),
        _ => None,
    }
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
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

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "lxl-graphics-{name}-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn missing_options_uses_defaults_without_creating_a_file() {
        let dir = temp_dir("missing");
        let snapshot = read(&dir).unwrap();
        assert!(!snapshot.exists);
        assert_eq!(snapshot.settings, GraphicsSettings::default());
        assert!(!options_path(&dir).exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn read_parses_known_keys_and_ignores_unknown_ones() {
        let text = "graphics:0\nrenderDistance:8\nsimulationDistance:6\nmaxFps:144\nguiScale:3\nparticles:2\nclouds:false\nentityShadows:false\nao:true\nenableVsync:false\nfullscreen:true\nkey_key.forward:key.keyboard.w\n";
        let settings = GraphicsSettings::from_options(text);
        assert_eq!(settings.preset, "fast");
        assert_eq!(settings.render_distance, 8);
        assert_eq!(settings.simulation_distance, 6);
        assert_eq!(settings.max_fps, 144);
        assert_eq!(settings.gui_scale, 3);
        assert_eq!(settings.particles, "minimal");
        assert!(!settings.clouds);
        assert!(!settings.entity_shadows);
        assert!(settings.ambient_occlusion);
        assert!(!settings.vsync);
        assert!(settings.fullscreen);
    }

    #[test]
    fn write_replaces_known_keys_and_preserves_the_rest() {
        let dir = temp_dir("write");
        let path = options_path(&dir);
        std::fs::write(&path, "graphics:1\nrenderDistance:12\nlang:zh_cn\n").unwrap();
        let settings = GraphicsSettings {
            preset: "fabulous".into(),
            render_distance: 16,
            simulation_distance: 10,
            max_fps: 60,
            ..GraphicsSettings::default()
        };
        write(&dir, &settings).unwrap();
        let written = std::fs::read_to_string(&path).unwrap();
        assert!(written.contains("graphics:2"));
        assert!(written.contains("renderDistance:16"));
        assert!(written.contains("simulationDistance:10"));
        assert!(written.contains("maxFps:60"));
        assert!(written.contains("lang:zh_cn"));
        assert!(path.with_extension("txt.bak").is_file());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn invalid_values_are_rejected() {
        let dir = temp_dir("invalid");
        let settings = GraphicsSettings {
            render_distance: 64,
            ..GraphicsSettings::default()
        };
        assert!(write(&dir, &settings).is_err());
        let _ = std::fs::remove_dir_all(dir);
    }
}
