use std::cmp::Reverse;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use futures_util::StreamExt;
use tokio::sync::{Notify, Semaphore};

use crate::error::{Error, Result};
use crate::net::{classify_reqwest_error, describe_transfer_error, redact_url};

use super::hashing::{sha1_file, verify_file};
use super::models::*;

pub mod cache;
pub mod source;

pub use cache::ContentCache;
pub use source::{
    bmclapi, builtin_mirror, builtin_mirrors, rewrite_url, BuiltinMirror, HealthRegistry,
    HostRewrite,
};

/// Smallest slice we are willing to split a file into. Below this the HTTP
/// overhead dominates and a single stream is faster.
const MIN_SEGMENT_BYTES: u64 = 1024 * 1024;

/// A failed transfer slice. Carries the byte count already written so the
/// aggregate progress can be rolled back precisely.
#[derive(Debug)]
struct FetchError {
    message: String,
    retryable: bool,
    written: u64,
    /// The server ignored Range and answered 200 OK, so segmented or resumable
    /// transfer is impossible for this file.
    range_unsupported: bool,
}

impl FetchError {
    fn new(message: impl Into<String>, retryable: bool, written: u64) -> Self {
        Self {
            message: message.into(),
            retryable,
            written,
            range_unsupported: false,
        }
    }

    fn range_unsupported(written: u64) -> Self {
        Self {
            message: "server does not support byte ranges".into(),
            retryable: false,
            written,
            range_unsupported: true,
        }
    }
}

/// Live byte counters shared by every transfer, plus the denominator used for
/// the percentage.
struct TransferStats {
    downloaded: AtomicU64,
    total: AtomicU64,
    active: AtomicUsize,
}

impl TransferStats {
    fn new(total: u64) -> Arc<Self> {
        Arc::new(Self {
            downloaded: AtomicU64::new(0),
            total: AtomicU64::new(total),
            active: AtomicUsize::new(0),
        })
    }

    fn add(&self, bytes: u64, progress: &SharedProgress) {
        let total = self.total.load(Ordering::Relaxed);
        let aggregate = self.downloaded.fetch_add(bytes, Ordering::Relaxed) + bytes;
        let denominator = total.max(aggregate);
        progress.emit(InstallProgressEvent::Bytes {
            downloaded: aggregate.min(denominator),
            total: denominator,
        });
    }

    fn rollback(&self, bytes: u64, progress: &SharedProgress) {
        if bytes == 0 {
            return;
        }
        let previous = self.downloaded.fetch_sub(bytes, Ordering::Relaxed);
        let remaining = previous.saturating_sub(bytes);
        let total = self.total.load(Ordering::Relaxed);
        progress.emit(InstallProgressEvent::Bytes {
            downloaded: remaining.min(total),
            total,
        });
    }
}

/// Adjustable concurrency window. Starts at the configured value, shrinks when
/// transfers start failing and grows back once the network recovers.
struct AdaptiveGate {
    limit: AtomicUsize,
    in_flight: AtomicUsize,
    max: usize,
    adaptive: bool,
    notify: Notify,
}

struct GatePermit<'a> {
    gate: &'a AdaptiveGate,
}

impl Drop for GatePermit<'_> {
    fn drop(&mut self) {
        self.gate.in_flight.fetch_sub(1, Ordering::SeqCst);
        self.gate.notify.notify_waiters();
    }
}

impl AdaptiveGate {
    fn new(limit: usize, max: usize, adaptive: bool) -> Self {
        Self {
            limit: AtomicUsize::new(limit.max(1)),
            in_flight: AtomicUsize::new(0),
            max: max.max(limit.max(1)),
            adaptive,
            notify: Notify::new(),
        }
    }

