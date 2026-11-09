use std::time::Duration;

use chrono::{DateTime, Utc};
use launcher_core::models::account::PlayerAppearance;
use launcher_core::{Error, Result};
use serde::Deserialize;
use serde_json::json;
use uuid::Uuid;

const XBOX_AUTH_URL: &str = "https://user.auth.xboxlive.com/user/authenticate";
const XSTS_URL: &str = "https://xsts.auth.xboxlive.com/xsts/authorize";
const MINECRAFT_LOGIN_URL: &str =
    "https://api.minecraftservices.com/authentication/login_with_xbox";
const ENTITLEMENTS_URL: &str = "https://api.minecraftservices.com/entitlements/mcstore";
const PROFILE_URL: &str = "https://api.minecraftservices.com/minecraft/profile";
const XBOX_PROFILE_URL: &str =
    "https://profile.xboxlive.com/users/me/profile/settings?settings=Gamertag";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct XboxTokens {
    pub token: String,
    pub user_hash: String,
    pub xuid: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct XstsResult {
    pub token: String,
    pub user_hash: String,
    pub xuid: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MinecraftProfile {
    pub id: Uuid,
    pub name: String,
}

#[derive(Debug, Clone)]
pub struct VerifiedMinecraft {
    pub profile: MinecraftProfile,
    pub access_token: String,
    pub expires_at: DateTime<Utc>,
    pub xuid: String,
    pub owns_game: bool,
    pub appearance: Option<PlayerAppearance>,
}

#[derive(Debug, Clone)]
pub struct MicrosoftAuthenticator {
    http: reqwest::Client,
}

impl Default for MicrosoftAuthenticator {
    fn default() -> Self {
        Self::new()
    }
}

impl MicrosoftAuthenticator {
    pub fn new() -> Self {
        Self {
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(30))
                .build()
                .unwrap_or_default(),
        }
    }

    pub async fn authenticate_microsoft(&self, microsoft_access_token: &str) -> Result<XboxTokens> {
        let body = json!({
            "Properties": {
                "AuthMethod": "RPS",
                "SiteName": "user.auth.xboxlive.com",
                "RpsTicket": format!("d={microsoft_access_token}")
            },
            "RelyingParty": "http://auth.xboxlive.com",
            "TokenType": "JWT"
        });
        let response = self.post_json(XBOX_AUTH_URL, &body, true).await?;
        if !response.status.is_success() {
            return Err(Error::Authentication(format!(
                "Xbox Live authentication failed (HTTP {}): {}",
                response.status,
                snippet(&response.body)
            )));
        }
        let payload: XboxAuthenticationResponse = serde_json::from_str(&response.body)
            .map_err(|e| Error::Authentication(format!("invalid Xbox Live response: {e}")))?;
        let claim =
            payload.display_claims.xui.first().ok_or_else(|| {
                Error::Authentication("Xbox Live response had no user hash".into())
            })?;
        if claim.uhs.is_empty() || payload.token.is_empty() {
            return Err(Error::Authentication(
                "Xbox Live response had no token or user hash".into(),
            ));
        }
        let mut tokens = XboxTokens {
            token: payload.token,
            user_hash: claim.uhs.clone(),
            xuid: claim.xuid(),
        };
        if tokens.xuid.as_deref().unwrap_or_default().is_empty() {
            tokens.xuid = self.resolve_xuid(&tokens).await.unwrap_or(None);
        }
        Ok(tokens)
    }

    pub async fn authorize_xsts(&self, xbox: &XboxTokens) -> Result<XstsResult> {
        self.authorize_xsts_for(xbox, "rp://api.minecraftservices.com/")
            .await
    }

    pub async fn authorize_xsts_for(
        &self,
        xbox: &XboxTokens,
        relying_party: &str,
    ) -> Result<XstsResult> {
        let body = json!({
            "Properties": {
                "SandboxId": "RETAIL",
                "UserTokens": [xbox.token]
            },
            "RelyingParty": relying_party,
            "TokenType": "JWT"
        });
        let response = self.post_json(XSTS_URL, &body, true).await?;
        if !response.status.is_success() {
            if response.status.as_u16() == 401 {
                let code = serde_json::from_str::<XstsErrorResponse>(&response.body)
                    .ok()
                    .and_then(|e| e.xerr);
                return Err(xsts_error(code));
            }
            return Err(Error::Authentication(format!(
                "XSTS authorization failed (HTTP {}): {}",
                response.status,
                snippet(&response.body)
            )));
        }
        let payload: XboxAuthenticationResponse = serde_json::from_str(&response.body)
            .map_err(|e| Error::Authentication(format!("invalid XSTS response: {e}")))?;
        let claim = payload
            .display_claims
            .xui
            .first()
            .ok_or_else(|| Error::Authentication("XSTS response had no user hash".into()))?;
        if payload.token.is_empty() || claim.uhs.is_empty() {
            return Err(Error::Authentication(
                "XSTS response had no token or user hash".into(),
            ));
        }
        Ok(XstsResult {
            token: payload.token,
            user_hash: claim.uhs.clone(),
            xuid: claim.xuid().or_else(|| xbox.xuid.clone()),
        })
    }

    /// Resolves the XUID via an Xbox Live audience; returns `None` when unavailable.
    pub async fn resolve_xuid(&self, xbox: &XboxTokens) -> Result<Option<String>> {
        let profile_token = self.authorize_xsts_for(xbox, "http://xboxlive.com").await?;
        self.fetch_xuid(&profile_token.token, &profile_token.user_hash)
            .await
    }

    pub async fn fetch_xuid(&self, xsts_token: &str, user_hash: &str) -> Result<Option<String>> {
        let response = self
            .http
            .get(XBOX_PROFILE_URL)
            .header(
                "Authorization",
                format!("XBL3.0 x={user_hash};{xsts_token}"),
            )
            .header("Accept", "application/json")
            .header("x-xbl-contract-version", "3")
            .send()
            .await
            .map_err(|e| Error::Unavailable(format!("Xbox profile service unreachable: {e}")))?;
        if !response.status().is_success() {
            return Ok(None);
        }
        let payload: XboxProfileResponse = response
            .json()
            .await
            .map_err(|e| Error::Authentication(format!("invalid Xbox profile response: {e}")))?;
        Ok(payload
            .profile_users
            .into_iter()
            .next()
            .map(|u| u.id)
            .filter(|id| !id.is_empty()))
    }

    pub async fn login_minecraft(&self, xsts: &XstsResult) -> Result<(String, DateTime<Utc>)> {
        let body = json!({
            "identityToken": format!("XBL3.0 x={};{}", xsts.user_hash, xsts.token)
        });
        let response = self.post_json(MINECRAFT_LOGIN_URL, &body, false).await?;
        if response.status.as_u16() == 403 {
            return Err(Error::Authentication(
                "Minecraft Services rejected this application (HTTP 403); the Entra app must be on the Minecraft API allow list".into(),
            ));
        }
        if !response.status.is_success() {
            return Err(Error::Authentication(format!(
                "Minecraft Services login failed (HTTP {}): {}",
                response.status,
                snippet(&response.body)
            )));
        }
        let payload: MinecraftLoginResponse = serde_json::from_str(&response.body)
            .map_err(|e| Error::Authentication(format!("invalid Minecraft login response: {e}")))?;
        if payload.access_token.is_empty() {
            return Err(Error::Authentication(
                "Minecraft Services returned no access token".into(),
            ));
        }
        let expires_at =
            Utc::now() + chrono::Duration::seconds(payload.expires_in.unwrap_or(86_400) as i64);
        Ok((payload.access_token, expires_at))
    }

    pub async fn fetch_entitlements(&self, token: &str) -> Result<Vec<String>> {
        let response = self
            .http
            .get(ENTITLEMENTS_URL)
            .bearer_auth(token)
            .header("Accept", "application/json")
            .send()
            .await
            .map_err(|e| Error::Unavailable(format!("Minecraft entitlements unreachable: {e}")))?;
        match response.status().as_u16() {
            401 => Err(Error::Authentication("Minecraft access token was rejected; sign in again".into())),
            403 => Err(Error::Authentication(
                "Minecraft entitlements request was rejected (HTTP 403); the Entra app must be allow-listed".into(),
            )),
            status if !(200..300).contains(&status) => Err(Error::Authentication(format!(
                "could not verify Minecraft ownership (HTTP {status})"
            ))),
            _ => {
                let payload: EntitlementsResponse = response
                    .json()
                    .await
                    .map_err(|e| Error::Authentication(format!("invalid entitlements response: {e}")))?;
                Ok(payload.items.into_iter().map(|i| i.name).collect())
            }
        }
    }

    /// Returns `None` for accounts without a Minecraft profile (HTTP 404).
    pub async fn fetch_profile(
        &self,
        token: &str,
    ) -> Result<Option<(MinecraftProfile, Option<PlayerAppearance>)>> {
        let response = self
            .http
            .get(PROFILE_URL)
            .bearer_auth(token)
            .header("Accept", "application/json")
            .send()
            .await
            .map_err(|e| {
                Error::Unavailable(format!("Minecraft profile service unreachable: {e}"))
            })?;
        match response.status().as_u16() {
            404 => return Ok(None),
            401 => return Err(Error::Authentication("Minecraft access token was rejected; sign in again".into())),
            403 => {
                return Err(Error::Authentication(
                    "Minecraft profile request was rejected (HTTP 403); the Entra app must be allow-listed".into(),
                ))
            }
            status if !(200..300).contains(&status) => {
                return Err(Error::Authentication(format!("Minecraft profile request failed (HTTP {status})")))
            }
            _ => {}
        }
        let payload: MinecraftProfileResponse = response.json().await.map_err(|e| {
            Error::Authentication(format!("invalid Minecraft profile response: {e}"))
        })?;
        let id = parse_minecraft_id(&payload.id)
            .ok_or_else(|| Error::Authentication("Minecraft profile had an invalid id".into()))?;
        if payload.name.is_empty() {
            return Err(Error::Authentication(
                "Minecraft profile had an empty name".into(),
            ));
        }
        let skin = payload.skins.as_ref().and_then(|s| {
            s.iter()
                .find(|s| s.state.eq_ignore_ascii_case("ACTIVE"))
                .or_else(|| s.first())
        });
        let cape = payload.capes.as_ref().and_then(|c| {
            c.iter()
                .find(|c| c.state.eq_ignore_ascii_case("ACTIVE"))
                .or_else(|| c.first())
        });
        let appearance = if skin.is_some() || cape.is_some() {
            Some(PlayerAppearance {
                skin_texture_url: skin.and_then(|s| secure_texture(&s.url)),
                cape_texture_url: cape.and_then(|c| secure_texture(&c.url)),
                skin_model: skin.map(|s| {
                    if s.variant.eq_ignore_ascii_case("SLIM") {
                        "slim"
                    } else {
                        "classic"
                    }
                    .to_string()
                }),
            })
        } else {
            None
        };
        Ok(Some((
            MinecraftProfile {
                id,
                name: payload.name,
            },
            appearance,
        )))
    }

    /// Full ownership + profile verification for a fresh Minecraft token.
    pub async fn verify_ownership_and_profile(
        &self,
        minecraft_token: String,
        expires_at: DateTime<Utc>,
        xuid: String,
    ) -> Result<VerifiedMinecraft> {
        let entitlements = self.fetch_entitlements(&minecraft_token).await?;
        let profile = self.fetch_profile(&minecraft_token).await?;
        // A Minecraft profile is only issued to Java owners, so either signal proves ownership.
        let owns_game = !entitlements.is_empty() || profile.is_some();
        let (profile, appearance) = profile.ok_or_else(|| {
            Error::Authentication(
                "this Microsoft account does not own Minecraft: Java Edition".into(),
            )
        })?;
        if !owns_game {
            return Err(Error::Authentication(
                "this Microsoft account does not own Minecraft: Java Edition".into(),
            ));
        }
        Ok(VerifiedMinecraft {
            profile,
            access_token: minecraft_token,
            expires_at,
            xuid,
            owns_game: true,
            appearance,
        })
    }

    async fn post_json(
        &self,
        url: &str,
        body: &serde_json::Value,
        contract_version: bool,
    ) -> Result<RawResponse> {
        let mut request = self
            .http
            .post(url)
            .header("Content-Type", "application/json")
            .header("Accept", "application/json")
            .json(body);
        if contract_version {
            request = request.header("x-xbl-contract-version", "1");
        }
        let response = request
            .send()
            .await
            .map_err(|e| Error::Unavailable(format!("{url} unreachable: {e}")))?;
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        Ok(RawResponse { status, body })
    }
}

struct RawResponse {
    status: reqwest::StatusCode,
    body: String,
}

fn snippet(body: &str) -> String {
    body.chars().take(300).collect()
}

/// Mojang returns `http://textures.minecraft.net/...`; prefer HTTPS.
fn secure_texture(url: &str) -> Option<String> {
    if url.is_empty() {
        return None;
    }
    if let Ok(mut parsed) = url::Url::parse(url) {
        if parsed.scheme() == "http" && parsed.host_str() == Some("textures.minecraft.net") {
            let _ = parsed.set_scheme("https");
        }
        return Some(parsed.to_string());
    }
    Some(url.to_string())
}

pub fn parse_minecraft_id(id: &str) -> Option<Uuid> {
    let hex: String = id.chars().filter(|c| *c != '-').collect();
    if hex.len() != 32 || !hex.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    Uuid::parse_str(&format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    ))
    .ok()
}

