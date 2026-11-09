use std::collections::{BTreeSet, HashMap};
use std::path::Path;

use launcher_core::install::models::{CancelFlag, SharedProgress};
use launcher_core::install::vanilla::VanillaInstaller;
use launcher_core::install::LoaderInstaller;
use launcher_core::java::JavaManager;
use launcher_core::modpack;
use launcher_core::modrinth::{ModrinthClient, SearchQuery};
use launcher_core::mods::{InstalledMod, ModManager, ModSource};
use launcher_core::resourcepacks::ResourcePackManager;
use launcher_core::shaders::ShaderPackManager;
use launcher_core::worlds::{WorldBackup, WorldManager, WorldSummary};
use serde::Serialize;
use tauri::{AppHandle, State};

use crate::commands::{command_error, CommandResult, InstanceView, TauriProgress};
use crate::state::AppState;

/* ------------------------------- mods -------------------------------- */
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstalledModView {
    pub project_id: String,
    pub name: String,
    pub version_id: Option<String>,
    pub version_number: Option<String>,
    pub file_name: Option<String>,
    pub enabled: bool,
    pub update_available: bool,
    pub latest_version_id: Option<String>,
    pub latest_version_number: Option<String>,
    pub icon_url: Option<String>,
    pub description: Option<String>,
}

impl InstalledModView {
    fn from_mod(item: &InstalledMod) -> Self {
        let fallback = item.file_name.trim_end_matches(".jar").to_string();
        Self {
            project_id: if item.project_id.is_empty() {
                item.slug.clone()
            } else {
                item.project_id.clone()
            },
            name: if item.title.trim().is_empty() {
                fallback
            } else {
                item.title.clone()
            },
            version_id: non_empty(&item.version_id),
            version_number: non_empty(&item.version_number),
            file_name: non_empty(&item.file_name),
            enabled: item.enabled,
            update_available: false,
            latest_version_id: None,
            latest_version_number: None,
            icon_url: non_empty(&item.icon_url),
            description: None,
        }
    }
}

fn non_empty(value: &str) -> Option<String> {
    (!value.trim().is_empty()).then(|| value.to_string())
}

fn show_update(view: &mut InstalledModView, update: &launcher_core::mods::ModUpdate) {
    view.update_available = true;
    view.latest_version_id = non_empty(update.latest_version_id.as_str())
        .or_else(|| non_empty(update.latest_version.id.as_str()));
    view.latest_version_number = non_empty(update.latest_version_number.as_str())
        .or_else(|| non_empty(update.latest_version.version_number.as_str()));
    if view.icon_url.is_none() {
        view.icon_url = non_empty(&update.icon_url);
    }
    if view.name.is_empty() {
        view.name = update.title.clone();
    }
}

#[tauri::command]
pub fn list_mods(
    state: State<'_, AppState>,
    instance_id: String,
) -> CommandResult<Vec<InstalledModView>> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let manager = ModManager::new(instance, state.layout.clone()).map_err(command_error)?;
    let mods = manager.list().map_err(command_error)?;
    Ok(mods.iter().map(InstalledModView::from_mod).collect())
}

#[tauri::command]
pub async fn search_modrinth(
    query: String,
    game_version: Option<String>,
    loader: Option<String>,
    limit: Option<u32>,
    offset: Option<u32>,
) -> CommandResult<launcher_core::modrinth::SearchResponse> {
    let client = ModrinthClient::new().map_err(command_error)?;
    let mut search = SearchQuery::new(query)
        .with_limit(limit.unwrap_or(20))
        .with_offset(offset.unwrap_or(0));
    if let Some(version) = game_version.filter(|value| !value.trim().is_empty()) {
        search = search.facet("versions", [version]);
    }
    if let Some(loader) = loader.filter(|value| !value.trim().is_empty()) {
        search = search.facet("categories", [loader.to_ascii_lowercase()]);
    }
    client.search(&search).await.map_err(command_error)
}

