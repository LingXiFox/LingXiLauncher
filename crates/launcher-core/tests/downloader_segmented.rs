//! Range, resume and content-cache coverage for the rewritten download
//! engine. These tests talk to a loopback server that understands HTTP range
//! requests, so segmenting, resuming and the shared object cache are exercised
//! through the real reqwest code path.

use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering::SeqCst};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use launcher_core::install::downloader::ContentCache;
use launcher_core::install::hashing::sha1_bytes;
use launcher_core::install::{
    CancelFlag, DownloadConfiguration, DownloadSourcePolicy, DownloadTask, Downloader,
    InstallProgressEvent, MissingDependencyKind, NoopProgress, ProgressSink, SharedProgress,
};

/// Records the Range header of every request so segmenting is observable.
#[derive(Clone, Default)]
struct RequestLog {
    requests: Arc<Mutex<Vec<Option<String>>>>,
    paths: Arc<Mutex<Vec<String>>>,
    active: Arc<AtomicUsize>,
    peak: Arc<AtomicUsize>,
}

impl RequestLog {
    fn ranges(&self) -> Vec<Option<String>> {
        self.requests.lock().expect("request log").clone()
    }

    /// Request paths in arrival order, for scheduling assertions.
    fn paths(&self) -> Vec<String> {
        self.paths.lock().expect("path log").clone()
    }

    fn peak(&self) -> usize {
        self.peak.load(SeqCst)
    }
}

/// Loopback HTTP server with optional range support. Returns the base URL plus
/// a handle to the request log.
fn serve(body: Vec<u8>, ranges: bool) -> (String, RequestLog) {
    serve_with(body, ranges, |_, _, _| Behavior::Normal)
}

enum Behavior {
    Normal,
    WrongRange,
    Truncated,
    Throttled,
    Redirect(String),
}

fn serve_with(
    body: Vec<u8>,
    ranges: bool,
    behavior: impl Fn(usize, &str, Option<&str>) -> Behavior + Send + Sync + 'static,
) -> (String, RequestLog) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
    let address = listener.local_addr().expect("local addr");
    let log = RequestLog::default();
    let recorded = log.clone();
    let payload = Arc::new(body);
    let behavior = Arc::new(behavior);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let payload = payload.clone();
            let recorded = recorded.clone();
            let behavior = behavior.clone();
            std::thread::spawn(move || {
                let mut reader = BufReader::new(stream.try_clone().expect("clone stream"));
                let mut request_line = String::new();
                if reader.read_line(&mut request_line).is_err() {
                    return;
                }
                let mut range_header = None;
                loop {
                    let mut header = String::new();
                    match reader.read_line(&mut header) {
                        Ok(0) => break,
                        Ok(_) if header == "\r\n" => break,
                        Ok(_) => {
                            let lower = header.to_ascii_lowercase();
                            if let Some(value) = lower.strip_prefix("range:") {
                                range_header = Some(value.trim().to_string());
                            }
                        }
                        Err(_) => return,
                    }
                }
                let sequence = {
                    let mut log = recorded.requests.lock().unwrap();
                    log.push(range_header.clone());
                    log.len()
                };
                let path = request_line
                    .split_whitespace()
                    .nth(1)
                    .unwrap_or_default()
                    .to_owned();
                recorded.paths.lock().unwrap().push(path);
                let active = recorded.active.fetch_add(1, SeqCst) + 1;
                recorded.peak.fetch_max(active, SeqCst);
                struct Request<'a>(&'a AtomicUsize);
                impl Drop for Request<'_> {
                    fn drop(&mut self) {
                        self.0.fetch_sub(1, SeqCst);
                    }
                }
                let _active = Request(&recorded.active);
                let behavior = behavior(sequence, &request_line, range_header.as_deref());
                if let Behavior::Redirect(url) = behavior {
                    let _ = write!(stream, "HTTP/1.1 302 Found\r\nLocation: {url}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                    return;
                }
                if matches!(behavior, Behavior::Throttled)
                    && range_header.as_deref() != Some("bytes=0-0")
                {
                    std::thread::sleep(Duration::from_millis(35));
                }
                let total = payload.len() as u64;
                let ranged = match (ranges, range_header.as_deref()) {
                    (true, Some(value)) => {
                        let spec = value.trim_start_matches("bytes=");
                        let (start, end) = spec.split_once('-').unwrap_or((spec, ""));
                        let start: u64 = start.parse().unwrap_or(0);
                        let end: u64 = if end.is_empty() {
                            total.saturating_sub(1)
                        } else {
                            end.parse().unwrap_or(total.saturating_sub(1))
                        };
                        Some((start, end.min(total.saturating_sub(1))))
                    }
                    _ => None,
                };
                match ranged {
                    Some((start, end)) => {
                        let header_start =
                            start + u64::from(matches!(behavior, Behavior::WrongRange));
                        let head = format!(
                            "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {}-{}/{}\r\nConnection: close\r\n\r\n",
                            end.saturating_sub(start) + 1,
                            header_start,
                            end,
                            total
                        );
                        let _ = stream.write_all(head.as_bytes());
                        let last = if matches!(behavior, Behavior::Truncated) {
                            start + (end - start) / 2
                        } else {
                            end
                        };
                        let _ = stream.write_all(&payload[start as usize..=last as usize]);
                        let _ = stream.flush();
                    }
                    None => {
                        let head = format!(
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            total
                        );
                        let _ = stream.write_all(head.as_bytes());
                        let bytes = if matches!(behavior, Behavior::Truncated) {
                            &payload[..payload.len() / 2]
                        } else {
                            &payload
                        };
                        let _ = stream.write_all(bytes);
                        let _ = stream.flush();
                    }
                }
            });
        }
    });
    (format!("http://{address}"), log)
}