    async fn acquire(&self) -> GatePermit<'_> {
        loop {
            // Register interest before checking so a release between the check
            // and the await cannot be missed.
            let notified = self.notify.notified();
            let limit = self.limit.load(Ordering::SeqCst).max(1);
            let in_flight = self.in_flight.load(Ordering::SeqCst);
            if in_flight < limit {
                self.in_flight.fetch_add(1, Ordering::SeqCst);
                return GatePermit { gate: self };
            }
            notified.await;
        }
    }

    fn on_success(&self) {
        if !self.adaptive {
            return;
        }
        let limit = self.limit.load(Ordering::SeqCst);
        if limit < self.max {
            self.limit
                .store((limit + 1).min(self.max), Ordering::SeqCst);
            self.notify.notify_waiters();
        }
    }

    fn on_failure(&self) {
        if !self.adaptive {
            return;
        }
        let limit = self.limit.load(Ordering::SeqCst);
        self.limit.store((limit / 2).max(1), Ordering::SeqCst);
    }

    #[cfg(test)]
    fn current(&self) -> usize {
        self.limit.load(Ordering::SeqCst)
    }
}

pub struct Downloader {
    client: reqwest::Client,
    probe_client: reqwest::Client,
    policy: DownloadSourcePolicy,
    mirror: Option<TrustedMirrorConfiguration>,
    builtin: Vec<BuiltinMirror>,
    configuration: DownloadConfiguration,
    health: Arc<HealthRegistry>,
    host_gates: std::sync::Mutex<HashMap<String, Arc<Semaphore>>>,
    cache: Option<ContentCache>,
}

impl Downloader {
    pub fn new(
        policy: DownloadSourcePolicy,
        mirror: Option<TrustedMirrorConfiguration>,
        configuration: DownloadConfiguration,
    ) -> Result<Self> {
        let builtin: Vec<BuiltinMirror> = configuration
            .builtin_mirrors
            .iter()
            .filter_map(|id| builtin_mirror(id))
            .collect();
        if policy == DownloadSourcePolicy::Mirror && mirror.is_none() && builtin.is_empty() {
            return Err(Error::MissingInput(
                "mirror policy requires --mirror-config or a built-in mirror".into(),
            ));
        }
        let client = crate::net::client_builder()
            .user_agent(user_agent())
            .connect_timeout(Duration::from_secs(20))
            .timeout(Duration::from_secs(600))
            .pool_max_idle_per_host(configuration.per_host_concurrency.max(2))
            .build()?;
        let probe_client = crate::net::client_builder()
            .user_agent(user_agent())
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .build()?;
        let cache = configuration.cache_directory.clone().map(ContentCache::new);
        Ok(Self {
            client,
            probe_client,
            policy,
            mirror,
            builtin,
            configuration,
            health: Arc::new(HealthRegistry::new(4, Duration::from_secs(20))),
            host_gates: std::sync::Mutex::new(HashMap::new()),
            cache,
        })
    }

    pub fn policy(&self) -> DownloadSourcePolicy {
        self.policy
    }

    /// Per-host concurrency gate, created on first use.
    fn host_gate(&self, url: &str) -> Arc<Semaphore> {
        let host = url::Url::parse(url)
            .ok()
            .and_then(|parsed| parsed.host_str().map(|value| value.to_string()))
            .unwrap_or_else(|| "unknown".to_string());
        let mut gates = self.host_gates.lock().expect("host gate lock");
        gates
            .entry(host)
            .or_insert_with(|| {
                Arc::new(Semaphore::new(
                    self.configuration.per_host_concurrency.max(1),
                ))
            })
            .clone()
    }

