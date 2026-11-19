use std::cmp::Reverse;
use std::collections::{HashMap, HashSet};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

use futures_util::{StreamExt, TryStreamExt};
use reqwest::header::{CONTENT_RANGE, LOCATION, RANGE};
use reqwest::{Response, StatusCode};
use tokio::sync::{Notify, OwnedSemaphorePermit, Semaphore};

use crate::error::{Error, Result};
use crate::net::{classify_reqwest_error, describe_transfer_error, redact_url};

use super::hashing::verify_file;
use super::models::*;

pub mod cache;
pub mod source;

pub use cache::ContentCache;
pub use source::{
    bmclapi, builtin_mirror, builtin_mirrors, rewrite_url, BuiltinMirror, HealthRegistry,
    HostRewrite,
};

const MIN_SEGMENT_BYTES: u64 = 1024 * 1024;
type HostGates = Mutex<HashMap<String, Arc<Semaphore>>>;

static GLOBAL: LazyLock<Semaphore> =
    LazyLock::new(|| Semaphore::new(DownloadConfiguration::default().global_concurrency));
static HOSTS: LazyLock<HostGates> = LazyLock::new(HostGates::default);
static DESTINATIONS: LazyLock<[tokio::sync::Mutex<()>; 1024]> =
    LazyLock::new(|| std::array::from_fn(|_| tokio::sync::Mutex::new(())));

#[derive(Debug)]
struct FetchError {
    message: String,
    retryable: bool,
    source_failure: bool,
    range_unsupported: bool,
}

impl FetchError {
    fn local(error: impl std::fmt::Display) -> Self {
        Self {
            message: error.to_string(),
            retryable: false,
            source_failure: false,
            range_unsupported: false,
        }
    }

    fn remote(message: String, retryable: bool, source_failure: bool) -> Self {
        Self {
            message,
            retryable,
            source_failure,
            range_unsupported: false,
        }
    }

    fn transport(url: &str, error: &reqwest::Error) -> Self {
        Self::remote(
            describe_transfer_error(
                "download",
                url,
                classify_reqwest_error(error),
                &error.to_string(),
            ),
            true,
            true,
        )
    }

    fn status(response: &Response) -> Self {
        let status = response.status();
        let transient = matches!(status.as_u16(), 408 | 429) || status.is_server_error();
        Self::remote(
            format!("HTTP {status} for {}", redact_url(response.url().as_str())),
            transient,
            transient || matches!(status.as_u16(), 401 | 403),
        )
    }

    fn range() -> Self {
        Self {
            range_unsupported: true,
            ..Self::remote(
                "server returned an incompatible byte range".into(),
                true,
                false,
            )
        }
    }

    fn cancelled() -> Self {
        Self::local("Cancelled")
    }
}

#[derive(Default)]
struct Counters {
    downloaded: u64,
    declared: u64,
    received: u64,
}

struct TransferStats {
    counters: Mutex<Counters>,
    active: Arc<std::sync::atomic::AtomicUsize>,
}

struct AttemptProgress {
    stats: Arc<TransferStats>,
    sink: SharedProgress,
    credited: std::sync::atomic::AtomicU64,
}

impl AttemptProgress {
    fn add(&self, bytes: u64, received: bool) {
        use std::sync::atomic::Ordering::Relaxed;
        self.credited.fetch_add(bytes, Relaxed);
        self.update(|counters| {
            counters.downloaded += bytes;
            if received {
                counters.received += bytes;
            }
        });
    }

    fn update(&self, change: impl FnOnce(&mut Counters)) {
        // Serialize both the counter and its event across parallel requests.
        let mut counters = self.stats.counters.lock().expect("progress counters");
        change(&mut counters);
        self.sink.emit(InstallProgressEvent::Bytes {
            downloaded: counters.downloaded,
            total: counters.declared.max(counters.downloaded),
        });
    }

    fn reset(&self) {
        use std::sync::atomic::Ordering::Relaxed;
        let bytes = self.credited.swap(0, Relaxed);
        if bytes != 0 {
            self.update(|counters| counters.downloaded -= bytes);
        }
    }

    fn commit(&mut self) {
        *self.credited.get_mut() = 0;
    }
}

