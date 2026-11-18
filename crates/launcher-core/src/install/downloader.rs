use std::cmp::Reverse;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use futures_util::StreamExt;

use crate::error::{Error, Result};

use super::hashing::{sha1_file, verify_file};
use super::models::*;
use crate::net::{classify_reqwest_error, describe_transfer_error, redact_url};

pub struct Downloader {
    client: reqwest::Client,
    policy: DownloadSourcePolicy,
    mirror: Option<TrustedMirrorConfiguration>,
    configuration: DownloadConfiguration,
}

impl Downloader {
    pub fn new(
        policy: DownloadSourcePolicy,
        mirror: Option<TrustedMirrorConfiguration>,
        configuration: DownloadConfiguration,
    ) -> Result<Self> {
        if policy == DownloadSourcePolicy::Mirror && mirror.is_none() {
            return Err(Error::MissingInput(
                "mirror policy requires --mirror-config".into(),
            ));
        }
        let client = reqwest::Client::builder()
            .user_agent(format!(
                "{}/{}",
                crate::models::launch::LAUNCHER_NAME,
                crate::models::launch::LAUNCHER_VERSION
            ))
            .connect_timeout(std::time::Duration::from_secs(20))
            .timeout(std::time::Duration::from_secs(600))
            .build()?;
        Ok(Self {
            client,
            policy,
            mirror,
            configuration,
        })
    }