    pub async fn download(
        &self,
        tasks: Vec<DownloadTask>,
        progress: SharedProgress,
        cancel: CancelFlag,
    ) -> Result<DownloadSummary> {
        let mut seen = std::collections::HashSet::new();
        let mut unique = Vec::new();
        for task in tasks {
            if seen.insert(task.destination.clone()) {
                unique.push(task);
            }
        }

        // A file can be satisfied from the destination itself or from the
        // shared content cache, which is what makes cross-instance reuse work.
        let mut cache_hits = 0usize;
        let mut pending = Vec::new();
        for task in unique {
            if verify_file(&task.destination, task.sha1.as_deref(), task.size)? {
                cache_hits += 1;
                continue;
            }
            if let (Some(cache), Some(sha1)) = (&self.cache, task.sha1.as_deref()) {
                if let Some(object) = cache.lookup(sha1, task.size) {
                    if cache.place(&object, &task.destination).is_ok() {
                        cache_hits += 1;
                        continue;
                    }
                }
            }
            pending.push(task);
        }

        pending.sort_by_key(|task| Reverse(task.size.unwrap_or(0)));
        let declared_bytes: u64 = pending.iter().map(|task| task.size.unwrap_or(0)).sum();
        progress.emit(InstallProgressEvent::Plan {
            total_files: cache_hits + pending.len(),
            total_bytes: declared_bytes,
            cache_hits,
        });

        if self.policy == DownloadSourcePolicy::LocalCacheOnly {
            let failures = pending
                .into_iter()
                .map(|task| DownloadFailure {
                    destination: task.destination,
                    code: "missing_dependency".into(),
                    message: "local-cache-only: file is not present in the local cache".into(),
                })
                .collect();
            return Ok(DownloadSummary {
                downloaded: Vec::new(),
                cache_hits,
                failures,
            });
        }

        let stats = TransferStats::new(declared_bytes);
        let gate = Arc::new(AdaptiveGate::new(
            self.configuration
                .concurrency
                .max(1)
                .min(self.configuration.global_concurrency.max(1)),
            self.configuration.global_concurrency.max(1),
            self.configuration.adaptive_concurrency,
        ));
        let stop_speed = Arc::new(AtomicU64::new(0));
        let speed_task =
            self.spawn_speed_reporter(stats.clone(), progress.clone(), stop_speed.clone());

        let results: Vec<std::result::Result<DownloadedFile, DownloadFailure>> =
            futures_util::stream::iter(pending.into_iter().map(|task| {
                let stats = stats.clone();
                let progress = progress.clone();
                let cancel = cancel.clone();
                let gate = gate.clone();
                async move { self.perform(task, &stats, &gate, &progress, &cancel).await }
            }))
            .buffer_unordered(self.configuration.global_concurrency.max(1))
            .collect()
            .await;

        stop_speed.store(1, Ordering::SeqCst);
        speed_task.await.ok();

        if cancel.is_cancelled() {
            // Requirement: a cancelled install must not leave half-written data
            // behind. Verified files stay in the content cache so a later run
            // restores them instantly.
            for file in results.iter().filter_map(|result| result.as_ref().ok()) {
                let _ = std::fs::remove_file(&file.path);
            }
            for failure in results.iter().filter_map(|result| result.as_ref().err()) {
                remove_partials(&failure.destination);
            }
            return Err(Error::Cancelled);
        }

        let mut downloaded = Vec::new();
        let mut failures = Vec::new();
        for result in results {
            match result {
                Ok(file) => downloaded.push(file),
                Err(failure) => {
                    remove_partials(&failure.destination);
                    failures.push(failure);
                }
            }
        }
        downloaded.sort_by(|a, b| a.path.cmp(&b.path));
        failures.sort_by(|a, b| a.destination.cmp(&b.destination));
        Ok(DownloadSummary {
            downloaded,
            cache_hits,
            failures,
        })
    }

    fn spawn_speed_reporter(
        &self,
        stats: Arc<TransferStats>,
        progress: SharedProgress,
        stop: Arc<AtomicU64>,
    ) -> tokio::task::JoinHandle<()> {
        let interval = Duration::from_millis(self.configuration.speed_report_interval_ms.max(100));
        tokio::spawn(async move {
            let mut last_bytes = 0u64;
            let mut ticker = tokio::time::interval(interval);
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            ticker.tick().await;
            loop {
                ticker.tick().await;
                if stop.load(Ordering::SeqCst) != 0 {
                    break;
                }
                let now = stats.downloaded.load(Ordering::Relaxed);
                let delta = now.saturating_sub(last_bytes);
                last_bytes = now;
                let per_second = (delta as f64 / interval.as_secs_f64()) as u64;
                let total = stats.total.load(Ordering::Relaxed);
                let remaining = if per_second > 0 && total > now {
                    Some((total - now) / per_second)
                } else {
                    None
                };
                progress.emit(InstallProgressEvent::Speed {
                    bytes_per_second: per_second,
                    remaining_seconds: remaining,
                    active_files: stats.active.load(Ordering::Relaxed),
                });
            }
        })
    }