impl Drop for AttemptProgress {
    fn drop(&mut self) {
        self.reset();
    }
}

struct AdaptiveGate {
    state: Mutex<(usize, usize)>, // (limit, in flight)
    max: usize,
    adaptive: bool,
    notify: Notify,
}

struct GatePermit(Arc<AdaptiveGate>);

impl Drop for GatePermit {
    fn drop(&mut self) {
        self.0.state.lock().expect("request gate").1 -= 1;
        self.0.notify.notify_waiters();
    }
}

impl AdaptiveGate {
    fn new(limit: usize, max: usize, adaptive: bool) -> Self {
        let max = max.max(1);
        Self {
            state: Mutex::new((limit.clamp(1, max), 0)),
            max,
            adaptive,
            notify: Notify::new(),
        }
    }

    async fn acquire(self: &Arc<Self>) -> GatePermit {
        loop {
            let notified = self.notify.notified();
            {
                let mut state = self.state.lock().expect("request gate");
                if state.1 < state.0 {
                    state.1 += 1;
                    return GatePermit(Arc::clone(self));
                }
            }
            notified.await;
        }
    }

    fn on_success(&self) {
        if self.adaptive {
            let mut state = self.state.lock().expect("request gate");
            if state.0 < self.max {
                state.0 += 1;
                self.notify.notify_waiters();
            }
        }
    }

    fn on_failure(&self) {
        if self.adaptive {
            let mut state = self.state.lock().expect("request gate");
            state.0 = (state.0 / 2).max(1);
        }
    }
}

struct ActiveRequest {
    response: Response,
    _host: OwnedSemaphorePermit,
    _shared_host: OwnedSemaphorePermit,
    _gate: GatePermit,
    _global: tokio::sync::SemaphorePermit<'static>,
}

#[derive(Clone)]
pub struct Downloader {
    client: reqwest::Client,
    policy: DownloadSourcePolicy,
    mirror: Option<TrustedMirrorConfiguration>,
    builtin: Vec<BuiltinMirror>,
    configuration: DownloadConfiguration,
    health: Arc<HealthRegistry>,
    gate: Arc<AdaptiveGate>,
    host_gates: Arc<HostGates>,
    cache: Option<Arc<ContentCache>>,
}

impl Downloader {
    pub fn new(
        policy: DownloadSourcePolicy,
        mirror: Option<TrustedMirrorConfiguration>,
        configuration: DownloadConfiguration,
    ) -> Result<Self> {
        let builtin: Vec<_> = configuration
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
            .user_agent(format!(
                "{}/{}",
                crate::models::launch::LAUNCHER_NAME,
                crate::models::launch::LAUNCHER_VERSION
            ))
            .connect_timeout(Duration::from_secs(20))
            .timeout(Duration::from_secs(600))
            .redirect(reqwest::redirect::Policy::none())
            .no_gzip()
            .build()?;
        let cache = configuration
            .cache_directory
            .clone()
            .map(ContentCache::new)
            .map(Arc::new);
        let gate = AdaptiveGate::new(
            configuration.concurrency,
            configuration.global_concurrency,
            configuration.adaptive_concurrency,
        );
        Ok(Self {
            client,
            policy,
            mirror,
            builtin,
            configuration,
            cache,
            gate: Arc::new(gate),
            health: Arc::new(HealthRegistry::new(4, Duration::from_secs(20))),
            host_gates: Arc::new(HostGates::default()),
        })
    }

    pub fn policy(&self) -> DownloadSourcePolicy {
        self.policy
    }