#[tauri::command]
pub async fn install_mod(
    state: State<'_, AppState>,
    instance_id: String,
    version_id: String,
) -> CommandResult<InstalledModView> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let manager = ModManager::new(instance, state.layout.clone()).map_err(command_error)?;
    let client = ModrinthClient::new().map_err(command_error)?;
    let version = client.version(&version_id).await.map_err(command_error)?;
    let installed = manager
        .install_version(&version)
        .await
        .map_err(command_error)?;
    Ok(InstalledModView::from_mod(&installed))
}

#[tauri::command]
pub fn toggle_mod(
    state: State<'_, AppState>,
    instance_id: String,
    project_id: String,
    enabled: bool,
) -> CommandResult<()> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let manager = ModManager::new(instance, state.layout.clone()).map_err(command_error)?;
    manager
        .set_enabled(&project_id, enabled)
        .map_err(command_error)?;
    Ok(())
}

#[tauri::command]
pub fn delete_mod(
    state: State<'_, AppState>,
    instance_id: String,
    project_id: String,
) -> CommandResult<()> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let manager = ModManager::new(instance, state.layout.clone()).map_err(command_error)?;
    manager.remove(&project_id).map_err(command_error)?;
    Ok(())
}

#[tauri::command]
pub async fn check_mod_updates(
    state: State<'_, AppState>,
    instance_id: String,
) -> CommandResult<Vec<InstalledModView>> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let manager = ModManager::new(instance, state.layout.clone()).map_err(command_error)?;
    let mods = manager.list().map_err(command_error)?;
    let updates = manager.check_updates().await.map_err(command_error)?;
    let by_project: HashMap<&str, &launcher_core::mods::ModUpdate> = updates
        .iter()
        .map(|update| (update.project_id.as_str(), update))
        .collect();
    Ok(mods
        .iter()
        .map(|item| {
            let mut view = InstalledModView::from_mod(item);
            if let Some(update) = by_project.get(view.project_id.as_str()) {
                show_update(&mut view, update);
            }
            view
        })
        .collect())
}

#[tauri::command]
pub async fn update_mod(
    state: State<'_, AppState>,
    instance_id: String,
    project_id: String,
) -> CommandResult<InstalledModView> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let manager = ModManager::new(instance, state.layout.clone()).map_err(command_error)?;
    let updates = manager.check_updates().await.map_err(command_error)?;
    let update = updates
        .iter()
        .find(|update| update.project_id == project_id)
        .ok_or_else(|| "没有找到该模组的可用更新".to_string())?;
    let installed = manager.apply_update(update).await.map_err(command_error)?;
    Ok(InstalledModView::from_mod(&installed))
}

#[allow(dead_code)]
pub(crate) fn install_local_mod(
    state: &AppState,
    instance_id: &str,
    path: &Path,
) -> CommandResult<InstalledModView> {
    let instance = state.instances.load(instance_id).map_err(command_error)?;
    let manager = ModManager::new(instance, state.layout.clone()).map_err(command_error)?;
    let installed = manager
        .install_file(path, ModSource::Manual)
        .map_err(command_error)?;
    Ok(InstalledModView::from_mod(&installed))
}

