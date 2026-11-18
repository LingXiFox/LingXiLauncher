//! GitHub Release update check (requirement: no silent self-update).
//!
//! The launcher only *reports* the newest published release. Downloading and
//! installing stays a deliberate user action in the browser so no unsigned
//! binary is ever executed automatically.

use serde::Serialize;

use crate::commands::CommandResult;

const RELEASES_URL: &str = "https://api.github.com/repos/LingXiFox/LingXiLauncher/releases/latest";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateInfo {
    pub current_version: String,
    pub latest_version: String,
    pub release_url: String,
    pub release_notes: Option<String>,
    pub published_at: Option<String>,
    pub available: bool,
}

#[tauri::command]
pub async fn check_update() -> CommandResult<UpdateInfo> {
    let client = launcher_core::net::client_builder()
        .user_agent(format!(
            "{}/{}",
            launcher_core::models::launch::LAUNCHER_NAME,
            launcher_core::models::launch::LAUNCHER_VERSION
        ))
        .connect_timeout(std::time::Duration::from_secs(15))
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|error| format!("无法创建更新检查客户端: {error}"))?;
    let response = client
        .get(RELEASES_URL)
        .header("Accept", "application/vnd.github+json")
        .send()
        .await
        .map_err(|error| format!("无法连接 GitHub: {error}"))?;
    if !response.status().is_success() {
        return Err(format!("GitHub 返回 {}", response.status().as_u16()));
    }
    let release: GitHubRelease = response
        .json()
        .await
        .map_err(|error| format!("无法解析 GitHub 响应: {error}"))?;
    let current = env!("CARGO_PKG_VERSION").to_string();
    let latest = release.tag_name.trim_start_matches('v').to_string();
    Ok(UpdateInfo {
        available: is_newer(&latest, &current),
        current_version: current,
        latest_version: latest,
        release_url: release.html_url,
        release_notes: release.body.filter(|text| !text.trim().is_empty()),
        published_at: release.published_at,
    })
}

#[derive(Debug, serde::Deserialize)]
struct GitHubRelease {
    tag_name: String,
    html_url: String,
    body: Option<String>,
    published_at: Option<String>,
}

/// Numeric, dot separated comparison. Pre-release suffixes are ignored so a
/// `0.11.0-rc.1` tag still counts as newer than `0.10.0`.
fn is_newer(candidate: &str, current: &str) -> bool {
    fn parts(value: &str) -> Vec<u64> {
        value
            .split(['.', '-', '+'])
            .map_while(|part| part.parse::<u64>().ok())
            .collect()
    }
    let left = parts(candidate);
    let right = parts(current);
    if left.is_empty() || right.is_empty() {
        return false;
    }
    let width = left.len().max(right.len());
    for index in 0..width {
        let a = left.get(index).copied().unwrap_or(0);
        let b = right.get(index).copied().unwrap_or(0);
        if a != b {
            return a > b;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::is_newer;

    #[test]
    fn newer_versions_are_detected_numerically() {
        assert!(is_newer("0.11.0", "0.10.0"));
        assert!(is_newer("0.10.1", "0.10.0"));
        assert!(is_newer("1.0.0", "0.99.9"));
        assert!(!is_newer("0.10.0", "0.10.0"));
        assert!(!is_newer("0.9.9", "0.10.0"));
    }
}
