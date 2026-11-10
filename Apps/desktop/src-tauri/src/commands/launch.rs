use launcher_core::launch::{latest_game_log, read_tail, LaunchPlanBuilder, LaunchService};
use launcher_core::models::account::{AccountKind, ActiveAccountStore, MicrosoftAccountStore};
use launcher_core::models::instance::Instance;
use launcher_core::models::launch::{
    ExitReason, GameProcessEvent, LaunchContext, LaunchIdentity, LaunchPreview,
};
use launcher_core::version::VersionResolver;
use tauri::{AppHandle, Emitter, Manager, State};
use tokio::sync::broadcast::error::RecvError;

use crate::commands::{command_error, CommandResult};
use crate::state::{AppState, RunningGameHandle};

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GameStatus {
    pub running: bool,
    pub pid: Option<u32>,
    pub instance_id: Option<String>,
    pub started_at: Option<chrono::DateTime<chrono::Utc>>,
}

#[tauri::command]
pub fn game_status(state: State<'_, AppState>) -> CommandResult<GameStatus> {
    let running = state.running.lock().expect("running lock");
    Ok(match running.as_ref() {
        Some(game) => GameStatus {
            running: true,
            pid: Some(game.process_id),
            instance_id: Some(game.instance_id.clone()),
            started_at: Some(game.started_at),
        },
        None => GameStatus {
            running: false,
            pid: None,
            instance_id: None,
            started_at: None,
        },
    })
}

#[tauri::command]
pub async fn preview_launch(
    state: State<'_, AppState>,
    instance_id: String,
) -> CommandResult<LaunchPreview> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let version_id = instance
        .manifest
        .version_id
        .clone()
        .ok_or_else(|| "实例尚未绑定游戏版本".to_string())?;
    let version = VersionResolver
        .resolve(&version_id, &state.layout.game_root)
        .map_err(command_error)?;
    let context = launch_context(&state, &instance, &version).await?;
    LaunchPlanBuilder::preview(&instance, &version, &state.layout, &context).map_err(command_error)
}

#[tauri::command]
pub async fn launch_instance(
    app: AppHandle,
    state: State<'_, AppState>,
    instance_id: String,
) -> CommandResult<GameStatus> {
    {
        let running = state.running.lock().expect("running lock");
        if let Some(game) = running.as_ref() {
            return Err(format!("已有游戏正在运行 (PID {})", game.process_id));
        }
    }
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let version_id = instance
        .manifest
        .version_id
        .clone()
        .ok_or_else(|| "实例尚未绑定游戏版本，请先安装游戏".to_string())?;
    let version = VersionResolver
        .resolve(&version_id, &state.layout.game_root)
        .map_err(command_error)?;
    let context = launch_context(&state, &instance, &version).await?;
    let plan = LaunchPlanBuilder::build(&instance, &version, &state.layout, &context)
        .map_err(command_error)?;
    let log_path = instance.logs_directory().join("latest.log");
    let game = LaunchService::launch(&plan, Some(log_path.clone()))
        .await
        .map_err(command_error)?;
    let process_id = game.process_id;
    let event_instance_id = instance.id().to_string();
    let started_at = game.started_at;
    let control = game.control.clone();

    {
        let mut running = state.running.lock().expect("running lock");
        *running = Some(RunningGameHandle {
            instance_id: instance.id().to_string(),
            process_id,
            started_at,
            control,
        });
    }

    let mut events = game.events;
    let app_for_task = app.clone();
    tokio::spawn(async move {
        loop {
            match events.recv().await {
                Ok(GameProcessEvent::Stdout { line }) => {
                    let _ = app_for_task.emit(
                        "game-log",
                        serde_json::json!({
                            "line": line,
                            "stream": "stdout",
                            "instanceId": event_instance_id.clone(),
                            "timestamp": chrono::Utc::now().to_rfc3339(),
                        }),
                    );
                }
                Ok(GameProcessEvent::Stderr { line }) => {
                    let _ = app_for_task.emit(
                        "game-log",
                        serde_json::json!({
                            "line": line,
                            "stream": "stderr",
                            "instanceId": event_instance_id.clone(),
                            "timestamp": chrono::Utc::now().to_rfc3339(),
                        }),
                    );
                }
                Ok(GameProcessEvent::Exited { exit }) => {
                    let state = app_for_task.state::<AppState>();
                    {
                        let mut running = state.running.lock().expect("running lock");
                        *running = None;
                    }
                    let message = match exit.reason {
                        ExitReason::Exited => exit
                            .code
                            .map(|code| format!("游戏已退出（代码 {code}）"))
                            .unwrap_or_else(|| "游戏已退出".to_string()),
                        ExitReason::Signalled => "游戏进程被信号终止".to_string(),
                        ExitReason::Cancelled => "游戏启动已取消".to_string(),
                    };
                    let _ = app_for_task.emit(
                        "game-exited",
                        serde_json::json!({ "code": exit.code, "message": message }),
                    );
                    if exit.is_success {
                        let _ = state.java.discover();
                    }
                    break;
                }
                Err(RecvError::Lagged(_)) => continue,
                Err(RecvError::Closed) => break,
            }
        }
    });

    let mut manifest = instance.manifest.clone();
    manifest.last_launched_at = Some(started_at);
    manifest.last_identity_mode = Some(plan.identity_mode);
    let _ = state.instances.save(&manifest);

    Ok(GameStatus {
        running: true,
        pid: Some(process_id),
        instance_id: Some(instance_id),
        started_at: Some(started_at),
    })
}