/* ------------------------------ modpacks ------------------------------ */

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MrpackSummaryView {
    pub name: String,
    pub version: Option<String>,
    pub author: Option<String>,
    pub description: Option<String>,
    pub mod_count: usize,
    pub minecraft_version: Option<String>,
    pub loader: Option<String>,
    pub files: Vec<MrpackFileView>,
    pub path: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MrpackFileView {
    pub path: String,
    pub size: Option<u64>,
}

#[tauri::command]
pub fn inspect_mrpack(path: String) -> CommandResult<MrpackSummaryView> {
    let archive = Path::new(&path);
    if !archive.is_file() {
        return Err("整合包文件不存在".into());
    }
    let summary = modpack::inspect(archive).map_err(command_error)?;
    let minecraft = summary.dependencies.get("minecraft").cloned();
    let loader = summary
        .dependencies
        .keys()
        .find(|key| {
            matches!(
                key.as_str(),
                "fabric-loader" | "quilt-loader" | "forge" | "neoforge"
            )
        })
        .cloned();
    Ok(MrpackSummaryView {
        name: summary.name,
        version: non_empty(&summary.version_id),
        author: None,
        description: non_empty(&summary.summary),
        mod_count: summary.file_count,
        minecraft_version: minecraft,
        loader,
        files: Vec::new(),
        path,
    })
}

#[tauri::command]
pub async fn import_mrpack(
    app: AppHandle,
    state: State<'_, AppState>,
    path: String,
    name: Option<String>,
) -> CommandResult<InstanceView> {
    let archive = Path::new(&path);
    if !archive.is_file() {
        return Err("整合包文件不存在".into());
    }
    if archive
        .extension()
        .and_then(|value| value.to_str())
        .map(|value| value.eq_ignore_ascii_case("mrpack"))
        != Some(true)
    {
        return Err("请选择 .mrpack 整合包文件".into());
    }
    let summary = modpack::inspect(archive).map_err(command_error)?;
    if let Some(loader) = modpack::resolve_loader(&summary.dependencies) {
        if !matches!(loader.kind.modrinth_loader(), "fabric" | "neoforge") {
            return Err(format!(
                "整合包使用 {} 加载器，目前仅支持 Fabric 与 NeoForge",
                loader.kind.modrinth_loader()
            ));
        }
    }
    let progress: SharedProgress = TauriProgress::shared(app.clone());
    let label = name.unwrap_or_default();
    let mut instance = modpack::install(archive, &label, &state.layout, Some(progress), None)
        .await
        .map_err(command_error)?;
    let manifest = modpack::read_manifest(&instance).map_err(command_error)?;
    let game_version = manifest
        .dependencies
        .get("minecraft")
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "整合包未声明 Minecraft 版本".to_string())?;
    let settings = state.settings_snapshot();
    let policy = settings.policy();
    if !state
        .layout
        .version_json(&game_version)
        .map(|path| path.is_file())
        .unwrap_or(false)
    {
        let installer = VanillaInstaller::new(
            state.layout.clone(),
            state.platform.clone(),
            policy,
            settings.mirror(),
        );
        installer
            .install(
                &game_version,
                TauriProgress::shared(app.clone()),
                CancelFlag::new(),
            )
            .await
            .map_err(command_error)?;
    }
    if let Some(loader) = manifest.loader.as_ref() {
        let installer = LoaderInstaller::new(state.layout.clone()).map_err(command_error)?;
        match loader.kind.modrinth_loader() {
            "fabric" => {
                installer
                    .install_fabric(
                        &instance,
                        &game_version,
                        Some(loader.version.as_str()),
                        TauriProgress::shared(app.clone()),
                        CancelFlag::new(),
                    )
                    .await
                    .map_err(command_error)?;
            }
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
                installer
                    .install_neoforge(
                        &instance,
                        &game_version,
                        &loader.version,
                        &java,
                        TauriProgress::shared(app.clone()),
                        CancelFlag::new(),
                    )
                    .await
                    .map_err(command_error)?;
            }
            other => return Err(format!("不支持的加载器: {other}")),
        }
        instance = state.instances.load(instance.id()).map_err(command_error)?;
    }
    Ok(InstanceView::from(instance))
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModpackUpdateView {
    pub current_version: String,
    pub latest_version: String,
    pub changelog: Option<String>,
    pub published_at: Option<chrono::DateTime<chrono::Utc>>,
    pub download_url: Option<String>,
}

#[tauri::command]
pub async fn check_modpack_update(
    state: State<'_, AppState>,
    instance_id: String,
) -> CommandResult<Option<ModpackUpdateView>> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let client = ModrinthClient::new().map_err(command_error)?;
    let update = modpack::check_update(&instance, &client)
        .await
        .map_err(command_error)?;
    Ok(update.map(|update| ModpackUpdateView {
        current_version: update.current_version_id.clone(),
        latest_version: update.latest_version_id().to_string(),
        changelog: update.latest_version.changelog.clone(),
        published_at: update.latest_version.date_published,
        download_url: non_empty(&update.download_url).or_else(|| {
            update
                .latest_version
                .primary_file()
                .map(|file| file.url.clone())
        }),
    }))
}

