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
    /// An install run has started and not finished yet. A leftover record from
    /// a previous process is detected via [`VersionInstallState::session`] and
    /// settled to [`InstallStatus::Interrupted`] on the next launch.
    Installing,
    /// All planned files verified and natives extracted.
    Complete,
    /// The last install attempt failed partway; cached files are kept.
    Failed,
    /// The user cancelled the install. Already verified files stay cached and
    /// the partial transfer can be resumed by a repair install.
    Cancelled,
    /// The process died (crash, power loss, force quit) while installing, so
    /// the outcome is unknown. Treated like [`InstallStatus::Cancelled`] for
    /// repair purposes but reported differently in the UI.
    Interrupted,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VersionInstallState {
    pub status: InstallStatus,
    pub updated_at: String,
    /// Identifies the process that started an [`InstallStatus::Installing`]
    /// run. When the state file is read by a different process the entry was
    /// left behind by an abnormal exit and never reached a terminal status.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
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

    /// Records a terminal status. The session is dropped: the record no longer
    /// belongs to a live install run.
    pub fn mark(&mut self, version_id: &str, status: InstallStatus) -> Result<()> {
        self.versions.insert(
            version_id.to_string(),
            VersionInstallState {
                status,
                updated_at: chrono::Utc::now().to_rfc3339(),
                session: None,
            },
        );
        Ok(())
    }

    /// Records the start of an install run owned by `session`.
    pub fn begin(&mut self, version_id: &str, session: &str) -> Result<()> {
        self.versions.insert(
            version_id.to_string(),
            VersionInstallState {
                status: InstallStatus::Installing,
                updated_at: chrono::Utc::now().to_rfc3339(),
                session: Some(session.to_string()),
            },
        );
        Ok(())
    }

    /// Marks every install that cannot belong to `session` as interrupted.
    ///
    /// Records written before sessions existed carry `session: None` and are
    /// treated as stale too: a live install always writes its session first.
    /// Returns true when something changed, so the caller can skip the write.
    pub fn settle(&mut self, session: &str) -> bool {
        let mut changed = false;
        for record in self.versions.values_mut() {
            if record.status != InstallStatus::Installing {
                continue;
            }
            if record.session.as_deref() == Some(session) {
                continue;
            }
            record.status = InstallStatus::Interrupted;
            record.session = None;
            record.updated_at = chrono::Utc::now().to_rfc3339();
            changed = true;
        }
        changed
    }

    /// Status of an install that can be resumed by a repair run.
    pub fn needs_repair(&self, version_id: &str) -> bool {
        matches!(
            self.status_of(version_id),
            Some(InstallStatus::Failed | InstallStatus::Cancelled | InstallStatus::Interrupted)
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_layout(name: &str) -> GameDataLayout {
        // Unique per call: the tests in this module run in parallel inside one
        // process, so a pid-only directory would let them overwrite each other.
        let root = std::env::temp_dir().join(format!(
            "lingxi-install-state-test-{}-{name}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|elapsed| elapsed.as_nanos())
                .unwrap_or_default()
        ));
        GameDataLayout::new(root.join("game"), root.join("data"))
    }

    #[test]
    fn state_roundtrip_and_status() {
        let layout = temp_layout("roundtrip");
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
        let layout = temp_layout("malformed");
        let path = layout.install_state_file();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, b"not json").unwrap();
        let state = InstallStateMap::load(&layout);
        assert_eq!(state.status_of("anything"), None);
    }

    #[test]
    fn installs_left_by_another_session_become_interrupted() {
        let layout = temp_layout("settle");
        let mut state = InstallStateMap::load(&layout);
        state.begin("1.21.4", "run-a").unwrap();
        state.mark("1.20.2", InstallStatus::Complete).unwrap();
        state.mark("1.19.4", InstallStatus::Cancelled).unwrap();
        state.save(&layout).unwrap();

        let mut reloaded = InstallStateMap::load(&layout);
        assert!(reloaded.settle("run-b"), "a stale run must be reported");
        assert_eq!(
            reloaded.status_of("1.21.4"),
            Some(InstallStatus::Interrupted)
        );
        assert_eq!(reloaded.status_of("1.20.2"), Some(InstallStatus::Complete));
        assert_eq!(reloaded.status_of("1.19.4"), Some(InstallStatus::Cancelled));
        assert!(!reloaded.settle("run-b"), "settling twice must be a no-op");
        assert!(reloaded.needs_repair("1.21.4"));
        assert!(reloaded.needs_repair("1.19.4"));
        assert!(!reloaded.needs_repair("1.20.2"));
    }

    #[test]
    fn the_live_session_keeps_its_own_install_running() {
        let layout = temp_layout("live");
        let mut state = InstallStateMap::load(&layout);
        state.begin("1.21.4", "run-a").unwrap();
        // Records written by a build from before sessions existed can never be
        // live; they must be settled like any other leftover.
        state.begin("1.20.2", "run-a").unwrap();
        state.versions.get_mut("1.20.2").unwrap().session = None;
        state.save(&layout).unwrap();

        let mut reloaded = InstallStateMap::load(&layout);
        assert!(reloaded.settle("run-a"));
        assert_eq!(
            reloaded.status_of("1.21.4"),
            Some(InstallStatus::Installing)
        );
        assert_eq!(
            reloaded.status_of("1.20.2"),
            Some(InstallStatus::Interrupted)
        );
    }
}