    async fn perform(
        &self,
        task: DownloadTask,
        stats: &Arc<TransferStats>,
        gate: &Arc<AdaptiveGate>,
        progress: &SharedProgress,
        cancel: &CancelFlag,
    ) -> std::result::Result<DownloadedFile, DownloadFailure> {
        if cancel.is_cancelled() {
            return Err(DownloadFailure {
                destination: task.destination,
                code: "cancelled".into(),
                message: "Cancelled".into(),
            });
        }
        progress.emit(InstallProgressEvent::FileStarted {
            path: task.destination.to_string_lossy().to_string(),
            size: task.size.unwrap_or(0),
        });
        let Some(official) = task.official_url.clone() else {
            let message = format!(
                "version metadata provides no download URL for {}",
                task.destination.display()
            );
            progress.emit(InstallProgressEvent::FileFailed {
                path: task.destination.to_string_lossy().to_string(),
                message: message.clone(),
            });
            return Err(DownloadFailure {
                destination: task.destination,
                code: "missing_dependency".into(),
                message,
            });
        };

        let candidates = self.candidates(&official);
        if candidates.is_empty() {
            let message = format!("no download source available for {}", redact_url(&official));
            progress.emit(InstallProgressEvent::FileFailed {
                path: task.destination.to_string_lossy().to_string(),
                message: message.clone(),
            });
            return Err(DownloadFailure {
                destination: task.destination,
                code: "unavailable".into(),
                message,
            });
        }

        let mut last_message = String::from("download failed");
        for (url, source_name) in candidates {
            let host_gate = self.host_gate(&url);
            let _host_permit = host_gate.acquire().await;
            let gate_permit = gate.acquire().await;
            stats.active.fetch_add(1, Ordering::Relaxed);
            let started = Instant::now();
            let outcome = self
                .attempt(&task, &url, &source_name, stats, progress, cancel)
                .await;
            stats.active.fetch_sub(1, Ordering::Relaxed);
            drop(gate_permit);
            match outcome {
                Ok(bytes) => {
                    gate.on_success();
                    self.health.record_success(&source_name, started.elapsed());
                    if let (Some(cache), Some(sha1)) = (&self.cache, task.sha1.as_deref()) {
                        let _ = cache.store(sha1, &task.destination);
                    }
                    progress.emit(InstallProgressEvent::FileFinished {
                        path: task.destination.to_string_lossy().to_string(),
                        bytes,
                        source: source_name.clone(),
                    });
                    return Ok(DownloadedFile {
                        path: task.destination,
                        bytes,
                        source: source_name,
                    });
                }
                Err((message, retryable)) => {
                    gate.on_failure();
                    self.health.record_failure(&source_name);
                    last_message = message;
                    // A hard failure on one mirror still deserves a try on the
                    // next one, so only give up early for fixed policies.
                    if !retryable && self.policy != DownloadSourcePolicy::Auto {
                        break;
                    }
                }
            }
        }
        progress.emit(InstallProgressEvent::FileFailed {
            path: task.destination.to_string_lossy().to_string(),
            message: last_message.clone(),
        });
        Err(DownloadFailure {
            destination: task.destination,
            code: "download_failed".into(),
            message: last_message,
        })
    }

    fn candidates(&self, official: &str) -> Vec<(String, String)> {
        let mut list: Vec<(String, String)> = Vec::new();
        match self.policy {
            DownloadSourcePolicy::Official => {
                list.push((official.to_string(), "official".into()));
            }
            DownloadSourcePolicy::Mirror => {
                if let Some(mirror) = &self.mirror {
                    if let Some(rewritten) = mirror.rewrite(official) {
                        list.push((rewritten, format!("mirror:{}", mirror.id)));
                    }
                }
                for mirror in &self.builtin {
                    if let Some(rewritten) = rewrite_url(mirror, official) {
                        list.push((rewritten, format!("builtin:{}", mirror.id)));
                    }
                }
            }
            DownloadSourcePolicy::Auto => {
                list.push((official.to_string(), "official".into()));
                if let Some(mirror) = &self.mirror {
                    if let Some(rewritten) = mirror.rewrite(official) {
                        list.push((rewritten, format!("mirror:{}", mirror.id)));
                    }
                }
                for mirror in &self.builtin {
                    if let Some(rewritten) = rewrite_url(mirror, official) {
                        list.push((rewritten, format!("builtin:{}", mirror.id)));
                    }
                }
                // Rank by observed health so a broken source falls behind.
                let health = &self.health;
                list.sort_by(|a, b| {
                    health
                        .score(&b.1)
                        .partial_cmp(&health.score(&a.1))
                        .unwrap_or(std::cmp::Ordering::Equal)
                });
            }
            DownloadSourcePolicy::LocalCacheOnly => {}
        }
        list
    }

