use std::time::Duration;

use chrono::{DateTime, Utc};
use launcher_core::{Error, Result};
use serde::Deserialize;
use url::Url;

use crate::config::AuthConfig;
use crate::pkce::Pkce;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OAuthToken {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub expires_at: DateTime<Utc>,
    pub scope: Option<String>,
    pub token_type: String,
}

impl OAuthToken {
    /// Treats a token as expired one minute early so callers never race the clock.
    pub fn is_expired(&self) -> bool {
        Utc::now() >= self.expires_at - chrono::Duration::seconds(60)
    }
}

#[derive(Debug, Clone)]
pub struct MicrosoftOAuthClient {
    config: AuthConfig,
    http: reqwest::Client,
}

impl MicrosoftOAuthClient {
    pub fn new(config: AuthConfig) -> Self {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .unwrap_or_default();
        Self { config, http }
    }

    pub fn authorization_url(
        &self,
        state: &str,
        code_challenge: &str,
        redirect_uri: &str,
    ) -> Result<String> {
        let mut url = Url::parse(&self.config.authorization_endpoint())
            .map_err(|e| Error::InvalidMetadata(format!("invalid authorization endpoint: {e}")))?;
        url.query_pairs_mut()
            .append_pair("client_id", &self.config.client_id)
            .append_pair("response_type", "code")
            .append_pair("redirect_uri", redirect_uri)
            .append_pair("response_mode", "query")
            .append_pair("scope", &self.config.scope())
            .append_pair("state", state)
            .append_pair("code_challenge", code_challenge)
            .append_pair("code_challenge_method", "S256")
            .append_pair("prompt", "select_account");
        Ok(url.into())
    }

    pub async fn exchange_code(
        &self,
        code: &str,
        verifier: &str,
        redirect_uri: &str,
    ) -> Result<OAuthToken> {
        let form = [
            ("client_id", self.config.client_id.as_str()),
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirect_uri),
            ("code_verifier", verifier),
            ("scope", &self.config.scope()),
        ];
        self.request_token(&form, false).await
    }

    pub async fn refresh(&self, refresh_token: &str) -> Result<OAuthToken> {
        let scope = self.config.scope();
        let form = [
            ("client_id", self.config.client_id.as_str()),
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token),
            ("scope", scope.as_str()),
        ];
        self.request_token(&form, true).await
    }

    async fn request_token(&self, form: &[(&str, &str)], is_refresh: bool) -> Result<OAuthToken> {
        let response = self
            .http
            .post(self.config.token_endpoint())
            .header("Accept", "application/json")
            .form(form)
            .send()
            .await
            .map_err(|e| {
                Error::Unavailable(format!("Microsoft token endpoint unreachable: {e}"))
            })?;
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        if !status.is_success() {
            let payload: TokenErrorPayload = serde_json::from_str(&body).unwrap_or_default();
            let description = payload
                .error_description
                .or(payload.error)
                .unwrap_or_else(|| format!("HTTP {status}"));
            if is_refresh && status.as_u16() == 400 {
                return Err(Error::Authentication(format!(
                    "saved Microsoft session has expired: {description}; sign in again"
                )));
            }
            return Err(Error::Authentication(format!(
                "Microsoft OAuth token request failed (HTTP {status}): {description}"
            )));
        }
        let payload: TokenResponsePayload = serde_json::from_str(&body)
            .map_err(|e| Error::Authentication(format!("invalid Microsoft token response: {e}")))?;
        if payload.access_token.is_empty() {
            return Err(Error::Authentication(
                "Microsoft OAuth response had no access token".into(),
            ));
        }
        Ok(OAuthToken {
            access_token: payload.access_token,
            refresh_token: payload.refresh_token.filter(|t| !t.is_empty()),
            expires_at: Utc::now()
                + chrono::Duration::seconds(payload.expires_in.unwrap_or(3600) as i64),
            scope: payload.scope,
            token_type: payload.token_type.unwrap_or_else(|| "Bearer".to_string()),
        })
    }
}

impl Pkce {
    /// Convenience for callers that build an authorization URL from a fresh PKCE pair.
    pub fn authorization_url(&self, config: &AuthConfig, redirect_uri: &str) -> Result<String> {
        MicrosoftOAuthClient::new(config.clone()).authorization_url(
            &self.state,
            &self.challenge,
            redirect_uri,
        )
    }
}

#[derive(Debug, Default, Deserialize)]
struct TokenResponsePayload {
    #[serde(default)]
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    expires_in: Option<u64>,
    #[serde(default)]
    scope: Option<String>,
    #[serde(default)]
    token_type: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct TokenErrorPayload {
    #[serde(default)]
    error: Option<String>,
    #[serde(default)]
    error_description: Option<String>,
}
