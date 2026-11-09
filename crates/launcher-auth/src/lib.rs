//! Microsoft → Xbox Live → Minecraft authentication.
//!
//! Public client (Authorization Code + PKCE, no client secret). The Entra
//! registration is embedded once here; `LINGXI_MICROSOFT_CLIENT_ID` remains a
//! developer-only override.

pub mod config;
pub mod loopback;
pub mod oauth;
pub mod pkce;
pub mod service;
pub mod xbox;

pub use config::AuthConfig;
pub use loopback::{OAuthCallback, wait_for_callback};
pub use oauth::{MicrosoftOAuthClient, OAuthToken};
pub use pkce::Pkce;
pub use service::{MicrosoftAuthService, MicrosoftSession, refresh_token_key};
pub use xbox::{MinecraftProfile, MicrosoftAuthenticator, XboxTokens, XstsResult};

pub use launcher_core::models::account::{MicrosoftAccount, PlayerAppearance};
