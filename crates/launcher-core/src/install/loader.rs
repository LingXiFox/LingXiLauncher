//! Mod loader installation. Fabric profiles are generated from the Fabric meta
//! API; NeoForge uses the official installer jar in client mode.

use std::path::{Path, PathBuf};
use std::process::Stdio;

use serde::Deserialize;

use crate::error::{Error, Result};
use crate::install::models::{CancelFlag, InstallProgressEvent, SharedProgress};
use crate::layout::{ensure_dir, GameDataLayout};
use crate::models::instance::{Instance, InstanceRepository};

pub const FABRIC_META: &str = "https://meta.fabricmc.net/v2";
pub const NEOFORGE_MAVEN: &str = "https://maven.neoforged.net/releases";

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LoaderKind {
    Vanilla,
    Fabric,
    NeoForge,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LoaderVersion {
    pub version: String,
    pub game_version: String,
    pub stable: bool,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LoaderInstallResult {
    pub loader: LoaderKind,
    pub game_version: String,
    pub loader_version: String,
    pub version_id: String,
    pub instance_id: String,
}

#[derive(Debug, Deserialize)]
struct FabricLoaderEntry {
    version: String,
    stable: bool,
}

pub struct LoaderInstaller {
    layout: GameDataLayout,
    client: reqwest::Client,
}

impl LoaderInstaller {
    pub fn new(layout: GameDataLayout) -> Result<Self> {
        let client = reqwest::Client::builder()
            .user_agent(format!("LingXiLauncher/{}", env!("CARGO_PKG_VERSION")))
            .timeout(std::time::Duration::from_secs(60))
            .build()
            .map_err(|e| Error::Http(e.to_string()))?;
        Ok(Self { layout, client })
    }

    pub async fn fabric_versions(&self, game_version: &str) -> Result<Vec<LoaderVersion>> {
        let url = format!("{FABRIC_META}/versions/loader/{game_version}");
        let response = self
            .client
            .get(&url)
            .send()
            .await
            .map_err(|e| Error::Http(e.to_string()))?;
        if !response.status().is_success() {
            return Err(Error::Unavailable(format!(
                "Fabric meta returned HTTP {}",
                response.status()
            )));
        }
        let entries: Vec<FabricLoaderEntry> = response
            .json()
            .await
            .map_err(|e| Error::Http(e.to_string()))?;
        Ok(entries
            .into_iter()
            .map(|entry| LoaderVersion {
                version: entry.version,
                game_version: game_version.to_string(),
                stable: entry.stable,
            })
            .collect())
    }

    pub async fn install_fabric(
        &self,
        instance: &Instance,
        game_version: &str,
        loader_version: Option<&str>,
        progress: SharedProgress,
        cancel: CancelFlag,
    ) -> Result<LoaderInstallResult> {
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        let loader_version = match loader_version {
            Some(version) => version.to_string(),
            None => self
                .fabric_versions(game_version)
                .await?
                .into_iter()
                .find(|entry| entry.stable)
                .map(|entry| entry.version)
                .ok_or_else(|| {
                    Error::NotFound(format!(
                        "no Fabric loader is available for Minecraft {game_version}"
                    ))
                })?,
        };
        progress.emit(InstallProgressEvent::Phase {
            phase: "loader".into(),
            message: format!("Installing Fabric {loader_version} for {game_version}"),
        });
        let url =
            format!("{FABRIC_META}/versions/loader/{game_version}/{loader_version}/profile/json");
        let response = self
            .client
            .get(&url)
            .send()
            .await
            .map_err(|e| Error::Http(e.to_string()))?;
        if !response.status().is_success() {
            return Err(Error::Unavailable(format!(
                "Fabric profile returned HTTP {}",
                response.status()
            )));
        }
        let profile: serde_json::Value = response
            .json()
            .await
            .map_err(|e| Error::InvalidMetadata(format!("invalid Fabric profile: {e}")))?;
        let version_id = profile
            .get("id")
            .and_then(|value| value.as_str())
            .map(|value| value.to_string())
            .unwrap_or_else(|| format!("fabric-loader-{loader_version}-{game_version}"));
        crate::paths::PathSafety::validate_component(&version_id)?;
        if profile.get("inheritsFrom").and_then(|value| value.as_str()) != Some(game_version) {
            return Err(Error::InvalidMetadata(format!(
                "Fabric profile for {game_version} has an unexpected parent"
            )));
        }
        let directory = self.layout.version_directory(&version_id)?;
        ensure_dir(&directory)?;
        let target = self.layout.version_json(&version_id)?;
        let data = serde_json::to_vec_pretty(&profile)
            .map_err(|e| Error::InvalidMetadata(e.to_string()))?;
        let temporary = target.with_extension("json.part");
        std::fs::write(&temporary, data)?;
        std::fs::rename(&temporary, &target)?;

        InstanceRepository::new(self.layout.clone()).assign_version(instance, &version_id)?;
        Ok(LoaderInstallResult {
            loader: LoaderKind::Fabric,
            game_version: game_version.to_string(),
            loader_version,
            version_id,
            instance_id: instance.id().to_string(),
        })
    }

    /// NeoForge publishes one Maven line per Minecraft minor line: 1.21.1 ->
    /// 21.1.x, 1.20.4 -> 20.4.x. We list that line and let the caller pick.
    pub async fn neoforge_versions(&self, game_version: &str) -> Result<Vec<LoaderVersion>> {
        let Some(prefix) = neoforge_prefix(game_version) else {
            return Ok(Vec::new());
        };
        let url = format!("{NEOFORGE_MAVEN}/net/neoforged/neoforge/maven-metadata.xml");
        let response = self
            .client
            .get(&url)
            .send()
            .await
            .map_err(|e| Error::Http(e.to_string()))?;
        if !response.status().is_success() {
            return Err(Error::Unavailable(format!(
                "NeoForge maven returned HTTP {}",
                response.status()
            )));
        }
        let text = response
            .text()
            .await
            .map_err(|e| Error::Http(e.to_string()))?;
        let mut versions = Vec::new();
        for chunk in text.split("<version>").skip(1) {
            let Some(end) = chunk.find("</version>") else {
                continue;
            };
            let version = &chunk[..end];
            if version.starts_with(&prefix) {
                versions.push(LoaderVersion {
                    version: version.to_string(),
                    game_version: game_version.to_string(),
                    stable: !version.contains("-beta"),
                });
            }
        }
        versions.sort_by(|a, b| version_cmp(&b.version, &a.version));
        Ok(versions)
    }

    pub async fn install_neoforge(
        &self,
        instance: &Instance,
        game_version: &str,
        loader_version: &str,
        java: &Path,
        progress: SharedProgress,
        cancel: CancelFlag,
    ) -> Result<LoaderInstallResult> {
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        let prefix = neoforge_prefix(game_version).ok_or_else(|| {
            Error::UnsupportedVersion(format!("NeoForge does not support {game_version}"))
        })?;
        if !loader_version.starts_with(&prefix) {
            return Err(Error::MissingInput(format!(
                "NeoForge {loader_version} does not target Minecraft {game_version}"
            )));
        }
        crate::paths::PathSafety::validate_component(loader_version)?;
        let installer = self
            .layout
            .downloads_cache_directory()
            .join(format!("neoforge-{loader_version}-installer.jar"));
        if let Some(parent) = installer.parent() {
            ensure_dir(parent)?;
        }
        progress.emit(InstallProgressEvent::Phase {
            phase: "loader".into(),
            message: format!("Downloading NeoForge {loader_version} installer"),
        });
        let url = format!(
            "{NEOFORGE_MAVEN}/net/neoforged/neoforge/{loader_version}/neoforge-{loader_version}-installer.jar"
        );
        let response = self
            .client
            .get(&url)
            .send()
            .await
            .map_err(|e| Error::Http(e.to_string()))?;
        if !response.status().is_success() {
            return Err(Error::Unavailable(format!(
                "NeoForge installer returned HTTP {}",
                response.status()
            )));
        }
        let bytes = response
            .bytes()
            .await
            .map_err(|e| Error::Http(e.to_string()))?;
        std::fs::write(&installer, &bytes)?;

        progress.emit(InstallProgressEvent::Phase {
            phase: "loader".into(),
            message: "Running NeoForge installer".into(),
        });
        let mut command = tokio::process::Command::new(java);
        command
            .arg("-jar")
            .arg(&installer)
            .arg("--installClient")
            .arg(&self.layout.game_root)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        #[cfg(windows)]
        {
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            command.creation_flags(CREATE_NO_WINDOW);
        }
        let output = command
            .output()
            .await
            .map_err(|e| Error::JavaUnusable(e.to_string()))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let tail: String = stderr
                .lines()
                .rev()
                .take(8)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect::<Vec<_>>()
                .join("\n");
            return Err(Error::Unavailable(format!(
                "NeoForge installer failed ({}): {tail}",
                output.status
            )));
        }

        let version_id = find_neoforge_version(&self.layout, loader_version)?;
        InstanceRepository::new(self.layout.clone()).assign_version(instance, &version_id)?;
        Ok(LoaderInstallResult {
            loader: LoaderKind::NeoForge,
            game_version: game_version.to_string(),
            loader_version: loader_version.to_string(),
            version_id,
            instance_id: instance.id().to_string(),
        })
    }
}

fn neoforge_prefix(game_version: &str) -> Option<String> {
    let mut parts = game_version.split('.');
    let major: u32 = parts.next()?.parse().ok()?;
    let minor: u32 = parts.next()?.parse().ok()?;
    if major != 1 {
        return None;
    }
    let patch: u32 = parts.next().unwrap_or("0").parse().unwrap_or(0);
    Some(format!("{minor}.{patch}."))
}

fn version_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    let split = |value: &str| -> Vec<u64> {
        value
            .split(['.', '-'])
            .map(|part| part.parse::<u64>().unwrap_or(0))
            .collect()
    };
    split(a).cmp(&split(b))
}

