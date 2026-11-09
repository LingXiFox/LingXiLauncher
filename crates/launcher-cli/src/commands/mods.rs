use launcher_core::models::instance::{Instance, InstanceRepository};
use launcher_core::modrinth::{best_version, ModrinthClient, SearchQuery};
use launcher_core::mods::ModManager;
use launcher_core::{Error, Result};
use serde_json::json;

use crate::context::Context;
use crate::ModAction;

pub fn loader_from_version(version_id: &str) -> Option<String> {
    let lower = version_id.to_ascii_lowercase();
    if lower.starts_with("fabric-loader-") {
        Some("fabric".into())
    } else if lower.starts_with("quilt-loader-") {
        Some("quilt".into())
    } else if lower.starts_with("neoforge-") {
        Some("neoforge".into())
    } else if lower.starts_with("forge-") {
        Some("forge".into())
    } else {
        None
    }
}

pub fn load_instance(context: &Context, id: &str) -> Result<Instance> {
    InstanceRepository::new(context.layout.clone()).load(id)
}

pub async fn mods(context: &Context, action: ModAction) -> Result<()> {
    match action {
        ModAction::Search {
            query,
            game_version,
            loader,
            offset,
            limit,
        } => {
            let client = ModrinthClient::new()?;
            let mut search = SearchQuery::new(query).facet("project_type", ["mod".to_string()]);
            if let Some(game_version) = game_version {
                search = search.facet("versions", [game_version]);
            }
            if let Some(loader) = loader {
                search = search.facet("categories", [loader]);
            }
            let response = client
                .search(&search.with_limit(limit).with_offset(offset))
                .await?;
            if context.json {
                context.json(&response)?;
            } else {
                context.header("Mod search results");
                for hit in &response.hits {
                    context.line(format!(
                        "{}  {}  {} downloads  {}",
                        hit.project_id,
                        hit.title,
                        hit.downloads,
                        hit.latest_version.as_deref().unwrap_or("-")
                    ));
                }
                context.field("Total hits", response.total_hits);
            }
            Ok(())
        }
        ModAction::Install {
            instance,
            project,
            version,
            game_version,
            loader,
        } => {
            let instance = load_instance(context, &instance)?;
            let client = ModrinthClient::new()?;
            let selected = match version {
                Some(id) => client.version(&id).await?,
                None => {
                    let game_version =
                        game_version.or_else(|| instance.manifest.version_id.clone());
                    let loader = loader.or_else(|| {
                        instance
                            .manifest
                            .version_id
                            .as_deref()
                            .and_then(loader_from_version)
                    });
                    let versions = client
                        .versions(
                            &project,
                            game_version
                                .as_deref()
                                .map(|v| vec![v.to_string()])
                                .unwrap_or_default()
                                .as_slice(),
                            loader
                                .as_deref()
                                .map(|v| vec![v.to_string()])
                                .unwrap_or_default()
                                .as_slice(),
                        )
                        .await?;
                    best_version(&versions, game_version.as_deref(), loader.as_deref())
                        .cloned()
                        .ok_or_else(|| {
                            Error::NotFound(format!(
                                "no compatible version for project '{project}'"
                            ))
                        })?
                }
            };
            let manager = ModManager::new(instance.clone(), context.layout.clone())?;
            let installed = manager.install_version(&selected).await?;
            if context.json {
                context.json(&installed)?;
            } else {
                context.header("Mod installed");
                context.field("Project", &installed.title);
                context.field("Version", &installed.version_number);
                context.field("File", &installed.file_name);
            }
            Ok(())
        }
        ModAction::List { instance } => {
            let instance = load_instance(context, &instance)?;
            let manager = ModManager::new(instance, context.layout.clone())?;
            let mods = manager.list()?;
            if context.json {
                context.json(&mods)?;
            } else {
                context.header("Installed mods");
                for item in mods {
                    context.line(format!(
                        "{}{}  {}  {}",
                        if item.enabled { "  " } else { "x " },
                        item.title,
                        item.version_number,
                        item.file_name
                    ));
                }
            }
            Ok(())
        }
        ModAction::Enable { instance, project } => set_enabled(context, &instance, &project, true),
        ModAction::Disable { instance, project } => {
            set_enabled(context, &instance, &project, false)
        }
        ModAction::Remove { instance, project } => {
            let instance = load_instance(context, &instance)?;
            let manager = ModManager::new(instance, context.layout.clone())?;
            manager.remove(&project)?;
            if context.json {
                context.json(&json!({ "removed": project }))?;
            } else {
                context.field("Removed", project);
            }
            Ok(())
        }
        ModAction::Updates { instance, apply } => {
            let instance = load_instance(context, &instance)?;
            let manager = ModManager::new(instance, context.layout.clone())?;
            let updates = manager.check_updates().await?;
            if apply {
                for update in &updates {
                    manager.apply_update(update).await?;
                }
            }
            if context.json {
                let rows: Vec<_> = updates
                    .iter()
                    .map(|update| {
                        json!({
                            "projectId": update.project_id,
                            "title": update.title,
                            "currentVersionId": update.current_version_id,
                            "latestVersionId": update.latest_version_id,
                            "latestVersionNumber": update.latest_version_number,
                        })
                    })
                    .collect();
                context.json(&json!({ "updates": rows, "applied": apply }))?;
            } else {
                context.header("Mod updates");
                if updates.is_empty() {
                    context.line("All mods are up to date.");
                }
                for update in &updates {
                    context.line(format!(
                        "{}  {} -> {}",
                        update.title, update.current_version_id, update.latest_version_number
                    ));
                }
                if apply {
                    context.field("Applied", updates.len());
                }
            }
            Ok(())
        }
    }
}

fn set_enabled(context: &Context, instance: &str, project: &str, enabled: bool) -> Result<()> {
    let instance = load_instance(context, instance)?;
    let manager = ModManager::new(instance, context.layout.clone())?;
    manager.set_enabled(project, enabled)?;
    if context.json {
        context.json(&json!({ "project": project, "enabled": enabled }))?;
    } else {
        context.field("Project", project);
        context.field("Enabled", if enabled { "yes" } else { "no" });
    }
    Ok(())
}