fn xsts_error(code: Option<i64>) -> Error {
    let message = match code {
        Some(2_148_916_227) => "this Xbox account is banned and cannot access Minecraft",
        Some(2_148_916_233) => "this Microsoft account has no Xbox profile",
        Some(2_148_916_235) => {
            "this account is a child account that needs an adult to join Xbox Live"
        }
        Some(2_148_916_236) => "this account is not available in its region for Xbox Live",
        Some(2_148_916_238) => "this account needs to finish Xbox Live setup at xbox.com",
        _ => "Xbox Live rejected this account (XSTS authorization failed)",
    };
    Error::Authentication(message.to_string())
}

#[derive(Debug, Deserialize)]
struct XboxAuthenticationResponse {
    #[serde(rename = "Token")]
    token: String,
    #[serde(rename = "DisplayClaims")]
    display_claims: DisplayClaims,
}

#[derive(Debug, Deserialize)]
struct DisplayClaims {
    xui: Vec<Xui>,
}

#[derive(Debug)]
struct Xui {
    uhs: String,
    xid: Option<XuidValue>,
}

/// Xbox responses may carry the XUID as a string or a number.
#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum XuidValue {
    Text(String),
    Number(i64),
    Unsigned(u64),
}

impl XuidValue {
    fn as_string(&self) -> String {
        match self {
            XuidValue::Text(v) => v.clone(),
            XuidValue::Number(v) => v.to_string(),
            XuidValue::Unsigned(v) => v.to_string(),
        }
    }
}

