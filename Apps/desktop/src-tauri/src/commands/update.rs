use serde::{Deserialize, Serialize};
use tauri::State;

use crate::commands::CommandResult;
use crate::state::{AppState, UpdateChannel};
use launcher_core::models::launch::LAUNCHER_NAME;

const RELEASES_URL: &str = "https://api.github.com/repos/LingXiFox/LingXiLauncher/releases";

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateInfo {
    current_version: &'static str,
    release: Option<UpdateRelease>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct UpdateRelease {
    version: String,
    url: String,
    notes: Option<String>,
    published_at: Option<String>,
}

#[tauri::command]
pub async fn check_update(state: State<'_, AppState>) -> CommandResult<UpdateInfo> {
    let channel = state.settings_snapshot().effective_update_channel();
    let current_version = env!("CARGO_PKG_VERSION");
    let current = ReleaseVersion::parse(current_version)
        .ok_or_else(|| format!("无法识别当前版本: {current_version}"))?;
    let client = launcher_core::net::client_builder()
        .user_agent(format!("{LAUNCHER_NAME}/{current_version}"))
        .connect_timeout(std::time::Duration::from_secs(15))
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|error| format!("无法创建更新检查客户端: {error}"))?;
    let mut best = None;
    for page in 1.. {
        let response = client
            .get(RELEASES_URL)
            .query(&[("per_page", 100), ("page", page)])
            .header("Accept", "application/vnd.github+json")
            .send()
            .await
            .map_err(|error| format!("无法连接 GitHub: {error}"))?;
        if !response.status().is_success() {
            return Err(format!("GitHub 返回 {}", response.status().as_u16()));
        }
        let has_next = response
            .headers()
            .get("link")
            .and_then(|header| header.to_str().ok())
            .is_some_and(|links| links.contains("rel=\"next\""));
        let releases: Vec<GitHubRelease> = response
            .json()
            .await
            .map_err(|error| format!("无法解析 GitHub 响应: {error}"))?;
        best = best_release(releases, current, channel, best);
        if !has_next {
            break;
        }
    }
    Ok(UpdateInfo {
        current_version,
        release: best.map(|(_, release)| UpdateRelease {
            version: release.tag_name[1..].to_owned(),
            url: release.html_url,
            notes: release.body.filter(|text| !text.trim().is_empty()),
            published_at: release.published_at,
        }),
    })
}

#[derive(Debug, Deserialize)]
struct GitHubRelease {
    tag_name: String,
    html_url: String,
    body: Option<String>,
    published_at: Option<String>,
    draft: bool,
    prerelease: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct ReleaseVersion {
    core: [u64; 3],
    channel: UpdateChannel,
    sequence: u64,
}

impl ReleaseVersion {
    fn parse(version: &str) -> Option<Self> {
        fn number(part: &str) -> Option<u64> {
            let value: u64 = part.parse().ok()?;
            (value.to_string() == part).then_some(value)
        }

        let (core, channel, sequence) = match version.split_once('-') {
            Some((core, suffix)) => {
                let (name, sequence) = suffix.split_once('.')?;
                let channel = match name {
                    "beta" => UpdateChannel::Beta,
                    "rc" => UpdateChannel::Rc,
                    _ => return None,
                };
                let sequence = number(sequence).filter(|sequence| *sequence > 0)?;
                (core, channel, sequence)
            }
            None => (version, UpdateChannel::Stable, 0),
        };
        let mut parts = core.split('.');
        let core = [
            number(parts.next()?)?,
            number(parts.next()?)?,
            number(parts.next()?)?,
        ];
        parts.next().is_none().then_some(Self {
            core,
            channel,
            sequence,
        })
    }
}

fn best_release(
    releases: Vec<GitHubRelease>,
    current: ReleaseVersion,
    channel: UpdateChannel,
    mut best: Option<(ReleaseVersion, GitHubRelease)>,
) -> Option<(ReleaseVersion, GitHubRelease)> {
    for release in releases {
        let Some(version) = release
            .tag_name
            .strip_prefix('v')
            .and_then(ReleaseVersion::parse)
        else {
            continue;
        };
        if !release.draft
            && release.prerelease == (version.channel != UpdateChannel::Stable)
            && version.channel >= channel
            && version > current
            && best
                .as_ref()
                .is_none_or(|(previous, _)| version > *previous)
        {
            best = Some((version, release));
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::Settings;

    fn release(tag: &str) -> GitHubRelease {
        GitHubRelease {
            tag_name: tag.into(),
            html_url: String::new(),
            body: None,
            published_at: None,
            draft: false,
            prerelease: tag.contains('-'),
        }
    }

    #[test]
    fn legacy_settings_follow_the_build_until_a_channel_is_saved() {
        let mut settings: Settings = serde_json::from_str(r#"{"defaultMemoryMib":4096}"#).unwrap();
        let installed = ReleaseVersion::parse(env!("CARGO_PKG_VERSION"))
            .unwrap()
            .channel;
        assert_eq!(settings.effective_update_channel(), installed);
        assert_eq!(settings.default_memory_mib, 4096);
        assert!(serde_json::to_value(&settings)
            .unwrap()
            .get("updateChannel")
            .is_none());
        let selected = if installed == UpdateChannel::Stable {
            UpdateChannel::Beta
        } else {
            UpdateChannel::Stable
        };
        settings.update_channel = Some(selected);
        let saved: Settings =
            serde_json::from_value(serde_json::to_value(&settings).unwrap()).unwrap();
        assert_eq!(saved.effective_update_channel(), selected);
    }

    #[test]
    fn orders_supported_versions_and_rejects_other_tags() {
        let ordered = [
            "0.10.0-beta.2",
            "0.10.0-beta.10",
            "0.10.0-rc.1",
            "0.10.0-rc.2",
            "0.10.0",
            "0.10.1-beta.1",
        ];
        assert!(ordered
            .windows(2)
            .all(|pair| ReleaseVersion::parse(pair[0]).unwrap()
                < ReleaseVersion::parse(pair[1]).unwrap()));
        for version in [
            "0.10",
            "0.10.0.1",
            "0.010.0",
            "0.10.0-alpha.1",
            "0.10.0-beta.0",
            "0.10.0-rc.01",
            "0.10.0+build",
        ] {
            assert!(ReleaseVersion::parse(version).is_none(), "{version}");
        }
    }

    #[test]
    fn filters_channels_and_keeps_the_highest_candidate_across_pages() {
        let installed = ReleaseVersion::parse("0.10.0-beta.4").unwrap();
        let releases = || {
            let mut draft = release("v1.0.0");
            draft.draft = true;
            let mut mislabeled = release("v2.0.0");
            mislabeled.prerelease = true;
            vec![
                release("v0.10.1-rc.2"),
                draft,
                release("v0.10.2-beta.1"),
                release("v0.10.0"),
                mislabeled,
            ]
        };
        for (channel, expected) in [
            (UpdateChannel::Stable, "v0.10.0"),
            (UpdateChannel::Rc, "v0.10.1-rc.2"),
            (UpdateChannel::Beta, "v0.10.2-beta.1"),
        ] {
            let best = best_release(releases(), installed, channel, None);
            let (_, selected) =
                best_release(vec![release("v0.10.0-beta.3")], installed, channel, best).unwrap();
            assert_eq!(selected.tag_name, expected);
        }
        assert!(best_release(
            vec![release("v0.10.0")],
            ReleaseVersion::parse("0.10.1-beta.1").unwrap(),
            UpdateChannel::Stable,
            None
        )
        .is_none());
    }
}
