use launcher_core::install::models::{
    CancelFlag, DownloadSourcePolicy, InstallReport, SharedProgress,
};
use launcher_core::install::vanilla::VanillaInstaller;
use launcher_core::java::JavaManager;
use launcher_core::models::version::VersionType;
use launcher_core::paths::PathSafety;
use serde::Serialize;
use tauri::{AppHandle, State};

use crate::commands::instances::ensure_instance_exists;
use crate::commands::{command_error, CommandResult, TauriProgress};
use crate::state::AppState;

/// Releases an install task slot on every exit path, including the early
/// returns that bail out before the installer even starts. Without this a
/// single metadata error would keep the version "installing" until restart.
struct InstallTaskGuard<'a> {
    installs: &'a std::sync::Mutex<std::collections::HashMap<String, crate::state::InstallTask>>,
    key: String,
}

impl Drop for InstallTaskGuard<'_> {
    fn drop(&mut self) {
        if let Ok(mut installs) = self.installs.lock() {
            installs.remove(&self.key);
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VersionView {
    pub id: String,
    #[serde(rename = "type")]
    pub version_type: VersionType,
    pub release_time: Option<chrono::DateTime<chrono::Utc>>,
    pub installed: bool,
    /// P0-3: "installing" / "failed" / "complete" or null when never installed,
    /// so the GUI can offer a repair install for partial downloads.
    pub install_status: Option<launcher_core::install::InstallStatus>,
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
    let install_state = launcher_core::install::InstallStateMap::load(&state.layout);
    Ok(manifest
        .versions
        .into_iter()
        .filter(|version| match filter.as_str() {
            "all" => true,
            "snapshot" => matches!(version.version_type, VersionType::Snapshot),
            _ => matches!(version.version_type, VersionType::Release),
        })
        .map(|version| {
            // P0-3: only the persistent install-state record counts as
            // installed; a version JSON in the cache merely means metadata
            // was fetched and must not produce a false "installed" badge.
            let installed = install_state.is_complete(&version.id)
                && state
                    .layout
                    .version_json(&version.id)
                    .map(|path| path.is_file())
                    .unwrap_or(false);
            let install_status = install_state.status_of(&version.id);
            VersionView {
                id: version.id,
                version_type: version.version_type,
                release_time: version.release_time,
                installed,
                install_status,
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
    let progress: SharedProgress = TauriProgress::shared(app, version_id.clone());
    // P1-5: register the task so the GUI can cancel it; refuse concurrent
    // installs of the same version instead of silently racing two runs.
    {
        let mut installs = state.installs.lock().expect("installs lock");
        if installs.contains_key(&version_id) {
            return Err(format!("版本 {version_id} 已有安装任务进行中"));
        }
        installs.insert(
            version_id.clone(),
            crate::state::InstallTask {
                key: version_id.clone(),
                version_id: version_id.clone(),
                instance_id: instance_id.clone(),
                started_at: chrono::Utc::now(),
                cancel: CancelFlag::new(),
            },
        );
    }
    let cancel = {
        let installs = state.installs.lock().expect("installs lock");
        installs
            .get(&version_id)
            .map(|task| task.cancel.clone())
            .expect("install task just inserted")
    };
    let _task = InstallTaskGuard {
        installs: &state.installs,
        key: version_id.clone(),
    };
    // P0-3: record the install lifecycle so partial installs are visible and
    // repairable instead of looking "installed".
    let mut install_state = launcher_core::install::InstallStateMap::load(&state.layout);
    install_state
        .mark(
            &version_id,
            launcher_core::install::InstallStatus::Installing,
        )
        .map_err(command_error)?;
    install_state.save(&state.layout).map_err(command_error)?;
    let started = std::time::Instant::now();
    crate::logging::info(format!("install {version_id}: started"));
    let result = installer.install(&version_id, progress, cancel).await;
    match &result {
        Ok(report) => crate::logging::timed(
            &format!("install {version_id}"),
            started,
            &format!(
                "{} files, {} bytes, {} cache hits, complete={}",
                report.downloaded_files,
                report.downloaded_bytes,
                report.cache_hits,
                report.is_complete()
            ),
        ),
        Err(error) => crate::logging::error(format!(
            "install {version_id} failed after {:.1}s: {error}",
            started.elapsed().as_secs_f64()
        )),
    }
    match &result {
        Ok(_) => {
            install_state
                .mark(&version_id, launcher_core::install::InstallStatus::Complete)
                .map_err(command_error)?;
            install_state.save(&state.layout).map_err(command_error)?;
        }
        Err(_) => {
            install_state
                .mark(&version_id, launcher_core::install::InstallStatus::Failed)
                .map_err(command_error)?;
            install_state.save(&state.layout).map_err(command_error)?;
        }
    }
    let mut report = result.map_err(command_error)?;
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

/// P1-5: request cancellation of an in-flight install. The flag is checked
/// between files and inside every transfer loop, so the task stops promptly
/// while keeping already-verified cache files.
#[tauri::command]
pub fn cancel_install(state: State<'_, AppState>, version_id: String) -> CommandResult<bool> {
    let matched = {
        let installs = state.installs.lock().expect("installs lock");
        installs
            .values()
            .filter(|task| task.matches(&version_id))
            .map(|task| {
                task.cancel.cancel();
                task.key.clone()
            })
            .collect::<Vec<_>>()
    };
    crate::logging::info(format!(
        "cancel_install({version_id}): matched {} task(s) {:?}",
        matched.len(),
        matched
    ));
    Ok(!matched.is_empty())
}

/// P1-5: which install tasks are currently running (for UI state restore).
#[tauri::command]
pub fn list_install_tasks(state: State<'_, AppState>) -> CommandResult<Vec<String>> {
    let installs = state.installs.lock().expect("installs lock");
    Ok(installs.keys().cloned().collect())
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
    let installer = crate::commands::loader_installer(&state)?;
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
    let installer = crate::commands::loader_installer(&state)?;
    // P1-5: loader installs are keyed by instance (one loader per instance) and
    // share the same registry as vanilla installs, so they can be cancelled.
    let task_key = format!("loader:{instance_id}");
    let cancel = {
        let mut installs = state.installs.lock().expect("installs lock");
        if installs.contains_key(&task_key) {
            return Err(format!("实例 {instance_id} 已有安装任务进行中"));
        }
        let flag = CancelFlag::new();
        installs.insert(
            task_key.clone(),
            crate::state::InstallTask {
                key: task_key.clone(),
                version_id: game_version.clone(),
                instance_id: Some(instance_id.clone()),
                started_at: chrono::Utc::now(),
                cancel: flag.clone(),
            },
        );
        flag
    };
    let _task = InstallTaskGuard {
        installs: &state.installs,
        key: task_key.clone(),
    };
    let progress: SharedProgress = TauriProgress::shared(app, task_key.clone());
    let result = match loader.as_str() {
        "fabric" => installer
            .install_fabric(
                &instance,
                &game_version,
                loader_version.as_deref(),
                progress,
                cancel.clone(),
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
                    cancel.clone(),
                )
                .await
                .map_err(command_error)
        }
        _ => Err(format!("未知的加载器: {loader}")),
    };
    match &result {
        Ok(_) => crate::logging::timed(
            &format!("loader install {task_key}"),
            std::time::Instant::now(),
            &format!("{} {game_version}", loader),
        ),
        Err(error) => crate::logging::error(format!("loader install {task_key} failed: {error}")),
    }
    result
}