    async fn attempt(
        &self,
        task: &DownloadTask,
        url: &str,
        source: &str,
        stats: &Arc<TransferStats>,
        progress: &SharedProgress,
        cancel: &CancelFlag,
    ) -> std::result::Result<u64, (String, bool)> {
        if let Some(parent) = task.destination.parent() {
            if let Err(error) = std::fs::create_dir_all(parent) {
                return Err((
                    format!("cannot create {}: {error}", parent.display()),
                    false,
                ));
            }
        }
        let partial = partial_path(&task.destination);
        let mut last_error: Option<(String, bool)> = None;
        let attempts = self.configuration.max_retries.max(1);
        for attempt in 0..attempts {
            if cancel.is_cancelled() {
                remove_partials(&task.destination);
                return Err(("Cancelled".into(), false));
            }
            if attempt > 0 {
                progress.emit(InstallProgressEvent::Retry {
                    path: task.destination.to_string_lossy().to_string(),
                    attempt,
                    max_attempts: attempts,
                    message: last_error
                        .as_ref()
                        .map(|(message, _)| message.clone())
                        .unwrap_or_default(),
                });
                let delay = self
                    .configuration
                    .retry_delay_ms
                    .saturating_mul(1u64 << attempt.min(4))
                    .min(8000);
                tokio::time::sleep(Duration::from_millis(delay)).await;
            }

            let outcome = if self.should_segment(task) {
                self.fetch_segmented(&task.destination, url, stats, progress, cancel)
                    .await
            } else {
                self.fetch_single(&partial, url, stats, progress, cancel)
                    .await
            };

            match outcome {
                Ok(bytes) => match self.finish_transfer(task, &partial, bytes, stats, progress) {
                    Ok(()) => return Ok(bytes),
                    Err(Retry::Recoverable(message)) => {
                        last_error = Some((message, true));
                        continue;
                    }
                    Err(Retry::Fatal(message)) => return Err((message, false)),
                },
                Err(error) => {
                    // The bytes live in a partial file that is about to be
                    // discarded, so take them out of the aggregate again.
                    stats.rollback(error.written, progress);
                    if error.range_unsupported {
                        match self
                            .fetch_single(&partial, url, stats, progress, cancel)
                            .await
                        {
                            Ok(bytes) => {
                                match self.finish_transfer(task, &partial, bytes, stats, progress) {
                                    Ok(()) => return Ok(bytes),
                                    Err(Retry::Recoverable(message)) => {
                                        last_error = Some((message, true));
                                        continue;
                                    }
                                    Err(Retry::Fatal(message)) => return Err((message, false)),
                                }
                            }
                            Err(plain) => {
                                stats.rollback(plain.written, progress);
                                remove_partials(&task.destination);
                                if !plain.retryable {
                                    return Err((plain.message, false));
                                }
                                last_error = Some((plain.message, true));
                                continue;
                            }
                        }
                    }
                    remove_partials(&task.destination);
                    if !error.retryable {
                        return Err((error.message, false));
                    }
                    last_error = Some((error.message, true));
                }
            }
        }
        let (message, retryable) = last_error.unwrap_or_else(|| ("download failed".into(), true));
        Err((format!("{message} (source: {source})"), retryable))
    }

