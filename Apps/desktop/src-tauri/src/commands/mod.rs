pub mod accounts;
pub mod app;
pub mod content;
pub mod diagnostics;
pub mod graphics;
pub mod instances;
pub mod launch;
pub mod performance;
pub mod settings;
pub mod versions;

use std::sync::Arc;

use launcher_core::install::models::{InstallProgressEvent, ProgressSink};
use launcher_core::models::account::LocalOfflineAccount;
use launcher_core::models::instance::{Instance, InstanceManifest};
use serde::Serialize;
use tauri::{AppHandle, Emitter};

pub type CommandResult<T> = Result<T, String>;

pub fn command_error(error: impl std::fmt::Display) -> String {
    error.to_string()
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstanceView {
    pub id: String,
    pub name: String,
    pub display_name: String,
    pub version_id: String,
    pub loader: Option<String>,
    pub loader_version: Option<String>,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub last_launched_at: Option<chrono::DateTime<chrono::Utc>>,
    pub memory_mib: Option<u32>,
    pub jvm_arguments: Option<String>,
    pub mod_count: u32,
    pub resource_pack_count: u32,
    pub shader_count: u32,
    pub path: String,
    pub game_directory: String,
    pub directory: String,
    pub java_runtime: Option<launcher_core::models::instance::JavaRuntimeRecord>,
    pub modpack: Option<InstanceModpackView>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstanceModpackView {
    pub name: String,
    pub version: String,
    pub project_id: Option<String>,
}

impl From<Instance> for InstanceView {
    fn from(instance: Instance) -> Self {
        let path = instance.directory.display().to_string();
        let game_directory = instance.game_directory.display().to_string();
        let directory = instance.directory.display().to_string();
        let mod_count = count_entries(&instance.mods_directory(), "jar")
            + count_entries(&instance.disabled_mods_directory(), "jar");
        let resource_pack_count =
            count_entries(&instance.game_directory.join("resourcepacks"), "zip");
        let shader_count = count_entries(&instance.game_directory.join("shaderpacks"), "zip");

        let modpack = launcher_core::modpack::read_manifest(&instance)
            .ok()
            .map(|manifest| InstanceModpackView {
                name: manifest.name,
                version: manifest.version_id,
                project_id: manifest.project_id,
            });

        let InstanceManifest {
            id,
            display_name,
            version_id,
            created_at,
            last_launched_at,
            memory_mib,
            jvm_arguments,
            java_runtime,
            ..
        } = instance.manifest;
        let version_id = version_id.unwrap_or_default();
        let (loader, loader_version) = loader_from_version(&version_id);
        Self {
            id,
            name: display_name.clone(),
            display_name,
            version_id,
            loader,
            loader_version,
            created_at,
            last_launched_at,
            memory_mib,
            jvm_arguments: jvm_arguments
                .map(|args| args.join("\n"))
                .filter(|value| !value.is_empty()),
            mod_count,
            resource_pack_count,
            shader_count,
            path,
            game_directory,
            directory,
            java_runtime,
            modpack,
        }
    }
}

fn loader_from_version(version_id: &str) -> (Option<String>, Option<String>) {
    if let Some(rest) = version_id.strip_prefix("fabric-loader-") {
        let loader_version = rest
            .rsplit_once('-')
            .map(|(version, _game)| version)
            .unwrap_or(rest);
        return (Some("fabric".into()), Some(loader_version.to_string()));
    }
    if let Some(rest) = version_id.strip_prefix("quilt-loader-") {
        let loader_version = rest
            .rsplit_once('-')
            .map(|(version, _game)| version)
            .unwrap_or(rest);
        return (Some("quilt".into()), Some(loader_version.to_string()));
    }
    if let Some(rest) = version_id.strip_prefix("neoforge-") {
        return (Some("neoforge".into()), Some(rest.to_string()));
    }
    if version_id.contains("-forge-") || version_id.starts_with("forge-") {
        let rest = version_id.rsplit("-forge-").next().unwrap_or(version_id);
        return (Some("forge".into()), Some(rest.to_string()));
    }
    (None, None)
}

fn count_entries(directory: &std::path::Path, extension: &str) -> u32 {
    std::fs::read_dir(directory)
        .map(|entries| {
            entries
                .flatten()
                .filter(|entry| {
                    entry
                        .path()
                        .extension()
                        .and_then(|value| value.to_str())
                        .map(|value| value.eq_ignore_ascii_case(extension))
                        .unwrap_or(false)
                })
                .count() as u32
        })
        .unwrap_or(0)
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaRuntimeView {
    pub path: String,
    pub version: String,
    pub vendor: String,
    pub architecture: String,
    pub major_version: u32,
    pub is_managed: bool,
}

impl From<launcher_core::java::JavaRuntime> for JavaRuntimeView {
    fn from(runtime: launcher_core::java::JavaRuntime) -> Self {
        Self {
            path: runtime.executable.display().to_string(),
            version: runtime.version_string,
            vendor: runtime.vendor,
            architecture: runtime.architecture.jvm_name().to_string(),
            major_version: runtime.major_version,
            is_managed: runtime.is_managed,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountView {
    pub kind: String,
    pub identifier: String,
    pub player_name: String,
    pub uuid: String,
    pub active: bool,
    pub unverified: bool,
    pub skin_texture_url: Option<String>,
    pub cape_texture_url: Option<String>,
    pub skin_model: Option<String>,
    pub owns_game: bool,
}

impl AccountView {
    pub fn local(
        account: &LocalOfflineAccount,
        active: Option<&launcher_core::models::account::AccountReference>,
    ) -> Self {
        let is_active = active
            .map(|reference| {
                reference.kind == launcher_core::models::account::AccountKind::Local
                    && reference
                        .identifier
                        .eq_ignore_ascii_case(&account.player_name)
            })
            .unwrap_or(false);
        Self {
            kind: "local".into(),
            identifier: account.player_name.clone(),
            player_name: account.player_name.clone(),
            uuid: account.offline_uuid.hyphenated().to_string(),
            active: is_active,
            unverified: true,
            skin_texture_url: None,
            cape_texture_url: None,
            skin_model: None,
            owns_game: false,
        }
    }

    pub fn microsoft(
        account: &launcher_core::models::account::MicrosoftAccount,
        active: Option<&launcher_core::models::account::AccountReference>,
    ) -> Self {
        let is_active = active
            .map(|reference| {
                reference.kind == launcher_core::models::account::AccountKind::Microsoft
                    && reference
                        .identifier
                        .eq_ignore_ascii_case(&account.id.to_string())
            })
            .unwrap_or(false);
        let appearance = account.appearance.clone().unwrap_or_default();
        Self {
            kind: "microsoft".into(),
            identifier: account.id.hyphenated().to_string(),
            player_name: account.player_name.clone(),
            uuid: account.id.hyphenated().to_string(),
            active: is_active,
            unverified: false,
            skin_texture_url: appearance.skin_texture_url,
            cape_texture_url: appearance.cape_texture_url,
            skin_model: appearance.skin_model,
            owns_game: account.owns_game,
        }
    }
}

pub(crate) struct TauriProgress {
    app: AppHandle,
}

impl TauriProgress {
    pub fn shared(app: AppHandle) -> Arc<dyn ProgressSink> {
        Arc::new(Self { app })
    }
}

impl ProgressSink for TauriProgress {
    fn emit(&self, event: InstallProgressEvent) {
        let _ = self.app.emit("install-progress", &event);
    }
}
