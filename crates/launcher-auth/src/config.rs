use std::time::Duration;

use launcher_core::{Error, Result};
use url::Url;

/// The approved LingXi Launcher Microsoft Entra public-client registration.
/// This is the single place the application identity lives; it contains no secret.
pub const CLIENT_ID: &str = "4c990be6-c02d-4f0d-84f6-c3d6785f2a36";
pub const TENANT: &str = "consumers";
pub const REDIRECT_URI: &str = "http://localhost";
pub const SCOPES: [&str; 2] = ["XboxLive.signin", "offline_access"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthConfig {
    pub client_id: String,
    pub tenant: String,
    /// Registered loopback redirect URI without a port; the port is chosen at runtime.
    pub redirect_uri: String,
    pub scopes: Vec<String>,
    pub authorization_timeout: Duration,
}

impl Default for AuthConfig {
    fn default() -> Self {
        Self {
            client_id: CLIENT_ID.to_string(),
            tenant: TENANT.to_string(),
            redirect_uri: REDIRECT_URI.to_string(),
            scopes: SCOPES.iter().map(|s| s.to_string()).collect(),
            authorization_timeout: Duration::from_secs(300),
        }
    }
}

impl AuthConfig {
    /// Embedded registration with optional developer overrides from the environment.
    pub fn from_environment() -> Result<Self> {
        let mut config = Self::default();
        if let Ok(value) = std::env::var("LINGXI_MICROSOFT_CLIENT_ID") {
            if !value.trim().is_empty() {
                config.client_id = value.trim().to_string();
            }
        }
        if let Ok(value) = std::env::var("LINGXI_MICROSOFT_TENANT") {
            if !value.trim().is_empty() {
                config.tenant = value.trim().to_string();
            }
        }
        if let Ok(value) = std::env::var("LINGXI_MICROSOFT_REDIRECT_URI") {
            if !value.trim().is_empty() {
                config.redirect_uri = value.trim().to_string();
            }
        }
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<()> {
        if self.client_id.trim().is_empty() {
            return Err(Error::MissingInput(
                "Microsoft Entra client id is empty".into(),
            ));
        }
        let tenant_ok = !self.tenant.is_empty()
            && self
                .tenant
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-');
        if !tenant_ok {
            return Err(Error::InvalidMetadata(format!(
                "invalid Entra tenant '{}'",
                self.tenant
            )));
        }
        let url = Url::parse(&self.redirect_uri).map_err(|_| {
            Error::InvalidMetadata(format!("invalid redirect URI '{}'", self.redirect_uri))
        })?;
        let loopback = url.scheme() == "http"
            && matches!(url.host_str(), Some("localhost") | Some("127.0.0.1"));
        if !loopback {
            return Err(Error::InvalidMetadata(
                "redirectURI must be a loopback HTTP URL (http://localhost or http://127.0.0.1)"
                    .into(),
            ));
        }
        if !self.scopes.iter().any(|s| s == "offline_access") {
            return Err(Error::InvalidMetadata(
                "OAuth scopes must include offline_access so the refresh token can be stored"
                    .into(),
            ));
        }
        if self.authorization_timeout.as_secs() == 0 || self.authorization_timeout.as_secs() > 900 {
            return Err(Error::InvalidMetadata(
                "authorization timeout must be between 1 and 900 seconds".into(),
            ));
        }
        Ok(())
    }

    pub fn authorization_endpoint(&self) -> String {
        format!(
            "https://login.microsoftonline.com/{}/oauth2/v2.0/authorize",
            self.tenant
        )
    }

    pub fn token_endpoint(&self) -> String {
        format!(
            "https://login.microsoftonline.com/{}/oauth2/v2.0/token",
            self.tenant
        )
    }

    pub fn scope(&self) -> String {
        self.scopes.join(" ")
    }

    /// Full redirect URI for a concrete loopback port.
    pub fn redirect_uri_for_port(&self, port: u16) -> String {
        let mut url = Url::parse(&self.redirect_uri)
            .unwrap_or_else(|_| Url::parse("http://localhost").unwrap());
        let _ = url.set_port(Some(port));
        url.to_string()
    }
}