#[tauri::command]
pub fn stop_game(state: State<'_, AppState>) -> CommandResult<()> {
    let running = state.running.lock().expect("running lock");
    let game = running.as_ref().ok_or_else(|| "游戏未在运行".to_string())?;
    game.control.stop();
    Ok(())
}

#[tauri::command]
pub fn read_game_log(
    state: State<'_, AppState>,
    instance_id: String,
    max_lines: Option<usize>,
) -> CommandResult<String> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let path = latest_game_log(&instance).or_else(|| {
        let candidate = instance.logs_directory().join("latest.log");
        candidate.is_file().then_some(candidate)
    });
    match path {
        Some(path) => read_tail(&path, max_lines.unwrap_or(400).min(5000)).map_err(command_error),
        None => Ok(String::new()),
    }
}

async fn launch_context(
    state: &AppState,
    instance: &Instance,
    version: &launcher_core::version::ResolvedVersion,
) -> CommandResult<LaunchContext> {
    let java = java_executable(state, instance, version)?;
    let identity = identity_for(state).await?;
    let mut context = LaunchContext::new(
        instance.directory.clone(),
        instance.game_directory.clone(),
        java,
        state.platform.clone(),
        identity,
    );
    context.launcher_name = launcher_core::models::launch::LAUNCHER_NAME.into();
    context.launcher_version = launcher_core::models::launch::LAUNCHER_VERSION.into();
    Ok(context)
}

fn java_executable(
    state: &AppState,
    instance: &Instance,
    version: &launcher_core::version::ResolvedVersion,
) -> CommandResult<std::path::PathBuf> {
    if let Some(runtime) = instance.manifest.java_runtime.as_ref() {
        let path = std::path::PathBuf::from(&runtime.executable);
        if path.is_file() {
            return Ok(path);
        }
    }
    if let Some(path) = state
        .settings_snapshot()
        .java_path
        .filter(|path| !path.is_empty())
    {
        let path = std::path::PathBuf::from(path);
        if path.is_file() {
            return Ok(path);
        }
    }
    let required = version.java_requirement.major_version.unwrap_or(21).max(8);
    if let Some(runtime) = state.java.find(required) {
        return Ok(runtime.executable);
    }
    Err(format!(
        "未找到 Java {required} 运行时，请在设置中指定 Java 路径或安装托管运行时"
    ))
}

async fn identity_for(state: &AppState) -> CommandResult<LaunchIdentity> {
    let active = ActiveAccountStore::new(state.layout.clone()).load();
    let reference = active.ok_or_else(|| "请先在账户管理登录 Microsoft 账户".to_string())?;
    match reference.kind {
        AccountKind::Local => Err(
            "桌面端仅支持 Microsoft 正版账户启动；离线账户请使用 CLI: lingxi launch --identity local:<name>"
                .to_string(),
        ),
        AccountKind::Microsoft => {
            let id = uuid::Uuid::parse_str(&reference.identifier)
                .map_err(|_| "无效的 Microsoft 账户 ID".to_string())?;
            let session = state.auth.session_for(id).await.map_err(command_error)?;
            let account = MicrosoftAccountStore::new(state.layout.clone())
                .load(id)
                .map_err(command_error)?;
            let mut identity = LaunchIdentity::microsoft(&account, session.access_token);
            identity.xuid = Some(session.xuid);
            Ok(identity)
        }
    }
}
