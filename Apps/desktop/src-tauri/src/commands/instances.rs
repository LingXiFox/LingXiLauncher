use std::path::{Path, PathBuf};

use launcher_core::error::Error;
use launcher_core::paths::PathSafety;
use tauri::State;

use crate::commands::{CommandResult, InstanceView};
use crate::state::AppState;

#[tauri::command]
pub fn list_instances(state: State<'_, AppState>) -> CommandResult<Vec<InstanceView>> {
    Ok(state
        .instances
        .list()
        .map_err(|e| e.to_string())?
        .into_iter()
        .map(InstanceView::from)
        .collect())
}

#[tauri::command]
pub fn create_instance(
    state: State<'_, AppState>,
    name: String,
    version_id: Option<String>,
) -> CommandResult<InstanceView> {
    let name = name.trim();
    if name.is_empty() {
        return Err("实例名称不能为空".into());
    }
    if name.chars().count() > 60 {
        return Err("实例名称过长".into());
    }
    let instance = state
        .instances
        .create_with_generated_id(name)
        .map_err(|e| e.to_string())?;
    if let Some(version) = version_id.filter(|value| !value.is_empty()) {
        let instance = state
            .instances
            .assign_version(&instance, &version)
            .map_err(|e| e.to_string())?;
        return Ok(InstanceView::from(instance));
    }
    Ok(InstanceView::from(instance))
}

#[tauri::command]
pub fn update_instance(
    state: State<'_, AppState>,
    id: String,
    memory_mib: Option<u32>,
    jvm_arguments: Option<String>,
) -> CommandResult<InstanceView> {
    let instance = state.instances.load(&id).map_err(|e| e.to_string())?;
    let args = match jvm_arguments {
        Some(text) => text
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(str::to_string)
            .collect(),
        None => instance.manifest.jvm_arguments.clone().unwrap_or_default(),
    };
    let instance = state
        .instances
        .set_performance(&instance, memory_mib, args)
        .map_err(|e| e.to_string())?;
    Ok(InstanceView::from(instance))
}

/// Updates the window, priority, hook, environment and renderer options of an
/// instance. Everything is validated before the manifest is written so a bad
/// command line or environment key never reaches the launch path.
#[tauri::command]
pub fn update_instance_launch(
    state: State<'_, AppState>,
    id: String,
    launch: launcher_core::models::instance::InstanceLaunchSettings,
) -> CommandResult<InstanceView> {
    launch.validate().map_err(|e| e.to_string())?;
    let mut instance = state.instances.load(&id).map_err(|e| e.to_string())?;
    instance.manifest.launch = launch;
    state
        .instances
        .save(&instance.manifest)
        .map_err(|e| e.to_string())?;
    let instance = state.instances.load(&id).map_err(|e| e.to_string())?;
    Ok(InstanceView::from(instance))
}

/// Verify that `directory` is exactly `<root>/<name>` and nothing else.
/// Refuses symlinks pointing elsewhere, shared parents and mismatched names so
/// a corrupted manifest can never redirect a delete at unrelated data.
fn checked_instance_path(root: &Path, directory: &Path, name: &str) -> CommandResult<PathBuf> {
    let root = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    let directory = directory
        .canonicalize()
        .unwrap_or_else(|_| directory.to_path_buf());
    if directory == root || !directory.starts_with(&root) {
        return Err("拒绝删除实例目录之外的路径".into());
    }
    if directory.file_name().and_then(|value| value.to_str()) != Some(name) {
        return Err("实例目录与清单不一致，已拒绝删除".into());
    }
    Ok(directory)
}