#[tauri::command]
pub async fn apply_modpack_update(
    app: AppHandle,
    state: State<'_, AppState>,
    instance_id: String,
) -> CommandResult<()> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let client = ModrinthClient::new().map_err(command_error)?;
    let update = modpack::check_update(&instance, &client)
        .await
        .map_err(command_error)?
        .ok_or_else(|| "当前整合包没有可用更新".to_string())?;
    let progress: SharedProgress = TauriProgress::shared(app);
    modpack::apply_update(&instance, &state.layout, &update, Some(progress), None)
        .await
        .map_err(command_error)?;
    Ok(())
}

/* ------------------------------- worlds ------------------------------- */

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorldView {
    pub folder: String,
    pub name: String,
    pub last_played: Option<chrono::DateTime<chrono::Utc>>,
    pub size_bytes: u64,
    pub game_mode: Option<String>,
    pub version: Option<String>,
}

impl From<WorldSummary> for WorldView {
    fn from(world: WorldSummary) -> Self {
        Self {
            folder: world.folder_name,
            name: world.name,
            last_played: world.last_played,
            size_bytes: world.size_bytes,
            game_mode: non_empty(&world.game_mode),
            version: world.version_name,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorldBackupView {
    pub id: String,
    pub name: String,
    pub folder: Option<String>,
    pub path: Option<String>,
    pub created_at: Option<chrono::DateTime<chrono::Utc>>,
    pub size_bytes: u64,
}

fn backup_view(
    manager: &WorldManager,
    instance: &launcher_core::models::instance::Instance,
    backup: WorldBackup,
) -> WorldBackupView {
    let directory = manager.backups_directory(instance).ok();
    WorldBackupView {
        id: backup.file_name.clone(),
        name: non_empty(&backup.world_folder).unwrap_or_else(|| backup.file_name.clone()),
        folder: non_empty(&backup.world_folder),
        path: directory.map(|directory| directory.join(&backup.file_name).display().to_string()),
        created_at: backup.created_at,
        size_bytes: backup.size_bytes,
    }
}

#[tauri::command]
pub fn list_worlds(
    state: State<'_, AppState>,
    instance_id: String,
) -> CommandResult<Vec<WorldView>> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let manager = WorldManager::new(state.layout.clone());
    let worlds = manager.list(&instance).map_err(command_error)?;
    Ok(worlds.into_iter().map(WorldView::from).collect())
}

#[tauri::command]
pub fn backup_world(
    state: State<'_, AppState>,
    instance_id: String,
    folder: String,
) -> CommandResult<WorldBackupView> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let manager = WorldManager::new(state.layout.clone());
    let backup = manager.backup(&instance, &folder).map_err(command_error)?;
    Ok(backup_view(&manager, &instance, backup))
}

#[tauri::command]
pub fn restore_world(
    state: State<'_, AppState>,
    instance_id: String,
    backup: String,
) -> CommandResult<()> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let manager = WorldManager::new(state.layout.clone());
    manager
        .restore_backup(&instance, &backup)
        .map_err(command_error)?;
    Ok(())
}

#[tauri::command]
pub fn delete_world(
    state: State<'_, AppState>,
    instance_id: String,
    folder: String,
) -> CommandResult<()> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let manager = WorldManager::new(state.layout.clone());
    manager
        .delete_world(&instance, &folder)
        .map_err(command_error)?;
    Ok(())
}

#[tauri::command]
pub fn list_backups(
    state: State<'_, AppState>,
    instance_id: String,
) -> CommandResult<Vec<WorldBackupView>> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let manager = WorldManager::new(state.layout.clone());
    let backups = manager.list_backups(&instance).map_err(command_error)?;
    Ok(backups
        .into_iter()
        .map(|backup| backup_view(&manager, &instance, backup))
        .collect())
}