fn find_neoforge_version(layout: &GameDataLayout, loader_version: &str) -> Result<String> {
    let expected = format!("neoforge-{loader_version}");
    let mut candidates = Vec::new();
    if let Ok(entries) = std::fs::read_dir(layout.versions_directory()) {
        for entry in entries.flatten() {
            if !entry.path().is_dir() {
                continue;
            }
            let Some(name) = entry.file_name().to_str().map(|value| value.to_string()) else {
                continue;
            };
            if name == expected {
                return Ok(name);
            }
            if name.starts_with(&format!("neoforge-{loader_version}")) {
                candidates.push(name);
            }
        }
    }
    candidates.sort();
    candidates.pop().ok_or_else(|| {
        Error::NotFound(format!(
            "NeoForge installer finished but no neoforge-{loader_version} version was created"
        ))
    })
}

/// Path to an executable Java used for installer jars.
pub fn installer_java(runtime: Option<&crate::java::JavaRuntime>) -> Result<PathBuf> {
    if let Some(runtime) = runtime {
        return Ok(runtime.executable.clone());
    }
    let home = std::env::var_os("JAVA_HOME").map(PathBuf::from);
    if let Some(home) = home {
        let candidate = home
            .join("bin")
            .join(if cfg!(windows) { "java.exe" } else { "java" });
        if candidate.is_file() {
            return Ok(candidate);
        }
    }
    Ok(PathBuf::from(if cfg!(windows) {
        "java.exe"
    } else {
        "java"
    }))
}