fn temp_dir(name: &str) -> PathBuf {
    let directory = std::env::temp_dir().join(format!(
        "lingxi-segmented-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock")
            .as_nanos()
    ));
    std::fs::create_dir_all(&directory).expect("create temp dir");
    directory
}

fn configuration(segments: usize) -> DownloadConfiguration {
    DownloadConfiguration {
        concurrency: 2,
        max_retries: 2,
        retry_delay_ms: 1,
        global_concurrency: 4,
        per_host_concurrency: 4,
        segments,
        segment_threshold_bytes: 1024 * 1024,
        ..DownloadConfiguration::default()
    }
}

fn task(destination: PathBuf, url: String, body: &[u8]) -> DownloadTask {
    DownloadTask::new(
        destination,
        Some(url),
        Some(sha1_bytes(body)),
        Some(body.len() as u64),
        MissingDependencyKind::Library,
    )
}

fn payload(size: usize) -> Vec<u8> {
    (0..size).map(|index| (index % 251) as u8).collect()
}

fn progress() -> SharedProgress {
    Arc::new(NoopProgress)
}

#[tokio::test]
async fn large_files_are_downloaded_in_parallel_ranges() {
    let body = payload(6 * 1024 * 1024);
    let (base, log) = serve(body.clone(), true);
    let directory = temp_dir("ranges");
    let destination = directory.join("client.jar");

    let summary = Downloader::new(DownloadSourcePolicy::Official, None, configuration(4))
        .expect("downloader")
        .download(
            vec![task(
                destination.clone(),
                format!("{base}/client.jar"),
                &body,
            )],
            progress(),
            CancelFlag::new(),
        )
        .await
        .expect("segmented download");

    assert!(summary.is_success());
    assert_eq!(std::fs::read(&destination).expect("read"), body);
    let ranges: Vec<String> = log
        .ranges()
        .into_iter()
        .flatten()
        .filter(|value| value != "bytes=0-0")
        .collect();
    assert!(
        ranges.len() >= 4,
        "expected at least four range requests, saw {ranges:?}"
    );
}

