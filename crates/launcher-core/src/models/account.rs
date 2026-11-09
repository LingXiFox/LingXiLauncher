use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::{Error, Result};
use crate::layout::GameDataLayout;
use crate::paths::PathSafety;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalOfflineAccount {
    pub player_name: String,
    pub offline_uuid: Uuid,
    pub identity_mode: super::instance::IdentityMode,
    pub created_at: DateTime<Utc>,
    pub unverified: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalOfflineProfile {
    pub player_name: String,
    pub stable_offline_uuid: Uuid,
}

impl LocalOfflineProfile {
    pub fn uuid_argument(&self) -> String {
        self.stable_offline_uuid.simple().to_string().to_lowercase()
    }
}

impl LocalOfflineAccount {
    pub fn profile(&self) -> LocalOfflineProfile {
        LocalOfflineProfile {
            player_name: self.player_name.clone(),
            stable_offline_uuid: self.offline_uuid,
        }
    }
}

/// Validates a Minecraft-compatible player name: 3-16 chars of `A-Za-z0-9_`.
pub fn validate_player_name(name: &str) -> Result<&str> {
    if name.len() < 3 || name.len() > 16 {
        return Err(Error::InvalidMetadata(format!(
            "invalid player name '{name}': 3-16 characters required"
        )));
    }
    if !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return Err(Error::InvalidMetadata(format!(
            "invalid player name '{name}': only A-Z a-z 0-9 _"
        )));
    }
    Ok(name)
}

/// Java-compatible `UUID.nameUUIDFromBytes("OfflinePlayer:<name>")`.
pub fn offline_uuid(name: &str) -> Uuid {
    use md5::{Digest, Md5};
    let mut hasher = Md5::new();
    hasher.update(format!("OfflinePlayer:{name}").as_bytes());
    let mut bytes: [u8; 16] = hasher.finalize().into();
    bytes[6] = (bytes[6] & 0x0f) | 0x30;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Uuid::from_bytes(bytes)
}

/// Stores local offline accounts under `<dataRoot>/accounts/local/<name>.json`.
pub struct LocalAccountStore {
    layout: GameDataLayout,
}

impl LocalAccountStore {
    pub fn new(layout: GameDataLayout) -> Self {
        Self { layout }
    }

    fn account_path(&self, player_name: &str) -> Result<std::path::PathBuf> {
        let name = PathSafety::validate_component(player_name)?;
        Ok(self
            .layout
            .local_accounts_directory()
            .join(format!("{name}.json")))
    }

    pub fn path_for(&self, player_name: &str) -> Result<std::path::PathBuf> {
        let name = validate_player_name(player_name)?;
        self.account_path(name)
    }

    pub fn delete(&self, player_name: &str) -> Result<()> {
        let path = self.path_for(player_name)?;
        if !path.is_file() {
            return Err(Error::NotFound(format!(
                "local offline account '{player_name}' does not exist"
            )));
        }
        Ok(std::fs::remove_file(path)?)
    }

    pub fn create(&self, player_name: &str) -> Result<LocalOfflineAccount> {
        let name = validate_player_name(player_name)?;
        if let Ok(existing) = self.load(name) {
            return Ok(existing);
        }
        let account = LocalOfflineAccount {
            player_name: name.to_string(),
            offline_uuid: offline_uuid(name),
            identity_mode: super::instance::IdentityMode::LocalOffline,
            created_at: Utc::now(),
            unverified: true,
        };
        let directory = self.layout.local_accounts_directory();
        crate::layout::ensure_dir(&directory)?;
        let data = serde_json::to_vec_pretty(&account)?;
        std::fs::write(self.account_path(name)?, data)?;
        Ok(account)
    }

    pub fn load(&self, player_name: &str) -> Result<LocalOfflineAccount> {
        let name = validate_player_name(player_name)?;
        let path = self.account_path(name)?;
        if !path.exists() {
            return Err(Error::NotFound(format!(
                "local offline account '{name}' does not exist"
            )));
        }
        let data = std::fs::read(&path)?;
        let account: LocalOfflineAccount = serde_json::from_slice(&data).map_err(|e| {
            Error::InvalidMetadata(format!(
                "corrupted local account file {}: {e}",
                path.display()
            ))
        })?;
        if account.identity_mode != super::instance::IdentityMode::LocalOffline {
            return Err(Error::InvalidMetadata(format!(
                "{} is not a local offline account",
                path.display()
            )));
        }
        Ok(account)
    }

