use launcher_core::install::models::{CancelFlag, SharedProgress};
use launcher_core::models::instance::JavaRuntimeRecord;
use tauri::{AppHandle, State};
use tauri_plugin_dialog::DialogExt;

use crate::commands::app::SettingsView;
use crate::commands::{command_error, CommandResult, JavaRuntimeView, TauriProgress};
use crate::state::{AppState, Settings};

#[tauri::command]
pub fn get_settings(state: State<'_, AppState>) -> CommandResult<SettingsView> {
    Ok(SettingsView::from(&state.settings_snapshot()))
}

#[tauri::command]
pub fn save_settings(
    state: State<'_, AppState>,
    java_path: Option<String>,
    source: Option<String>,
    mirror_config_path: Option<String>,
    default_memory_mib: Option<u32>,
    appearance: Option<String>,
) -> CommandResult<SettingsView> {
    let mut settings = state.settings_snapshot();
    if let Some(path) = java_path {
        settings.java_path = Some(path).filter(|value| !value.trim().is_empty());
    }
    if let Some(source) = source {
        let source = match source.trim().to_ascii_lowercase().as_str() {
            "auto" => "auto",
            "official" => "official",
            "mirror" => "mirror",
            "localcache" | "local-cache-only" => "local-cache-only",
            other => return Err(format!("未知的下载源: {other}")),
        };
        settings.source = source.to_string();
    }
    if let Some(path) = mirror_config_path {
        let path = path.trim().to_string();
        if !path.is_empty() && !std::path::Path::new(&path).is_file() {
            return Err("镜像配置文件不存在".into());
        }
        settings.mirror_config_path = Some(path).filter(|value| !value.is_empty());
    }
    if let Some(memory) = default_memory_mib {
        settings.default_memory_mib =
            launcher_core::models::instance::InstanceMemory::validate(memory)
                .map_err(command_error)?;
    }
    if let Some(appearance) = appearance {
        settings.appearance = match appearance.as_str() {
            "light" => "light".into(),
            "system" => "system".into(),
            _ => "dark".into(),
        };
    }
    state.save_settings(&settings).map_err(command_error)?;
    Ok(SettingsView::from(&settings))
}

impl From<&Settings> for SettingsView {
    fn from(settings: &Settings) -> Self {
        Self {
            java_path: settings.java_path.clone(),
            source: match settings.source.as_str() {
                "local-cache-only" => "localCache".to_string(),
                other => other.to_string(),
            },
            mirror_config_path: settings.mirror_config_path.clone(),
            default_memory_mib: settings.default_memory_mib,
            appearance: settings.appearance.clone(),
        }
    }
}

#[tauri::command]
pub fn java_runtimes(state: State<'_, AppState>) -> CommandResult<Vec<JavaRuntimeView>> {
    Ok(state
        .java
        .discover()
        .into_iter()
        .map(JavaRuntimeView::from)
        .collect())
}

#[tauri::command]
pub fn inspect_java(
    state: State<'_, AppState>,
    executable: String,
) -> CommandResult<JavaRuntimeView> {
    state
        .java
        .inspect(std::path::Path::new(&executable))
        .map(JavaRuntimeView::from)
        .map_err(command_error)
}

#[tauri::command]
pub async fn install_java(
    app: AppHandle,
    state: State<'_, AppState>,
    major: u32,
) -> CommandResult<JavaRuntimeView> {
    if !(8..=64).contains(&major) {
        return Err("Java 主版本不合理".into());
    }
    let progress: SharedProgress = TauriProgress::shared(app);
    state
        .java
        .install_managed(major, progress, CancelFlag::new())
        .await
        .map(JavaRuntimeView::from)
        .map_err(command_error)
}

#[tauri::command]
pub fn set_instance_java(
    state: State<'_, AppState>,
    instance_id: String,
    executable: Option<String>,
) -> CommandResult<()> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let mut manifest = instance.manifest.clone();
    manifest.java_runtime = match executable.filter(|value| !value.trim().is_empty()) {
        Some(executable) => {
            let runtime = state
                .java
                .inspect(std::path::Path::new(&executable))
                .map_err(command_error)?;
            Some(JavaRuntimeRecord {
                version: runtime.version_string,
                major_version: runtime.major_version,
                architecture: runtime.architecture.jvm_name().to_string(),
                executable: runtime.executable.display().to_string(),
                vendor: Some(runtime.vendor),
                checksum: None,
                source: "manual".into(),
                component: None,
                artifact_sha1: None,
                artifact_sha256: None,
                executable_sha256: None,
                recorded_at: chrono::Utc::now(),
            })
        }
        None => None,
    };
    state.instances.save(&manifest).map_err(command_error)
}