    async fn request(
        &self,
        url: &str,
        range: Option<&str>,
        cancel: &CancelFlag,
    ) -> std::result::Result<ActiveRequest, FetchError> {
        let operation = async {
            let mut target = url::Url::parse(url).map_err(FetchError::local)?;
            for hop in 0..=10 {
                let host = target
                    .host_str()
                    .ok_or_else(|| FetchError::local("download URL has no host"))?;
                let local = host_gate(
                    &self.host_gates,
                    host,
                    self.configuration.per_host_concurrency,
                );
                let shared = host_gate(
                    &HOSTS,
                    host,
                    DownloadConfiguration::default().per_host_concurrency,
                );
                let local = local.acquire_owned().await.expect("host gate is open");
                let shared = shared.acquire_owned().await.expect("host gate is open");
                let gate = self.gate.acquire().await;
                let global = GLOBAL.acquire().await.expect("global gate is open");
                let mut request = self.client.get(target.clone());
                if let Some(range) = range {
                    request = request.header(RANGE, range);
                }
                let response = request
                    .send()
                    .await
                    .map_err(|error| FetchError::transport(target.as_str(), &error))?;
                if matches!(response.status().as_u16(), 301 | 302 | 303 | 307 | 308) {
                    if let Some(next) = response
                        .headers()
                        .get(LOCATION)
                        .and_then(|value| value.to_str().ok())
                        .and_then(|value| target.join(value).ok())
                    {
                        if hop == 10
                            || !matches!(next.scheme(), "http" | "https")
                            || (target.scheme() == "https" && next.scheme() == "http")
                        {
                            return Err(FetchError::remote(
                                "invalid download redirect chain".into(),
                                false,
                                true,
                            ));
                        }
                        target = next;
                        continue; // Release the old host before acquiring the next one.
                    }
                }
                return Ok(ActiveRequest {
                    response,
                    _host: local,
                    _shared_host: shared,
                    _gate: gate,
                    _global: global,
                });
            }
            unreachable!()
        };
        tokio::select! {
            biased;
            _ = cancel.cancelled() => Err(FetchError::cancelled()),
            result = operation => result,
        }
    }

    pub async fn download(
        &self,
        tasks: Vec<DownloadTask>,
        progress: SharedProgress,
        cancel: CancelFlag,
    ) -> Result<DownloadSummary> {
        use std::sync::atomic::Ordering::Relaxed;

        let mut seen = HashSet::new();
        let mut summary = DownloadSummary::default();
        let mut pending = Vec::new();
        for task in tasks {
            if cancel.is_cancelled() {
                return Err(Error::Cancelled);
            }
            if !seen.insert(task.destination.clone()) {
                continue;
            }
            let guard = tokio::select! {
                biased;
                _ = cancel.cancelled() => return Err(Error::Cancelled),
                guard = destination_gate(&task.destination).lock() => guard,
            };
            if self.cached(&task)? {
                summary.cache_hits += 1;
            } else {
                pending.push(task);
            }
            drop(guard);
        }
        let declared = pending.iter().map(|task| task.size.unwrap_or(0)).sum();
        summary.declared_bytes = declared;
        progress.emit(InstallProgressEvent::Plan {
            total_files: summary.cache_hits + pending.len(),
            total_bytes: declared,
            cache_hits: summary.cache_hits,
        });

        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        if self.policy == DownloadSourcePolicy::LocalCacheOnly {
            summary.failures = pending
                .into_iter()
                .map(|task| DownloadFailure {
                    destination: task.destination,
                    code: "missing_dependency".into(),
                    message: "local-cache-only: file is not present in the local cache".into(),
                })
                .collect();
            return Ok(summary);
        }

        // Launch-critical files first, asset bulk last: the first window of
        // transfers decides whether the game becomes startable quickly, so the
        // client jar goes first, then libraries and natives, then assets.
        pending.sort_by_key(|task| (schedule_rank(task.kind), Reverse(task.size.unwrap_or(0))));
        let stats = Arc::new(TransferStats {
            counters: Mutex::new(Counters {
                declared,
                ..Counters::default()
            }),
            active: Arc::default(),
        });
        let downloader = Arc::new(self.clone());
        let mut transfers = futures_util::stream::iter(pending.into_iter().map(|task| {
            Arc::clone(&downloader).perform(
                task,
                Arc::clone(&stats),
                progress.clone(),
                cancel.clone(),
            )
        }))
        .buffer_unordered(self.configuration.global_concurrency.max(1));
        let interval = Duration::from_millis(self.configuration.speed_report_interval_ms.max(100));
        let mut ticker = tokio::time::interval_at(tokio::time::Instant::now() + interval, interval);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let (mut last_bytes, mut last_tick) = (0, Instant::now());
        loop {
            tokio::select! {
                result = transfers.next() => match result {
                    Some(Ok(Some(file))) => summary.downloaded.push(file),
                    Some(Ok(None)) => summary.cache_hits += 1,
                    Some(Err(failure)) => summary.failures.push(failure),
                    None => break,
                },
                _ = ticker.tick() => {
                    let counters = stats.counters.lock().expect("speed counters");
                    let per_second = ((counters.received - last_bytes) as f64 / last_tick.elapsed().as_secs_f64()) as u64;
                    last_bytes = counters.received;
                    last_tick = Instant::now();
                    progress.emit(InstallProgressEvent::Speed {
                        bytes_per_second: per_second,
                        remaining_seconds: counters.declared.saturating_sub(counters.downloaded).checked_div(per_second),
                        active_files: stats.active.load(Relaxed),
                    });
                }
            }
        }
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        summary.declared_bytes = stats.counters.lock().expect("progress counters").declared;
        summary.downloaded.sort_by(|a, b| a.path.cmp(&b.path));
        summary
            .failures
            .sort_by(|a, b| a.destination.cmp(&b.destination));
        Ok(summary)
    }