    pub fn list(&self) -> Result<Vec<LocalOfflineAccount>> {
        let directory = self.layout.local_accounts_directory();
        if !directory.is_dir() {
            return Ok(Vec::new());
        }
        let mut files: Vec<std::path::PathBuf> = std::fs::read_dir(&directory)?
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("json"))
            .collect();
        files.sort();
        let mut accounts = Vec::new();
        for file in files {
            let data = std::fs::read(&file)?;
            match serde_json::from_slice::<LocalOfflineAccount>(&data) {
                Ok(account)
                    if account.identity_mode == super::instance::IdentityMode::LocalOffline =>
                {
                    accounts.push(account)
                }
                Ok(_) => {}
                Err(e) => {
                    tracing::warn!(path = %file.display(), error = %e, "skipping corrupted local account")
                }
            }
        }
        Ok(accounts)
    }

    pub fn profile(&self, player_name: &str) -> Result<LocalOfflineProfile> {
        Ok(self.load(player_name)?.profile())
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlayerAppearance {
    #[serde(default)]
    pub skin_texture_url: Option<String>,
    #[serde(default)]
    pub cape_texture_url: Option<String>,
    #[serde(default)]
    pub skin_model: Option<String>,
}

/// Non-secret Microsoft account metadata. Tokens live in the OS secret store.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MicrosoftAccount {
    pub id: Uuid,
    pub player_name: String,
    pub xuid: String,
    pub added_at: DateTime<Utc>,
    #[serde(default)]
    pub last_validated_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub owns_game: bool,
    #[serde(default)]
    pub appearance: Option<PlayerAppearance>,
}

pub struct MicrosoftAccountStore {
    layout: GameDataLayout,
}

impl MicrosoftAccountStore {
    pub fn new(layout: GameDataLayout) -> Self {
        Self { layout }
    }

    fn file(&self, id: Uuid) -> std::path::PathBuf {
        self.layout
            .microsoft_accounts_directory()
            .join(format!("{}.json", id.hyphenated()))
    }

    pub fn list(&self) -> Result<Vec<MicrosoftAccount>> {
        let directory = self.layout.microsoft_accounts_directory();
        if !directory.is_dir() {
            return Ok(Vec::new());
        }
        let mut paths: Vec<_> = std::fs::read_dir(&directory)?
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("json"))
            .collect();
        paths.sort();
        let mut accounts = Vec::new();
        for path in paths {
            let data = std::fs::read(&path)?;
            match serde_json::from_slice(&data) {
                Ok(account) => accounts.push(account),
                Err(e) => {
                    tracing::warn!(path = %path.display(), error = %e, "skipping corrupted account")
                }
            }
        }
        Ok(accounts)
    }

    pub fn load(&self, id: Uuid) -> Result<MicrosoftAccount> {
        let path = self.file(id);
        if !path.exists() {
            return Err(Error::NotFound(format!(
                "Microsoft account {id} is not stored locally"
            )));
        }
        Ok(serde_json::from_slice(&std::fs::read(&path)?)?)
    }

    pub fn save(&self, account: &MicrosoftAccount) -> Result<()> {
        crate::layout::ensure_dir(&self.layout.microsoft_accounts_directory())?;
        let data = serde_json::to_vec_pretty(account)?;
        std::fs::write(self.file(account.id), data)?;
        Ok(())
    }

    pub fn delete(&self, id: Uuid) -> Result<()> {
        let path = self.file(id);
        if path.exists() {
            std::fs::remove_file(path)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offline_uuid_matches_java() {
        // UUID.nameUUIDFromBytes("OfflinePlayer:Notch")
        let id = offline_uuid("Notch");
        assert_eq!(id.to_string(), "b50ad385-829d-3141-a216-7e7d7539ba7f");
    }

    #[test]
    fn names_are_validated() {
        assert!(validate_player_name("ab").is_err());
        assert!(validate_player_name("bad name").is_err());
        assert!(validate_player_name("Good_Name1").is_ok());
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AccountKind {
    Microsoft,
    Local,
}

impl AccountKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Microsoft => "microsoft",
            Self::Local => "local",
        }
    }
}

impl std::str::FromStr for AccountKind {
    type Err = Error;

    fn from_str(value: &str) -> Result<Self> {
        match value {
            "microsoft" => Ok(Self::Microsoft),
            "local" | "offline" => Ok(Self::Local),
            other => Err(Error::InvalidMetadata(format!(
                "unknown account kind '{other}'"
            ))),
        }
    }
}

/// Identity selection shared by CLI and GUI: references only, no credentials.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountReference {
    pub kind: AccountKind,
    pub identifier: String,
}

impl AccountReference {
    pub fn storage_key(&self) -> String {
        format!(
            "{}:{}",
            match self.kind {
                AccountKind::Microsoft => "microsoft",
                AccountKind::Local => "local",
            },
            self.identifier
        )
    }
}

/// Persists the active account reference in `<dataRoot>/accounts/active.json`.
pub struct ActiveAccountStore {
    layout: GameDataLayout,
}

impl ActiveAccountStore {
    pub fn new(layout: GameDataLayout) -> Self {
        Self { layout }
    }

    fn file(&self) -> std::path::PathBuf {
        self.layout.accounts_directory().join("active.json")
    }

    pub fn load(&self) -> Option<AccountReference> {
        let data = std::fs::read(self.file()).ok()?;
        serde_json::from_slice(&data).ok()
    }

    pub fn save(&self, reference: Option<&AccountReference>) -> Result<()> {
        match reference {
            Some(reference) => {
                crate::layout::ensure_dir(&self.layout.accounts_directory())?;
                std::fs::write(self.file(), serde_json::to_vec_pretty(reference)?)?;
            }
            None => {
                let path = self.file();
                if path.exists() {
                    std::fs::remove_file(path)?;
                }
            }
        }
        Ok(())
    }
}
