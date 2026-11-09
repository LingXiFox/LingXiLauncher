use launcher_auth::{AuthConfig, MicrosoftAuthService};
use launcher_core::models::account::{
    AccountKind, AccountReference, ActiveAccountStore, LocalAccountStore, MicrosoftAccountStore,
};
use launcher_core::{Error, Result};
use serde_json::json;
use uuid::Uuid;

use crate::context::Context;
use crate::{AccountAction, LocalAccountAction, MicrosoftAccountAction};

fn auth_service(context: &Context) -> Result<MicrosoftAuthService> {
    MicrosoftAuthService::new(
        AuthConfig::default(),
        context.layout.clone(),
        context.runtime.secrets.clone(),
    )
}

fn set_active(context: &Context, kind: AccountKind, identifier: &str) -> Result<()> {
    ActiveAccountStore::new(context.layout.clone()).save(Some(&AccountReference {
        kind,
        identifier: identifier.to_string(),
    }))
}

pub async fn account(context: &Context, action: AccountAction) -> Result<()> {
    match action {
        AccountAction::Local { action } => local(context, action),
        AccountAction::Microsoft { action } => microsoft(context, action).await,
        AccountAction::List => list(context),
    }
}

fn local(context: &Context, action: LocalAccountAction) -> Result<()> {
    let store = LocalAccountStore::new(context.layout.clone());
    match action {
        LocalAccountAction::Create { name } => {
            let account = store.create(&name)?;
            set_active(context, AccountKind::Local, &account.player_name)?;
            if context.json {
                context.json(&json!({
                    "name": account.player_name,
                    "uuid": account.offline_uuid,
                    "createdAt": account.created_at,
                    "active": true,
                }))?;
            } else {
                context.header("Local account created");
                context.field("Name", &account.player_name);
                context.field("UUID", account.offline_uuid);
                context.field("Active", "yes");
            }
            Ok(())
        }
        LocalAccountAction::List => {
            let accounts = store.list()?;
            if context.json {
                let rows: Vec<_> = accounts
                    .iter()
                    .map(|account| {
                        json!({
                            "name": account.player_name,
                            "uuid": account.offline_uuid,
                            "createdAt": account.created_at,
                        })
                    })
                    .collect();
                context.json(&rows)?;
            } else {
                context.header("Local accounts");
                for account in accounts {
                    context.line(format!("{}  {}", account.player_name, account.offline_uuid));
                }
            }
            Ok(())
        }
        LocalAccountAction::Delete { name } => {
            store.delete(&name)?;
            let active = ActiveAccountStore::new(context.layout.clone()).load();
            if active.as_ref().is_some_and(|reference| {
                reference.kind == AccountKind::Local && reference.identifier == name
            }) {
                ActiveAccountStore::new(context.layout.clone()).save(None)?;
            }
            if context.json {
                context.json(&json!({ "deleted": name }))?;
            } else {
                context.field("Deleted", name);
            }
            Ok(())
        }
    }
}

async fn microsoft(context: &Context, action: MicrosoftAccountAction) -> Result<()> {
    match action {
        MicrosoftAccountAction::Login => {
            let auth = auth_service(context)?;
            let system = context.runtime.system.clone();
            let (account, _session) = auth.sign_in(move |url| system.open_url(url)).await?;
            set_active(context, AccountKind::Microsoft, &account.id.to_string())?;
            if context.json {
                context.json(&account)?;
            } else {
                context.header("Microsoft account signed in");
                context.field("Player", &account.player_name);
                context.field("UUID", account.id);
            }
            Ok(())
        }
        MicrosoftAccountAction::Status => {
            let auth = auth_service(context)?;
            let accounts = auth.accounts()?;
            let active = ActiveAccountStore::new(context.layout.clone()).load();
            if context.json {
                let rows: Vec<_> = accounts
                    .iter()
                    .map(|account| {
                        json!({
                            "id": account.id,
                            "playerName": account.player_name,
                            "ownsGame": account.owns_game,
                            "addedAt": account.added_at,
                            "lastValidatedAt": account.last_validated_at,
                            "active": active.as_ref().is_some_and(|reference| {
                                reference.kind == AccountKind::Microsoft
                                    && reference.identifier.eq_ignore_ascii_case(&account.id.to_string())
                            }),
                        })
                    })
                    .collect();
                context.json(&rows)?;
            } else {
                context.header("Microsoft accounts");
                for account in accounts {
                    let marker = active.as_ref().is_some_and(|reference| {
                        reference.kind == AccountKind::Microsoft
                            && reference
                                .identifier
                                .eq_ignore_ascii_case(&account.id.to_string())
                    });
                    context.line(format!(
                        "{}{}  {}  {}",
                        if marker { "* " } else { "  " },
                        account.player_name,
                        account.id,
                        if account.owns_game {
                            "owns Minecraft"
                        } else {
                            "no game entitlement"
                        }
                    ));
                }
            }
            Ok(())
        }
        MicrosoftAccountAction::Logout { id } => {
            let uuid = Uuid::parse_str(&id)
                .map_err(|_| Error::MissingInput(format!("'{id}' is not a UUID")))?;
            let auth = auth_service(context)?;
            auth.sign_out(uuid)?;
            let active = ActiveAccountStore::new(context.layout.clone()).load();
            if active.as_ref().is_some_and(|reference| {
                reference.kind == AccountKind::Microsoft
                    && reference.identifier.eq_ignore_ascii_case(&id)
            }) {
                ActiveAccountStore::new(context.layout.clone()).save(None)?;
            }
            if context.json {
                context.json(&json!({ "signedOut": id }))?;
            } else {
                context.field("Signed out", id);
            }
            Ok(())
        }
    }
}

fn list(context: &Context) -> Result<()> {
    let local = LocalAccountStore::new(context.layout.clone()).list()?;
    let microsoft = MicrosoftAccountStore::new(context.layout.clone()).list()?;
    let active = ActiveAccountStore::new(context.layout.clone()).load();
    let is_active = |kind: AccountKind, identifier: &str| {
        active.as_ref().is_some_and(|reference| {
            reference.kind == kind && reference.identifier.eq_ignore_ascii_case(identifier)
        })
    };
    if context.json {
        context.json(&json!({
            "local": local.iter().map(|account| json!({
                "name": account.player_name,
                "uuid": account.offline_uuid,
                "active": is_active(AccountKind::Local, &account.player_name),
            })).collect::<Vec<_>>(),
            "microsoft": microsoft.iter().map(|account| json!({
                "id": account.id,
                "playerName": account.player_name,
                "active": is_active(AccountKind::Microsoft, &account.id.to_string()),
            })).collect::<Vec<_>>(),
            "active": active.as_ref().map(|reference| json!({
                "kind": reference.kind.as_str(),
                "identifier": reference.identifier,
            })),
        }))?;
    } else {
        context.header("Accounts");
        for account in &local {
            context.line(format!(
                "{}{}  local",
                if is_active(AccountKind::Local, &account.player_name) {
                    "* "
                } else {
                    "  "
                },
                account.player_name
            ));
        }
        for account in &microsoft {
            context.line(format!(
                "{}{}  microsoft  {}",
                if is_active(AccountKind::Microsoft, &account.id.to_string()) {
                    "* "
                } else {
                    "  "
                },
                account.player_name,
                account.id
            ));
        }
    }
    Ok(())
}
