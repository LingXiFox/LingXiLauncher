use std::path::Path;

use launcher_core::models::instance::{Instance, InstanceRepository};
use launcher_core::{Error, Result};

use crate::context::Context;
use crate::InstanceAction;

const SKIPPED: [&str; 4] = ["logs", "crash-reports", ".tmp", "screenshots"];

pub fn instance(context: &Context, action: InstanceAction) -> Result<()> {
    let repository = InstanceRepository::new(context.layout.clone());
    match action {
        InstanceAction::Create { name, version, id } => {
            let instance = match id {
                Some(id) => repository.create(&id, &name, version.as_deref())?,
                None => {
                    let created = repository.create_with_generated_id(&name)?;
                    match version.as_deref() {
                        Some(version) => repository.assign_version(&created, version)?,
                        None => created,
                    }
                }
            };
            print_instance(context, &instance)?;
            Ok(())
        }
        InstanceAction::List => {
            let instances = repository.list()?;
            if context.json {
                let rows: Vec<_> = instances
                    .iter()
                    .map(|instance| {
                        serde_json::json!({
                            "id": instance.id(),
                            "name": instance.manifest.display_name,
                            "versionId": instance.manifest.version_id,
                            "createdAt": instance.manifest.created_at,
                            "lastLaunchedAt": instance.manifest.last_launched_at,
                            "directory": instance.directory.display().to_string(),
                        })
                    })
                    .collect();
                context.json(&rows)?;
            } else {
                context.header("Instances");
                for instance in instances {
                    context.line(format!(
                        "{}  {}  {}",
                        instance.id(),
                        instance.manifest.display_name,
                        instance.manifest.version_id.as_deref().unwrap_or("-")
                    ));
                }
            }
            Ok(())
        }
        InstanceAction::Copy {
            source,
            name,
            saves,
        } => {
            let source = repository.load(&source)?;
            let target = repository.create_with_generated_id(&name)?;
            copy_game_directory(&source.game_directory, &target.game_directory, saves)?;
            repository.set_performance(
                &target,
                source.manifest.memory_mib,
                source.manifest.jvm_arguments.clone().unwrap_or_default(),
            )?;
            if let Some(version) = source.manifest.version_id.as_deref() {
                repository.assign_version(&target, version)?;
            }
            let target = repository.load(target.id())?;
            if context.json {
                context.json(&serde_json::json!({
                    "id": target.id(),
                    "name": target.manifest.display_name,
                    "source": source.id(),
                    "directory": target.directory.display().to_string(),
                    "saves": saves,
                }))?;
            } else {
                context.header("Instance copied");
                context.field("Source", source.id());
                context.field("New instance", target.id());
                context.field("Name", target.manifest.display_name);
                context.field("Saves", if saves { "copied" } else { "skipped" });
            }
            Ok(())
        }
    }
}

fn print_instance(context: &Context, instance: &Instance) -> Result<()> {
    if context.json {
        context.json(&serde_json::json!({
            "id": instance.id(),
            "name": instance.manifest.display_name,
            "versionId": instance.manifest.version_id,
            "directory": instance.directory.display().to_string(),
            "gameDirectory": instance.game_directory.display().to_string(),
        }))?;
    } else {
        context.header("Instance created");
        context.field("ID", instance.id());
        context.field("Name", &instance.manifest.display_name);
        context.field(
            "Version",
            instance.manifest.version_id.as_deref().unwrap_or("-"),
        );
        context.field("Directory", instance.directory.display());
    }
    Ok(())
}

fn copy_game_directory(source: &Path, target: &Path, include_saves: bool) -> Result<()> {
    if !source.is_dir() {
        return Err(Error::NotFound(format!(
            "instance game directory {} does not exist",
            source.display()
        )));
    }
    copy_tree(source, target, include_saves)
}

fn copy_tree(source: &Path, target: &Path, include_saves: bool) -> Result<()> {
    std::fs::create_dir_all(target)?;
    for entry in std::fs::read_dir(source)? {
        let entry = entry?;
        let name = entry.file_name();
        let name_text = name.to_string_lossy();
        if name_text == "saves" && !include_saves {
            continue;
        }
        if SKIPPED.contains(&name_text.as_ref()) {
            continue;
        }
        let file_type = entry.file_type()?;
        if file_type.is_symlink() {
            continue;
        }
        let from = entry.path();
        let to = target.join(&name);
        if file_type.is_dir() {
            copy_tree(&from, &to, include_saves)?;
        } else if file_type.is_file() {
            std::fs::copy(&from, &to).map_err(|error| {
                Error::Io(std::io::Error::new(
                    error.kind(),
                    format!("copy {} to {}: {error}", from.display(), to.display()),
                ))
            })?;
        }
    }
    Ok(())
}
