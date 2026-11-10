use std::path::{Path, PathBuf};

use launcher_core::java::JavaManager;
use launcher_core::models::instance::{Instance, InstanceRepository};
use launcher_core::modpack::{self, ModpackLoaderKind, ModpackManifest, ModpackUpdate};
use launcher_core::modrinth::ModrinthClient;
use launcher_core::{Error, Result};

use crate::context::Context;
use crate::{ModpackAction, ModpackUpdateAction, MrpackAction};

pub async fn mrpack(context: &Context, action: MrpackAction) -> Result<()> {
    match action {
        MrpackAction::Inspect { file } => {
            let summary = modpack::inspect(&file)?;
            if context.json {
                context.json(&summary)?;
            } else {
                context.header("Modpack archive");
                context.field("Name", &summary.name);
                context.field("Version", &summary.version_id);
                if !summary.summary.is_empty() {
                    context.field("Summary", &summary.summary);
                }
                context.field("Files", summary.file_count);
                context.field("Size", crate::context::format_bytes(summary.total_size));
                for (key, value) in &summary.dependencies {
                    context.field(key, value);
                }
            }
            Ok(())
        }
        MrpackAction::Install { file, name } => {
            let summary = modpack::inspect(&file)?;
            let loader = modpack::resolve_loader(&summary.dependencies);
            if let Some(loader) = &loader {
                if matches!(
                    loader.kind,
                    ModpackLoaderKind::Quilt | ModpackLoaderKind::Forge
                ) {
                    return Err(Error::UnsupportedVersion(format!(
                        "modpack uses {} which is not supported yet",
                        loader.kind.modrinth_loader()
                    )));
                }
            }
            let display_name = name.unwrap_or_else(|| summary.name.clone());
            let cancel = context.cancel();
            let instance = modpack::install(
                &file,
                &display_name,
                &context.layout,
                Some(context.progress()),
                Some(&cancel),
            )
            .await?;
            let manifest = modpack::read_manifest(&instance)?;
            let game_version =
                manifest
                    .dependencies
                    .get("minecraft")
                    .cloned()
                    .ok_or_else(|| {
                        Error::InvalidMetadata(
                            "modpack does not declare a Minecraft version".into(),
                        )
                    })?;
            if !context.layout.version_json(&game_version)?.is_file() {
                context
                    .installer()
                    .install(&game_version, context.progress(), context.cancel())
                    .await?;
            }
            if let Some(loader) = manifest.loader.as_ref() {
                install_loader(context, &instance, &game_version, loader).await?;
            }
            let instance = InstanceRepository::new(context.layout.clone()).load(instance.id())?;
            print_instance(context, &instance)?;
            Ok(())
        }
    }
}

async fn install_loader(
    context: &Context,
    instance: &Instance,
    game_version: &str,
    loader: &modpack::ModpackLoader,
) -> Result<()> {
    let installer = context.loader_installer()?;
    match loader.kind {
        ModpackLoaderKind::Fabric => {
            installer
                .install_fabric(
                    instance,
                    game_version,
                    Some(&loader.version),
                    context.progress(),
                    context.cancel(),
                )
                .await?;
        }
        ModpackLoaderKind::NeoForge => {
            let java = instance
                .manifest
                .java_runtime
                .as_ref()
                .map(|runtime| PathBuf::from(&runtime.executable))
                .or_else(|| {
                    JavaManager::new(context.layout.clone())
                        .find(21)
                        .map(|runtime| runtime.executable)
                })
                .unwrap_or_else(|| PathBuf::from(if cfg!(windows) { "java.exe" } else { "java" }));
            installer
                .install_neoforge(
                    instance,
                    game_version,
                    &loader.version,
                    &java,
                    context.progress(),
                    context.cancel(),
                )
                .await?;
        }
        ModpackLoaderKind::Quilt | ModpackLoaderKind::Forge => {
            return Err(Error::UnsupportedVersion(format!(
                "loader {} is not supported yet",
                loader.kind.modrinth_loader()
            )));
        }
    }
    Ok(())
}

