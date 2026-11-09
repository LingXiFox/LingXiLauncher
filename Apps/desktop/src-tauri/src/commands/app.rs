use launcher_core::models::account::{
    ActiveAccountStore, LocalAccountStore, MicrosoftAccountStore,
};
use serde::Serialize;
use tauri::State;

use crate::commands::accounts::{collect_account_snapshot, AccountSnapshotView};
use crate::commands::{AccountView, CommandResult, InstanceView, JavaRuntimeView};
use crate::state::AppState;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsView {
    pub java_path: Option<String>,
    pub source: String,
    pub mirror_config_path: Option<String>,
    pub default_memory_mib: u32,
    pub appearance: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Bootstrap {
    pub version: String,
    pub data_root: String,
    pub game_root: String,
    pub platform: String,
    pub architecture: String,
    pub settings: SettingsView,
    pub accounts: AccountSnapshotView,
    pub active_account: Option<AccountView>,
    pub instances: Vec<InstanceView>,
    pub java_runtimes: Vec<JavaRuntimeView>,
    pub is_game_running: bool,
    pub game_pid: Option<u32>,
}

pub fn collect_accounts(state: &AppState) -> Result<Vec<AccountView>, String> {
    let active = ActiveAccountStore::new(state.layout.clone()).load();
    let mut accounts = Vec::new();
    for account in LocalAccountStore::new(state.layout.clone())
        .list()
        .map_err(|e| e.to_string())?
    {
        accounts.push(AccountView::local(&account, active.as_ref()));
    }
    for account in MicrosoftAccountStore::new(state.layout.clone())
        .list()
        .map_err(|e| e.to_string())?
    {
        accounts.push(AccountView::microsoft(&account, active.as_ref()));
    }
    Ok(accounts)
}

#[tauri::command]
pub fn bootstrap(state: State<'_, AppState>) -> CommandResult<Bootstrap> {
    let settings = state.settings_snapshot();
    let accounts = collect_account_snapshot(&state)?;
    let active_account = collect_accounts(&state)?
        .into_iter()
        .find(|account| account.active);
    let running = state.running.lock().expect("running lock");
    Ok(Bootstrap {
        version: env!("CARGO_PKG_VERSION").to_string(),
        data_root: state.layout.data_root.display().to_string(),
        game_root: state.layout.game_root.display().to_string(),
        platform: state.platform.os.as_str().to_string(),
        architecture: state.platform.architecture.jvm_name().to_string(),
        settings: SettingsView::from(&settings),
        accounts,
        active_account,
        instances: state
            .instances
            .list()
            .map_err(|e| e.to_string())?
            .into_iter()
            .map(InstanceView::from)
            .collect(),
        java_runtimes: state
            .java
            .discover()
            .into_iter()
            .map(JavaRuntimeView::from)
            .collect(),
        is_game_running: running.is_some(),
        game_pid: running.as_ref().map(|game| game.process_id),
    })
}