#[tokio::test]
async fn segmented_download_completes_with_single_per_host_permit() {
    let body = payload(6 * 1024 * 1024);
    let (base, log) = serve(body.clone(), true);
    let directory = temp_dir("single-host-permit");
    let destination = directory.join("client.jar");
    let mut configuration = configuration(4);
    configuration.per_host_concurrency = 1;

    let summary = tokio::time::timeout(
        Duration::from_secs(10),
        Downloader::new(DownloadSourcePolicy::Official, None, configuration)
            .expect("downloader")
            .download(
                vec![task(
                    destination.clone(),
                    format!("{base}/client.jar"),
                    &body,
                )],
                progress(),
                CancelFlag::new(),
            ),
    )
    .await
    .expect("segmented download should not deadlock")
    .expect("segmented download");

    assert!(summary.is_success());
    assert_eq!(std::fs::read(&destination).expect("read"), body);
    assert_eq!(log.peak(), 1);
}

#[tokio::test]
async fn completed_segments_resume_without_contacting_the_source() {
    let body = payload(6 * 1024 * 1024);
    let directory = temp_dir("completed-segments");
    let destination = directory.join("client.jar");
    let segments = destination.with_extension("jar.part.segments");
    let hash = sha1_bytes(&body);
    let total = body.len() as u64;
    let count = 4u64;
    let chunk = total.div_ceil(count);
    let segment_directory = segments.join(&hash).join(format!("{total}-{chunk}"));

    std::fs::create_dir_all(&segment_directory).expect("create segment directory");
    for index in 0..count {
        let start = index * chunk;
        if start >= total {
            continue;
        }
        let end = start.saturating_add(chunk).min(total);
        std::fs::write(
            segment_directory.join(index.to_string()),
            &body[start as usize..end as usize],
        )
        .expect("write completed segment");
    }

    let summary = Downloader::new(DownloadSourcePolicy::Official, None, configuration(4))
        .expect("downloader")
        .download(
            vec![task(
                destination.clone(),
                "http://127.0.0.1:1/unreachable".into(),
                &body,
            )],
            progress(),
            CancelFlag::new(),
        )
        .await
        .expect("completed segments should be usable offline");

    assert!(summary.is_success());
    assert_eq!(std::fs::read(&destination).expect("read destination"), body);
    assert!(!segments.exists());
}

#[tokio::test]
async fn servers_without_range_support_fall_back_to_a_single_stream() {
    let body = payload(6 * 1024 * 1024);
    let (base, _log) = serve(body.clone(), false);
    let directory = temp_dir("fallback");
    let destination = directory.join("client.jar");

    let summary = Downloader::new(DownloadSourcePolicy::Official, None, configuration(4))
        .expect("downloader")
        .download(
            vec![task(
                destination.clone(),
                format!("{base}/client.jar"),
                &body,
            )],
            progress(),
            CancelFlag::new(),
        )
        .await
        .expect("fallback download");

    assert!(summary.is_success());
    assert_eq!(std::fs::read(&destination).expect("read"), body);
}

#[tokio::test]
async fn interrupted_partial_files_resume_instead_of_restarting() {
    let body = payload(2 * 1024 * 1024);
    let (base, log) = serve(body.clone(), true);
    let directory = temp_dir("resume");
    let destination = directory.join("client.jar");
    // Pretend a previous run was interrupted after the first 512 KiB.
    let partial = directory.join("client.jar.part");
    std::fs::write(&partial, &body[..512 * 1024]).expect("write partial");

    let summary = Downloader::new(DownloadSourcePolicy::Official, None, configuration(1))
        .expect("downloader")
        .download(
            vec![task(
                destination.clone(),
                format!("{base}/client.jar"),
                &body,
            )],
            progress(),
            CancelFlag::new(),
        )
        .await
        .expect("resumed download");

    assert!(summary.is_success());
    assert_eq!(std::fs::read(&destination).expect("read"), body);
    let ranges: Vec<String> = log.ranges().into_iter().flatten().collect();
    assert!(
        ranges
            .iter()
            .any(|value| value.starts_with("bytes=524288-")),
        "expected a resume request from the partial offset, saw {ranges:?}"
    );
}

