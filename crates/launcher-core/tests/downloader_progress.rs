//! End-to-end coverage for the download pipeline against a local HTTP server.
//!
//! These tests drive the real reqwest path (streaming, verification, retries,
//! cancellation) without touching the network or the user's game directory, so
//! the Windows RC regressions — progress that never advances, failures reported
//! as success, byte counters that stay inflated — stay fixed.

use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use launcher_core::install::hashing::sha1_bytes;
use launcher_core::install::{
    CancelFlag, DownloadConfiguration, DownloadSourcePolicy, DownloadTask, Downloader,
    InstallProgressEvent, MissingDependencyKind, ProgressSink, SharedProgress,
};
use launcher_core::Error;

/// Records every event the downloader emits so assertions can replay them.
#[derive(Default)]
struct RecordingSink {
    events: Mutex<Vec<InstallProgressEvent>>,
}

impl ProgressSink for RecordingSink {
    fn emit(&self, event: InstallProgressEvent) {
        self.events.lock().expect("progress lock").push(event);
    }
}

impl RecordingSink {
    fn snapshot(&self) -> Vec<InstallProgressEvent> {
        self.events.lock().expect("progress lock").clone()
    }
}

fn shared_sink() -> (Arc<RecordingSink>, SharedProgress) {
    let sink = Arc::new(RecordingSink::default());
    (sink.clone(), sink)
}

/// Minimal HTTP/1.1 server: one thread per connection, one canned response per
/// path, 404 for anything unknown.
fn serve(routes: Vec<(String, u16, Vec<u8>)>) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
    let address = listener.local_addr().expect("local addr");
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let routes = routes.clone();
            std::thread::spawn(move || {
                let mut reader = BufReader::new(stream.try_clone().expect("clone stream"));
                let mut request_line = String::new();
                if reader.read_line(&mut request_line).is_err() {
                    return;
                }
                loop {
                    let mut header = String::new();
                    match reader.read_line(&mut header) {
                        Ok(0) => break,
                        Ok(_) if header == "\r\n" => break,
                        Ok(_) => continue,
                        Err(_) => return,
                    }
                }
                let path = request_line
                    .split_whitespace()
                    .nth(1)
                    .unwrap_or("/")
                    .to_string();
                let (status, body) = routes
                    .iter()
                    .find(|(route, _, _)| route == &path)
                    .map(|(_, status, body)| (*status, body.clone()))
                    .unwrap_or((404, Vec::new()));
                let reason = if status == 200 { "OK" } else { "Not Found" };
                let head = format!(
                    "HTTP/1.1 {status} {reason}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(head.as_bytes());
                let _ = stream.write_all(&body);
                let _ = stream.flush();
            });
        }
    });
    format!("http://{address}")
}

fn temp_dir(name: &str) -> PathBuf {
    let directory = std::env::temp_dir().join(format!(
        "lingxi-downloader-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock")
            .as_nanos()
    ));
    std::fs::create_dir_all(&directory).expect("create temp dir");
    directory
}