    fn cached(&self, task: &DownloadTask) -> Result<bool> {
        if verify_file(&task.destination, task.sha1.as_deref(), task.size)? {
            return Ok(true);
        }
        Ok(self
            .cache
            .as_ref()
            .zip(task.sha1.as_deref())
            .is_some_and(|(cache, hash)| {
                cache
                    .materialize(hash, task.size, &task.destination)
                    .unwrap_or(false)
            }))
    }

    async fn perform(
        self: Arc<Self>,
        task: DownloadTask,
        stats: Arc<TransferStats>,
        progress: SharedProgress,
        cancel: CancelFlag,
    ) -> std::result::Result<Option<DownloadedFile>, DownloadFailure> {
        use std::sync::atomic::Ordering::Relaxed;
        let path = task.destination.to_string_lossy().into_owned();
        let failure = |code: &str, message: String| {
            if !cancel.is_cancelled() {
                progress.emit(InstallProgressEvent::FileFailed {
                    path: path.clone(),
                    message: message.clone(),
                });
            }
            DownloadFailure {
                destination: task.destination.clone(),
                code: code.into(),
                message,
            }
        };
        let mut credited = AttemptProgress {
            stats: Arc::clone(&stats),
            sink: progress.clone(),
            credited: Default::default(),
        };
        let destination = destination_gate(&task.destination);
        let _guard = tokio::select! {
            biased;
            _ = cancel.cancelled() => return Err(failure("cancelled", "Cancelled".into())),
            guard = destination.lock() => guard,
        };

        // Another installation may have populated the same destination while queued.
        if self
            .cached(&task)
            .map_err(|error| failure("download_failed", error.to_string()))?
        {
            credited.update(|counters| counters.declared -= task.size.unwrap_or(0));
            progress.emit(InstallProgressEvent::FileFinished {
                path: path.clone(),
                bytes: 0,
                source: "cache".into(),
            });
            return Ok(None);
        }
        prepare_parent(&task.destination)
            .map_err(|error| failure("download_failed", error.to_string()))?;
        let partial = partial_path(&task.destination);
        let segments = segments_path(&task.destination);
        if let Some(hash) = task.sha1.as_deref().filter(|hash| cache::is_sha1(hash)) {
            for staged in [&partial, &segments.join("assembled.part")] {
                if !verify_file(staged, Some(hash), task.size)
                    .map_err(|error| failure("download_failed", error.to_string()))?
                {
                    continue;
                }
                if cancel.is_cancelled() {
                    return Err(failure("cancelled", "Cancelled".into()));
                }
                std::fs::rename(staged, &task.destination)
                    .map_err(|error| failure("download_failed", error.to_string()))?;
                discard_segments(&segments);
                if let Some(cache) = &self.cache {
                    let _ = cache.store(hash, &task.destination);
                }
                credited.update(|counters| counters.declared -= task.size.unwrap_or(0));
                progress.emit(InstallProgressEvent::FileFinished {
                    path,
                    bytes: 0,
                    source: "cache".into(),
                });
                return Ok(None);
            }
        }
        let official = task.official_url.as_deref().ok_or_else(|| {
            failure(
                "missing_dependency",
                format!("version metadata provides no download URL for {path}"),
            )
        })?;
        progress.emit(InstallProgressEvent::FileStarted {
            path: path.clone(),
            size: task.size.unwrap_or(0),
        });

        struct ActiveFile(Arc<std::sync::atomic::AtomicUsize>);
        impl Drop for ActiveFile {
            fn drop(&mut self) {
                self.0.fetch_sub(1, Relaxed);
            }
        }
        stats.active.fetch_add(1, Relaxed);
        let _active = ActiveFile(Arc::clone(&stats.active));
        let mut last = format!("no available download source for {}", redact_url(official));
        let candidates = self.candidates(official);
        for (url, source, health_key) in candidates {
            if cancel.is_cancelled() {
                break;
            }
            let Some(admission) = self.health.admit(&health_key) else {
                continue;
            };
            let started = Instant::now();
            let outcome = self
                .attempt(
                    &task,
                    &url,
                    partial.clone(),
                    segments.clone(),
                    &credited,
                    &cancel,
                    admission.is_probe(),
                )
                .await;
            if cancel.is_cancelled() && outcome.is_err() {
                credited.reset();
                break;
            }
            match outcome {
                Ok(bytes) => {
                    credited.commit();
                    self.gate.on_success();
                    admission.success(started.elapsed());
                    if let (Some(cache), Some(hash)) = (&self.cache, task.sha1.as_deref()) {
                        let _ = cache.store(hash, &task.destination);
                    }
                    progress.emit(InstallProgressEvent::FileFinished {
                        path,
                        bytes,
                        source: source.clone(),
                    });
                    return Ok(Some(DownloadedFile {
                        path: task.destination,
                        bytes,
                        source,
                    }));
                }
                Err(error) => {
                    credited.reset();
                    if error.source_failure {
                        self.gate.on_failure();
                        admission.failure();
                    } else {
                        admission.defer();
                    }
                    last = format!("{} (source: {source})", error.message);
                }
            }
        }
        if cancel.is_cancelled() {
            return Err(failure("cancelled", "Cancelled".into()));
        }
        Err(failure("download_failed", last))
    }

