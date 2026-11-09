use launcher_core::models::account::{
    AccountKind, AccountReference, ActiveAccountStore, LocalAccountStore, MicrosoftAccountStore,
};
use serde::Serialize;
use tauri::{Emitter, Manager, State};

use crate::commands::app::collect_accounts;
use crate::commands::{command_error, AccountView, CommandResult};
use crate::state::AppState;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalAccountView {
    pub name: String,
    pub uuid: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MicrosoftAccountView {
    pub id: String,
    pub player_name: String,
    pub skin_texture_url: Option<String>,
    pub signed_in_at: chrono::DateTime<chrono::Utc>,
    pub owns_game: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LoginStart {
    pub url: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountSnapshotView {
    pub microsoft: Vec<MicrosoftAccountView>,
    pub local: Vec<LocalAccountView>,
}

pub(crate) fn local_account_views(state: &AppState) -> Result<Vec<LocalAccountView>, String> {
    let accounts = LocalAccountStore::new(state.layout.clone())
        .list()
        .map_err(command_error)?;
    Ok(accounts
        .into_iter()
        .map(|account| LocalAccountView {
            name: account.player_name,
            uuid: account.offline_uuid.hyphenated().to_string(),
            created_at: account.created_at,
        })
        .collect())
}

pub(crate) fn microsoft_account_views(
    state: &AppState,
) -> Result<Vec<MicrosoftAccountView>, String> {
    let accounts = MicrosoftAccountStore::new(state.layout.clone())
        .list()
        .map_err(command_error)?;
    Ok(accounts
        .into_iter()
        .map(|account| MicrosoftAccountView {
            id: account.id.hyphenated().to_string(),
            player_name: account.player_name,
            skin_texture_url: account
                .appearance
                .and_then(|appearance| appearance.skin_texture_url),
            signed_in_at: account.added_at,
            owns_game: account.owns_game,
        })
        .collect())
}

pub fn collect_account_snapshot(state: &AppState) -> Result<AccountSnapshotView, String> {
    Ok(AccountSnapshotView {
        microsoft: microsoft_account_views(state)?,
        local: local_account_views(state)?,
    })
}

fn active_store(state: &AppState) -> ActiveAccountStore {
    ActiveAccountStore::new(state.layout.clone())
}

fn view_for(state: &AppState, kind: AccountKind, identifier: &str) -> CommandResult<AccountView> {
    collect_accounts(state)?
        .into_iter()
        .find(|account| {
            account.kind == kind.as_str() && account.identifier.eq_ignore_ascii_case(identifier)
        })
        .ok_or_else(|| "账户不存在".to_string())
}

#[tauri::command]
pub fn list_accounts(state: State<'_, AppState>) -> CommandResult<Vec<AccountView>> {
    collect_accounts(&state)
}

#[tauri::command]
pub fn list_local_accounts(state: State<'_, AppState>) -> CommandResult<Vec<LocalAccountView>> {
    local_account_views(&state)
}

#[tauri::command]
pub fn list_microsoft_accounts(
    state: State<'_, AppState>,
) -> CommandResult<Vec<MicrosoftAccountView>> {
    microsoft_account_views(&state)
}

#[tauri::command]
pub fn create_local_account(
    state: State<'_, AppState>,
    name: String,
) -> CommandResult<LocalAccountView> {
    let store = LocalAccountStore::new(state.layout.clone());
    let account = store.create(name.trim()).map_err(command_error)?;
    active_store(&state)
        .save(Some(&AccountReference {
            kind: AccountKind::Local,
            identifier: account.player_name.clone(),
        }))
        .map_err(command_error)?;
    Ok(LocalAccountView {
        name: account.player_name,
        uuid: account.offline_uuid.hyphenated().to_string(),
        created_at: account.created_at,
    })
}

#[tauri::command]
pub fn delete_local_account(state: State<'_, AppState>, name: String) -> CommandResult<()> {
    let store = LocalAccountStore::new(state.layout.clone());
    let account = store.load(&name).map_err(command_error)?;
    store.delete(&account.player_name).map_err(command_error)?;
    let active = active_store(&state).load();
    if active
        .as_ref()
        .map(|reference| {
            reference.kind == AccountKind::Local
                && reference
                    .identifier
                    .eq_ignore_ascii_case(&account.player_name)
        })
        .unwrap_or(false)
    {
        active_store(&state).save(None).map_err(command_error)?;
    }
    Ok(())
}

#[tauri::command]
pub fn set_active_account(
    state: State<'_, AppState>,
    kind: String,
    identifier: String,
) -> CommandResult<Vec<AccountView>> {
    let kind: AccountKind = kind.parse().map_err(command_error)?;
    let reference = match kind {
        AccountKind::Local => {
            let account = LocalAccountStore::new(state.layout.clone())
                .load(&identifier)
                .map_err(command_error)?;
            AccountReference {
                kind,
                identifier: account.player_name,
            }
        }
        AccountKind::Microsoft => {
            let id = uuid::Uuid::parse_str(&identifier).map_err(command_error)?;
            let account = MicrosoftAccountStore::new(state.layout.clone())
                .load(id)
                .map_err(command_error)?;
            AccountReference {
                kind,
                identifier: account.id.hyphenated().to_string(),
            }
        }
    };
    active_store(&state)
        .save(Some(&reference))
        .map_err(command_error)?;
    collect_accounts(&state)
}

#[tauri::command]
pub fn clear_active_account(state: State<'_, AppState>) -> CommandResult<Vec<AccountView>> {
    active_store(&state).save(None).map_err(command_error)?;
    collect_accounts(&state)
}

#[tauri::command]
pub async fn begin_microsoft_login(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
) -> CommandResult<LoginStart> {
    let (url_tx, url_rx) = tokio::sync::oneshot::channel::<String>();
    let (cancel_tx, cancel_rx) = tokio::sync::watch::channel(false);
    {
        let mut slot = state.auth_cancel.lock().expect("auth cancel lock");
        if slot.is_some() {
            return Err("已有正在进行的 Microsoft 登录".into());
        }
        *slot = Some(cancel_tx);
    }

    let auth = state.auth.clone();
    let system = state.runtime.system.clone();
    let handle = app.clone();
    tauri::async_runtime::spawn(async move {
        let open_browser = move |url: &str| {
            let _ = url_tx.send(url.to_string());
            system.open_url(url)
        };
        let result = auth.sign_in_streaming(open_browser, cancel_rx).await;
        let app_state = handle.state::<AppState>();
        {
            let mut slot = app_state.auth_cancel.lock().expect("auth cancel lock");
            *slot = None;
        }
        match result {
            Ok((account, _session)) => {
                let reference = AccountReference {
                    kind: AccountKind::Microsoft,
                    identifier: account.id.hyphenated().to_string(),
                };
                if let Err(error) =
                    ActiveAccountStore::new(app_state.layout.clone()).save(Some(&reference))
                {
                    let _ = handle.emit("auth-error", error.to_string());
                    return;
                }
                let _ = handle.emit("auth-changed", serde_json::json!({ "kind": "microsoft" }));
            }
            Err(error) => {
                let _ = handle.emit("auth-error", error.to_string());
            }
        }
    });

    let url = url_rx
        .await
        .map_err(|_| "Microsoft 登录未能启动".to_string())?;
    Ok(LoginStart { url })
}

#[tauri::command]
pub fn cancel_microsoft_login(state: State<'_, AppState>) -> CommandResult<()> {
    let sender = state.auth_cancel.lock().expect("auth cancel lock").take();
    if let Some(sender) = sender {
        let _ = sender.send(true);
    }
    Ok(())
}

#[tauri::command]
pub async fn sign_in_microsoft(state: State<'_, AppState>) -> CommandResult<AccountView> {
    let system = state.runtime.system.clone();
    let (account, _session) = state
        .auth
        .sign_in(move |url| system.open_url(url))
        .await
        .map_err(command_error)?;
    active_store(&state)
        .save(Some(&AccountReference {
            kind: AccountKind::Microsoft,
            identifier: account.id.hyphenated().to_string(),
        }))
        .map_err(command_error)?;
    view_for(
        &state,
        AccountKind::Microsoft,
        &account.id.hyphenated().to_string(),
    )
}

#[tauri::command]
pub async fn validate_microsoft_account(
    state: State<'_, AppState>,
    id: String,
) -> CommandResult<AccountView> {
    let id = uuid::Uuid::parse_str(&id).map_err(command_error)?;
    state.auth.session_for(id).await.map_err(command_error)?;
    let account = MicrosoftAccountStore::new(state.layout.clone())
        .load(id)
        .map_err(command_error)?;
    view_for(
        &state,
        AccountKind::Microsoft,
        &account.id.hyphenated().to_string(),
    )
}

#[tauri::command]
pub fn sign_out_microsoft(
    state: State<'_, AppState>,
    id: String,
) -> CommandResult<Vec<AccountView>> {
    let id = uuid::Uuid::parse_str(&id).map_err(command_error)?;
    state.auth.sign_out(id).map_err(command_error)?;
    let active = active_store(&state).load();
    if active
        .as_ref()
        .map(|reference| {
            reference.kind == AccountKind::Microsoft
                && reference
                    .identifier
                    .eq_ignore_ascii_case(&id.hyphenated().to_string())
        })
        .unwrap_or(false)
    {
        active_store(&state).save(None).map_err(command_error)?;
    }
    collect_accounts(&state)
}

#[tauri::command]
pub fn player_appearance(
    state: State<'_, AppState>,
    kind: String,
    identifier: String,
) -> CommandResult<Option<launcher_core::models::account::PlayerAppearance>> {
    let kind: AccountKind = kind.parse().map_err(command_error)?;
    match kind {
        AccountKind::Local => Ok(None),
        AccountKind::Microsoft => {
            let id = uuid::Uuid::parse_str(&identifier).map_err(command_error)?;
            let account = MicrosoftAccountStore::new(state.layout.clone())
                .load(id)
                .map_err(command_error)?;
            Ok(account.appearance)
        }
    }
}
