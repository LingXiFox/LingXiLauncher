pub mod arguments;
pub mod rules;

use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::layout::GameDataLayout;
use crate::models::version::{
    ArgumentEntry, Artifact, AssetIndex, JavaVersion, Library, LoggingClient, VersionMetadata, VersionType,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum VersionCompatibility {
    Modern,
    LegacyArguments,
    Incomplete,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaVersionRequirement {
    pub component: Option<String>,
    pub major_version: Option<u32>,
}

#[derive(Debug, Clone)]
pub struct ResolvedVersion {
    pub id: String,
    pub version_type: Option<VersionType>,
    pub main_class: String,
    pub asset_index_id: String,
    pub java_requirement: JavaVersionRequirement,
    pub libraries: Vec<Library>,
    pub jvm_arguments: Vec<ArgumentEntry>,
    pub game_arguments: Vec<ArgumentEntry>,
    pub default_user_jvm_arguments: Vec<ArgumentEntry>,
    pub asset_index: Option<AssetIndex>,
    pub client_logging: Option<LoggingClient>,
    pub client_jar: Option<Artifact>,
    pub client_jar_version_id: String,
    pub natives_version_id: String,
    pub inherits_from: Option<String>,
    pub compatibility: VersionCompatibility,
    pub version_directory: PathBuf,
    pub metadata_url: PathBuf,
    pub release_time: Option<DateTime<Utc>>,
}

impl ResolvedVersion {
    pub fn requires_java(&self, major: u32) -> bool {
        self.java_requirement.major_version.is_some_and(|required| required > major)
    }
}

pub struct VersionResolver;

impl VersionResolver {
    pub fn resolve(&self, version_id: &str, game_root: &Path) -> Result<ResolvedVersion> {
        let layout = GameDataLayout::new(game_root, game_root);
        let chain = load_chain(version_id, &layout, &[])?;
        let child = chain.last().ok_or_else(|| Error::InvalidMetadata(format!("empty version chain for {version_id}")))?;
        normalize(&chain, version_id, &layout, child)
    }

    /// Normalizes decoded metadata with no parent chain. Metadata with `inheritsFrom`
    /// is rejected: callers must resolve from a game root so the parent is loaded.
    pub fn resolve_metadata(
        &self,
        metadata: VersionMetadata,
        version_id: &str,
        version_directory: PathBuf,
        metadata_url: PathBuf,
    ) -> Result<ResolvedVersion> {
        if let Some(parent) = metadata.inherits_from.as_ref().filter(|p| !p.trim().is_empty()) {
            return Err(Error::NotFound(format!(
                "version {version_id} inherits from '{parent}' but no parent chain was supplied"
            )));
        }
        if metadata.id != version_id {
            return Err(Error::InvalidMetadata(format!(
                "version JSON id '{}' does not match requested version '{version_id}'",
                metadata.id
            )));
        }
        normalize_with(&[metadata.clone()], version_id, version_directory, metadata_url, &metadata)
    }
}

fn load_chain(version_id: &str, layout: &GameDataLayout, stack: &[String]) -> Result<Vec<VersionMetadata>> {
    if stack.len() >= 16 {
        return Err(Error::UnsupportedVersion(format!(
            "version inheritance chain is deeper than 16 entries at '{version_id}'"
        )));
    }
    if stack.iter().any(|entry| entry == version_id) {
        let cycle = stack.iter().cloned().chain(std::iter::once(version_id.to_string())).collect::<Vec<_>>().join(" -> ");
        return Err(Error::InvalidMetadata(format!("circular version inheritance: {cycle}")));
    }
    let path = layout.version_json(version_id)?;
    if !path.is_file() {
        return Err(Error::NotFound(format!("version metadata not found: {}", path.display())));
    }
    let data = std::fs::read(&path)?;
    let metadata: VersionMetadata = serde_json::from_slice(&data).map_err(|e| {
        Error::InvalidMetadata(format!("corrupted versions/{version_id}/{version_id}.json: {e}"))
    })?;
    if metadata.id != version_id {
        return Err(Error::InvalidMetadata(format!(
            "version JSON id '{}' does not match directory '{version_id}'",
            metadata.id
        )));
    }
    match metadata.inherits_from.as_ref().map(|p| p.trim()).filter(|p| !p.is_empty()) {
        Some(parent) => {
            let parent = parent.to_string();
            let mut chain = load_chain(&parent, layout, &[stack, &[version_id.to_string()]].concat())?;
            chain.push(metadata);
            Ok(chain)
        }
        None => Ok(vec![metadata]),
    }
}

fn normalize(chain: &[VersionMetadata], requested_id: &str, layout: &GameDataLayout, child: &VersionMetadata) -> Result<ResolvedVersion> {
    normalize_with(
        chain,
        requested_id,
        layout.version_directory(requested_id)?,
        layout.version_json(requested_id)?,
        child,
    )
}

fn normalize_with(
    chain: &[VersionMetadata],
    requested_id: &str,
    version_directory: PathBuf,
    metadata_url: PathBuf,
    child: &VersionMetadata,
) -> Result<ResolvedVersion> {
    let main_class = chain
        .iter()
        .rev()
        .find_map(|m| m.main_class.as_ref().filter(|v| !v.trim().is_empty()).cloned())
        .ok_or_else(|| Error::InvalidMetadata(format!("version {requested_id} declares an empty mainClass")))?;

    let asset_index = chain.iter().rev().find_map(|m| m.asset_index.clone());
    let assets = chain.iter().rev().find_map(|m| m.assets.clone());
    let asset_index_id = asset_index
        .as_ref()
        .map(|a| a.id.clone())
        .or(assets)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| Error::InvalidMetadata(format!("version {requested_id} has no assetIndex or assets id")))?;

    let java_requirement = merged_java_requirement(chain);
    let libraries = merged_libraries(chain);
    let (jvm, game, default_user, compatibility) = merged_arguments(chain);
    if game.is_empty() {
        return Err(Error::InvalidMetadata(format!(
            "version {requested_id} declares no game arguments after inheritance"
        )));
    }

    let client_info = chain
        .iter()
        .rev()
        .find_map(|m| m.downloads.as_ref().and_then(|d| d.client.clone()).map(|client| (m.id.clone(), client)));
    let client_jar_version_id = client_info.as_ref().map(|(id, _)| id.clone()).unwrap_or_else(|| requested_id.to_string());

    Ok(ResolvedVersion {
        id: requested_id.to_string(),
        version_type: chain.iter().rev().find_map(|m| m.version_type),
        main_class,
        asset_index_id,
        java_requirement,
        libraries,
        jvm_arguments: jvm,
        game_arguments: game,
        default_user_jvm_arguments: default_user,
        asset_index,
        client_logging: chain.iter().rev().find_map(|m| m.logging.clone()).and_then(|l| l.client),
        client_jar: client_info.map(|(_, client)| client),
        client_jar_version_id: client_jar_version_id.clone(),
        natives_version_id: client_jar_version_id,
        inherits_from: child.inherits_from.clone(),
        compatibility,
        version_directory,
        metadata_url,
        release_time: chain.iter().rev().find_map(|m| m.release_time),
    })
}

fn merged_java_requirement(chain: &[VersionMetadata]) -> JavaVersionRequirement {
    let mut component = None;
    let mut major: Option<u32> = None;
    for metadata in chain {
        let Some(requirement) = metadata.java_version.as_ref() else { continue };
        if major.is_none() || requirement.major_version >= major.unwrap_or(0) {
            major = Some(requirement.major_version);
            if !requirement.component.is_empty() {
                component = Some(requirement.component.clone());
            }
        }
    }
    JavaVersionRequirement { component, major_version: major }
}

fn library_key(library: &Library) -> String {
    let base = match library.maven() {
        Ok(coordinates) => format!(
            "{}:{}:{}",
            coordinates.group,
            coordinates.artifact,
            coordinates.classifier.unwrap_or_default()
        ),
        Err(_) => library.name.clone(),
    };
    let natives = library
        .natives
        .as_ref()
        .map(|map| {
            let mut pairs: Vec<String> = map.iter().map(|(k, v)| format!("{k}={v}")).collect();
            pairs.sort();
            pairs.join(",")
        })
        .unwrap_or_default();
    let classifiers = library
        .downloads
        .as_ref()
        .and_then(|d| d.classifiers.as_ref())
        .map(|map| {
            let mut keys: Vec<String> = map.keys().cloned().collect();
            keys.sort();
            keys.join(",")
        })
        .unwrap_or_default();
    let extract = library
        .extract
        .as_ref()
        .map(|e| {
            let mut values = e.exclude.clone();
            values.sort();
            values.join(",")
        })
        .unwrap_or_default();
    format!("{base}|natives={natives}|classifiers={classifiers}|extract={extract}")
}

fn merged_libraries(chain: &[VersionMetadata]) -> Vec<Library> {
    let mut result: Vec<Library> = Vec::new();
    let mut index: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    for metadata in chain {
        for library in &metadata.libraries {
            let key = library_key(library);
            if let Some(existing) = index.get(&key) {
                result[*existing] = library.clone();
            } else {
                index.insert(key, result.len());
                result.push(library.clone());
            }
        }
    }
    result
}

fn merged_arguments(chain: &[VersionMetadata]) -> (Vec<ArgumentEntry>, Vec<ArgumentEntry>, Vec<ArgumentEntry>, VersionCompatibility) {
    let mut jvm = Vec::new();
    let mut game = Vec::new();
    let mut default_user = Vec::new();
    for metadata in chain {
        if let Some(arguments) = &metadata.arguments {
            jvm.extend(arguments.jvm.iter().cloned());
            game.extend(arguments.game.iter().cloned());
            default_user.extend(arguments.default_user_jvm.iter().cloned());
        }
    }
    let mut compatibility = VersionCompatibility::Modern;
    let legacy = chain
        .iter()
        .rev()
        .find_map(|m| m.minecraft_arguments.as_ref().filter(|v| !v.is_empty()));
    if game.is_empty() {
        if let Some(raw) = legacy {
            game = parse_legacy_arguments(raw);
            compatibility = VersionCompatibility::LegacyArguments;
        }
    }
    if jvm.is_empty() {
        jvm = legacy_jvm_arguments();
        if compatibility == VersionCompatibility::Modern {
            compatibility = VersionCompatibility::Incomplete;
        }
    }
    (jvm, game, default_user, compatibility)
}

pub fn parse_legacy_arguments(raw: &str) -> Vec<ArgumentEntry> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut quote: Option<char> = None;
    let mut escaping = false;
    for character in raw.chars() {
        if escaping {
            current.push(character);
            escaping = false;
            continue;
        }
        if character == '\\' {
            escaping = true;
            continue;
        }
        if let Some(active) = quote {
            if character == active {
                quote = None;
            } else {
                current.push(character);
            }
            continue;
        }
        if character == '"' || character == '\'' {
            quote = Some(character);
        } else if character.is_whitespace() {
            if !current.is_empty() {
                tokens.push(ArgumentEntry::Plain(std::mem::take(&mut current)));
            }
        } else {
            current.push(character);
        }
    }
    if !current.is_empty() {
        tokens.push(ArgumentEntry::Plain(current));
    }
    tokens
}

pub fn legacy_jvm_arguments() -> Vec<ArgumentEntry> {
    [
        "-Djava.library.path=${natives_directory}",
        "-Dminecraft.launcher.brand=${launcher_name}",
        "-Dminecraft.launcher.version=${launcher_version}",
        "-cp",
        "${classpath}",
    ]
    .into_iter()
    .map(|value| ArgumentEntry::Plain(value.to_string()))
    .collect()
}

/// Convenience so callers can build a requirement without naming the model.
pub fn requirement_from(java: Option<&JavaVersion>) -> JavaVersionRequirement {
    match java {
        Some(value) => JavaVersionRequirement { component: Some(value.component.clone()), major_version: Some(value.major_version) },
        None => JavaVersionRequirement::default(),
    }
}
