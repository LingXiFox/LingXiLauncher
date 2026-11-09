//! Version manifest retrieval and caching. The manifest is the only remote
//! index the launcher trusts for version metadata locations.

use std::path::Path;

use crate::error::{Error, Result};
use crate::layout::{ensure_dir, GameDataLayout};
use crate::models::version::{VersionManifest, VersionMetadata, VersionSummary};

pub const VERSION_MANIFEST_URL: &str =
    "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";

pub struct ManifestService {
    layout: GameDataLayout,
    client: reqwest::Client,
    manifest_url: String,
}

impl ManifestService {
    pub fn new(layout: GameDataLayout) -> Result<Self> {
        Self::with_url(layout, VERSION_MANIFEST_URL)
    }

    pub fn with_url(layout: GameDataLayout, manifest_url: impl Into<String>) -> Result<Self> {
        let client = reqwest::Client::builder()
            .user_agent(format!(
                "{}/{}",
                crate::models::launch::LAUNCHER_NAME,
                crate::models::launch::LAUNCHER_VERSION
            ))
            .connect_timeout(std::time::Duration::from_secs(20))
            .timeout(std::time::Duration::from_secs(120))
            .build()?;
        Ok(Self {
            layout,
            client,
            manifest_url: manifest_url.into(),
        })
    }

    pub fn cached_manifest_path(&self) -> std::path::PathBuf {
        self.layout
            .manifests_cache_directory()
            .join("version_manifest_v2.json")
    }

    pub fn cached_manifest(&self) -> Option<VersionManifest> {
        let data = std::fs::read(self.cached_manifest_path()).ok()?;
        serde_json::from_slice(&data).ok()
    }

    /// Loads the manifest, using the cached copy unless `refresh` is set or the
    /// cache is unreadable.
    pub async fn manifest(&self, refresh: bool) -> Result<VersionManifest> {
        if !refresh {
            if let Some(manifest) = self.cached_manifest() {
                return Ok(manifest);
            }
        }
        let response = self
            .client
            .get(&self.manifest_url)
            .send()
            .await
            .map_err(|e| Error::Http(format!("version manifest request failed: {e}")))?;
        if !response.status().is_success() {
            return Err(Error::Http(format!(
                "version manifest returned HTTP {}",
                response.status()
            )));
        }
        let bytes = response
            .bytes()
            .await
            .map_err(|e| Error::Http(e.to_string()))?;
        let manifest: VersionManifest = serde_json::from_slice(&bytes)
            .map_err(|e| Error::InvalidMetadata(format!("version manifest is malformed: {e}")))?;
        if manifest.versions.is_empty() {
            return Err(Error::InvalidMetadata(
                "version manifest contains no versions".into(),
            ));
        }
        ensure_dir(&self.layout.manifests_cache_directory())?;
        write_atomic(&self.cached_manifest_path(), &bytes)?;
        Ok(manifest)
    }

    pub async fn summary(&self, version_id: &str) -> Result<VersionSummary> {
        let manifest = self.manifest(false).await?;
        manifest
            .versions
            .into_iter()
            .find(|v| v.id == version_id)
            .ok_or_else(|| {
                Error::NotFound(format!("version '{version_id}' is not in the manifest"))
            })
    }

    pub fn cached_metadata(&self, version_id: &str) -> Option<VersionMetadata> {
        let path = self.layout.version_json(version_id).ok()?;
        let data = std::fs::read(path).ok()?;
        serde_json::from_slice(&data).ok()
    }

    /// Downloads and caches `<versions>/<id>/<id>.json`, verifying the SHA-1 from
    /// the manifest when present.
    pub async fn metadata(&self, summary: &VersionSummary) -> Result<VersionMetadata> {
        if let Some(metadata) = self.cached_metadata(&summary.id) {
            return Ok(metadata);
        }
        let response = self
            .client
            .get(&summary.url)
            .send()
            .await
            .map_err(|e| Error::Http(format!("version metadata request failed: {e}")))?;
        if !response.status().is_success() {
            return Err(Error::Http(format!(
                "version metadata for '{}' returned HTTP {}",
                summary.id,
                response.status()
            )));
        }
        let bytes = response
            .bytes()
            .await
            .map_err(|e| Error::Http(e.to_string()))?;
        if !summary.sha1.is_empty() && !summary.sha1.eq_ignore_ascii_case(&sha1_hex(&bytes)) {
            return Err(Error::HashMismatch {
                path: self.layout.version_json(&summary.id).unwrap_or_default(),
                expected: summary.sha1.clone(),
                actual: sha1_hex(&bytes),
            });
        }
        let metadata: VersionMetadata = serde_json::from_slice(&bytes)
            .map_err(|e| Error::InvalidMetadata(format!("version metadata is malformed: {e}")))?;
        if metadata.id != summary.id {
            return Err(Error::InvalidMetadata(format!(
                "version metadata id '{}' does not match '{}'",
                metadata.id, summary.id
            )));
        }
        let path = self.layout.version_json(&summary.id)?;
        ensure_dir(path.parent().expect("version directory"))?;
        write_atomic(&path, &bytes)?;
        Ok(metadata)
    }

    pub async fn metadata_by_id(&self, version_id: &str) -> Result<VersionMetadata> {
        if let Some(metadata) = self.cached_metadata(version_id) {
            return Ok(metadata);
        }
        let summary = self.summary(version_id).await?;
        self.metadata(&summary).await
    }
}

fn sha1_hex(bytes: &[u8]) -> String {
    use sha1::{Digest, Sha1};
    let mut hasher = Sha1::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| Error::UnsafePath(path.display().to_string()))?;
    ensure_dir(parent)?;
    let temp = path.with_extension("json.part");
    std::fs::write(&temp, bytes)?;
    std::fs::rename(&temp, path)?;
    Ok(())
}
