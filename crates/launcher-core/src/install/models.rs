use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

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
// Field-level rename is required: the GUI consumes these events as JSON and
// expects camelCase keys (totalFiles etc.) for every variant field. The plain
// rename_all only covers variant names, which is why the Windows GUI showed
// "waiting for file list" forever (all payload keys arrived as snake_case).
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
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
    ExtendPlan {
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
    /// Aggregate speed sample so the GUI can show MB/s and ETA without polling.
    Speed {
        bytes_per_second: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        remaining_seconds: Option<u64>,
        active_files: usize,
    },
    /// A single file is being retried; without this the UI looks frozen while a
    /// slow mirror times out.
    Retry {
        path: String,
        attempt: usize,
        max_attempts: usize,
        message: String,
    },
}

pub trait ProgressSink: Send + Sync {
    fn emit(&self, event: InstallProgressEvent);
}

pub struct NoopProgress;
impl ProgressSink for NoopProgress {
    fn emit(&self, _event: InstallProgressEvent) {}
}

/// Combines the core and asset batches without losing either batch's counters.
pub(super) struct BatchProgress {
    inner: SharedProgress,
    batches: Arc<Mutex<[BatchCounters; 2]>>,
    index: usize,
}

#[derive(Default)]
struct BatchCounters {
    planned: bool,
    downloaded: u64,
    total: u64,
    speed: u64,
    active: usize,
}

impl BatchProgress {
    pub(super) fn pair(inner: SharedProgress) -> [Arc<Self>; 2] {
        let batches = Arc::default();
        [0, 1].map(|index| {
            Arc::new(Self {
                inner: inner.clone(),
                batches: Arc::clone(&batches),
                index,
            })
        })
    }

    pub(super) fn finish(&self) {
        self.emit(InstallProgressEvent::Speed {
            bytes_per_second: 0,
            remaining_seconds: None,
            active_files: 0,
        });
    }
}

impl ProgressSink for BatchProgress {
    fn emit(&self, event: InstallProgressEvent) {
        // Hold the lock through emission so concurrent batches cannot publish
        // snapshots in a different order than they were computed.
        let mut batches = self.batches.lock().expect("batch progress lock");
        let event = match event {
            InstallProgressEvent::Plan {
                total_files,
                total_bytes,
                cache_hits,
            } => {
                let first = !batches.iter().any(|batch| batch.planned);
                batches[self.index].planned = true;
                batches[self.index].total = total_bytes;
                if first {
                    InstallProgressEvent::Plan {
                        total_files,
                        total_bytes,
                        cache_hits,
                    }
                } else {
                    InstallProgressEvent::ExtendPlan {
                        total_files,
                        total_bytes,
                        cache_hits,
                    }
                }
            }
            InstallProgressEvent::Bytes { downloaded, total } => {
                batches[self.index].downloaded = downloaded;
                batches[self.index].total = total;
                InstallProgressEvent::Bytes {
                    downloaded: batches.iter().map(|batch| batch.downloaded).sum(),
                    total: batches.iter().map(|batch| batch.total).sum(),
                }
            }
            InstallProgressEvent::Speed {
                bytes_per_second,
                active_files,
                ..
            } => {
                batches[self.index].speed = bytes_per_second;
                batches[self.index].active = active_files;
                let speed = batches.iter().map(|batch| batch.speed).sum();
                let remaining: u64 = batches
                    .iter()
                    .map(|batch| batch.total.saturating_sub(batch.downloaded))
                    .sum();
                InstallProgressEvent::Speed {
                    bytes_per_second: speed,
                    remaining_seconds: remaining.checked_div(speed),
                    active_files: batches.iter().map(|batch| batch.active).sum(),
                }
            }
            other => other,
        };
        self.inner.emit(event);
    }
}

pub type SharedProgress = Arc<dyn ProgressSink>;

/// Cooperative cancellation shared by GUI and CLI installs.
#[derive(Debug, Default)]
struct Cancellation {
    flag: AtomicBool,
    notify: tokio::sync::Notify,
}

#[derive(Debug, Clone, Default)]
pub struct CancelFlag(Arc<Cancellation>);

impl CancelFlag {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn cancel(&self) {
        self.0.flag.store(true, Ordering::SeqCst);
        self.0.notify.notify_waiters();
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.flag.load(Ordering::SeqCst)
    }

    pub async fn cancelled(&self) {
        let notified = self.0.notify.notified();
        if !self.is_cancelled() {
            notified.await;
        }
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
    /// Sum of declared sizes, excluding cache hits.
    #[serde(default)]
    pub declared_bytes: u64,
}

impl DownloadSummary {
    pub fn downloaded_bytes(&self) -> u64 {
        self.downloaded.iter().map(|f| f.bytes).sum()
    }

    /// Folds a follow-up batch into this summary so one report covers every
    /// phase of an install.
    pub fn absorb(&mut self, other: DownloadSummary) {
        self.downloaded.extend(other.downloaded);
        self.cache_hits += other.cache_hits;
        self.failures.extend(other.failures);
        self.declared_bytes += other.declared_bytes;
    }

