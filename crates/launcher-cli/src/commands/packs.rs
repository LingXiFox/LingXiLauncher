use std::path::{Path, PathBuf};

use launcher_core::install::hashing::sha1_file;
use launcher_core::modrinth::{best_version, ModrinthClient, SearchQuery};
use launcher_core::mods::sanitize_file_name;
use launcher_core::resourcepacks::{ResourcePackEntry, ResourcePackManager};
use launcher_core::shaders::{ShaderPackEntry, ShaderPackManager};
use launcher_core::{Error, Result};
use serde::Serialize;

use crate::commands::mods::{load_instance, loader_from_version};
use crate::context::Context;
use crate::PackAction;

#[derive(Clone, Copy)]
enum Kind {
    Resource,
    Shader,
}

impl Kind {
    fn project_type(self) -> &'static str {
        match self {
            Self::Resource => "resourcepack",
            Self::Shader => "shader",
        }
    }

    fn loader(self) -> Option<&'static str> {
        match self {
            Self::Resource => None,
            Self::Shader => Some("iris"),
        }
    }
}

enum Manager {
    Resource(ResourcePackManager),
    Shader(ShaderPackManager),
}

impl Manager {
    fn new(kind: Kind, game_directory: PathBuf) -> Self {
        match kind {
            Kind::Resource => Self::Resource(ResourcePackManager::new(game_directory)),
            Kind::Shader => Self::Shader(ShaderPackManager::new(game_directory)),
        }
    }

    fn list(&self) -> Result<Vec<PackRow>> {
        match self {
            Self::Resource(manager) => Ok(manager.list()?.into_iter().map(PackRow::from).collect()),
            Self::Shader(manager) => Ok(manager.list()?.into_iter().map(PackRow::from).collect()),
        }
    }

    fn import(&self, source: &Path) -> Result<PackRow> {
        match self {
            Self::Resource(manager) => Ok(PackRow::from(manager.import(source)?)),
            Self::Shader(manager) => Ok(PackRow::from(manager.import(source)?)),
        }
    }

    fn set_enabled(&self, file_name: &str, enabled: bool) -> Result<()> {
        match self {
            Self::Resource(manager) => manager.set_enabled(file_name, enabled),
            Self::Shader(manager) => manager.set_enabled(file_name, enabled),
        }
    }

    fn delete(&self, file_name: &str) -> Result<()> {
        match self {
            Self::Resource(manager) => manager.delete(file_name),
            Self::Shader(manager) => manager.delete(file_name),
        }
    }

