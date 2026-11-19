//! 5000-asset loopback benchmark.
//!
//! Models a Minecraft install stage: thousands of small files fetched from one
//! origin with keep-alive, written to the game directory and copied into the
//! content cache. Reports wall time, file throughput, connection reuse, emitted
//! progress events, plus isolated network and warm-cache filesystem timings.
//!
//! Run with:
//!   cargo test --release -p launcher-core --test downloader_assets_bench -- --ignored --nocapture

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use futures_util::stream::{self, StreamExt};
use launcher_core::install::hashing::sha1_bytes;
use launcher_core::install::{
    CancelFlag, DownloadConfiguration, DownloadSourcePolicy, DownloadTask, Downloader,
    InstallProgressEvent, MissingDependencyKind, ProgressSink, SharedProgress,
};

const FILES: usize = 5000;
const MAX_KIB: usize = 64;
const RESPONSE_DELAY: Duration = Duration::from_millis(20);

#[derive(Default)]
struct CountingProgress {
    bytes_events: AtomicUsize,
    other_events: AtomicUsize,
    failures: std::sync::Mutex<Vec<String>>,
}

impl ProgressSink for CountingProgress {
    fn emit(&self, event: InstallProgressEvent) {
        match event {
            InstallProgressEvent::Bytes { .. } => {
                self.bytes_events.fetch_add(1, Ordering::Relaxed);
            }
            InstallProgressEvent::FileFailed { path, message } => {
                self.other_events.fetch_add(1, Ordering::Relaxed);
                let mut failures = self.failures.lock().expect("failures");
                if failures.len() < 5 {
                    let _ = path;
                    failures.push(message);
                }
            }
            _ => {
                self.other_events.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
}

#[derive(Default)]
struct ServerStats {
    connections: AtomicUsize,
    requests: AtomicUsize,
    wait_micros: AtomicUsize,
}

fn build_files() -> Vec<(String, Arc<Vec<u8>>)> {
    (0..FILES)
        .map(|index| {
            let mut state = (index as u64)
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            state ^= state >> 33;
            let kib = 1 + (state as usize % MAX_KIB);
            let size = kib * 1024;
            // Unique bytes per index: identical bodies would be deduplicated by
            // the content cache and never hit the network.
            let mut body = Vec::with_capacity(size);
            for _ in 0..size {
                state = state
                    .wrapping_mul(6364136223846793005)
                    .wrapping_add(1442695040888963407);
                body.push((state >> 33) as u8);
            }
            (format!("/assets/{index:05}.bin"), Arc::new(body))
        })
        .collect()
}

fn serve(files: Arc<HashMap<String, Arc<Vec<u8>>>>) -> (String, Arc<ServerStats>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
    let address = listener.local_addr().expect("local addr");
    let stats = Arc::new(ServerStats::default());
    let shared = Arc::clone(&stats);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { continue };
            shared.connections.fetch_add(1, Ordering::Relaxed);
            let files = Arc::clone(&files);
            let stats = Arc::clone(&shared);
            std::thread::spawn(move || handle(stream, files, stats));
        }
    });
    (format!("http://{address}"), stats)
}