    fn candidates(&self, official: &str) -> Vec<(String, String, String)> {
        let mut list = Vec::new();
        if matches!(
            self.policy,
            DownloadSourcePolicy::Auto | DownloadSourcePolicy::Official
        ) {
            list.push((official.to_owned(), "official".to_owned()));
        }
        if matches!(
            self.policy,
            DownloadSourcePolicy::Auto | DownloadSourcePolicy::Mirror
        ) {
            if let Some(mirror) = &self.mirror {
                if let Some(url) = mirror.rewrite(official) {
                    list.push((url, format!("mirror:{}", mirror.id)));
                }
            }
            for mirror in &self.builtin {
                if let Some(url) = rewrite_url(mirror, official) {
                    list.push((url, format!("builtin:{}", mirror.id)));
                }
            }
        }
        let mut seen = HashSet::new();
        let mut list: Vec<_> = list
            .into_iter()
            .filter_map(|(url, source)| {
                if !seen.insert(url.clone()) {
                    return None;
                }
                let parsed = url::Url::parse(&url).ok()?;
                let key = format!("{source}:{}", parsed.origin().ascii_serialization());
                Some((url, source, key))
            })
            .collect();
        // A due recovery probe must not be permanently outranked by a healthy fallback.
        list.sort_by_cached_key(|(_, _, key)| Reverse(self.health.priority(key)));
        list
    }