pub async fn modpack(context: &Context, action: ModpackAction) -> Result<()> {
    match action {
        ModpackAction::Info { instance } => {
            let instance = load_instance(context, &instance)?;
            let manifest = modpack::read_manifest(&instance)?;
            if context.json {
                context.json(&manifest)?;
            } else {
                print_manifest(&manifest);
            }
            Ok(())
        }
        ModpackAction::Update { action } => update(context, action).await,
    }
}

async fn update(context: &Context, action: ModpackUpdateAction) -> Result<()> {
    match action {
        ModpackUpdateAction::Check { instance } => {
            let instance = load_instance(context, &instance)?;
            let client = ModrinthClient::new()?;
            let update = modpack::check_update(&instance, &client).await?;
            if context.json {
                match &update {
                    Some(update) => context.json(&serde_json::json!({
                        "update": update.latest_version.id,
                        "version_number": update.latest_version.version_number,
                        "type": update.latest_version.version_type,
                    }))?,
                    None => context.json(&serde_json::json!({ "update": null }))?,
                }
            } else if let Some(update) = &update {
                context.header("Modpack update available");
                context.field("Current", &update.current_version_id);
                context.field("Latest", &update.latest_version.version_number);
                context.field("Version ID", &update.latest_version.id);
            } else {
                context.line("Already up to date.");
            }
            Ok(())
        }
        ModpackUpdateAction::Preview { instance } => {
            let instance = load_instance(context, &instance)?;
            let client = ModrinthClient::new()?;
            let update = require_update(&instance, &client).await?;
            let current = instance.manifest.version_id.clone().unwrap_or_default();
            if context.json {
                context.json(&serde_json::json!({
                    "currentVersionID": current,
                    "targetVersionNumber": update.latest_version.version_number,
                    "targetVersionID": update.latest_version.id,
                    "fileCount": update.latest_version.files.len(),
                    "downloadURL": update.download_url,
                }))?;
            } else {
                context.header("Modpack update preview");
                context.field("Current", current);
                context.field("Target", &update.latest_version.version_number);
                context.field("Files", update.latest_version.files.len());
                context.field("Download", &update.download_url);
            }
            Ok(())
        }
        ModpackUpdateAction::Apply {
            instance,
            preserve,
            yes,
        } => {
            if !yes {
                return Err(Error::MissingInput(
                    "modpack update apply requires --yes".into(),
                ));
            }
            let instance = load_instance(context, &instance)?;
            let client = ModrinthClient::new()?;
            let update = require_update(&instance, &client).await?;
            let preserved = preserve
                .as_deref()
                .map(parse_preserve)
                .transpose()?
                .unwrap_or_default();
            let staging = if preserved.is_empty() {
                None
            } else {
                Some(stage_preserved(&instance, &preserved)?)
            };
            let cancel = context.cancel();
            let updated = modpack::apply_update(
                &instance,
                &context.layout,
                &update,
                Some(context.progress()),
                Some(&cancel),
            )
            .await?;
            if let Some(staging) = staging {
                restore_preserved(&updated, &staging, &preserved)?;
                let _ = std::fs::remove_dir_all(&staging);
            }
            let updated = InstanceRepository::new(context.layout.clone()).load(updated.id())?;
            if context.json {
                context.json(&serde_json::json!({
                    "instance": updated.id(),
                    "version": updated.manifest.version_id,
                    "applied": update.latest_version.version_number,
                }))?;
            } else {
                context.header("Modpack updated");
                context.field("Instance", updated.id());
                context.field("Version", update.latest_version.version_number);
            }
            Ok(())
        }
        ModpackUpdateAction::Recover { instance } => {
            let instance = load_instance(context, &instance)?;
            let recovered = recover(&instance)?;
            if context.json {
                context.json(&serde_json::json!({ "recovered": recovered }))?;
            } else if recovered {
                context.line("Recovered interrupted update.");
            } else {
                context.line("No interrupted update found.");
            }
            Ok(())
        }
    }
}