/* --------------------------- resource packs --------------------------- */

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ContentPackView {
    pub file_name: String,
    pub name: String,
    pub description: Option<String>,
    pub enabled: bool,
    pub size_bytes: u64,
    pub icon_url: Option<String>,
}

#[tauri::command]
pub fn list_resourcepacks(
    state: State<'_, AppState>,
    instance_id: String,
) -> CommandResult<Vec<ContentPackView>> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let manager = ResourcePackManager::for_instance(&instance);
    let packs = manager.list().map_err(command_error)?;
    Ok(packs
        .into_iter()
        .map(|pack| ContentPackView {
            file_name: pack.file_name,
            name: pack.title,
            description: non_empty(&pack.description),
            enabled: pack.enabled,
            size_bytes: pack.size_bytes,
            icon_url: pack.icon_data_url,
        })
        .collect())
}

#[tauri::command]
pub fn import_resourcepack(
    state: State<'_, AppState>,
    instance_id: String,
    path: String,
) -> CommandResult<ContentPackView> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let manager = ResourcePackManager::for_instance(&instance);
    let pack = manager.import(Path::new(&path)).map_err(command_error)?;
    Ok(ContentPackView {
        file_name: pack.file_name,
        name: pack.title,
        description: non_empty(&pack.description),
        enabled: pack.enabled,
        size_bytes: pack.size_bytes,
        icon_url: pack.icon_data_url,
    })
}

#[tauri::command]
pub fn toggle_resourcepack(
    state: State<'_, AppState>,
    instance_id: String,
    file_name: String,
    enabled: bool,
) -> CommandResult<()> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    ResourcePackManager::for_instance(&instance)
        .set_enabled(&file_name, enabled)
        .map_err(command_error)
}

#[tauri::command]
pub fn delete_resourcepack(
    state: State<'_, AppState>,
    instance_id: String,
    file_name: String,
) -> CommandResult<()> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    ResourcePackManager::for_instance(&instance)
        .delete(&file_name)
        .map_err(command_error)
}

/* ------------------------------- shaders ------------------------------ */

#[tauri::command]
pub fn list_shaders(
    state: State<'_, AppState>,
    instance_id: String,
) -> CommandResult<Vec<ContentPackView>> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let manager = ShaderPackManager::for_instance(&instance);
    let packs = manager.list().map_err(command_error)?;
    Ok(packs
        .into_iter()
        .map(|pack| ContentPackView {
            file_name: pack.file_name,
            name: pack.name,
            description: None,
            enabled: pack.enabled,
            size_bytes: pack.size_bytes,
            icon_url: None,
        })
        .collect())
}

#[tauri::command]
pub fn import_shader(
    state: State<'_, AppState>,
    instance_id: String,
    path: String,
) -> CommandResult<ContentPackView> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let manager = ShaderPackManager::for_instance(&instance);
    let pack = manager.import(Path::new(&path)).map_err(command_error)?;
    Ok(ContentPackView {
        file_name: pack.file_name,
        name: pack.name,
        description: None,
        enabled: pack.enabled,
        size_bytes: pack.size_bytes,
        icon_url: None,
    })
}

#[tauri::command]
pub fn toggle_shader(
    state: State<'_, AppState>,
    instance_id: String,
    file_name: String,
    enabled: bool,
) -> CommandResult<()> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    ShaderPackManager::for_instance(&instance)
        .set_enabled(&file_name, enabled)
        .map_err(command_error)
}

#[tauri::command]
pub fn delete_shader(
    state: State<'_, AppState>,
    instance_id: String,
    file_name: String,
) -> CommandResult<()> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    ShaderPackManager::for_instance(&instance)
        .delete(&file_name)
        .map_err(command_error)
}

#[allow(dead_code)]
fn _assert_send() {
    let _: Option<BTreeSet<String>> = None;
    let _: Option<CancelFlag> = None;
}