    pub fn policy(&self) -> DownloadSourcePolicy {
        self.policy
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

        let mut cache_hits = 0usize;
        let mut pending = Vec::new();
        for task in unique {
            if verify_file(&task.destination, task.sha1.as_deref(), task.size)? {
                cache_hits += 1;
            } else {
                pending.push(task);
            }
        }
        // P1-5: a cancelled or crashed run can leave "<name>.<ext>.part" files
        // behind. They are never trusted (a retry always re-streams and
        // re-verifies), so drop them while planning and keep the cache clean.
        for task in &pending {
            let partial = partial_path(&task.destination);
            if partial.is_file() {
                let _ = std::fs::remove_file(&partial);
            }
        }
        pending.sort_by_key(|task| Reverse(task.size.unwrap_or(0)));
        let total_bytes: u64 = pending.iter().map(|t| t.size.unwrap_or(0)).sum();
        progress.emit(InstallProgressEvent::Plan {
            total_files: cache_hits + pending.len(),
            total_bytes,
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

        let downloaded_bytes = Arc::new(AtomicU64::new(0));
        let concurrency = self.configuration.concurrency.max(1);
        let results: Vec<std::result::Result<DownloadedFile, DownloadFailure>> =
            futures_util::stream::iter(pending.into_iter().map(|task| {
                let downloaded_bytes = downloaded_bytes.clone();
                let progress = progress.clone();
                let cancel = cancel.clone();
                async move {
                    self.perform(task, total_bytes, downloaded_bytes, &progress, &cancel)
                        .await
                }
            }))
            .buffer_unordered(concurrency)
            .collect()
            .await;

        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }

        let mut downloaded = Vec::new();
        let mut failures = Vec::new();
        for result in results {
            match result {
                Ok(file) => downloaded.push(file),
                Err(failure) => failures.push(failure),
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

    async fn perform(
        &self,
        task: DownloadTask,
        total_bytes: u64,
        downloaded_bytes: Arc<AtomicU64>,
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
            let message = format!("no source policy candidate for {official}");
            return Err(DownloadFailure {
                destination: task.destination,
                code: "unavailable".into(),
                message,
            });
        }

        let mut last_message = String::from("download failed");
        for (url, source_name) in candidates {
            match self
                .attempt(
                    &task,
                    &url,
                    &source_name,
                    total_bytes,
                    &downloaded_bytes,
                    progress,
                    cancel,
                )
                .await
            {
                Ok(bytes) => {
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
                    last_message = message;
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
        let mut list = Vec::new();
        match self.policy {
            DownloadSourcePolicy::Official => list.push((official.to_string(), "official".into())),
            DownloadSourcePolicy::Mirror => {
                if let Some(mirror) = &self.mirror {
                    if let Some(rewritten) = mirror.rewrite(official) {
                        list.push((rewritten, format!("mirror:{}", mirror.id)));
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
            }
            DownloadSourcePolicy::LocalCacheOnly => {}
        }
        list
    }

    #[allow(clippy::too_many_arguments)]
    async fn attempt(
        &self,
        task: &DownloadTask,
        url: &str,
        source: &str,
        total_bytes: u64,
        downloaded_bytes: &Arc<AtomicU64>,
        progress: &SharedProgress,
        cancel: &CancelFlag,
    ) -> std::result::Result<u64, (String, bool)> {
        if let Some(parent) = task.destination.parent() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                return Err((format!("cannot create {}: {e}", parent.display()), false));
            }
        }
        let partial = partial_path(&task.destination);
        let mut last_error = String::new();
        for attempt in 0..self.configuration.max_retries.max(1) {
            if cancel.is_cancelled() {
                return Err(("Cancelled".into(), false));
            }
            match self
                .fetch_once(
                    url,
                    &partial,
                    progress,
                    total_bytes,
                    downloaded_bytes,
                    cancel,
                )
                .await
            {
                Ok(bytes) => {
                    let matches =
                        verify_file(&partial, task.sha1.as_deref(), task.size).unwrap_or(false);
                    if !matches {
                        let actual = sha1_file(&partial).unwrap_or_else(|_| "unreadable".into());
                        let _ = std::fs::remove_file(&partial);
                        rollback_bytes(bytes, downloaded_bytes, progress, total_bytes);
                        return Err((
                            format!(
                                "verification failed for {}: expected {:?}, got {actual}",
                                task.destination.display(),
                                task.sha1
                            ),
                            true,
                        ));
                    }
                    if let Err(e) = std::fs::rename(&partial, &task.destination) {
                        let _ = std::fs::remove_file(&partial);
                        rollback_bytes(bytes, downloaded_bytes, progress, total_bytes);
                        return Err((
                            format!("cannot place {}: {e}", task.destination.display()),
                            false,
                        ));
                    }
                    return Ok(bytes);
                }
                Err((message, retryable)) => {
                    last_error = message;
                    let _ = std::fs::remove_file(&partial);
                    if !retryable {
                        return Err((last_error, false));
                    }
                    if attempt + 1 < self.configuration.max_retries.max(1) {
                        let delay = self.configuration.retry_delay_ms * (attempt as u64 + 1);
                        tokio::time::sleep(std::time::Duration::from_millis(delay.min(5000))).await;
                    }
                }
            }
        }
        Err((format!("{last_error} (source: {source})"), true))
    }

    async fn fetch_once(
        &self,
        url: &str,
        destination: &Path,
        progress: &SharedProgress,
        total_bytes: u64,
        downloaded_bytes: &Arc<AtomicU64>,
        cancel: &CancelFlag,
    ) -> std::result::Result<u64, (String, bool)> {
        let result = self
            .fetch_stream(
                url,
                destination,
                progress,
                total_bytes,
                downloaded_bytes,
                cancel,
            )
            .await;
        if let Err((_, _, bytes)) = &result {
            // The stream loop already added its bytes to the aggregate; if this
            // attempt ultimately failed the bytes are discarded with the partial
            // file, so roll the aggregate back to keep progress honest (P2-12).
            rollback_bytes(*bytes, downloaded_bytes, progress, total_bytes);
        }
        result.map_err(|(message, retryable, _)| (message, retryable))
    }

    async fn fetch_stream(
        &self,
        url: &str,
        destination: &Path,
        progress: &SharedProgress,
        total_bytes: u64,
        downloaded_bytes: &Arc<AtomicU64>,
        cancel: &CancelFlag,
    ) -> std::result::Result<u64, (String, bool, u64)> {
        let response = self.client.get(url).send().await.map_err(|e| {
            (
                describe_transfer_error(
                    "download",
                    url,
                    classify_reqwest_error(&e),
                    &e.to_string(),
                ),
                true,
                0u64,
            )
        })?;
        let status = response.status();
        if !status.is_success() {
            let retryable =
                status.as_u16() == 408 || status.as_u16() == 429 || status.is_server_error();
            return Err((
                format!("download: HTTP {status} for {}", redact_url(url)),
                retryable,
                0u64,
            ));
        }
        let mut file = tokio::fs::File::create(destination).await.map_err(|e| {
            (
                format!("cannot create {}: {e}", destination.display()),
                false,
                0u64,
            )
        })?;
        let mut stream = response.bytes_stream();
        let mut written = 0u64;
        while let Some(chunk) = stream.next().await {
            if cancel.is_cancelled() {
                return Err(("Cancelled".into(), false, written));
            }
            let chunk = chunk.map_err(|e| {
                (
                    describe_transfer_error(
                        "download body",
                        url,
                        classify_reqwest_error(&e),
                        &e.to_string(),
                    ),
                    true,
                    written,
                )
            })?;
            tokio::io::AsyncWriteExt::write_all(&mut file, &chunk)
                .await
                .map_err(|e| (format!("write error: {e}"), false, written))?;
            written += chunk.len() as u64;
            let aggregate = downloaded_bytes.fetch_add(chunk.len() as u64, Ordering::Relaxed)
                + chunk.len() as u64;
            progress.emit(InstallProgressEvent::Bytes {
                downloaded: aggregate.min(total_bytes),
                total: total_bytes,
            });
        }
        tokio::io::AsyncWriteExt::flush(&mut file)
            .await
            .map_err(|e| (format!("flush error: {e}"), false, written))?;
        Ok(written)
    }
}

/// P2-12: give back bytes that were counted while streaming but whose file was
/// discarded, so the reported progress never exceeds what is on disk.
fn rollback_bytes(
    bytes: u64,
    downloaded_bytes: &Arc<AtomicU64>,
    progress: &SharedProgress,
    total_bytes: u64,
) {
    if bytes == 0 {
        return;
    }
    let previous = downloaded_bytes.fetch_sub(bytes, Ordering::Relaxed);
    let remaining = previous.saturating_sub(bytes);
    progress.emit(InstallProgressEvent::Bytes {
        downloaded: remaining.min(total_bytes),
        total: total_bytes,
    });
}

/// "<name>.<ext>.part" next to the destination, so a download can never
/// overwrite a file that already passed verification.
fn partial_path(destination: &Path) -> std::path::PathBuf {
    destination.with_extension(format!(
        "{}part",
        destination
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| format!("{e}."))
            .unwrap_or_default()
    ))
}