    fn directory(&self) -> PathBuf {
        match self {
            Self::Resource(manager) => manager.packs_directory(),
            Self::Shader(manager) => manager.packs_directory(),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct PackRow {
    file_name: String,
    name: String,
    description: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pack_format: Option<i32>,
    enabled: bool,
    size_bytes: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    icon_data_url: Option<String>,
}

impl From<ResourcePackEntry> for PackRow {
    fn from(entry: ResourcePackEntry) -> Self {
        Self {
            file_name: entry.file_name,
            name: entry.title,
            description: entry.description,
            pack_format: entry.pack_format,
            enabled: entry.enabled,
            size_bytes: entry.size_bytes,
            icon_data_url: entry.icon_data_url,
        }
    }
}

impl From<ShaderPackEntry> for PackRow {
    fn from(entry: ShaderPackEntry) -> Self {
        Self {
            file_name: entry.file_name,
            name: entry.name,
            description: String::new(),
            pack_format: None,
            enabled: entry.enabled,
            size_bytes: entry.size_bytes,
            icon_data_url: None,
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PackUpdateRow {
    file_name: String,
    project_id: Option<String>,
    current_version_id: Option<String>,
    current_version_number: Option<String>,
    latest_version_id: Option<String>,
    latest_version_number: Option<String>,
    update_available: bool,
    note: Option<String>,
}

pub async fn resourcepack(context: &Context, action: PackAction) -> Result<()> {
    packs(context, Kind::Resource, action).await
}

pub async fn shader(context: &Context, action: PackAction) -> Result<()> {
    packs(context, Kind::Shader, action).await
}

async fn packs(context: &Context, kind: Kind, action: PackAction) -> Result<()> {
    match action {
        PackAction::Search {
            query,
            instance,
            offset,
            limit,
        } => {
            let instance = instance
                .as_deref()
                .map(|id| load_instance(context, id))
                .transpose()?;
            let game_version = instance
                .as_ref()
                .and_then(|instance| instance.manifest.version_id.clone());
            let mut search = SearchQuery::new(query.unwrap_or_default())
                .facet("project_type", [kind.project_type().to_string()]);
            if let Some(game_version) = game_version {
                search = search.facet("versions", [game_version]);
            }
            if let Some(loader) = kind.loader() {
                search = search.facet("categories", [loader.to_string()]);
            }
            let client = ModrinthClient::new()?;
            let response = client
                .search(&search.with_limit(limit).with_offset(offset))
                .await?;
            if context.json {
                context.json(&response)?;
            } else {
                context.header(if matches!(kind, Kind::Shader) {
                    "Shader search results"
                } else {
                    "Resource pack search results"
                });
                for hit in &response.hits {
                    context.line(format!(
                        "{}  {}  {} downloads",
                        hit.project_id, hit.title, hit.downloads
                    ));
                }
                context.field("Total hits", response.total_hits);
            }
            Ok(())
        }
        PackAction::Install {
            instance,
            project,
            version,
        } => {
            let instance = load_instance(context, &instance)?;
            let game_version = instance.manifest.version_id.clone().ok_or_else(|| {
                Error::MissingInput("the instance has no assigned Minecraft version".into())
            })?;
            let client = ModrinthClient::new()?;
            let selected = match version {
                Some(id) => client.version(&id).await?,
                None => {
                    let game_versions = vec![game_version];
                    let loaders = kind
                        .loader()
                        .map(|loader| vec![loader.to_string()])
                        .unwrap_or_default();
                    let versions = client.versions(&project, &game_versions, &loaders).await?;
                    best_version(
                        &versions,
                        game_versions.first().map(String::as_str),
                        kind.loader(),
                    )
                    .cloned()
                    .ok_or_else(|| {
                        Error::NotFound(format!("no compatible version for project '{project}'"))
                    })?
                }
            };
            let file = selected.primary_file().ok_or_else(|| {
                Error::InvalidMetadata("the selected version has no downloadable file".into())
            })?;
            let file_name = sanitize_file_name(&file.filename)?;
            let cache = context.layout.downloads_cache_directory();
            std::fs::create_dir_all(&cache)?;
            let destination = cache.join(file_name);
            client.download_file(file, &destination).await?;
            let manager = Manager::new(kind, instance.game_directory.clone());
            let imported = manager.import(&destination)?;
            if context.json {
                context.json(&imported)?;
            } else {
                context.header("Pack installed");
                context.field("Name", &imported.name);
                context.field("File", &imported.file_name);
                context.field("Version", &selected.version_number);
            }
            Ok(())
        }
        PackAction::List { instance } => {
            let instance = load_instance(context, &instance)?;
            let manager = Manager::new(kind, instance.game_directory.clone());
            let packs = manager.list()?;
            if context.json {
                context.json(&packs)?;
            } else {
                context.header("Installed packs");
                if packs.is_empty() {
                    context.line("No packs found.");
                }
                for pack in packs {
                    context.line(format!(
                        "{}{}  {}",
                        if pack.enabled { "  " } else { "x " },
                        pack.name,
                        pack.file_name
                    ));
                }
            }
            Ok(())
        }
        PackAction::Import { instance, file } => {
            let instance = load_instance(context, &instance)?;
            let manager = Manager::new(kind, instance.game_directory.clone());
            let imported = manager.import(&file)?;
            if context.json {
                context.json(&imported)?;
            } else {
                context.header("Pack imported");
                context.field("Name", &imported.name);
                context.field("File", &imported.file_name);
            }
            Ok(())
        }
        PackAction::Updates { instance } => {
            let instance = load_instance(context, &instance)?;
            let manager = Manager::new(kind, instance.game_directory.clone());
            let installed = manager.list()?;
            let client = ModrinthClient::new()?;
            let game_version = instance.manifest.version_id.clone().unwrap_or_default();
            let loader = kind.loader().map(str::to_string).or_else(|| {
                instance
                    .manifest
                    .version_id
                    .as_deref()
                    .and_then(loader_from_version)
            });
            let mut rows = Vec::new();
            for pack in installed {
                let path = manager.directory().join(&pack.file_name);
                if !pack.file_name.to_ascii_lowercase().ends_with(".zip") || !path.is_file() {
                    rows.push(PackUpdateRow {
                        file_name: pack.file_name,
                        project_id: None,
                        current_version_id: None,
                        current_version_number: None,
                        latest_version_id: None,
                        latest_version_number: None,
                        update_available: false,
                        note: Some("only zip archives can be checked for updates".into()),
                    });
                    continue;
                }
                let sha1 = sha1_file(&path)?;
                let current = match client.version_from_sha1(&sha1).await {
                    Ok(version) => version,
                    Err(Error::NotFound(_)) => {
                        rows.push(PackUpdateRow {
                            file_name: pack.file_name,
                            project_id: None,
                            current_version_id: None,
                            current_version_number: None,
                            latest_version_id: None,
                            latest_version_number: None,
                            update_available: false,
                            note: Some(
                                "not published on Modrinth; cannot check for updates".into(),
                            ),
                        });
                        continue;
                    }
                    Err(error) => return Err(error),
                };
                let game_versions = if game_version.is_empty() {
                    Vec::new()
                } else {
                    vec![game_version.clone()]
                };
                let loaders: Vec<String> = loader.iter().cloned().collect();
                let versions = client
                    .versions(&current.project_id, &game_versions, &loaders)
                    .await?;
                let latest = best_version(
                    &versions,
                    game_versions.first().map(String::as_str),
                    loader.as_deref(),
                )
                .cloned();
                let update_available = latest
                    .as_ref()
                    .is_some_and(|version| version.id != current.id);
                rows.push(PackUpdateRow {
                    file_name: pack.file_name,
                    project_id: Some(current.project_id.clone()),
                    current_version_id: Some(current.id.clone()),
                    current_version_number: Some(current.version_number.clone()),
                    latest_version_id: latest.as_ref().map(|version| version.id.clone()),
                    latest_version_number: latest
                        .as_ref()
                        .map(|version| version.version_number.clone()),
                    update_available,
                    note: None,
                });
            }
            if context.json {
                context.json(&rows)?;
            } else {
                context.header("Pack updates");
                if rows.is_empty() {
                    context.line("No packs installed.");
                }
                for row in rows {
                    if row.update_available {
                        context.line(format!(
                            "{}  {} -> {}",
                            row.file_name,
                            row.current_version_number.as_deref().unwrap_or("-"),
                            row.latest_version_number.as_deref().unwrap_or("-")
                        ));
                    } else {
                        context.line(format!(
                            "{}  {}",
                            row.file_name,
                            row.note.as_deref().unwrap_or("up to date")
                        ));
                    }
                }
            }
            Ok(())
        }
        PackAction::Enable { instance, file } => set_enabled(context, kind, &instance, &file, true),
        PackAction::Disable { instance, file } => {
            set_enabled(context, kind, &instance, &file, false)
        }
        PackAction::Remove { instance, file } => {
            let instance = load_instance(context, &instance)?;
            let manager = Manager::new(kind, instance.game_directory.clone());
            manager.delete(&file)?;
            if context.json {
                context.json(&serde_json::json!({ "removed": file }))?;
            } else {
                context.field("Removed", file);
            }
            Ok(())
        }
    }
}

fn set_enabled(
    context: &Context,
    kind: Kind,
    instance: &str,
    file: &str,
    enabled: bool,
) -> Result<()> {
    let instance = load_instance(context, instance)?;
    let manager = Manager::new(kind, instance.game_directory.clone());
    manager.set_enabled(file, enabled)?;
    if context.json {
        context.json(&serde_json::json!({ "file": file, "enabled": enabled }))?;
    } else {
        context.field("File", file);
        context.field("Enabled", if enabled { "yes" } else { "no" });
    }
    Ok(())
}