fn downloader() -> Downloader {
    Downloader::new(
        DownloadSourcePolicy::Official,
        None,
        DownloadConfiguration {
            concurrency: 2,
            max_retries: 2,
            retry_delay_ms: 1,
            ..DownloadConfiguration::default()
        },
    )
    .expect("downloader")
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

#[tokio::test]
async fn progress_grows_from_plan_to_finished_file() {
    let body = b"lingxi progress payload".to_vec();
    let base = serve(vec![("/lib.jar".into(), 200, body.clone())]);
    let directory = temp_dir("progress");
    let destination = directory.join("lib.jar");
    let (sink, progress) = shared_sink();

    let summary = downloader()
        .download(
            vec![task(destination.clone(), format!("{base}/lib.jar"), &body)],
            progress,
            CancelFlag::new(),
        )
        .await
        .expect("download succeeds");

    assert!(summary.is_success());
    assert_eq!(summary.downloaded.len(), 1);
    assert_eq!(std::fs::read(&destination).expect("read file"), body);

    let events = sink.snapshot();
    let plan = events
        .iter()
        .find_map(|event| match event {
            InstallProgressEvent::Plan {
                total_files,
                total_bytes,
                cache_hits,
            } => Some((*total_files, *total_bytes, *cache_hits)),
            _ => None,
        })
        .expect("plan event");
    assert_eq!(plan, (1, body.len() as u64, 0));

    let finished = events
        .iter()
        .find_map(|event| match event {
            InstallProgressEvent::FileFinished { bytes, source, .. } => {
                Some((*bytes, source.clone()))
            }
            _ => None,
        })
        .expect("file finished event");
    assert_eq!(finished, (body.len() as u64, "official".to_string()));

    let last_downloaded = events
        .iter()
        .filter_map(|event| match event {
            InstallProgressEvent::Bytes { downloaded, .. } => Some(*downloaded),
            _ => None,
        })
        .next_back()
        .expect("byte events");
    assert_eq!(last_downloaded, body.len() as u64);
}

#[tokio::test]
async fn verified_cache_files_are_reused_on_retry() {
    let body = b"cached payload".to_vec();
    let base = serve(vec![("/cached.jar".into(), 200, body.clone())]);
    let directory = temp_dir("cache");
    let destination = directory.join("cached.jar");
    let jobs = vec![task(
        destination.clone(),
        format!("{base}/cached.jar"),
        &body,
    )];

    downloader()
        .download(jobs.clone(), shared_sink().1, CancelFlag::new())
        .await
        .expect("first download");

    let (sink, progress) = shared_sink();
    let summary = downloader()
        .download(jobs, progress, CancelFlag::new())
        .await
        .expect("second download");

    assert_eq!(summary.cache_hits, 1);
    assert!(summary.downloaded.is_empty());
    assert!(summary.is_success());
    let plan = sink
        .snapshot()
        .into_iter()
        .find_map(|event| match event {
            InstallProgressEvent::Plan {
                total_files,
                total_bytes,
                cache_hits,
            } => Some((total_files, total_bytes, cache_hits)),
            _ => None,
        })
        .expect("plan event");
    assert_eq!(plan, (1, 0, 1));
}

#[tokio::test]
async fn corrupted_cache_entry_is_downloaded_again() {
    let body = b"fresh bytes".to_vec();
    let base = serve(vec![("/broken.jar".into(), 200, body.clone())]);
    let directory = temp_dir("corrupted");
    let destination = directory.join("broken.jar");
    std::fs::write(&destination, b"truncated").expect("write stale file");

    let summary = downloader()
        .download(
            vec![task(
                destination.clone(),
                format!("{base}/broken.jar"),
                &body,
            )],
            shared_sink().1,
            CancelFlag::new(),
        )
        .await
        .expect("download succeeds");

    assert_eq!(summary.cache_hits, 0);
    assert_eq!(summary.downloaded.len(), 1);
    assert_eq!(std::fs::read(&destination).expect("read file"), body);
}

#[tokio::test]
async fn failed_transfer_is_reported_and_rolls_back_byte_progress() {
    // The served body never matches the expected SHA-1, so every attempt fails
    // verification. The aggregate byte counter must fall back to zero instead
    // of claiming the file was downloaded (the Windows RC drift bug).
    let body = b"mismatched payload".to_vec();
    let base = serve(vec![("/bad.jar".into(), 200, body.clone())]);
    let directory = temp_dir("failure");
    let destination = directory.join("bad.jar");
    let bad_task = DownloadTask::new(
        destination,
        Some(format!("{base}/bad.jar")),
        Some(sha1_bytes(b"expected something else")),
        Some(body.len() as u64),
        MissingDependencyKind::Library,
    );
    let (sink, progress) = shared_sink();

    let summary = downloader()
        .download(vec![bad_task], progress, CancelFlag::new())
        .await
        .expect("download returns a summary with failures");

    assert!(
        !summary.is_success(),
        "a failed file must not look like success"
    );
    assert_eq!(summary.failures.len(), 1);
    let last_downloaded = sink
        .snapshot()
        .into_iter()
        .filter_map(|event| match event {
            InstallProgressEvent::Bytes { downloaded, .. } => Some(downloaded),
            _ => None,
        })
        .next_back()
        .expect("byte events");
    assert_eq!(
        last_downloaded, 0,
        "byte progress must roll back on failure"
    );
}

#[tokio::test]
async fn http_error_surfaces_as_a_failure_not_a_success() {
    let base = serve(Vec::new());
    let directory = temp_dir("http-error");
    let missing_task = DownloadTask::new(
        directory.join("gone.jar"),
        Some(format!("{base}/gone.jar")),
        Some(sha1_bytes(b"never served")),
        None,
        MissingDependencyKind::Library,
    );

    let summary = downloader()
        .download(vec![missing_task], shared_sink().1, CancelFlag::new())
        .await
        .expect("download returns a summary");

    assert!(!summary.is_success());
    let failure = summary.failures.first().expect("failure recorded");
    assert!(
        failure.message.contains("HTTP 404"),
        "unexpected message: {}",
        failure.message
    );
}

#[tokio::test]
async fn cancelled_install_stops_and_reports_cancellation() {
    let body = b"cancel me".to_vec();
    let base = serve(vec![("/slow.jar".into(), 200, body.clone())]);
    let directory = temp_dir("cancel");
    let cancel = CancelFlag::new();
    cancel.cancel();

    let error = downloader()
        .download(
            vec![task(
                directory.join("slow.jar"),
                format!("{base}/slow.jar"),
                &body,
            )],
            shared_sink().1,
            cancel,
        )
        .await
        .expect_err("cancelled downloads error out");

    assert!(
        matches!(error, Error::Cancelled),
        "unexpected error: {error:?}"
    );
}