    #[allow(clippy::too_many_arguments)]
    async fn attempt(
        &self,
        task: &DownloadTask,
        url: &str,
        partial: PathBuf,
        segments: PathBuf,
        progress: &AttemptProgress,
        cancel: &CancelFlag,
        probe: bool,
    ) -> std::result::Result<u64, FetchError> {
        let attempts = if probe {
            1
        } else {
            self.configuration.max_retries.max(1)
        };
        let mut segmented = task.sha1.as_deref().is_some_and(cache::is_sha1)
            && self.configuration.segments > 1
            && task.size.is_some_and(|size| {
                size >= self
                    .configuration
                    .segment_threshold_bytes
                    .max(2 * MIN_SEGMENT_BYTES)
            });
        let mut last = FetchError::local("download failed");
        for attempt in 0..attempts {
            if cancel.is_cancelled() {
                return Err(FetchError::cancelled());
            }
            if attempt > 0 {
                progress.sink.emit(InstallProgressEvent::Retry {
                    path: task.destination.to_string_lossy().into_owned(),
                    attempt,
                    max_attempts: attempts,
                    message: last.message.clone(),
                });
                let delay = self
                    .configuration
                    .retry_delay_ms
                    .saturating_mul(1u64 << attempt.min(4))
                    .min(8000);
                tokio::select! {
                    _ = cancel.cancelled() => return Err(FetchError::cancelled()),
                    _ = tokio::time::sleep(Duration::from_millis(delay)) => (),
                }
            }
            let assembly = segments.join("assembled.part");
            let mut staged = partial.clone();
            let outcome = if segmented && !partial.is_file() {
                match self
                    .fetch_segmented(
                        task,
                        url,
                        assembly.clone(),
                        segments.clone(),
                        progress,
                        cancel,
                    )
                    .await
                {
                    Err(error) if error.range_unsupported => {
                        progress.reset();
                        segmented = false;
                        self.fetch_single(task, url, partial.clone(), progress, cancel)
                            .await
                    }
                    result => {
                        staged = assembly.clone();
                        result
                    }
                }
            } else {
                self.fetch_single(task, url, partial.clone(), progress, cancel)
                    .await
            };
            match outcome {
                Ok(bytes) => {
                    if cancel.is_cancelled() {
                        return Err(FetchError::cancelled());
                    }
                    if verify_file(&staged, task.sha1.as_deref(), task.size)
                        .map_err(FetchError::local)?
                    {
                        std::fs::rename(&staged, &task.destination).map_err(FetchError::local)?;
                        // The destination is complete now, so any segment state
                        // (including layouts left by an older hash) is dead weight.
                        discard_segments(&segments);
                        return Ok(bytes);
                    }
                    let _ = std::fs::remove_file(&staged);
                    discard_segments(&segments);
                    last = FetchError::remote(
                        format!("verification failed for {}", task.destination.display()),
                        true,
                        true,
                    );
                }
                Err(error) => {
                    if staged == assembly || !task.sha1.as_deref().is_some_and(cache::is_sha1) {
                        let _ = std::fs::remove_file(staged);
                    }
                    if !error.retryable {
                        progress.reset();
                        return Err(error);
                    }
                    last = error;
                }
            }
            progress.reset();
        }
        Err(last)
    }

    async fn fetch_segmented(
        &self,
        task: &DownloadTask,
        url: &str,
        partial: PathBuf,
        segments: PathBuf,
        progress: &AttemptProgress,
        cancel: &CancelFlag,
    ) -> std::result::Result<u64, FetchError> {
        let total = task.size.expect("segmented file has a size");
        let hash = task.sha1.as_deref().expect("segmented file has a hash");
        let count = (self.configuration.segments as u64).min(total / MIN_SEGMENT_BYTES);
        let chunk = total.div_ceil(count);
        let directory = segments.join(hash).join(format!("{total}-{chunk}"));
        std::fs::create_dir_all(&directory).map_err(FetchError::local)?;
        let ranges: Vec<_> = (0..count)
            .filter_map(|index| {
                let start = index * chunk;
                (start < total).then(|| {
                    (
                        directory.join(index.to_string()),
                        start,
                        start.saturating_add(chunk - 1).min(total - 1),
                    )
                })
            })
            .collect();
        if !ranges.iter().all(|(segment, start, end)| {
            segment
                .metadata()
                .is_ok_and(|meta| meta.len() == end - start + 1)
        }) {
            let mut probe = self.request(url, Some("bytes=0-0"), cancel).await?;
            range_response(&probe.response, 0, 0, total)?;
            let probe_data = tokio::select! {
                _ = cancel.cancelled() => return Err(FetchError::cancelled()),
                data = probe.response.chunk() => data.map_err(|error| FetchError::transport(url, &error))?,
            };
            if !probe_data.is_some_and(|data| data.len() == 1) {
                return Err(FetchError::range());
            }
        }
        futures_util::stream::iter(ranges.clone().into_iter().map(
            |(segment, start, end)| async move {
                let length = end - start + 1;
                let existing = valid_prefix(&segment, length)?;
                if existing == length {
                    progress.add(existing, false);
                    return Ok(());
                }
                let from = start + existing;
                let request = self
                    .request(url, Some(&format!("bytes={from}-{end}")), cancel)
                    .await?;
                range_response(&request.response, from, end, total)?;
                self.write_response(request, segment, existing, Some(length), progress, cancel)
                    .await?;
                Ok(())
            },
        ))
        .buffer_unordered(
            self.configuration
                .segments
                .min(self.configuration.global_concurrency.max(1)),
        )
        .try_collect::<Vec<_>>()
        .await?;

        // Keep intact segments until the assembled file is validated and published.
        let mut output = std::fs::File::create(&partial).map_err(FetchError::local)?;
        for (segment, _, _) in &ranges {
            if cancel.is_cancelled() {
                return Err(FetchError::cancelled());
            }
            let mut input = std::fs::File::open(segment).map_err(FetchError::local)?;
            io::copy(&mut input, &mut output).map_err(FetchError::local)?;
        }
        output.sync_data().map_err(FetchError::local)?;
        Ok(total)
    }

