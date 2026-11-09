use launcher_core::worlds::WorldManager;
use launcher_core::{Error, Result};
use serde_json::json;

use crate::commands::mods::load_instance;
use crate::context::Context;
use crate::WorldAction;

pub fn world(context: &Context, action: WorldAction) -> Result<()> {
    let manager = WorldManager::new(context.layout.clone());
    match action {
        WorldAction::List { instance } => {
            let instance = load_instance(context, &instance)?;
            let worlds = manager.list(&instance)?;
            if context.json {
                context.json(&worlds)?;
            } else {
                context.header("Worlds");
                if worlds.is_empty() {
                    context.line("No worlds found.");
                }
                for world in worlds {
                    context.line(format!(
                        "{}  {}  {}  {}",
                        world.folder_name,
                        world.name,
                        world.version_name.as_deref().unwrap_or("-"),
                        crate::context::format_bytes(world.size_bytes)
                    ));
                }
            }
            Ok(())
        }
        WorldAction::Backups { instance } => {
            let instance = load_instance(context, &instance)?;
            let backups = manager.list_backups(&instance)?;
            if context.json {
                context.json(&backups)?;
            } else {
                context.header("World backups");
                if backups.is_empty() {
                    context.line("No backups found.");
                }
                for backup in backups {
                    context.line(format!(
                        "{}  {}  {}  {}",
                        backup.file_name,
                        backup.world_folder,
                        backup
                            .created_at
                            .as_ref()
                            .map(|value| value.to_rfc3339())
                            .unwrap_or_else(|| "-".to_string()),
                        crate::context::format_bytes(backup.size_bytes)
                    ));
                }
            }
            Ok(())
        }
        WorldAction::Backup { instance, world } => {
            let instance = load_instance(context, &instance)?;
            let backups = match world {
                Some(folder) => vec![manager.backup(&instance, &folder)?],
                None => manager.backup_all(&instance)?,
            };
            if context.json {
                context.json(&backups)?;
            } else {
                context.header("World backup");
                if backups.is_empty() {
                    context.line("No worlds to back up.");
                }
                for backup in backups {
                    context.line(format!(
                        "{}  {}  {}",
                        backup.file_name,
                        backup.world_folder,
                        crate::context::format_bytes(backup.size_bytes)
                    ));
                }
            }
            Ok(())
        }
        WorldAction::Restore {
            instance,
            backup,
            confirm,
        } => {
            if !confirm {
                return Err(Error::MissingInput(
                    "world restore requires --confirm".into(),
                ));
            }
            let instance = load_instance(context, &instance)?;
            let restored = manager.restore_backup(&instance, &backup)?;
            if context.json {
                context.json(&restored)?;
            } else {
                context.header("World restored");
                context.field("Backup", backup);
                context.field("World", restored.name);
                context.field("Folder", restored.folder_name);
            }
            Ok(())
        }
        WorldAction::Delete {
            instance,
            backup,
            world,
            confirm,
        } => {
            if !confirm {
                return Err(Error::MissingInput(
                    "world delete requires --confirm".into(),
                ));
            }
            let instance = load_instance(context, &instance)?;
            match (backup, world) {
                (Some(backup), None) => {
                    manager.delete_backup(&instance, &backup)?;
                    if context.json {
                        context.json(&json!({ "deletedBackup": backup }))?;
                    } else {
                        context.field("Deleted backup", backup);
                    }
                }
                (None, Some(world)) => {
                    manager.delete_world(&instance, &world)?;
                    if context.json {
                        context.json(&json!({ "deletedWorld": world }))?;
                    } else {
                        context.field("Deleted world", world);
                    }
                }
                _ => {
                    return Err(Error::MissingInput(
                        "world delete requires exactly one of --backup or --world".into(),
                    ));
                }
            }
            Ok(())
        }
    }
}
