use launcher_core::install::models::{
    CancelFlag, DownloadSourcePolicy, InstallReport, SharedProgress,
};
use launcher_core::install::vanilla::VanillaInstaller;
use launcher_core::install::LoaderInstaller;
use launcher_core::java::JavaManager;
use launcher_core::models::version::VersionType;
use launcher_core::paths::PathSafety;
use serde::Serialize;
use tauri::{AppHandle, State};

use crate::commands::instances::ensure_instance_exists;
use crate::commands::{command_error, CommandResult, TauriProgress};
use crate::state::AppState;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VersionView {
    pub id: String,
    #[serde(rename = "type")]
    pub version_type: VersionType,
    pub release_time: Option<chrono::DateTime<chrono::Utc>>,
    pub installed: bool,
}

#[tauri::command]
pub fn list_versions(
    state: State<'_, AppState>,
    filter: Option<String>,
) -> CommandResult<Vec<VersionView>> {
    let manifest = state
        .manifest
        .cached_manifest()
        .ok_or_else(|| "版本清单尚未下载，请点击刷新".to_string())?;
    let filter = filter.unwrap_or_else(|| "release".into());
    Ok(manifest
        .versions
        .into_iter()
        .filter(|version| match filter.as_str() {
            "all" => true,
            "snapshot" => matches!(version.version_type, VersionType::Snapshot),
            _ => matches!(version.version_type, VersionType::Release),
        })
        .map(|version| {
            let installed = state
                .layout
                .version_json(&version.id)
                .map(|path| path.is_file())
                .unwrap_or(false);
            VersionView {
                id: version.id,
                version_type: version.version_type,
                release_time: version.release_time,
                installed,
            }
        })
        .collect())
}

#[tauri::command]
pub async fn refresh_versions(state: State<'_, AppState>) -> CommandResult<Vec<VersionView>> {
    state.manifest.manifest(true).await.map_err(command_error)?;
    list_versions(state, Some("release".into()))
}

#[tauri::command]
pub async fn install_version(
    app: AppHandle,
    state: State<'_, AppState>,
    version_id: String,
    instance_id: Option<String>,
    source: Option<String>,
) -> CommandResult<InstallReport> {
    PathSafety::validate_component(&version_id).map_err(command_error)?;
    if let Some(instance) = instance_id.as_deref() {
        ensure_instance_exists(&state, instance).map_err(command_error)?;
    }
    let settings = state.settings_snapshot();
    let policy = source
        .as_deref()
        .map(DownloadSourcePolicy::parse)
        .transpose()
        .map_err(command_error)?
        .unwrap_or_else(|| settings.policy());
    let installer = VanillaInstaller::new(
        state.layout.clone(),
        state.platform.clone(),
        policy,
        settings.mirror(),
    );
    let progress: SharedProgress = TauriProgress::shared(app);
    let mut report = installer
        .install(&version_id, progress, CancelFlag::new())
        .await
        .map_err(command_error)?;
    if let Some(instance_id) = instance_id {
        let instance = state.instances.load(&instance_id).map_err(command_error)?;
        state
            .instances
            .assign_version(&instance, &version_id)
            .map_err(command_error)?;
        report.instance_id = instance_id;
    }
    Ok(report)
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LoaderVersionView {
    pub version: String,
    pub game_version: String,
    pub stable: bool,
}

#[tauri::command]
pub async fn list_loader_versions(
    state: State<'_, AppState>,
    loader: String,
    game_version: String,
) -> CommandResult<Vec<LoaderVersionView>> {
    let installer = LoaderInstaller::new(state.layout.clone()).map_err(command_error)?;
    let versions = match loader.as_str() {
        "fabric" => installer.fabric_versions(&game_version).await,
        "neoforge" => installer.neoforge_versions(&game_version).await,
        _ => return Err(format!("未知的加载器: {loader}")),
    }
    .map_err(command_error)?;
    Ok(versions
        .into_iter()
        .map(|version| LoaderVersionView {
            version: version.version,
            game_version: version.game_version,
            stable: version.stable,
        })
        .collect())
}

#[tauri::command]
pub async fn install_loader(
    app: AppHandle,
    state: State<'_, AppState>,
    loader: String,
    instance_id: String,
    game_version: String,
    loader_version: Option<String>,
) -> CommandResult<launcher_core::install::LoaderInstallResult> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let installer = LoaderInstaller::new(state.layout.clone()).map_err(command_error)?;
    let progress: SharedProgress = TauriProgress::shared(app);
    match loader.as_str() {
        "fabric" => installer
            .install_fabric(
                &instance,
                &game_version,
                loader_version.as_deref(),
                progress,
                CancelFlag::new(),
            )
            .await
            .map_err(command_error),
        "neoforge" => {
            let java = instance
                .manifest
                .java_runtime
                .as_ref()
                .map(|runtime| std::path::PathBuf::from(&runtime.executable))
                .filter(|path| path.is_file())
                .or_else(|| {
                    JavaManager::new(state.layout.clone())
                        .find(21)
                        .map(|runtime| runtime.executable)
                })
                .unwrap_or_else(|| {
                    std::path::PathBuf::from(if cfg!(windows) { "java.exe" } else { "java" })
                });
            let Some(loader_version) = loader_version else {
                return Err("NeoForge 需要指定加载器版本".into());
            };
            installer
                .install_neoforge(
                    &instance,
                    &game_version,
                    &loader_version,
                    &java,
                    progress,
                    CancelFlag::new(),
                )
                .await
                .map_err(command_error)
        }
        _ => Err(format!("未知的加载器: {loader}")),
    }
}
