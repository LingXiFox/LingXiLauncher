//! Persistent installation state per version.
//!
//! The version JSON arriving in the cache only means metadata was fetched,
//! not that the game is playable. This module records the real lifecycle
//! (installing / complete / failed) so the GUI can label versions honestly
//! and offer a repair path for partial installs, without re-scanning or
//! hashing every file on each version list refresh.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::error::Result;
use crate::layout::GameDataLayout;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum InstallStatus {
    /// An install run has started and not finished yet (crash or power loss
    /// leaves this state behind; the version then needs a repair install).
    Installing,
    /// All planned files verified and natives extracted.
    Complete,
    /// The last install attempt failed partway; cached files are kept.
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VersionInstallState {
    pub status: InstallStatus,
    pub updated_at: String,
}

/// File layout: version id maps to status + updatedAt.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallStateMap {
    #[serde(flatten)]
    pub versions: BTreeMap<String, VersionInstallState>,
}

impl InstallStateMap {
    pub fn load(layout: &GameDataLayout) -> Self {
        let path = layout.install_state_file();
        let Ok(data) = std::fs::read(&path) else {
            return Self::default();
        };
        serde_json::from_slice(&data).unwrap_or_default()
    }

    pub fn save(&self, layout: &GameDataLayout) -> Result<()> {
        let path = layout.install_state_file();
        if let Some(parent) = path.parent() {
            crate::layout::ensure_dir(parent)?;
        }
        let data = serde_json::to_vec_pretty(self)?;
        let temporary = path.with_extension("json.part");
        std::fs::write(&temporary, data)?;
        std::fs::rename(&temporary, &path)?;
        Ok(())
    }

    pub fn status_of(&self, version_id: &str) -> Option<InstallStatus> {
        self.versions.get(version_id).map(|s| s.status)
    }

    pub fn is_complete(&self, version_id: &str) -> bool {
        self.status_of(version_id) == Some(InstallStatus::Complete)
    }

    pub fn mark(&mut self, version_id: &str, status: InstallStatus) -> Result<()> {
        self.versions.insert(
            version_id.to_string(),
            VersionInstallState {
                status,
                updated_at: chrono::Utc::now().to_rfc3339(),
            },
        );
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_layout() -> GameDataLayout {
        let root =
            std::env::temp_dir().join(format!("lingxi-install-state-test-{}", std::process::id()));
        GameDataLayout::new(root.join("game"), root.join("data"))
    }

    #[test]
    fn state_roundtrip_and_status() {
        let layout = temp_layout();
        let mut state = InstallStateMap::load(&layout);
        assert!(!state.is_complete("1.21.4"));

        state.mark("1.21.4", InstallStatus::Installing).unwrap();
        state.mark("1.20.2", InstallStatus::Complete).unwrap();
        state.save(&layout).unwrap();

        let reloaded = InstallStateMap::load(&layout);
        assert_eq!(reloaded.status_of("1.20.2"), Some(InstallStatus::Complete));
        assert_eq!(
            reloaded.status_of("1.21.4"),
            Some(InstallStatus::Installing)
        );
        assert!(reloaded.is_complete("1.20.2"));
        assert!(!reloaded.is_complete("1.21.4"));
    }

    #[test]
    fn malformed_file_falls_back_to_default() {
        let layout = temp_layout();
        let path = layout.install_state_file();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, b"not json").unwrap();
        let state = InstallStateMap::load(&layout);
        assert_eq!(state.status_of("anything"), None);
    }
}