    async fn fetch_single(
        &self,
        task: &DownloadTask,
        url: &str,
        partial: PathBuf,
        progress: &AttemptProgress,
        cancel: &CancelFlag,
    ) -> std::result::Result<u64, FetchError> {
        let mut existing = if task.sha1.as_deref().is_some_and(cache::is_sha1) {
            valid_prefix(
                &partial,
                task.size.map_or(u64::MAX, |size| size.saturating_sub(1)),
            )?
        } else {
            0
        };
        let mut expected = task.size;
        let mut request = if existing == 0 {
            self.request(url, None, cancel).await?
        } else {
            self.request(url, Some(&format!("bytes={existing}-")), cancel)
                .await?
        };
        if existing > 0
            && matches!(
                request.response.status(),
                StatusCode::PARTIAL_CONTENT | StatusCode::RANGE_NOT_SATISFIABLE
            )
        {
            match content_range(&request.response) {
                Some((start, end, total))
                    if request.response.status() == StatusCode::PARTIAL_CONTENT
                        && start == existing
                        && end == total - 1
                        && expected.is_none_or(|size| size == total) =>
                {
                    expected = Some(total)
                }
                _ => {
                    drop(request);
                    let _ = std::fs::remove_file(&partial);
                    existing = 0;
                    request = self.request(url, None, cancel).await?;
                }
            }
        } else if request.response.status() == StatusCode::OK {
            existing = 0;
        }
        if request.response.status() != StatusCode::OK
            && !(existing > 0 && request.response.status() == StatusCode::PARTIAL_CONTENT)
        {
            return Err(FetchError::status(&request.response));
        }
        let expected = expected.or_else(|| request.response.content_length());
        self.write_response(request, partial, existing, expected, progress, cancel)
            .await
    }

    async fn write_response(
        &self,
        mut request: ActiveRequest,
        path: PathBuf,
        existing: u64,
        expected: Option<u64>,
        progress: &AttemptProgress,
        cancel: &CancelFlag,
    ) -> std::result::Result<u64, FetchError> {
        if let (Some(length), Some(expected)) = (request.response.content_length(), expected) {
            if length != expected.saturating_sub(existing) {
                return Err(FetchError::remote(
                    "unexpected download Content-Length".into(),
                    true,
                    true,
                ));
            }
        }
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .append(existing > 0)
            .truncate(existing == 0)
            .open(&path)
            .map_err(FetchError::local)?;
        let mut written = existing;
        progress.add(existing, false);
        loop {
            let chunk = tokio::select! {
                biased;
                _ = cancel.cancelled() => return Err(FetchError::cancelled()),
                chunk = request.response.chunk() => chunk.map_err(|error| FetchError::transport(request.response.url().as_str(), &error))?,
            };
            let Some(chunk) = chunk else {
                break;
            };
            if expected
                .is_some_and(|expected| chunk.len() as u64 > expected.saturating_sub(written))
            {
                return Err(FetchError::remote(
                    "download body exceeded its expected size".into(),
                    true,
                    true,
                ));
            }
            file.write_all(&chunk).map_err(FetchError::local)?;
            written += chunk.len() as u64;
            progress.add(chunk.len() as u64, true);
        }
        drop(request);
        if expected.is_some_and(|expected| expected != written) {
            return Err(FetchError::remote(
                "download body ended before its expected size".into(),
                true,
                true,
            ));
        }
        file.sync_data().map_err(FetchError::local)?;
        Ok(written)
    }
}

