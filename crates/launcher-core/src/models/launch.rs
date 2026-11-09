use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::instance::IdentityMode;
use crate::platform::PlatformContext;

pub const LAUNCHER_NAME: &str = "LingXi Launcher";
pub const LAUNCHER_VERSION: &str = env!("CARGO_PKG_VERSION");
pub const REDACTION_PLACEHOLDER: &str = "<redacted>";

#[derive(Debug, Clone)]
pub struct LaunchIdentity {
    pub mode: IdentityMode,
    pub player_name: String,
    pub uuid: Uuid,
    /// Microsoft access token. Never serialized or logged.
    pub access_token: Option<String>,
    pub xuid: Option<String>,
    pub user_type: String,
}

impl LaunchIdentity {
    pub fn local_offline(profile: &super::account::LocalOfflineProfile) -> Self {
        Self {
            mode: IdentityMode::LocalOffline,
            player_name: profile.player_name.clone(),
            uuid: profile.stable_offline_uuid,
            access_token: None,
            xuid: None,
            user_type: "legacy".into(),
        }
    }

    pub fn microsoft(account: &super::account::MicrosoftAccount, access_token: String) -> Self {
        Self {
            mode: IdentityMode::Microsoft,
            player_name: account.player_name.clone(),
            uuid: account.id,
            access_token: Some(access_token),
            xuid: Some(account.xuid.clone()),
            user_type: "msa".into(),
        }
    }

    pub fn display_name(&self) -> String {
        match self.mode {
            IdentityMode::Microsoft => format!("Microsoft ({})", self.player_name),
            IdentityMode::LicensedOffline => format!("Licensed offline ({})", self.player_name),
            IdentityMode::LocalOffline => format!("Local offline / unverified ({})", self.player_name),
        }
    }

    pub fn uuid_argument(&self) -> String {
        self.uuid.simple().to_string().to_lowercase()
    }
}

#[derive(Debug, Clone)]
pub struct LaunchContext {
    pub instance_directory: PathBuf,
    pub game_directory: PathBuf,
    pub java_executable: PathBuf,
    pub platform: PlatformContext,
    pub identity: LaunchIdentity,
    pub additional_jvm_arguments: Vec<String>,
    pub features: BTreeMap<String, bool>,
    pub quick_play_singleplayer: Option<String>,
    pub launcher_name: String,
    pub launcher_version: String,
}

impl LaunchContext {
    pub fn new(instance_directory: PathBuf, game_directory: PathBuf, java: PathBuf, platform: PlatformContext, identity: LaunchIdentity) -> Self {
        Self {
            instance_directory,
            game_directory,
            java_executable: java,
            platform,
            identity,
            additional_jvm_arguments: Vec::new(),
            features: BTreeMap::new(),
            quick_play_singleplayer: None,
            launcher_name: LAUNCHER_NAME.to_string(),
            launcher_version: LAUNCHER_VERSION.to_string(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct LaunchPlan {
    pub java_executable: PathBuf,
    pub arguments: Vec<String>,
    pub redacted_arguments: Vec<String>,
    pub working_directory: PathBuf,
    pub environment_overrides: BTreeMap<String, String>,
    pub version_id: String,
    pub identity_mode: IdentityMode,
}

impl LaunchPlan {
    pub fn redacted_summary(&self) -> String {
        format!(
            "<LaunchPlan version={} identity={} java={} arguments=<redacted, count={}>>",
            self.version_id,
            self.identity_mode.as_str(),
            self.java_executable.display(),
            self.arguments.len()
        )
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MissingDependency {
    pub name: String,
    pub reason: String,
    #[serde(default)]
    pub relative_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchDiagnostic {
    pub severity: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchPreview {
    pub identity_mode: IdentityMode,
    pub identity_display_name: String,
    pub version_id: String,
    pub java_executable: PathBuf,
    pub main_class: String,
    pub classpath_entry_count: usize,
    pub classpath_entries: Vec<String>,
    pub game_directory: PathBuf,
    pub jvm_arguments: Vec<String>,
    pub game_arguments: Vec<String>,
    pub missing_dependencies: Vec<MissingDependency>,
    pub diagnostics: Vec<LaunchDiagnostic>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ExitReason {
    Exited,
    Signalled,
    Cancelled,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GameExit {
    pub code: Option<i32>,
    pub reason: ExitReason,
    pub signal: Option<i32>,
    pub is_success: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum GameProcessEvent {
    Stdout { line: String },
    Stderr { line: String },
    Exited { exit: GameExit },
}