#[tokio::test]
async fn content_cache_satisfies_a_second_destination_without_network() {
    let body = payload(256 * 1024);
    let (base, log) = serve(body.clone(), true);
    let directory = temp_dir("content-cache");
    let cache = directory.join("cache");
    let first = directory.join("one.jar");
    let second = directory.join("nested").join("two.jar");
    let mut tuned = configuration(1);
    tuned.cache_directory = Some(cache.clone());

    let downloader =
        Downloader::new(DownloadSourcePolicy::Official, None, tuned).expect("downloader");
    downloader
        .download(
            vec![task(first.clone(), format!("{base}/lib.jar"), &body)],
            progress(),
            CancelFlag::new(),
        )
        .await
        .expect("first download");
    let requests_after_first = log.ranges().len();

    let summary = downloader
        .download(
            vec![task(second.clone(), format!("{base}/lib.jar"), &body)],
            progress(),
            CancelFlag::new(),
        )
        .await
        .expect("second download");

    assert_eq!(summary.cache_hits, 1);
    assert!(summary.downloaded.is_empty());
    assert_eq!(std::fs::read(&second).expect("read"), body);
    assert_eq!(
        log.ranges().len(),
        requests_after_first,
        "a cached object must not trigger another request"
    );
}

#[test]
fn concurrent_cache_publication_keeps_one_verified_object() {
    let body = payload(2 * 1024 * 1024);
    let directory = temp_dir("concurrent-cache-publication");
    let source = directory.join("source.bin");
    let cache = Arc::new(ContentCache::new(directory.join("cache")));
    let hash = sha1_bytes(&body);
    std::fs::write(&source, &body).expect("write source");

    std::thread::scope(|scope| {
        let workers: Vec<_> = (0..8)
            .map(|_| {
                let cache = Arc::clone(&cache);
                let source = source.clone();
                let hash = hash.clone();
                scope.spawn(move || cache.store(&hash, &source).expect("publish cache object"))
            })
            .collect();

        for worker in workers {
            assert_eq!(
                worker.join().expect("cache worker"),
                cache.object_path(&hash).unwrap()
            );
        }
    });

    let object = cache
        .lookup(&hash, Some(body.len() as u64))
        .expect("cache object");
    assert_eq!(std::fs::read(object).expect("read cache object"), body);
}

#[derive(Default)]
struct ByteLog(Mutex<Vec<(u64, u64)>>);

impl ProgressSink for ByteLog {
    fn emit(&self, event: InstallProgressEvent) {
        if let InstallProgressEvent::Bytes { downloaded, total } = event {
            self.0.lock().unwrap().push((downloaded, total));
        }
    }
}

#[tokio::test]
async fn range_requests_from_overlapping_batches_obey_the_same_window() {
    let body = payload(4 * 1024 * 1024);
    let (url, log) = serve_with(body.clone(), true, |_, _, _| Behavior::Throttled);
    let directory = temp_dir("window");
    for (global, host) in [(2, 4), (4, 2)] {
        let downloader = Downloader::new(
            DownloadSourcePolicy::Official,
            None,
            DownloadConfiguration {
                concurrency: 4,
                global_concurrency: global,
                per_host_concurrency: host,
                adaptive_concurrency: false,
                ..configuration(4)
            },
        )
        .unwrap();
        let run = |name| {
            downloader.download(
                vec![task(directory.join(name), url.clone(), &body)],
                progress(),
                CancelFlag::new(),
            )
        };
        let (a, b) = tokio::time::timeout(Duration::from_secs(10), async {
            tokio::join!(run(format!("a{global}")), run(format!("b{global}")))
        })
        .await
        .unwrap();
        assert!(a.unwrap().is_success() && b.unwrap().is_success());
    }
    assert_eq!(log.peak.load(SeqCst), 2);
}

