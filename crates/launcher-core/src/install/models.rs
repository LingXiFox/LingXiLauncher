use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum MissingDependencyKind {
    VersionMetadata,
    ClientJar,
    Library,
    AssetIndex,
    Asset,
    Native,
    LogConfig,
    Java,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MissingDependency {
    pub kind: MissingDependencyKind,
    pub name: String,
    pub path: PathBuf,
    #[serde(default)]
    pub reason: String,
    #[serde(default)]
    pub url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadTask {
    pub destination: PathBuf,
    pub official_url: Option<String>,
    pub sha1: Option<String>,
    pub size: Option<u64>,
    pub kind: MissingDependencyKind,
}

impl DownloadTask {
    pub fn new(
        destination: PathBuf,
        official_url: Option<String>,
        sha1: Option<String>,
        size: Option<u64>,
        kind: MissingDependencyKind,
    ) -> Self {
        Self {
            destination,
            official_url,
            sha1: sha1.map(|s| s.to_lowercase()),
            size,
            kind,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum InstallProgressEvent {
    Phase {
        phase: String,
        message: String,
    },
    Plan {
        total_files: usize,
        total_bytes: u64,
        cache_hits: usize,
    },
    FileStarted {
        path: String,
        size: u64,
    },
    FileFinished {
        path: String,
        bytes: u64,
        source: String,
    },
    FileFailed {
        path: String,
        message: String,
    },
    Bytes {
        downloaded: u64,
        total: u64,
    },
}

pub trait ProgressSink: Send + Sync {
    fn emit(&self, event: InstallProgressEvent);
}

pub struct NoopProgress;
impl ProgressSink for NoopProgress {
    fn emit(&self, _event: InstallProgressEvent) {}
}

pub type SharedProgress = Arc<dyn ProgressSink>;

/// Cooperative cancellation shared by GUI and CLI installs.
#[derive(Debug, Clone, Default)]
pub struct CancelFlag(Arc<AtomicBool>);

impl CancelFlag {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadedFile {
    pub path: PathBuf,
    pub bytes: u64,
    pub source: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadFailure {
    pub destination: PathBuf,
    pub code: String,
    pub message: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadSummary {
    pub downloaded: Vec<DownloadedFile>,
    pub cache_hits: usize,
    pub failures: Vec<DownloadFailure>,
}

impl DownloadSummary {
    pub fn downloaded_bytes(&self) -> u64 {
        self.downloaded.iter().map(|f| f.bytes).sum()
    }

    pub fn is_success(&self) -> bool {
        self.failures.is_empty()
    }
}

#[derive(Debug, Clone)]
pub struct DownloadConfiguration {
    pub concurrency: usize,
    pub max_retries: usize,
    pub retry_delay_ms: u64,
}

impl Default for DownloadConfiguration {
    fn default() -> Self {
        Self {
            concurrency: 4,
            max_retries: 3,
            retry_delay_ms: 500,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallReport {
    pub version_id: String,
    pub instance_id: String,
    pub game_directory: PathBuf,
    pub downloaded_files: usize,
    pub downloaded_bytes: u64,
    pub cache_hits: usize,
    pub asset_object_count: usize,
    pub extracted_natives: usize,
    pub missing_after_install: Vec<MissingDependency>,
    pub diagnostics: Vec<crate::models::launch::LaunchDiagnostic>,
    pub java_requirement: crate::version::JavaVersionRequirement,
    pub source_policy: String,
    pub platform_architecture: String,
}

impl InstallReport {
    pub fn is_complete(&self) -> bool {
        self.missing_after_install.is_empty()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DownloadSourcePolicy {
    Official,
    Mirror,
    Auto,
    LocalCacheOnly,
}

impl DownloadSourcePolicy {
    pub fn parse(value: &str) -> crate::error::Result<Self> {
        match value {
            "official" => Ok(Self::Official),
            "mirror" => Ok(Self::Mirror),
            "auto" => Ok(Self::Auto),
            "local-cache-only" => Ok(Self::LocalCacheOnly),
            other => Err(crate::error::Error::MissingInput(format!(
                "unknown download source policy '{other}' (official|mirror|auto|local-cache-only)"
            ))),
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Official => "official",
            Self::Mirror => "mirror",
            Self::Auto => "auto",
            Self::LocalCacheOnly => "local-cache-only",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MirrorHostRule {
    pub official_host: String,
    pub mirror_base_url: String,
    #[serde(default)]
    pub path_prefix: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrustedMirrorConfiguration {
    pub id: String,
    pub display_name: String,
    pub rules: Vec<MirrorHostRule>,
}

impl TrustedMirrorConfiguration {
    pub fn load(path: &std::path::Path) -> crate::error::Result<Self> {
        let data = std::fs::read(path)?;
        let config: Self = serde_json::from_slice(&data)?;
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> crate::error::Result<()> {
        use crate::error::Error;
        if self.id.trim().is_empty() || self.display_name.trim().is_empty() {
            return Err(Error::InvalidMetadata(
                "mirror configuration needs id and displayName".into(),
            ));
        }
        if self.rules.is_empty() {
            return Err(Error::InvalidMetadata(format!(
                "mirror '{}' declares no host rules",
                self.id
            )));
        }
        for rule in &self.rules {
            let url = url::Url::parse(&rule.mirror_base_url).map_err(|e| {
                Error::InvalidMetadata(format!("invalid mirror URL {}: {e}", rule.mirror_base_url))
            })?;
            if url.scheme() != "https" || url.host().is_none() {
                return Err(Error::InvalidMetadata(format!(
                    "mirror '{}' maps {} to a non-HTTPS URL",
                    self.id, rule.official_host
                )));
            }
        }
        Ok(())
    }

    /// Rewrites an official URL for the matching host. Unknown hosts are never rewritten.
    pub fn rewrite(&self, official: &str) -> Option<String> {
        let parsed = url::Url::parse(official).ok()?;
        let host = parsed.host_str()?.to_ascii_lowercase();
        let rule = self
            .rules
            .iter()
            .find(|r| r.official_host.eq_ignore_ascii_case(&host))?;
        let mut base = rule.mirror_base_url.trim_end_matches('/').to_string();
        if let Some(prefix) = rule.path_prefix.as_ref().filter(|p| !p.is_empty()) {
            base.push('/');
            base.push_str(prefix.trim_matches('/'));
        }
        Some(format!("{base}{}", parsed.path()))
    }
}

/// Maps a file path's parent directory, creating it when missing.
pub fn prepare_parent(path: &std::path::Path) -> crate::error::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    Ok(())
}
