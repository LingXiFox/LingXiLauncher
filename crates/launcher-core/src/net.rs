//! Shared helpers for metadata HTTP calls (P1-4).
//!
//! Every metadata request has an explicit connect and total timeout, and every
//! failure has to be actionable: "the network is down" and "the server answered
//! 403" need different reactions from the user. Messages carry the phase that
//! failed plus a redacted URL (query strings can hold OAuth codes and tokens).

use std::sync::{Mutex, OnceLock};

/// How outbound HTTP traffic finds a proxy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProxyMode {
    /// Follow the operating system / environment settings (reqwest default).
    System,
    /// Always use the configured proxy URL.
    Manual,
    /// Never use a proxy, even when the environment defines one.
    Off,
}

/// Process wide proxy configuration shared by every HTTP client.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProxySettings {
    pub mode: ProxyMode,
    pub url: Option<String>,
}

impl Default for ProxySettings {
    fn default() -> Self {
        Self {
            mode: ProxyMode::System,
            url: None,
        }
    }
}

fn proxy_slot() -> &'static Mutex<ProxySettings> {
    static SLOT: OnceLock<Mutex<ProxySettings>> = OnceLock::new();
    SLOT.get_or_init(|| Mutex::new(ProxySettings::default()))
}

/// Installs the proxy configuration used by all subsequently built clients.
pub fn set_proxy(settings: ProxySettings) {
    *proxy_slot().lock().expect("proxy lock") = settings;
}

pub fn proxy_settings() -> ProxySettings {
    proxy_slot().lock().expect("proxy lock").clone()
}

/// Builds a reqwest client builder honouring the process wide proxy setting.
pub fn client_builder() -> reqwest::ClientBuilder {
    let settings = proxy_settings();
    let builder = reqwest::Client::builder();
    match settings.mode {
        ProxyMode::System => builder,
        ProxyMode::Off => builder.no_proxy(),
        ProxyMode::Manual => match settings.url.as_deref().map(reqwest::Proxy::all) {
            Some(Ok(proxy)) => builder.proxy(proxy),
            // An unparsable proxy falls back to the system setting instead of
            // failing every request in the launcher.
            _ => builder,
        },
    }
}

/// Removes query string, fragment and userinfo so a URL can be logged or shown.
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

/// Which kind of transport failure happened, so the message can say so.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferFailure {
    /// The TCP/TLS connection never got established in time.
    ConnectTimeout,
    /// The connection is up but the server stopped sending.
    ReadTimeout,
    /// Connection refused, DNS failure, TLS error, ...
    Connect,
    /// Headers arrived, the body stream broke off.
    Body,
}

impl TransferFailure {
    pub fn label(self) -> &'static str {
        match self {
            Self::ConnectTimeout => "connection timeout",
            Self::ReadTimeout => "read timeout",
            Self::Connect => "connection failed",
            Self::Body => "response interrupted",
        }
    }
}

/// Builds the user-facing message for a failed metadata request.
pub fn describe_transfer_error(
    phase: &str,
    url: &str,
    failure: TransferFailure,
    detail: &str,
) -> String {
    format!(
        "{phase}: {} for {} ({detail})",
        failure.label(),
        redact_url(url)
    )
}

/// Classifies a reqwest error into a timeout vs a hard connection failure.
pub fn classify_reqwest_error(error: &reqwest::Error) -> TransferFailure {
    if error.is_timeout() {
        if error.is_connect() {
            TransferFailure::ConnectTimeout
        } else {
            TransferFailure::ReadTimeout
        }
    } else if error.is_connect() {
        TransferFailure::Connect
    } else if error.is_body() || error.is_decode() {
        TransferFailure::Body
    } else {
        TransferFailure::Connect
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redacts_query_and_fragment() {
        assert_eq!(
            redact_url("https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"),
            "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
        );
        assert_eq!(
            redact_url("https://example.test/a/b?token=SECRET#frag"),
            "https://example.test/a/b"
        );
        assert_eq!(
            redact_url("https://user:pass@example.test/a"),
            "https://example.test/a"
        );
        assert!(!redact_url("https://example.test/x?code=SECRET").contains("SECRET"));
    }

    #[test]
    fn messages_name_the_phase_and_the_failure_kind() {
        let text = describe_transfer_error(
            "asset index",
            "https://resources.download.minecraft.net/ab/abcdef?x=1",
            TransferFailure::ReadTimeout,
            "operation timed out",
        );
        assert!(text.starts_with("asset index: read timeout for "));
        assert!(text.contains("https://resources.download.minecraft.net/ab/abcdef"));
        assert!(!text.contains("?x=1"));
        assert!(text.contains("operation timed out"));

        assert_eq!(
            describe_transfer_error(
                "manifest",
                "https://a.test/b",
                TransferFailure::Connect,
                "dns"
            ),
            "manifest: connection failed for https://a.test/b (dns)"
        );
    }
}