#[tokio::test]
async fn redirects_reacquire_the_destination_host_slot() {
    if std::net::TcpListener::bind("127.0.0.2:0").is_err() {
        return;
    }
    // Loopback DNS and IPv4 lead to the same server but are distinct scheduler hosts.
    let body = payload(4 * 1024 * 1024);
    let (target, log) = serve_with(body.clone(), true, |_, _, _| Behavior::Throttled);
    let redirect = target.clone();
    let (alias, _) = serve_with(vec![], false, move |_, _, _| {
        Behavior::Redirect(redirect.clone())
    });
    let alias = alias.replace("127.0.0.1", "localhost");
    let directory = temp_dir("redirect");
    let downloader = Downloader::new(
        DownloadSourcePolicy::Official,
        None,
        DownloadConfiguration {
            concurrency: 4,
            per_host_concurrency: 1,
            adaptive_concurrency: false,
            ..configuration(4)
        },
    )
    .unwrap();
    let result = tokio::time::timeout(
        Duration::from_secs(10),
        downloader.download(
            vec![
                task(directory.join("direct.jar"), target, &body),
                task(directory.join("redirected.jar"), alias, &body),
            ],
            progress(),
            CancelFlag::new(),
        ),
    )
    .await
    .unwrap()
    .unwrap();
    assert!(result.is_success(), "{:?}", result.failures);
    assert_eq!(log.peak.load(SeqCst), 1);
}

#[tokio::test]
async fn invalid_range_after_other_segments_started_rolls_back_before_fallback() {
    let body = payload(4 * 1024 * 1024);
    let (url, log) = serve_with(body.clone(), true, |_, _, range| match range {
        Some("bytes=1048576-2097151") => {
            std::thread::sleep(Duration::from_millis(100));
            Behavior::WrongRange
        }
        _ => Behavior::Normal,
    });
    let directory = temp_dir("bad-range");
    let sink = Arc::new(ByteLog::default());
    let result = Downloader::new(DownloadSourcePolicy::Official, None, configuration(4))
        .unwrap()
        .download(
            vec![task(directory.join("library.jar"), url, &body)],
            sink.clone(),
            CancelFlag::new(),
        )
        .await
        .unwrap();
    assert_eq!(result.downloaded_bytes(), body.len() as u64);
    assert!(log.ranges().contains(&None));
    let events = sink.0.lock().unwrap();
    assert!(events
        .windows(2)
        .any(|pair| pair[0].0 > 0 && pair[1].0 == 0));
    assert!(events.iter().all(|event| event.0 <= body.len() as u64));
    assert_eq!(events.last().unwrap().0, body.len() as u64);
}

#[tokio::test]
async fn failed_truncated_stream_resumes_in_a_fresh_downloader() {
    let body = payload(1024 * 1024);
    let (url, _) = serve_with(body.clone(), true, |_, _, _| Behavior::Truncated);
    let directory = temp_dir("fresh-resume");
    let destination = directory.join("library.jar");
    let mut configuration = configuration(1);
    configuration.max_retries = 1;
    let sink = Arc::new(ByteLog::default());
    let first = Downloader::new(DownloadSourcePolicy::Official, None, configuration.clone())
        .unwrap()
        .download(
            vec![task(destination.clone(), url, &body)],
            sink.clone(),
            CancelFlag::new(),
        )
        .await
        .unwrap();
    assert!(!first.is_success());
    assert_eq!(sink.0.lock().unwrap().last().unwrap().0, 0);
    assert!(!destination.exists());
    let offset = std::fs::metadata(destination.with_extension("jar.part"))
        .unwrap()
        .len();
    assert!(offset > 0);
    let (url, log) = serve(body.clone(), true);
    let second = Downloader::new(DownloadSourcePolicy::Official, None, configuration)
        .unwrap()
        .download(
            vec![task(destination.clone(), url, &body)],
            progress(),
            CancelFlag::new(),
        )
        .await
        .unwrap();
    assert_eq!(second.downloaded_bytes(), body.len() as u64);
    assert_eq!(std::fs::read(destination).unwrap(), body);
    assert_eq!(log.ranges(), vec![Some(format!("bytes={offset}-"))]);
}

