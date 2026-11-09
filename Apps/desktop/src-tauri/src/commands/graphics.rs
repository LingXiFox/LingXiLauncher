use launcher_core::graphics::{self, GraphicsSettings, GraphicsSnapshot};
use tauri::State;

use crate::commands::{command_error, CommandResult};
use crate::state::AppState;

#[tauri::command]
pub fn read_instance_graphics(
    state: State<'_, AppState>,
    instance_id: String,
) -> CommandResult<GraphicsSnapshot> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    graphics::read(&instance.game_directory).map_err(command_error)
}

#[tauri::command]
pub fn save_instance_graphics(
    state: State<'_, AppState>,
    instance_id: String,
    settings: GraphicsSettings,
) -> CommandResult<GraphicsSnapshot> {
    let running = state.running.lock().expect("running lock");
    if running.is_some() {
        return Err("游戏正在运行，请先退出游戏再修改图形设置。".to_string());
    }
    drop(running);
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    graphics::write(&instance.game_directory, &settings).map_err(command_error)
}