async fn require_update(instance: &Instance, client: &ModrinthClient) -> Result<ModpackUpdate> {
    modpack::check_update(instance, client)
        .await?
        .ok_or_else(|| Error::NotFound("modpack is already up to date".into()))
}

fn parse_preserve(value: &str) -> Result<Vec<PathBuf>> {
    let mut paths = Vec::new();
    for part in value.split(',') {
        let trimmed = part.trim();
        if trimmed.is_empty() {
            continue;
        }
        let path = PathBuf::from(trimmed);
        if path.is_absolute()
            || path
                .components()
                .any(|c| matches!(c, std::path::Component::ParentDir))
        {
            return Err(Error::UnsafePath(format!(
                "invalid preserve path '{trimmed}'"
            )));
        }
        paths.push(path);
    }
    Ok(paths)
}

fn stage_preserved(instance: &Instance, paths: &[PathBuf]) -> Result<PathBuf> {
    let staging = instance
        .directory
        .join(format!(".preserve-{}", uuid::Uuid::new_v4()));
    for relative in paths {
        let source = instance.game_directory.join(relative);
        if !source.is_file() {
            continue;
        }
        let destination = staging.join(relative);
        if let Some(parent) = destination.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::copy(&source, &destination)?;
    }
    Ok(staging)
}

fn restore_preserved(instance: &Instance, staging: &Path, paths: &[PathBuf]) -> Result<()> {
    for relative in paths {
        let source = staging.join(relative);
        if !source.is_file() {
            continue;
        }
        let destination = instance.game_directory.join(relative);
        if let Some(parent) = destination.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::copy(&source, &destination)?;
    }
    Ok(())
}

fn recover(instance: &Instance) -> Result<bool> {
    let mut recovered = false;
    for entry in std::fs::read_dir(&instance.directory)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        let is_stale_update = name.starts_with(".modpack-update-")
            || (name.starts_with('.') && name.ends_with(".mrpack"));
        let is_staging = name.starts_with(".preserve-");
        if is_stale_update || is_staging {
            let path = entry.path();
            if path.is_dir() {
                std::fs::remove_dir_all(&path)?;
            } else {
                std::fs::remove_file(&path)?;
            }
            recovered = true;
        }
    }
    Ok(recovered)
}

fn load_instance(context: &Context, id: &str) -> Result<Instance> {
    InstanceRepository::new(context.layout.clone()).load(id)
}

fn print_manifest(manifest: &ModpackManifest) {
    println!("Modpack: {}", manifest.name);
    println!("Version: {}", manifest.version_id);
    if !manifest.summary.is_empty() {
        println!("Summary: {}", manifest.summary);
    }
    println!("Files: {}", manifest.files.len());
    println!("Installed: {}", manifest.installed_at);
    for (key, value) in &manifest.dependencies {
        println!("{key}: {value}");
    }
    if let Some(loader) = &manifest.loader {
        println!(
            "Loader: {} {}",
            loader.kind.modrinth_loader(),
            loader.version
        );
    }
}

fn print_instance(context: &Context, instance: &Instance) -> Result<()> {
    if context.json {
        context.json(&serde_json::json!({
            "id": instance.id(),
            "displayName": instance.manifest.display_name,
            "versionId": instance.manifest.version_id,
            "gameDirectory": instance.game_directory,
        }))?;
    } else {
        context.header("Instance ready");
        context.field("Instance", instance.id());
        context.field("Name", &instance.manifest.display_name);
        context.field(
            "Version",
            instance.manifest.version_id.as_deref().unwrap_or("-"),
        );
        context.field("Game directory", instance.game_directory.display());
    }
    Ok(())
}
