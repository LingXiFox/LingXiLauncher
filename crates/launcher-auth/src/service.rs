use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use chrono::Utc;
use launcher_core::models::account::{MicrosoftAccount, MicrosoftAccountStore};
use launcher_core::{Error, Result, SecretStore};
use tokio::net::TcpListener;
use uuid::Uuid;

use crate::config::AuthConfig;
use crate::loopback::wait_for_callback;
use crate::oauth::{MicrosoftOAuthClient, OAuthToken};
use crate::pkce::Pkce;
use crate::xbox::{MinecraftProfile, MicrosoftAuthenticator, VerifiedMinecraft};

pub const KEYCHAIN_SERVICE: &str = "LingXiLauncher";
pub const REFRESH_TOKEN_PREFIX: &str = "microsoft-refresh-token:v1:";

pub fn refresh_token_key(account_id: Uuid) -> String {
    format!("{REFRESH_TOKEN_PREFIX}{account_id}")
}

#[derive(Debug, Clone)]
pub struct MicrosoftSession {
    pub profile: MinecraftProfile,
    pub access_token: String,
    pub expires_at: chrono::DateTime<Utc>,
    pub xuid: String,
    pub user_type: String,
}

impl MicrosoftSession {
    pub fn is_expired(&self) -> bool {
        Utc::now() >= self.expires_at - chrono::Duration::seconds(120)
    }
}

#[derive(Clone)]
struct CachedSession {
    session: MicrosoftSession,
    refresh_token: String,
}

pub struct MicrosoftAuthService {
    config: AuthConfig,
    oauth: MicrosoftOAuthClient,
    authenticator: MicrosoftAuthenticator,
    secrets: Arc<dyn SecretStore>,
    accounts: MicrosoftAccountStore,
    sessions: Mutex<HashMap<Uuid, CachedSession>>,
}

impl MicrosoftAuthService {
    pub fn new(config: AuthConfig, layout: launcher_core::GameDataLayout, secrets: Arc<dyn SecretStore>) -> Result<Self> {
        config.validate()?;
        Ok(Self {
            oauth: MicrosoftOAuthClient::new(config.clone()),
            config,
            authenticator: MicrosoftAuthenticator::new(),
            secrets,
            accounts: MicrosoftAccountStore::new(layout),
            sessions: Mutex::new(HashMap::new()),
        })
    }

    pub fn configuration(&self) -> &AuthConfig {
        &self.config
    }

    pub fn accounts(&self) -> Result<Vec<MicrosoftAccount>> {
        self.accounts.list()
    }

    pub fn account(&self, id: Uuid) -> Result<MicrosoftAccount> {
        self.accounts.load(id)
    }

    /// Interactive sign-in through a loopback redirect. `open_browser` receives
    /// the authorization URL and returns once the browser has been asked to open it.
    pub async fn sign_in<F>(&self, open_browser: F) -> Result<(MicrosoftAccount, MicrosoftSession)>
    where
        F: FnOnce(&str) -> Result<()>,
    {
        let listener = TcpListener::bind(("127.0.0.1", 0))
            .await
            .map_err(|e| Error::Authentication(format!("cannot bind local sign-in port: {e}")))?;
        let port = listener
            .local_addr()
            .map_err(|e| Error::Authentication(format!("cannot read local sign-in port: {e}")))?
            .port();
        let redirect_uri = self.config.redirect_uri_for_port(port);
        let pkce = Pkce::generate()?;
        let url = self.oauth.authorization_url(&pkce.state, &pkce.challenge, &redirect_uri)?;

        open_browser(&url)?;
        let callback = wait_for_callback(listener, &pkce.state, &redirect_uri, self.config.authorization_timeout).await?;
        let token = self.oauth.exchange_code(&callback.code, &pkce.verifier, &callback.redirect_uri).await?;
        let refresh_token = token.refresh_token.clone().ok_or_else(|| {
            Error::Authentication("Microsoft did not return a refresh token; offline sign-in cannot be restored".into())
        })?;
        self.complete(token.access_token, refresh_token, None).await
    }

