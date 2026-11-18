//! Persistent launcher log (P1-8).
//!
//! The GUI already has a log viewer (`read_logs` with kind `launcher`) that
//! reads the newest file in `<dataRoot>/logs/launcher`. Until now nothing ever
//! wrote there, so install failures on a Windows box left no trail at all.
//!
//! Design constraints:
//! - no new dependencies: a `Mutex<File>` appender instead of a tracing layer;
//! - never log credentials: call sites pass messages only, and URLs go through
//!   `redact_url` which drops query strings and fragments (OAuth codes, states
//!   and session tokens live there);
//! - a logging failure must never break a launcher command, so every I/O error
//!   is swallowed.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::sync::{Mutex, OnceLock};

use launcher_core::layout::GameDataLayout;

static LOG_FILE: OnceLock<Mutex<File>> = OnceLock::new();

/// Open (or create) `<dataRoot>/logs/launcher/launcher.log`. Safe to call more
/// than once; later calls are no-ops so tests and the Tauri runtime can share
/// the process safely.
pub fn init(layout: &GameDataLayout) {
    let directory = layout.logs_directory();
    if launcher_core::layout::ensure_dir(&directory).is_err() {
        return;
    }
    let path = directory.join("launcher.log");
    if let Ok(file) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = LOG_FILE.set(Mutex::new(file));
    }
}

fn write(level: &str, message: &str) {
    let Some(lock) = LOG_FILE.get() else {
        return;
    };
    let Ok(mut file) = lock.lock() else {
        return;
    };
    let stamp = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ");
    let _ = writeln!(file, "{stamp} [{level}] {message}");
    let _ = file.flush();
}

pub fn info(message: impl AsRef<str>) {
    write("INFO", message.as_ref());
}

pub fn error(message: impl AsRef<str>) {
    write("ERROR", message.as_ref());
}

/// Strip everything that could carry a credential: query string, fragment and
/// userinfo. Keeps scheme://host/path which is all we need for diagnosis.
pub fn redact_url(raw: &str) -> String {
    let without_fragment = raw.split('#').next().unwrap_or(raw);
    let without_query = without_fragment
        .split('?')
        .next()
        .unwrap_or(without_fragment);
    match without_query.split_once("://") {
        Some((scheme, rest)) => match rest.split_once('/') {
            Some((authority, path)) => {
                let host = authority.rsplit('@').next().unwrap_or(authority);
                format!("{scheme}://{host}/{path}")
            }
            None => {
                let host = rest.rsplit('@').next().unwrap_or(rest);
                format!("{scheme}://{host}")
            }
        },
        None => without_query.to_string(),
    }
}

/// Append a one-line record for a finished transfer/install phase together
/// with its duration, which is what makes a slow Windows install diagnosable.
pub fn timed(phase: &str, started: std::time::Instant, detail: &dyn std::fmt::Display) {
    info(format!(
        "{phase} finished in {:.1}s: {detail}",
        started.elapsed().as_secs_f64()
    ));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redact_url_drops_query_and_fragment() {
        let url = "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize?client_id=abc&code=SECRET#frag";
        let redacted = redact_url(url);
        assert_eq!(
            redacted,
            "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize"
        );
        assert!(!redacted.contains("SECRET"));
    }

    #[test]
    fn redact_url_strips_userinfo_and_loopback_query() {
        let url = "http://127.0.0.1:51234/callback?code=SECRET&state=xyz";
        assert_eq!(redact_url(url), "http://127.0.0.1:51234/callback");
    }

    #[test]
    fn redact_url_keeps_plain_hosts_intact() {
        assert_eq!(
            redact_url("https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"),
            "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
        );
        assert_eq!(redact_url("not-a-url?x=1"), "not-a-url");
    }
}
