//! Throughput baseline for the download engine.
//!
//! Run with `cargo test -p launcher-core --test downloader_bench -- --ignored --nocapture`.
//! The server is a loopback socket, so this measures the engine itself
//! (segment planning, merge, hashing, cache writes) rather than the network.

use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use launcher_core::install::hashing::sha1_bytes;
use launcher_core::install::{
    CancelFlag, DownloadConfiguration, DownloadSourcePolicy, DownloadTask, Downloader,
    MissingDependencyKind, NoopProgress, SharedProgress,
};

const PAYLOAD_BYTES: usize = 48 * 1024 * 1024;

fn serve(body: Vec<u8>) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
    let address = listener.local_addr().expect("local addr");
    let payload = Arc::new(body);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let payload = payload.clone();
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
                let total = payload.len() as u64;
                let ranged = range_header.as_deref().map(|value| {
                    let spec = value.trim_start_matches("bytes=");
                    let (start, end) = spec.split_once('-').unwrap_or((spec, ""));
                    let start: u64 = start.parse().unwrap_or(0);
                    let end: u64 = if end.is_empty() {
                        total.saturating_sub(1)
                    } else {
                        end.parse().unwrap_or(total.saturating_sub(1))
                    };
                    (start, end.min(total.saturating_sub(1)))
                });
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
    format!("http://{address}")
}

fn temp_dir(name: &str) -> PathBuf {
    let directory = std::env::temp_dir().join(format!(
        "lingxi-bench-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock")
            .as_nanos()
    ));
    std::fs::create_dir_all(&directory).expect("create temp dir");
    directory
}

fn payload(size: usize) -> Vec<u8> {
    (0..size).map(|index| (index % 251) as u8).collect()
}

fn progress() -> SharedProgress {
    Arc::new(NoopProgress)
}

async fn measure_file_set(
    label: &str,
    configuration: DownloadConfiguration,
    body: &[u8],
    base: &str,
    files: usize,
) {
    let directory = temp_dir(label);
    let tasks: Vec<DownloadTask> = (0..files)
        .map(|index| {
            DownloadTask::new(
                directory.join(format!("lib-{index}.jar")),
                Some(format!("{base}/lib.jar")),
                Some(sha1_bytes(body)),
                Some(body.len() as u64),
                MissingDependencyKind::Library,
            )
        })
        .collect();
    let started = Instant::now();
    let summary = Downloader::new(DownloadSourcePolicy::Official, None, configuration)
        .expect("downloader")
        .download(tasks, progress(), CancelFlag::new())
        .await
        .expect("bench download");
    let elapsed = started.elapsed();
    assert!(summary.is_success());
    let mib = (body.len() * files) as f64 / (1024.0 * 1024.0);
    println!(
        "{label}: {files} files / {:.1} MiB in {:.2}s = {:.1} MiB/s ({:.0} files/s)",
        mib,
        elapsed.as_secs_f64(),
        mib / elapsed.as_secs_f64(),
        files as f64 / elapsed.as_secs_f64()
    );
    let _ = std::fs::remove_dir_all(&directory);
}

async fn measure(label: &str, configuration: DownloadConfiguration, body: &[u8], base: &str) {
    let directory = temp_dir(label);
    let destination = directory.join("client.jar");
    let task = DownloadTask::new(
        destination.clone(),
        Some(format!("{base}/client.jar")),
        Some(sha1_bytes(body)),
        Some(body.len() as u64),
        MissingDependencyKind::Library,
    );
    let started = Instant::now();
    let summary = Downloader::new(DownloadSourcePolicy::Official, None, configuration)
        .expect("downloader")
        .download(vec![task], progress(), CancelFlag::new())
        .await
        .expect("bench download");
    let elapsed = started.elapsed();
    assert!(summary.is_success());
    let mib = body.len() as f64 / (1024.0 * 1024.0);
    println!(
        "{label}: {:.1} MiB in {:.2}s = {:.1} MiB/s",
        mib,
        elapsed.as_secs_f64(),
        mib / elapsed.as_secs_f64()
    );
    let _ = std::fs::remove_dir_all(&directory);
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "download throughput baseline; run with --ignored --nocapture"]
async fn download_throughput_baseline() {
    let body = payload(PAYLOAD_BYTES);
    let base = serve(body.clone());

    let single = DownloadConfiguration {
        concurrency: 1,
        global_concurrency: 1,
        per_host_concurrency: 1,
        segments: 1,
        ..DownloadConfiguration::default()
    };
    let segmented = DownloadConfiguration {
        concurrency: 4,
        global_concurrency: 8,
        per_host_concurrency: 8,
        segments: 8,
        segment_threshold_bytes: 1024 * 1024,
        ..DownloadConfiguration::default()
    };

    measure("single-stream", single.clone(), &body, &base).await;
    measure("eight-segments", segmented.clone(), &body, &base).await;

    // The realistic Minecraft workload is thousands of small files, where the
    // win comes from request concurrency rather than range splitting.
    let small = payload(64 * 1024);
    let small_base = serve(small.clone());
    measure_file_set("50-files-sequential", single, &small, &small_base, 50).await;
    measure_file_set("50-files-concurrent", segmented, &small, &small_base, 50).await;
}