    /// Completes sign-in from an already-exchanged Microsoft token. Used by tests
    /// and by front-ends that host their own loopback callback.
    pub async fn complete_sign_in(&self, microsoft_access_token: &str, refresh_token: &str) -> Result<(MicrosoftAccount, MicrosoftSession)> {
        self.complete(microsoft_access_token.to_string(), refresh_token.to_string(), None).await
    }

    /// Returns a usable Minecraft session, refreshing the stored Microsoft token
    /// when needed. Never falls back to a different identity mode.
    pub async fn session_for(&self, account_id: Uuid) -> Result<MicrosoftSession> {
        if let Some(cached) = self.cached(account_id) {
            return Ok(cached);
        }
        let account = self.accounts.load(account_id)?;
        let refresh_token = self
            .secrets
            .get(KEYCHAIN_SERVICE, &refresh_token_key(account_id))?
            .filter(|t| !t.is_empty())
            .ok_or_else(|| {
                Error::Authentication(format!(
                    "no saved Microsoft session for {}; sign in with Microsoft again",
                    account.player_name
                ))
            })?;
        let token = self.oauth.refresh(&refresh_token).await?;
        let next_refresh = token.refresh_token.clone().unwrap_or(refresh_token);
        let (_, session) = self.complete(token.access_token, next_refresh, Some(account)).await?;
        Ok(session)
    }

    pub fn sign_out(&self, account_id: Uuid) -> Result<()> {
        let _ = self.secrets.delete(KEYCHAIN_SERVICE, &refresh_token_key(account_id));
        self.accounts.delete(account_id)?;
        self.sessions.lock().expect("session lock").remove(&account_id);
        Ok(())
    }

    pub fn forget_session(&self, account_id: Uuid) {
        self.sessions.lock().expect("session lock").remove(&account_id);
    }

    fn cached(&self, account_id: Uuid) -> Option<MicrosoftSession> {
        let guard = self.sessions.lock().expect("session lock");
        guard
            .get(&account_id)
            .filter(|c| !c.session.is_expired())
            .map(|c| c.session.clone())
    }

    async fn complete(
        &self,
        microsoft_access_token: String,
        refresh_token: String,
        existing: Option<MicrosoftAccount>,
    ) -> Result<(MicrosoftAccount, MicrosoftSession)> {
        let xbox = self.authenticator.authenticate_microsoft(&microsoft_access_token).await?;
        let xsts = self.authenticator.authorize_xsts(&xbox).await?;
        // Minecraft accepts an explicit "0" placeholder when the XUID is unavailable;
        // online features may be limited, but local play still works.
        let xuid = xsts.xuid.clone().unwrap_or_else(|| "0".to_string());
        let (minecraft_token, expires_at) = self.authenticator.login_minecraft(&xsts).await?;
        let verified: VerifiedMinecraft = self
            .authenticator
            .verify_ownership_and_profile(minecraft_token, expires_at, xuid)
            .await?;

        let account = MicrosoftAccount {
            id: verified.profile.id,
            player_name: verified.profile.name.clone(),
            xuid: verified.xuid.clone(),
            added_at: existing.as_ref().map(|a| a.added_at).unwrap_or_else(Utc::now),
            last_validated_at: Some(Utc::now()),
            owns_game: verified.owns_game,
            appearance: verified.appearance.clone().or_else(|| existing.and_then(|a| a.appearance)),
        };
        // Persist the refresh token first: metadata without a token would be a broken account.
        self.secrets
            .set(KEYCHAIN_SERVICE, &refresh_token_key(account.id), &refresh_token)?;
        self.accounts.save(&account)?;

        let session = MicrosoftSession {
            profile: verified.profile,
            access_token: verified.access_token,
            expires_at: verified.expires_at,
            xuid: verified.xuid,
            user_type: "msa".to_string(),
        };
        self.sessions.lock().expect("session lock").insert(
            account.id,
            CachedSession { session: session.clone(), refresh_token },
        );
        Ok((account, session))
    }
}

/// Converts an OAuth token into a session (helper for front-ends that cache tokens).
pub fn session_from_token(profile: MinecraftProfile, token: &OAuthToken, xuid: String) -> MicrosoftSession {
    MicrosoftSession {
        profile,
        access_token: token.access_token.clone(),
        expires_at: token.expires_at,
        xuid,
        user_type: "msa".to_string(),
    }
}