fn handle(
    mut stream: TcpStream,
    files: Arc<HashMap<String, Arc<Vec<u8>>>>,
    stats: Arc<ServerStats>,
) {
    stream.set_nodelay(true).expect("TCP_NODELAY");
    let Ok(clone) = stream.try_clone() else {
        return;
    };
    let mut reader = BufReader::new(clone);
    loop {
        let mut request_line = String::new();
        match reader.read_line(&mut request_line) {
            Ok(0) => return,
            Ok(_) => {}
            Err(_) => return,
        }
        if request_line.trim().is_empty() {
            continue;
        }
        let path = request_line
            .split_whitespace()
            .nth(1)
            .unwrap_or("/")
            .split('?')
            .next()
            .unwrap_or("/")
            .to_string();
        let mut range = None;
        loop {
            let mut header = String::new();
            match reader.read_line(&mut header) {
                Ok(0) => return,
                Ok(_) if header == "\r\n" => break,
                Ok(_) => {
                    if let Some(value) = header.to_ascii_lowercase().strip_prefix("range:") {
                        range = Some(value.trim().to_string());
                    }
                }
                Err(_) => return,
            }
        }
        stats.requests.fetch_add(1, Ordering::Relaxed);
        let delay_start = Instant::now();
        std::thread::sleep(RESPONSE_DELAY);
        stats.wait_micros.fetch_add(
            delay_start.elapsed().as_micros() as usize,
            Ordering::Relaxed,
        );
        let Some(body) = files.get(&path) else {
            let _ = stream.write_all(
                b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n",
            );
            continue;
        };
        let total = body.len();
        let ranged = range.as_deref().map(|value| {
            let spec = value.trim_start_matches("bytes=");
            let (start, end) = spec.split_once('-').unwrap_or((spec, ""));
            let start: usize = start.parse().unwrap_or(0);
            let end: usize = if end.is_empty() {
                total.saturating_sub(1)
            } else {
                end.parse().unwrap_or(total.saturating_sub(1))
            };
            (start.min(total), end.min(total.saturating_sub(1)))
        });
        let written = match ranged {
            Some((start, end)) => {
                let head = format!(
                    "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {}-{}/{}\r\nConnection: keep-alive\r\n\r\n",
                    end.saturating_sub(start) + 1,
                    start,
                    end,
                    total
                );
                stream.write_all(head.as_bytes()).is_ok()
                    && stream.write_all(&body[start..=end]).is_ok()
            }
            None => {
                let head = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: keep-alive\r\n\r\n",
                    total
                );
                stream.write_all(head.as_bytes()).is_ok() && stream.write_all(body).is_ok()
            }
        };
        if !written || stream.flush().is_err() {
            return;
        }
    }
}

fn temp_dir(name: &str) -> PathBuf {
    let directory = std::env::temp_dir().join(format!(
        "lingxi-assets-bench-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock")
            .as_nanos()
    ));
    std::fs::create_dir_all(&directory).expect("create temp dir");
    directory
}