#[tokio::test]
async fn cancellation_while_waiting_for_http_headers_is_prompt() {
    let body = payload(1024 * 1024);
    let (url, log) = serve_with(body.clone(), true, |_, _, _| {
        std::thread::sleep(Duration::from_secs(2));
        Behavior::Normal
    });
    let directory = temp_dir("cancel-stalled");
    let destination = directory.join("library.jar");
    let downloader =
        Downloader::new(DownloadSourcePolicy::Official, None, configuration(1)).unwrap();
    let cancel = CancelFlag::new();
    let transfer = downloader.download(
        vec![task(destination.clone(), url, &body)],
        progress(),
        cancel.clone(),
    );
    let result = tokio::time::timeout(Duration::from_secs(1), async {
        let (result, ()) = tokio::join!(transfer, async {
            while log.ranges().is_empty() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            cancel.cancel();
        });
        result
    })
    .await
    .unwrap();
    assert!(matches!(result, Err(launcher_core::Error::Cancelled)));
    assert!(!destination.exists());
}

/// With a single transfer slot the scheduling tiers decide the order: the
/// client jar must go first and the asset bulk last, otherwise a large asset
/// object delays every file the game needs to start.
#[tokio::test]
async fn launch_critical_files_are_scheduled_before_assets() {
    let body = payload(2 * 1024 * 1024);
    let (base, log) = serve(body.clone(), false);
    let directory = temp_dir("schedule");
    let settings = DownloadConfiguration {
        global_concurrency: 1,
        per_host_concurrency: 1,
        adaptive_concurrency: false,
        segments: 1,
        ..configuration(1)
    };
    let sha1 = sha1_bytes(&body);
    let size = Some(body.len() as u64);
    let scheduled = |name: &str, kind: MissingDependencyKind| {
        DownloadTask::new(
            directory.join(name),
            Some(format!("{base}/{name}")),
            Some(sha1.clone()),
            size,
            kind,
        )
    };

    let summary = Downloader::new(DownloadSourcePolicy::Official, None, settings)
        .expect("downloader")
        .download(
            vec![
                scheduled("asset.bin", MissingDependencyKind::Asset),
                scheduled("library.jar", MissingDependencyKind::Library),
                scheduled("client.jar", MissingDependencyKind::ClientJar),
            ],
            progress(),
            CancelFlag::new(),
        )
        .await
        .expect("ordered download");

    assert!(summary.is_success(), "failures: {:?}", summary.failures);
    assert_eq!(
        log.paths(),
        vec![
            "/client.jar".to_string(),
            "/library.jar".to_string(),
            "/asset.bin".to_string()
        ],
        "launch-critical files must be requested before asset objects"
    );
}

/// Segment scratch state from an earlier hash layout must not survive a
/// completed download, otherwise every metadata change leaks a directory tree.
#[tokio::test]
async fn stale_segment_layouts_are_discarded_after_success() {
    let body = payload(6 * 1024 * 1024);
    let (base, _log) = serve(body.clone(), true);
    let directory = temp_dir("stale-segments");
    let destination = directory.join("client.jar");
    let segments = directory.join("client.jar.part.segments");
    let stale = segments
        .join("0000000000000000000000000000000000000000")
        .join("1-1");
    std::fs::create_dir_all(&stale).expect("create stale layout");
    std::fs::write(stale.join("0"), b"leftover").expect("write stale segment");

    let summary = Downloader::new(DownloadSourcePolicy::Official, None, configuration(4))
        .expect("downloader")
        .download(
            vec![task(
                destination.clone(),
                format!("{base}/client.jar"),
                &body,
            )],
            progress(),
            CancelFlag::new(),
        )
        .await
        .expect("segmented download");

    assert!(summary.is_success());
    assert_eq!(std::fs::read(&destination).expect("read"), body);
    assert!(
        !segments.exists(),
        "segment scratch state must be removed once the file is verified"
    );
}
