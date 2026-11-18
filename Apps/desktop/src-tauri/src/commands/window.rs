//! Window level commands: the detached log viewer and the restart hook used
//! after a settings change that only takes effect on a fresh launch.

use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

use crate::commands::CommandResult;

/// Label of the detached log window. Kept in sync with the frontend router and
/// with the capability entry in `capabilities/default.json`.
pub const LOG_WINDOW_LABEL: &str = "logs";

#[tauri::command]
pub fn open_log_window(app: AppHandle) -> CommandResult<()> {
    if let Some(window) = app.get_webview_window(LOG_WINDOW_LABEL) {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        return Ok(());
    }
    WebviewWindowBuilder::new(&app, LOG_WINDOW_LABEL, WebviewUrl::App("index.html".into()))
        .title("灵曦启动器 · 运行日志")
        .inner_size(940.0, 620.0)
        .min_inner_size(640.0, 420.0)
        .build()
        .map_err(|error| format!("无法打开日志窗口: {error}"))?;
    Ok(())
}

#[tauri::command]
pub fn restart_app(app: AppHandle) -> CommandResult<()> {
    // Restarting tears the process down, so this never returns.
    app.restart();
}