fn progress() -> (SharedProgress, Arc<CountingProgress>) {
    let sink = Arc::new(CountingProgress::default());
    (sink.clone(), sink)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
#[ignore = "5000-asset throughput benchmark; run with --ignored --nocapture"]
async fn assets_5000_benchmark() {
    let files = build_files();
    let total_bytes: usize = files.iter().map(|(_, body)| body.len()).sum();
    let lookup: Arc<HashMap<String, Arc<Vec<u8>>>> =
        Arc::new(files.iter().cloned().collect::<HashMap<_, _>>());
    let (base, stats) = serve(lookup);

    let root = temp_dir("run");
    let output = root.join("out");
    let cache = root.join("cache");
    std::fs::create_dir_all(&output).expect("out dir");
    std::fs::create_dir_all(&cache).expect("cache dir");

    let tasks: Vec<DownloadTask> = files
        .iter()
        .map(|(path, body)| {
            DownloadTask::new(
                output.join(path.trim_start_matches('/')),
                Some(format!("{base}{path}")),
                Some(sha1_bytes(body)),
                Some(body.len() as u64),
                MissingDependencyKind::Asset,
            )
        })
        .collect();
    let unique_hashes = files
        .iter()
        .map(|(_, body)| sha1_bytes(body))
        .collect::<std::collections::HashSet<_>>()
        .len();
    println!("BENCH unique_hashes={unique_hashes} files={FILES}");

    let configuration = DownloadConfiguration {
        cache_directory: Some(cache),
        ..DownloadConfiguration::default()
    };
    let (sink, counter) = progress();
    let started = Instant::now();
    let summary = Downloader::new(DownloadSourcePolicy::Official, None, configuration.clone())
        .expect("downloader")
        .download(tasks.clone(), sink, CancelFlag::new())
        .await
        .expect("bench download");
    let elapsed = started.elapsed();
    if !summary.failures.is_empty() {
        let mut messages: std::collections::BTreeMap<String, usize> =
            std::collections::BTreeMap::new();
        for failure in &summary.failures {
            *messages
                .entry(format!("{} | {}", failure.code, failure.message))
                .or_default() += 1;
        }
        for (message, count) in messages.iter().take(6) {
            println!("FAIL[{count}] {message}");
        }
        for message in counter.failures.lock().expect("failures").iter() {
            println!("EVENT_FAIL {message}");
        }
    }
    assert_eq!(summary.downloaded.len(), FILES);
    let downloader_stats = (
        stats.connections.load(Ordering::Relaxed),
        stats.requests.load(Ordering::Relaxed),
    );
    println!(
        "BENCH downloader ms={} files_per_s={:.0} mib_per_s={:.1} bytes_events={} other_events={} connections={} requests={} simulated_wait_sum_ms={}",
        elapsed.as_millis(),
        FILES as f64 / elapsed.as_secs_f64(),
        total_bytes as f64 / (1024.0 * 1024.0) / elapsed.as_secs_f64(),
        counter.bytes_events.load(Ordering::Relaxed),
        counter.other_events.load(Ordering::Relaxed),
        downloader_stats.0,
        downloader_stats.1,
        stats.wait_micros.load(Ordering::Relaxed) / 1_000,
    );

    // The network-only run uses the same host ceiling, without disk or SHA work.
    let client = reqwest::Client::builder()
        .no_gzip()
        .build()
        .expect("client");
    let fetches = files.iter().map(|(path, _)| {
        let client = client.clone();
        let url = format!("{base}{path}");
        async move {
            let response = client.get(url).send().await.expect("network floor");
            response.bytes().await.expect("network floor body").len()
        }
    });
    let net_start = Instant::now();
    let (received, request_time) = stream::iter(fetches.map(|fetch| async move {
        let started = Instant::now();
        (fetch.await, started.elapsed())
    }))
    .buffer_unordered(configuration.per_host_concurrency)
    .fold(
        (0, Duration::ZERO),
        |(sum, time), (bytes, duration)| async move { (sum + bytes, time + duration) },
    )
    .await;
    let net_elapsed = net_start.elapsed();
    println!(
        "BENCH network_only ms={} mean_request_ms={:.2} bytes={} connections={} requests={}",
        net_elapsed.as_millis(),
        request_time.as_secs_f64() * 1_000.0 / FILES as f64,
        received,
        stats.connections.load(Ordering::Relaxed) - downloader_stats.0,
        stats.requests.load(Ordering::Relaxed) - downloader_stats.1,
    );
    assert_eq!(received, total_bytes);

    // Exercise the actual cache lookup, SHA verification and copy to a fresh instance.
    let warm_tasks = tasks
        .into_iter()
        .map(|mut task| {
            task.destination = root
                .join("warm")
                .join(task.destination.strip_prefix(&output).unwrap());
            task
        })
        .collect();
    let warm = Downloader::new(DownloadSourcePolicy::LocalCacheOnly, None, configuration).unwrap();
    let disk_start = Instant::now();
    let result = warm
        .download(warm_tasks, progress().0, CancelFlag::new())
        .await
        .unwrap();
    let disk_elapsed = disk_start.elapsed();
    assert_eq!(result.cache_hits, FILES);
    assert!(result.failures.is_empty());
    assert_eq!(stats.requests.load(Ordering::Relaxed), FILES * 2);
    println!(
        "BENCH disk_warm_cache ms={} files_per_s={:.0} bytes={}",
        disk_elapsed.as_millis(),
        FILES as f64 / disk_elapsed.as_secs_f64(),
        total_bytes
    );

    let _ = std::fs::remove_dir_all(&root);
}