    /// Verifies the freshly written partial file and atomically moves it into
    /// place. Verification failures are retried, placement failures are not.
    fn finish_transfer(
        &self,
        task: &DownloadTask,
        partial: &Path,
        bytes: u64,
        stats: &Arc<TransferStats>,
        progress: &SharedProgress,
    ) -> std::result::Result<(), Retry> {
        let matches = verify_file(partial, task.sha1.as_deref(), task.size).unwrap_or(false);
        if !matches {
            let actual = sha1_file(partial).unwrap_or_else(|_| "unreadable".into());
            remove_partials(&task.destination);
            stats.rollback(bytes, progress);
            return Err(Retry::Recoverable(format!(
                "verification failed for {}: expected {:?}, got {actual}",
                task.destination.display(),
                task.sha1
            )));
        }
        if let Err(error) = std::fs::rename(partial, &task.destination) {
            remove_partials(&task.destination);
            stats.rollback(bytes, progress);
            return Err(Retry::Fatal(format!(
                "cannot place {}: {error}",
                task.destination.display()
            )));
        }
        Ok(())
    }

    /// Large files with a known size are split into HTTP Range segments. An
    /// unsupported server is handled by the caller falling back to a stream.
    fn should_segment(&self, task: &DownloadTask) -> bool {
        let Some(size) = task.size else {
            return false;
        };
        self.configuration.segments > 1
            && size
                >= self
                    .configuration
                    .segment_threshold_bytes
                    .max(MIN_SEGMENT_BYTES)
    }

    async fn fetch_segmented(
        &self,
        destination: &Path,
        url: &str,
        stats: &Arc<TransferStats>,
        progress: &SharedProgress,
        cancel: &CancelFlag,
    ) -> std::result::Result<u64, FetchError> {
        let Some((_total, ranges)) = self.probe_ranges(url).await? else {
            return Err(FetchError::range_unsupported(0));
        };
        if ranges.len() < 2 {
            return Err(FetchError::range_unsupported(0));
        }
        let mut futures = Vec::new();
        for (index, range) in ranges.into_iter().enumerate() {
            let segment = segment_path(destination, index);
            let stats = stats.clone();
            let progress = progress.clone();
            let cancel = cancel.clone();
            futures.push(async move {
                self.download_range(url, &segment, range, &stats, &progress, &cancel)
                    .await
            });
        }
        let results = futures_util::stream::iter(futures)
            .buffer_unordered(self.configuration.segments.max(1))
            .collect::<Vec<_>>()
            .await;
        let mut written = 0u64;
        let mut first_error: Option<FetchError> = None;
        for result in results {
            match result {
                Ok(bytes) => written += bytes,
                Err(error) => {
                    if first_error.is_none() {
                        first_error = Some(error);
                    }
                }
            }
        }
        if let Some(error) = first_error {
            return Err(error);
        }
        // Concatenate the segments into the canonical partial file so the
        // regular verification path can handle it.
        let partial = partial_path(destination);
        let mut output = tokio::fs::File::create(&partial).await.map_err(|error| {
            FetchError::new(
                format!("cannot create {}: {error}", partial.display()),
                false,
                0,
            )
        })?;
        let mut index = 0usize;
        while segment_path(destination, index).is_file() {
            let segment = segment_path(destination, index);
            let mut input = tokio::fs::File::open(&segment).await.map_err(|error| {
                FetchError::new(format!("cannot read segment: {error}"), true, 0)
            })?;
            tokio::io::copy(&mut input, &mut output)
                .await
                .map_err(|error| {
                    FetchError::new(format!("cannot assemble segments: {error}"), true, 0)
                })?;
            let _ = std::fs::remove_file(&segment);
            index += 1;
        }
        tokio::io::AsyncWriteExt::flush(&mut output)
            .await
            .map_err(|error| FetchError::new(format!("flush error: {error}"), false, written))?;
        Ok(written)
    }