#[tauri::command]
pub fn reveal_data_folder(state: State<'_, AppState>) -> CommandResult<()> {
    let path = state.layout.data_root.clone();
    launcher_core::layout::ensure_dir(&path).map_err(command_error)?;
    state
        .runtime
        .system
        .reveal_in_file_manager(&path)
        .map_err(command_error)
}

#[tauri::command]
pub fn reveal_instance_folder(
    state: State<'_, AppState>,
    instance_id: String,
) -> CommandResult<()> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    state
        .runtime
        .system
        .reveal_in_file_manager(&instance.game_directory)
        .map_err(command_error)
}

#[tauri::command]
pub fn open_external(state: State<'_, AppState>, url: String) -> CommandResult<()> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err("只允许打开 http(s) 链接".into());
    }
    state.runtime.system.open_url(&url).map_err(command_error)
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LogContentView {
    pub path: String,
    pub content: String,
}

fn read_tail(path: &std::path::Path, max_bytes: u64) -> Result<String, String> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = std::fs::File::open(path).map_err(command_error)?;
    let length = file.metadata().map_err(command_error)?.len();
    if length > max_bytes {
        file.seek(SeekFrom::Start(length - max_bytes))
            .map_err(command_error)?;
    }
    let mut buffer = Vec::new();
    file.read_to_end(&mut buffer).map_err(command_error)?;
    Ok(String::from_utf8_lossy(&buffer).into_owned())
}

fn latest_file(directory: &std::path::Path) -> Option<std::path::PathBuf> {
    std::fs::read_dir(directory)
        .ok()?
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.is_file())
        .max_by_key(|path| path.metadata().and_then(|meta| meta.modified()).ok())
}

#[tauri::command]
pub fn read_logs(
    state: State<'_, AppState>,
    kind: String,
    instance_id: Option<String>,
) -> CommandResult<LogContentView> {
    let instance = match instance_id
        .as_deref()
        .filter(|value| !value.trim().is_empty())
    {
        Some(id) => Some(state.instances.load(id).map_err(command_error)?),
        None => None,
    };
    let launcher_log = || latest_file(&state.layout.logs_directory());
    let game_log = || {
        instance
            .as_ref()
            .and_then(launcher_core::launch::latest_game_log)
    };
    let path = match kind.as_str() {
        "launcher" => launcher_log(),
        "game" => game_log(),
        "latest" => game_log().or_else(launcher_log),
        other => return Err(format!("未知的日志类型: {other}")),
    };
    match path {
        Some(path) => {
            let content = read_tail(&path, 4 * 1024 * 1024)?;
            Ok(LogContentView {
                path: path.display().to_string(),
                content,
            })
        }
        None => Ok(LogContentView {
            path: String::new(),
            content: String::new(),
        }),
    }
}

#[tauri::command]
pub fn open_logs_folder(state: State<'_, AppState>) -> CommandResult<()> {
    let path = state.layout.logs_directory();
    launcher_core::layout::ensure_dir(&path).map_err(command_error)?;
    state
        .runtime
        .system
        .reveal_in_file_manager(&path)
        .map_err(command_error)
}

#[tauri::command]
pub fn reveal_path(state: State<'_, AppState>, path: String) -> CommandResult<()> {
    let target = std::fs::canonicalize(path.trim()).map_err(|_| "路径不存在".to_string())?;
    let data_root = std::fs::canonicalize(&state.layout.data_root).map_err(command_error)?;
    let game_root = std::fs::canonicalize(&state.layout.game_root).map_err(command_error)?;
    if !target.starts_with(&data_root) && !target.starts_with(&game_root) {
        return Err("只能打开启动器数据目录内的路径".into());
    }
    state
        .runtime
        .system
        .reveal_in_file_manager(&target)
        .map_err(command_error)
}

#[tauri::command]
pub fn detect_java(state: State<'_, AppState>) -> CommandResult<Vec<JavaRuntimeView>> {
    Ok(state
        .java
        .discover()
        .into_iter()
        .map(JavaRuntimeView::from)
        .collect())
}

#[tauri::command]
pub fn browse_java(app: AppHandle) -> CommandResult<Option<String>> {
    let file = app.dialog().file().blocking_pick_file();
    Ok(file
        .and_then(|path| path.into_path().ok())
        .map(|path| path.display().to_string()))
}