impl Xui {
    fn xuid(&self) -> Option<String> {
        self.xid
            .as_ref()
            .map(|v| v.as_string())
            .filter(|v| !v.is_empty())
    }
}

// Serde cannot call `user_hash`/`xuid` automatically, so normalize on construction.
impl<'de> Deserialize<'de> for Xui {
    fn deserialize<D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> std::result::Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Raw {
            uhs: String,
            #[serde(default)]
            xid: Option<XuidValue>,
            #[serde(default)]
            xuid: Option<XuidValue>,
            #[serde(default, rename = "XUID")]
            xuid_upper: Option<XuidValue>,
        }
        let raw = Raw::deserialize(deserializer)?;
        Ok(Xui {
            uhs: raw.uhs,
            xid: raw.xid.or(raw.xuid).or(raw.xuid_upper),
        })
    }
}

#[derive(Debug, Deserialize)]
struct XboxProfileResponse {
    #[serde(rename = "profileUsers", default)]
    profile_users: Vec<ProfileUser>,
}

#[derive(Debug, Deserialize)]
struct ProfileUser {
    id: String,
}

#[derive(Debug, Deserialize)]
struct XstsErrorResponse {
    #[serde(rename = "XErr")]
    xerr: Option<i64>,
}

#[derive(Debug, Deserialize)]
struct MinecraftLoginResponse {
    #[serde(rename = "access_token", default)]
    access_token: String,
    #[serde(rename = "expires_in", default)]
    expires_in: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct EntitlementsResponse {
    #[serde(default)]
    items: Vec<Entitlement>,
}

#[derive(Debug, Deserialize)]
struct Entitlement {
    #[serde(default)]
    name: String,
}

#[derive(Debug, Deserialize)]
struct MinecraftProfileResponse {
    #[serde(default)]
    id: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    skins: Option<Vec<Texture>>,
    #[serde(default)]
    capes: Option<Vec<Texture>>,
}

#[derive(Debug, Deserialize)]
struct Texture {
    #[serde(default)]
    url: String,
    #[serde(default)]
    state: String,
    #[serde(default)]
    variant: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_dashed_and_plain_minecraft_ids() {
        let expected = Uuid::parse_str("069a79f4-44e9-4726-a5be-fca90e38aaf5").unwrap();
        assert_eq!(
            parse_minecraft_id("069a79f444e94726a5befca90e38aaf5"),
            Some(expected)
        );
        assert_eq!(
            parse_minecraft_id("069a79f4-44e9-4726-a5be-fca90e38aaf5"),
            Some(expected)
        );
        assert_eq!(parse_minecraft_id("not-a-uuid"), None);
    }

    #[test]
    fn upgrades_mojang_texture_hosts_to_https() {
        assert_eq!(
            secure_texture("http://textures.minecraft.net/texture/abc").as_deref(),
            Some("https://textures.minecraft.net/texture/abc")
        );
        assert_eq!(
            secure_texture("https://example.com/skin.png").as_deref(),
            Some("https://example.com/skin.png")
        );
    }
}