    /// Asks the server whether it honours Range and returns the byte ranges to
    /// fetch. None means "no range support, use a single stream".
    async fn probe_ranges(
        &self,
        url: &str,
    ) -> std::result::Result<Option<(u64, Vec<(u64, u64)>)>, FetchError> {
        let response = self
            .probe_client
            .get(url)
            .header(reqwest::header::RANGE, "bytes=0-0")
            .send()
            .await
            .map_err(|error| {
                FetchError::new(
                    describe_transfer_error(
                        "range probe",
                        url,
                        classify_reqwest_error(&error),
                        &error.to_string(),
                    ),
                    true,
                    0,
                )
            })?;
        if response.status() != reqwest::StatusCode::PARTIAL_CONTENT {
            return Ok(None);
        }
        let total = response
            .headers()
            .get(reqwest::header::CONTENT_RANGE)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.rsplit('/').next().map(|part| part.to_string()))
            .and_then(|value| value.parse::<u64>().ok());
        let Some(total) = total else {
            return Ok(None);
        };
        if total < MIN_SEGMENT_BYTES {
            return Ok(None);
        }
        let wanted = self.configuration.segments.max(1) as u64;
        let segments = wanted.min((total / MIN_SEGMENT_BYTES).max(1));
        if segments < 2 {
            return Ok(None);
        }
        let chunk = total.div_ceil(segments);
        let mut ranges = Vec::new();
        let mut start = 0u64;
        while start < total {
            let end = (start + chunk - 1).min(total - 1);
            ranges.push((start, end));
            start = end + 1;
        }
        Ok(Some((total, ranges)))
    }

    async fn download_range(
        &self,
        url: &str,
        segment: &Path,
        (start, end): (u64, u64),
        stats: &Arc<TransferStats>,
        progress: &SharedProgress,
        cancel: &CancelFlag,
    ) -> std::result::Result<u64, FetchError> {
        let existing = std::fs::metadata(segment)
            .map(|meta| meta.len())
            .unwrap_or(0);
        let expected = end - start + 1;
        if existing >= expected {
            return Ok(0);
        }
        let from = start + existing;
        let response = self
            .client
            .get(url)
            .header(reqwest::header::RANGE, format!("bytes={from}-{end}"))
            .send()
            .await
            .map_err(|error| {
                FetchError::new(
                    describe_transfer_error(
                        "segment",
                        url,
                        classify_reqwest_error(&error),
                        &error.to_string(),
                    ),
                    true,
                    0,
                )
            })?;
        if response.status() == reqwest::StatusCode::OK {
            return Err(FetchError::range_unsupported(0));
        }
        let status = response.status();
        if !status.is_success() {
            let retryable =
                status.as_u16() == 408 || status.as_u16() == 429 || status.is_server_error();
            return Err(FetchError::new(
                format!("segment: HTTP {status} for {}", redact_url(url)),
                retryable,
                0,
            ));
        }
        let mut file = if existing > 0 {
            tokio::fs::OpenOptions::new()
                .append(true)
                .open(segment)
                .await
        } else {
            tokio::fs::File::create(segment).await
        }
        .map_err(|error| FetchError::new(format!("cannot open segment: {error}"), false, 0))?;

        let mut stream = response.bytes_stream();
        let mut written = 0u64;
        while let Some(chunk) = stream.next().await {
            if cancel.is_cancelled() {
                return Err(FetchError::new("Cancelled", false, written));
            }
            let chunk = chunk.map_err(|error| {
                FetchError::new(
                    describe_transfer_error(
                        "segment body",
                        url,
                        classify_reqwest_error(&error),
                        &error.to_string(),
                    ),
                    true,
                    written,
                )
            })?;
            tokio::io::AsyncWriteExt::write_all(&mut file, &chunk)
                .await
                .map_err(|error| {
                    FetchError::new(format!("write error: {error}"), false, written)
                })?;
            written += chunk.len() as u64;
            stats.add(chunk.len() as u64, progress);
        }
        tokio::io::AsyncWriteExt::flush(&mut file)
            .await
            .map_err(|error| FetchError::new(format!("flush error: {error}"), false, written))?;
        Ok(written)
    }

    /// Single stream download with resume support: an existing partial file is
    /// continued with Range when the server allows it.
    async fn fetch_single(
        &self,
        partial: &Path,
        url: &str,
        stats: &Arc<TransferStats>,
        progress: &SharedProgress,
        cancel: &CancelFlag,
    ) -> std::result::Result<u64, FetchError> {
        let existing = std::fs::metadata(partial)
            .map(|meta| meta.len())
            .unwrap_or(0);
        let mut request = self.client.get(url);
        if existing > 0 {
            request = request.header(reqwest::header::RANGE, format!("bytes={existing}-"));
        }
        let response = request.send().await.map_err(|error| {
            FetchError::new(
                describe_transfer_error(
                    "download",
                    url,
                    classify_reqwest_error(&error),
                    &error.to_string(),
                ),
                true,
                0,
            )
        })?;
        let status = response.status();
        if !status.is_success() {
            let retryable =
                status.as_u16() == 408 || status.as_u16() == 429 || status.is_server_error();
            return Err(FetchError::new(
                format!("download: HTTP {status} for {}", redact_url(url)),
                retryable,
                0,
            ));
        }
        // A 200 means the request was answered in full: start from zero.
        let resume = existing > 0 && status == reqwest::StatusCode::PARTIAL_CONTENT;
        let mut file = if resume {
            tokio::fs::OpenOptions::new()
                .append(true)
                .open(partial)
                .await
        } else {
            tokio::fs::File::create(partial).await
        }
        .map_err(|error| {
            FetchError::new(
                format!("cannot create {}: {error}", partial.display()),
                false,
                0,
            )
        })?;

        let mut stream = response.bytes_stream();
        let mut written = 0u64;
        while let Some(chunk) = stream.next().await {
            if cancel.is_cancelled() {
                return Err(FetchError::new("Cancelled", false, written));
            }
            let chunk = chunk.map_err(|error| {
                FetchError::new(
                    describe_transfer_error(
                        "download body",
                        url,
                        classify_reqwest_error(&error),
                        &error.to_string(),
                    ),
                    true,
                    written,
                )
            })?;
            tokio::io::AsyncWriteExt::write_all(&mut file, &chunk)
                .await
                .map_err(|error| {
                    FetchError::new(format!("write error: {error}"), false, written)
                })?;
            written += chunk.len() as u64;
            stats.add(chunk.len() as u64, progress);
        }
        tokio::io::AsyncWriteExt::flush(&mut file)
            .await
            .map_err(|error| FetchError::new(format!("flush error: {error}"), false, written))?;
        Ok(written)
    }
}