/// P1-7: deleting an instance must handle the instance directory and its
/// isolated game directory as one lifecycle unit, and must never destroy the
/// player's worlds by accident. `keep_saves` defaults to true: the `saves`
/// folder is moved into `<dataRoot>/kept-saves/<id>-<timestamp>/` first.
#[tauri::command]
pub fn delete_instance(
    state: State<'_, AppState>,
    id: String,
    keep_saves: Option<bool>,
) -> CommandResult<()> {
    let instance = state.instances.load(&id).map_err(|e| e.to_string())?;
    let keep_saves = keep_saves.unwrap_or(true);
    let directory = checked_instance_path(
        &state.layout.instances_directory(),
        &instance.directory,
        instance.id(),
    )?;
    // The isolated game directory is only removed when it is the standard
    // per-instance path. Anything else (a hand-edited manifest pointing at a
    // shared .minecraft) is left alone: deleting it would take other
    // instances' files with it.
    let game_directory = checked_instance_path(
        &state.layout.data_root.join(".minecraft").join("versions"),
        &instance.game_directory,
        instance.id(),
    )
    .ok();
    let saves = game_directory
        .as_ref()
        .map(|path| path.join("saves"))
        .filter(|path| path.is_dir());
    if keep_saves {
        if let Some(saves) = saves {
            let stamp = chrono::Utc::now().format("%Y%m%d-%H%M%S");
            let target =
                state
                    .layout
                    .kept_saves_directory()
                    .join(format!("{}-{}", instance.id(), stamp));
            launcher_core::layout::ensure_dir(&target).map_err(|e| e.to_string())?;
            copy_tree(&saves, &target.join("saves"))?;
        }
    }
    if directory.is_dir() {
        std::fs::remove_dir_all(&directory).map_err(|e| e.to_string())?;
    }
    if let Some(game_directory) = game_directory.filter(|path| path.is_dir()) {
        std::fs::remove_dir_all(&game_directory).map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
pub fn copy_instance(
    state: State<'_, AppState>,
    id: String,
    name: String,
) -> CommandResult<InstanceView> {
    let source = state.instances.load(&id).map_err(|e| e.to_string())?;
    let target = state
        .instances
        .create_with_generated_id(name.trim())
        .map_err(|e| e.to_string())?;
    if let Some(version) = source.manifest.version_id.clone() {
        state
            .instances
            .assign_version(&target, &version)
            .map_err(|e| e.to_string())?;
    }
    copy_tree(&source.game_directory, &target.game_directory)?;
    if source.mods_metadata().is_file() {
        std::fs::copy(source.mods_metadata(), target.mods_metadata()).map_err(|e| e.to_string())?;
    }
    if source.disabled_mods_directory().is_dir() {
        copy_tree(
            &source.disabled_mods_directory(),
            &target.disabled_mods_directory(),
        )?;
    }
    let mut manifest = target.manifest.clone();
    manifest.memory_mib = source.manifest.memory_mib;
    manifest.jvm_arguments = source.manifest.jvm_arguments.clone();
    manifest.java_runtime = source.manifest.java_runtime.clone();
    manifest.launch = source.manifest.launch.clone();
    state.instances.save(&manifest).map_err(|e| e.to_string())?;
    let target = state
        .instances
        .load(target.id())
        .map_err(|e| e.to_string())?;
    Ok(InstanceView::from(target))
}

#[tauri::command]
pub fn set_instance_version(
    state: State<'_, AppState>,
    id: String,
    version_id: String,
) -> CommandResult<InstanceView> {
    let instance = state.instances.load(&id).map_err(|e| e.to_string())?;
    let instance = state
        .instances
        .assign_version(&instance, &version_id)
        .map_err(|e| e.to_string())?;
    Ok(InstanceView::from(instance))
}

fn copy_tree(source: &Path, target: &Path) -> CommandResult<()> {
    if !source.is_dir() {
        return Ok(());
    }
    launcher_core::layout::ensure_dir(target).map_err(|e| e.to_string())?;
    for entry in std::fs::read_dir(source)
        .map_err(|e| e.to_string())?
        .flatten()
    {
        let path = entry.path();
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        PathSafety::validate_component(name).map_err(|e| e.to_string())?;
        let destination = target.join(name);
        let metadata = std::fs::symlink_metadata(&path).map_err(|e| e.to_string())?;
        if metadata.file_type().is_symlink() {
            continue;
        }
        if metadata.is_dir() {
            if name == "logs" || name == "crash-reports" {
                continue;
            }
            copy_tree(&path, &destination)?;
        } else if metadata.is_file() {
            std::fs::copy(&path, &destination).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

pub(crate) fn ensure_instance_exists(state: &AppState, id: &str) -> Result<(), Error> {
    state.instances.load(id).map(|_| ())
}