    pub fn is_success(&self) -> bool {
        self.failures.is_empty()
    }
}

#[derive(Debug, Clone)]
pub struct DownloadConfiguration {
    /// Requests in parallel. This is the *initial* value when adaptive
    /// concurrency is enabled and the hard ceiling otherwise.
    pub concurrency: usize,
    pub max_retries: usize,
    pub retry_delay_ms: u64,
    /// Absolute request ceiling, also bounded by the process-wide default.
    pub global_concurrency: usize,
    /// Ceiling for requests against one host, also bounded across installers.
    pub per_host_concurrency: usize,
    /// Maximum number of HTTP Range segments used for a single large file.
    pub segments: usize,
    /// Files at or above this size are eligible for segmented downloads.
    pub segment_threshold_bytes: u64,
    /// Grow/shrink the transfer window based on observed failures.
    pub adaptive_concurrency: bool,
    /// Built-in mirrors available to the auto policy (currently `bmclapi`).
    pub builtin_mirrors: Vec<String>,
    /// Content addressed cache root; `None` disables cross-instance reuse.
    pub cache_directory: Option<std::path::PathBuf>,
    /// How often aggregate speed samples are emitted.
    pub speed_report_interval_ms: u64,
}

impl Default for DownloadConfiguration {
    fn default() -> Self {
        Self {
            concurrency: 8,
            max_retries: 3,
            retry_delay_ms: 500,
            global_concurrency: 24,
            per_host_concurrency: 8,
            segments: 4,
            segment_threshold_bytes: 4 * 1024 * 1024,
            adaptive_concurrency: true,
            builtin_mirrors: vec!["bmclapi".to_string()],
            cache_directory: None,
            speed_report_interval_ms: 500,
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
        base.push_str(parsed.path());
        if let Some(query) = parsed.query() {
            base.push('?');
            base.push_str(query);
        }
        Some(base)
    }
}

/// Maps a file path's parent directory, creating it when missing.
pub fn prepare_parent(path: &std::path::Path) -> crate::error::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    Ok(())
}

#[cfg(test)]
mod progress_event_tests {
    use super::*;

    /// Golden protocol test: the GUI reducer keys off these exact JSON shapes.
    /// If a field name changes, this test must be updated together with the
    /// frontend reducer in Apps/desktop/src/services/progress.ts.
    #[test]
    fn progress_events_serialize_with_camel_case_fields() {
        let cases: Vec<(InstallProgressEvent, &str)> = vec![
            (
                InstallProgressEvent::Phase {
                    phase: "download".into(),
                    message: "Installing Minecraft 1.21.4".into(),
                },
                r#"{"kind":"phase","phase":"download","message":"Installing Minecraft 1.21.4"}"#,
            ),
            (
                InstallProgressEvent::Plan {
                    total_files: 42,
                    total_bytes: 1_048_576,
                    cache_hits: 3,
                },
                r#"{"kind":"plan","totalFiles":42,"totalBytes":1048576,"cacheHits":3}"#,
            ),
            (
                InstallProgressEvent::FileStarted {
                    path: "libraries/a.jar".into(),
                    size: 128,
                },
                r#"{"kind":"fileStarted","path":"libraries/a.jar","size":128}"#,
            ),
            (
                InstallProgressEvent::FileFinished {
                    path: "libraries/a.jar".into(),
                    bytes: 128,
                    source: "official".into(),
                },
                r#"{"kind":"fileFinished","path":"libraries/a.jar","bytes":128,"source":"official"}"#,
            ),
            (
                InstallProgressEvent::FileFailed {
                    path: "libraries/a.jar".into(),
                    message: "HTTP 500 for url".into(),
                },
                r#"{"kind":"fileFailed","path":"libraries/a.jar","message":"HTTP 500 for url"}"#,
            ),
            (
                InstallProgressEvent::Bytes {
                    downloaded: 512,
                    total: 1024,
                },
                r#"{"kind":"bytes","downloaded":512,"total":1024}"#,
            ),
        ];
        for (event, expected) in cases {
            let actual = serde_json::to_string(&event).expect("serialize event");
            assert_eq!(actual, expected, "event JSON drifted from protocol");
        }
    }

    struct VecSink(std::sync::Mutex<Vec<InstallProgressEvent>>);

    impl ProgressSink for VecSink {
        fn emit(&self, event: InstallProgressEvent) {
            self.0.lock().expect("sink lock").push(event);
        }
    }

    #[test]
    fn overlapping_batches_merge_progress_and_preserve_rollbacks() {
        let sink = Arc::new(VecSink(std::sync::Mutex::new(Vec::new())));
        let [core, assets] = BatchProgress::pair(sink.clone());
        core.emit(InstallProgressEvent::Plan {
            total_files: 3,
            total_bytes: 1_000,
            cache_hits: 2,
        });
        core.emit(InstallProgressEvent::Bytes {
            downloaded: 700,
            total: 1_000,
        });
        assets.emit(InstallProgressEvent::Plan {
            total_files: 10,
            total_bytes: 5_000,
            cache_hits: 1,
        });
        assets.emit(InstallProgressEvent::Bytes {
            downloaded: 250,
            total: 5_000,
        });
        core.emit(InstallProgressEvent::Bytes {
            downloaded: 0,
            total: 1_000,
        });
        assets.emit(InstallProgressEvent::Speed {
            bytes_per_second: 500,
            remaining_seconds: None,
            active_files: 2,
        });
        core.finish();

        let events = sink.0.lock().expect("sink lock");
        assert!(matches!(events[0], InstallProgressEvent::Plan { .. }));
        assert_eq!(
            serde_json::to_string(&events[2]).expect("serialize"),
            r#"{"kind":"extendPlan","totalFiles":10,"totalBytes":5000,"cacheHits":1}"#
        );
        assert_eq!(
            serde_json::to_string(&events[3]).expect("serialize"),
            r#"{"kind":"bytes","downloaded":950,"total":6000}"#
        );
        assert!(matches!(
            events[4],
            InstallProgressEvent::Bytes {
                downloaded: 250,
                total: 6000
            }
        ));
        assert!(matches!(
            events[6],
            InstallProgressEvent::Speed {
                bytes_per_second: 500,
                active_files: 2,
                ..
            }
        ));
    }
}