/// Scheduling tier for a download kind.
///
/// Everything the JVM needs to reach the title screen (client jar, libraries,
/// natives, logging config) is ranked ahead of the asset bulk, which is only
/// read once the game opens a resource screen. Without the tiers a large asset
/// object could occupy the first window and delay the files the launch needs.
fn schedule_rank(kind: MissingDependencyKind) -> u8 {
    match kind {
        MissingDependencyKind::ClientJar => 0,
        MissingDependencyKind::Native | MissingDependencyKind::Library => 1,
        MissingDependencyKind::LogConfig | MissingDependencyKind::VersionMetadata => 2,
        MissingDependencyKind::AssetIndex => 3,
        MissingDependencyKind::Asset => 4,
        MissingDependencyKind::Java => 5,
    }
}

fn host_gate(gates: &HostGates, host: &str, size: usize) -> Arc<Semaphore> {
    gates
        .lock()
        .expect("host gates")
        .entry(host.to_owned())
        .or_insert_with(|| Arc::new(Semaphore::new(size.max(1))))
        .clone()
}

fn destination_gate(path: &Path) -> &'static tokio::sync::Mutex<()> {
    use std::hash::{DefaultHasher, Hash, Hasher};
    // ponytail: stripe destination locks in-process; unrelated paths may occasionally share a slot.
    let mut hasher = DefaultHasher::new();
    path.hash(&mut hasher);
    &DESTINATIONS[hasher.finish() as usize % DESTINATIONS.len()]
}

fn content_range(response: &Response) -> Option<(u64, u64, u64)> {
    let header = response
        .headers()
        .get(CONTENT_RANGE)?
        .to_str()
        .ok()?
        .strip_prefix("bytes ")?;
    let (span, total) = header.split_once('/')?;
    let (start, end) = span.split_once('-')?;
    let (start, end, total) = (start.parse().ok()?, end.parse().ok()?, total.parse().ok()?);
    (start <= end && end < total).then_some((start, end, total))
}

fn range_response(
    response: &Response,
    start: u64,
    end: u64,
    total: u64,
) -> std::result::Result<(), FetchError> {
    match response.status() {
        StatusCode::PARTIAL_CONTENT if content_range(response) == Some((start, end, total)) => {
            Ok(())
        }
        StatusCode::OK | StatusCode::PARTIAL_CONTENT | StatusCode::RANGE_NOT_SATISFIABLE => {
            Err(FetchError::range())
        }
        _ => Err(FetchError::status(response)),
    }
}

fn valid_prefix(path: &Path, max: u64) -> std::result::Result<u64, FetchError> {
    match std::fs::metadata(path) {
        Ok(metadata) if metadata.is_file() && metadata.len() <= max => Ok(metadata.len()),
        Ok(_) => std::fs::remove_file(path)
            .map(|()| 0)
            .map_err(FetchError::local),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(0),
        Err(error) => Err(FetchError::local(error)),
    }
}

fn suffixed(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    PathBuf::from(name)
}

fn partial_path(destination: &Path) -> PathBuf {
    suffixed(destination, ".part")
}

fn segments_path(destination: &Path) -> PathBuf {
    suffixed(destination, ".part.segments")
}

/// Removes the segment scratch directory of a destination.
///
/// Segment directories are named by content hash, so a destination whose hash
/// changed (or a run interrupted between layouts) can leave several behind.
/// They are only resumable while the destination is incomplete, so the whole
/// tree goes away once the file is verified.
fn discard_segments(segments: &Path) {
    let _ = std::fs::remove_dir_all(segments);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn gate_shrinks_on_failure_and_recovers() {
        let gate = Arc::new(AdaptiveGate::new(2, 3, true));
        let first = gate.acquire().await;
        gate.on_failure();
        assert!(gate.acquire().now_or_never().is_none());
        gate.on_success();
        let second = gate.acquire().await;
        assert!(gate.acquire().now_or_never().is_none());
        drop((first, second));
    }

    use futures_util::FutureExt;
}
