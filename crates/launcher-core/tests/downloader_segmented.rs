//! Range, resume and content-cache coverage for the rewritten download
//! engine. These tests talk to a loopback server that understands HTTP range
//! requests, so segmenting, resuming and the shared object cache are exercised
//! through the real reqwest code path.

use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use launcher_core::install::hashing::sha1_bytes;
use launcher_core::install::{
    CancelFlag, DownloadConfiguration, DownloadSourcePolicy, DownloadTask, Downloader,
    MissingDependencyKind, NoopProgress, SharedProgress,
};

/// Records the Range header of every request so segmenting is observable.
#[derive(Clone, Default)]
struct RequestLog(Arc<Mutex<Vec<Option<String>>>>);

impl RequestLog {
    fn ranges(&self) -> Vec<Option<String>> {
        self.0.lock().expect("request log").clone()
    }
}

/// Loopback HTTP server with optional range support. Returns the base URL plus
/// a handle to the request log.
fn serve(body: Vec<u8>, ranges: bool) -> (String, RequestLog) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
    let address = listener.local_addr().expect("local addr");
    let log = RequestLog::default();
    let recorded = log.clone();
    let payload = Arc::new(body);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let payload = payload.clone();
            let recorded = recorded.clone();
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
                recorded
                    .0
                    .lock()
                    .expect("request log")
                    .push(range_header.clone());
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
                        let head = format!(
                            "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {}-{}/{}\r\nConnection: close\r\n\r\n",
                            end.saturating_sub(start) + 1,
                            start,
                            end,
                            total
                        );
                        let _ = stream.write_all(head.as_bytes());
                        let _ = stream.write_all(&payload[start as usize..=end as usize]);
                        let _ = stream.flush();
                    }
                    None => {
                        let head = format!(
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            total
                        );
                        let _ = stream.write_all(head.as_bytes());
                        let _ = stream.write_all(&payload);
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