fn user_agent() -> String {
    format!(
        "{}/{}",
        crate::models::launch::LAUNCHER_NAME,
        crate::models::launch::LAUNCHER_VERSION
    )
}

enum Retry {
    Recoverable(String),
    Fatal(String),
}

/// "<name>.<ext>.part" next to the destination, so a download can never
/// overwrite a file that already passed verification.
fn partial_path(destination: &Path) -> PathBuf {
    let extension = destination
        .extension()
        .and_then(|value| value.to_str())
        .map(|value| format!("{value}.part"))
        .unwrap_or_else(|| "part".to_string());
    destination.with_extension(extension)
}

fn segment_path(destination: &Path, index: usize) -> PathBuf {
    let mut path = partial_path(destination).into_os_string();
    path.push(format!(".seg{index}"));
    PathBuf::from(path)
}

/// Removes every artefact a cancelled or failed transfer may have produced.
fn remove_partials(destination: &Path) {
    let _ = std::fs::remove_file(partial_path(destination));
    let mut index = 0usize;
    while segment_path(destination, index).exists() {
        let _ = std::fs::remove_file(segment_path(destination, index));
        index += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn partial_and_segment_paths_are_predictable() {
        let destination = PathBuf::from("/tmp/libs/example.jar");
        assert_eq!(
            partial_path(&destination),
            PathBuf::from("/tmp/libs/example.jar.part")
        );
        assert_eq!(
            segment_path(&destination, 2),
            PathBuf::from("/tmp/libs/example.jar.part.seg2")
        );
        let plain = PathBuf::from("/tmp/no-extension");
        assert_eq!(
            partial_path(&plain),
            PathBuf::from("/tmp/no-extension.part")
        );
    }

    #[test]
    fn gate_shrinks_on_failure_and_recovers() {
        let gate = AdaptiveGate::new(8, 16, true);
        gate.on_failure();
        assert_eq!(gate.current(), 4);
        gate.on_failure();
        assert_eq!(gate.current(), 2);
        gate.on_success();
        assert_eq!(gate.current(), 3);
    }
}
