//! Modrinth API v2 client and wire models.
//!
//! Only the endpoints the launcher needs are implemented: search, project
//! lookup, version lookup and verified file downloads. All optional response
//! fields carry `#[serde(default)]` so a partial or evolving API payload never
//! breaks the launcher.

use std::path::{Path, PathBuf};
use std::time::Duration;

use chrono::{DateTime, Utc};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use tokio::io::AsyncWriteExt;

use crate::error::{Error, Result};
use crate::install::hashing::sha512_file;
use crate::install::models::{CancelFlag, InstallProgressEvent, SharedProgress};

pub const MODRINTH_API_BASE: &str = "https://api.modrinth.com/v2";
pub const MODRINTH_USER_AGENT: &str = concat!(
    "LingXiLauncher/",
    env!("CARGO_PKG_VERSION"),
    " (local launcher)"
);

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum SearchIndex {
    #[default]
    Relevance,
    Downloads,
    Follows,
    Newest,
    Updated,
}

impl SearchIndex {
    pub fn as_str(self) -> &'static str {
        match self {
            SearchIndex::Relevance => "relevance",
            SearchIndex::Downloads => "downloads",
            SearchIndex::Follows => "follows",
            SearchIndex::Newest => "newest",
            SearchIndex::Updated => "updated",
        }
    }
}

/// A `/search` request. Facets are groups of `key:value` filters; values inside
/// one group are OR-ed, groups are AND-ed (Modrinth semantics).
#[derive(Debug, Clone)]
pub struct SearchQuery {
    pub query: String,
    pub facets: Vec<Vec<String>>,
    pub limit: u32,
    pub offset: u32,
    pub index: SearchIndex,
}

impl SearchQuery {
    pub fn new(query: impl Into<String>) -> Self {
        Self {
            query: query.into(),
            facets: Vec::new(),
            limit: 20,
            offset: 0,
            index: SearchIndex::Relevance,
        }
    }

    pub fn with_facets(mut self, facets: Vec<Vec<String>>) -> Self {
        self.facets = facets;
        self
    }

    /// Adds one facet group, for example `facet("categories", ["fabric"])`.
    pub fn facet(
        mut self,
        name: impl Into<String>,
        values: impl IntoIterator<Item = String>,
    ) -> Self {
        let name = name.into();
        let group: Vec<String> = values
            .into_iter()
            .map(|value| format!("{name}:{value}"))
            .collect();
        if !group.is_empty() {
            self.facets.push(group);
        }
        self
    }

    pub fn with_limit(mut self, limit: u32) -> Self {
        self.limit = limit.clamp(1, 100);
        self
    }

    pub fn with_offset(mut self, offset: u32) -> Self {
        self.offset = offset;
        self
    }

    pub fn with_index(mut self, index: SearchIndex) -> Self {
        self.index = index;
        self
    }

    fn facets_json(&self) -> Result<Option<String>> {
        if self.facets.is_empty() {
            return Ok(None);
        }
        Ok(Some(serde_json::to_string(&self.facets)?))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "snake_case"))]
pub struct SearchResponse {
    #[serde(default)]
    pub hits: Vec<SearchHit>,
    #[serde(default)]
    pub offset: u32,
    #[serde(default)]
    pub limit: u32,
    #[serde(default)]
    pub total_hits: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "snake_case"))]
pub struct SearchHit {
    #[serde(default)]
    pub project_id: String,
    #[serde(default)]
    pub slug: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub categories: Vec<String>,
    #[serde(default)]
    pub client_side: String,
    #[serde(default)]
    pub server_side: String,
    #[serde(default)]
    pub project_type: String,
    #[serde(default)]
    pub downloads: u64,
    #[serde(default)]
    pub follows: u64,
    #[serde(default)]
    pub icon_url: Option<String>,
    #[serde(default)]
    pub date_modified: Option<DateTime<Utc>>,
    #[serde(default)]
    pub latest_version: Option<String>,
    #[serde(default)]
    pub license: String,
    #[serde(default)]
    pub versions: Vec<String>,
    #[serde(default)]
    pub gallery: Vec<GalleryImage>,
}

/// The search endpoint returns gallery URLs as plain strings, while project
/// responses use objects. Accept both shapes instead of rejecting the payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum GalleryImage {
    Url(String),
    Entry(GalleryEntry),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "snake_case"))]
pub struct GalleryEntry {
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub featured: bool,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub created: Option<DateTime<Utc>>,
    #[serde(default)]
    pub ordering: i64,
}

// ---------------------------------------------------------------------------
// Projects
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "snake_case"))]
pub struct Project {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub slug: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub categories: Vec<String>,
    #[serde(default)]
    pub client_side: String,
    #[serde(default)]
    pub server_side: String,
    #[serde(default)]
    pub project_type: String,
    #[serde(default)]
    pub downloads: u64,
    #[serde(default)]
    pub follows: u64,
    #[serde(default)]
    pub icon_url: Option<String>,
    #[serde(default)]
    pub color: Option<u32>,
    #[serde(default)]
    pub date_modified: Option<DateTime<Utc>>,
    #[serde(default)]
    pub published: Option<DateTime<Utc>>,
    #[serde(default)]
    pub updated: Option<DateTime<Utc>>,
    #[serde(default)]
    pub latest_version: Option<String>,
    #[serde(default)]
    pub license: License,
    #[serde(default)]
    pub versions: Vec<String>,
    #[serde(default)]
    pub game_versions: Vec<String>,
    #[serde(default)]
    pub loaders: Vec<String>,
    #[serde(default)]
    pub gallery: Vec<GalleryEntry>,
    #[serde(default)]
    pub source_url: Option<String>,
    #[serde(default)]
    pub issues_url: Option<String>,
    #[serde(default)]
    pub wiki_url: Option<String>,
    #[serde(default)]
    pub discord_url: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "snake_case"))]
pub struct License {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub url: Option<String>,
}

impl License {
    pub fn display_name(&self) -> String {
        if !self.name.trim().is_empty() {
            self.name.clone()
        } else {
            self.id.clone()
        }
    }
}

// ---------------------------------------------------------------------------
// Versions
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum VersionType {
    #[default]
    Release,
    Beta,
    Alpha,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "snake_case"))]
pub struct Version {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub project_id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub version_number: String,
    #[serde(default)]
    pub version_type: VersionType,
    #[serde(default)]
    pub game_versions: Vec<String>,
    #[serde(default)]
    pub loaders: Vec<String>,
    #[serde(default)]
    pub date_published: Option<DateTime<Utc>>,
    #[serde(default)]
    pub downloads: u64,
    #[serde(default)]
    pub files: Vec<VersionFile>,
    #[serde(default)]
    pub dependencies: Vec<Dependency>,
    #[serde(default)]
    pub changelog: Option<String>,
    #[serde(default)]
    pub featured: bool,
}

impl Version {
    /// The file Modrinth marks as primary, falling back to the first file.
    pub fn primary_file(&self) -> Option<&VersionFile> {
        self.files
            .iter()
            .find(|file| file.primary)
            .or_else(|| self.files.first())
    }

    pub fn file_named(&self, filename: &str) -> Option<&VersionFile> {
        self.files
            .iter()
            .find(|file| file.filename.eq_ignore_ascii_case(filename))
    }

    pub fn is_compatible_with(&self, game_version: &str, loader: &str) -> bool {
        self.game_versions
            .iter()
            .any(|value| value.eq_ignore_ascii_case(game_version))
            && self
                .loaders
                .iter()
                .any(|value| value.eq_ignore_ascii_case(loader))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "snake_case"))]
pub struct VersionFile {
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub filename: String,
    #[serde(default)]
    pub primary: bool,
    #[serde(default)]
    pub size: u64,
    #[serde(default)]
    pub hashes: FileHashes,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct FileHashes {
    #[serde(default)]
    pub sha1: String,
    #[serde(default)]
    pub sha512: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum DependencyType {
    #[default]
    Required,
    Optional,
    Incompatible,
    Embedded,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "snake_case"))]
pub struct Dependency {
    #[serde(default)]
    pub version_id: Option<String>,
    #[serde(default)]
    pub project_id: Option<String>,
    #[serde(default)]
    pub file_name: Option<String>,
    #[serde(default)]
    pub dependency_type: DependencyType,
}

/// Chooses the newest version that has a downloadable primary file and matches
/// the optional game version / loader filters.
pub fn best_version<'a>(
    versions: &'a [Version],
    game_version: Option<&str>,
    loader: Option<&str>,
) -> Option<&'a Version> {
    versions
        .iter()
        .filter(|version| version.primary_file().is_some())
        .filter(|version| {
            game_version.is_none_or(|wanted| {
                version
                    .game_versions
                    .iter()
                    .any(|value| value.eq_ignore_ascii_case(wanted))
            })
        })
        .filter(|version| {
            loader.is_none_or(|wanted| {
                version
                    .loaders
                    .iter()
                    .any(|value| value.eq_ignore_ascii_case(wanted))
            })
        })
        .max_by(|left, right| {
            left.date_published
                .cmp(&right.date_published)
                .then_with(|| left.downloads.cmp(&right.downloads))
        })
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

pub struct ModrinthClient {
    http: reqwest::Client,
    base_url: String,
}

impl ModrinthClient {
    pub fn new() -> Result<Self> {
        Self::with_base_url(MODRINTH_API_BASE)
    }

    pub fn with_base_url(base_url: impl Into<String>) -> Result<Self> {
        let http = reqwest::Client::builder()
            .user_agent(MODRINTH_USER_AGENT)
            .connect_timeout(Duration::from_secs(20))
            .timeout(Duration::from_secs(180))
            .build()?;
        Ok(Self {
            http,
            base_url: base_url.into().trim_end_matches('/').to_string(),
        })
    }

    pub fn http_client(&self) -> &reqwest::Client {
        &self.http
    }

    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    pub async fn search(&self, query: &SearchQuery) -> Result<SearchResponse> {
        let mut params: Vec<(&str, String)> = vec![
            ("query", query.query.clone()),
            ("limit", query.limit.to_string()),
            ("offset", query.offset.to_string()),
            ("index", query.index.as_str().to_string()),
        ];
        if let Some(facets) = query.facets_json()? {
            params.push(("facets", facets));
        }
        self.get_json("/search", &params).await
    }

    pub async fn search_text(&self, query: &str) -> Result<SearchResponse> {
        self.search(&SearchQuery::new(query)).await
    }

    pub async fn project(&self, id_or_slug: &str) -> Result<Project> {
        let identifier = validate_identifier(id_or_slug, "project id")?;
        self.get_json(&format!("/project/{identifier}"), &[]).await
    }

    /// Lists project versions. `game_versions` and `loaders` are sent as
    /// JSON-encoded arrays, exactly as the Modrinth API expects.
    pub async fn versions(
        &self,
        id_or_slug: &str,
        game_versions: &[String],
        loaders: &[String],
    ) -> Result<Vec<Version>> {
        let identifier = validate_identifier(id_or_slug, "project id")?;
        let mut params: Vec<(&str, String)> = Vec::new();
        if !game_versions.is_empty() {
            params.push(("game_versions", serde_json::to_string(game_versions)?));
        }
        if !loaders.is_empty() {
            params.push(("loaders", serde_json::to_string(loaders)?));
        }
        self.get_json(&format!("/project/{identifier}/version"), &params)
            .await
    }

    pub async fn version(&self, version_id: &str) -> Result<Version> {
        let identifier = validate_identifier(version_id, "version id")?;
        self.get_json(&format!("/version/{identifier}"), &[]).await
    }

    /// Looks up the Modrinth version that owns a file with the given SHA-1.
    pub async fn version_from_sha1(&self, sha1: &str) -> Result<Version> {
        let hash = sha1.trim().to_ascii_lowercase();
        if hash.len() != 40 || !hash.chars().all(|value| value.is_ascii_hexdigit()) {
            return Err(Error::InvalidMetadata(format!(
                "invalid SHA-1 hash '{sha1}'"
            )));
        }
        self.get_json(
            &format!("/version_file/{hash}"),
            &[("algorithm", "sha1".to_string())],
        )
        .await
    }

    /// Convenience wrapper around [`best_version`].
    pub fn best_version<'a>(
        &self,
        versions: &'a [Version],
        game_version: Option<&str>,
        loader: Option<&str>,
    ) -> Option<&'a Version> {
        best_version(versions, game_version, loader)
    }

    /// Downloads a version file to `destination` and verifies its SHA-512 and
    /// size. An already valid destination is reused.
    pub async fn download_file(&self, file: &VersionFile, destination: &Path) -> Result<()> {
        let sha512 = (!file.hashes.sha512.is_empty()).then_some(file.hashes.sha512.as_str());
        let size = (file.size > 0).then_some(file.size);
        self.download_verified(&file.url, destination, sha512, size, None, None)
            .await
    }

    /// Streams `url` into `<destination>.part`, verifies it, then renames it
    /// into place. Progress (if supplied) receives byte counters; lifecycle
    /// events (`FileStarted`/`FileFinished`) are the caller's responsibility.
    pub async fn download_verified(
        &self,
        url: &str,
        destination: &Path,
        sha512: Option<&str>,
        size: Option<u64>,
        progress: Option<&SharedProgress>,
        cancel: Option<&CancelFlag>,
    ) -> Result<()> {
        ensure_http_url(url)?;
        if let Some(parent) = destination.parent() {
            tokio::fs::create_dir_all(parent).await.map_err(|e| {
                Error::Io(std::io::Error::new(
                    e.kind(),
                    format!("create {}: {e}", parent.display()),
                ))
            })?;
        }

        if verify_existing(destination, sha512, size)? {
            if let (Some(sink), Ok(metadata)) = (progress, std::fs::metadata(destination)) {
                sink.emit(InstallProgressEvent::Bytes {
                    downloaded: metadata.len(),
                    total: size.unwrap_or(metadata.len()),
                });
            }
            return Ok(());
        }

        let partial = partial_path(destination);
        let result = self
            .stream_to_partial(url, &partial, size, progress, cancel)
            .await;
        if let Err(error) = result {
            let _ = tokio::fs::remove_file(&partial).await;
            return Err(error);
        }

        let written = tokio::fs::metadata(&partial)
            .await
            .map(|metadata| metadata.len())
            .unwrap_or(0);
        if let Some(expected_size) = size {
            if written != expected_size {
                let _ = tokio::fs::remove_file(&partial).await;
                return Err(Error::HashMismatch {
                    path: destination.to_path_buf(),
                    expected: format!("size {expected_size}"),
                    actual: format!("size {written}"),
                });
            }
        }
        if let Some(expected) = sha512.filter(|value| !value.is_empty()) {
            let actual = sha512_async(&partial).await?;
            if !actual.eq_ignore_ascii_case(expected) {
                let _ = tokio::fs::remove_file(&partial).await;
                return Err(Error::HashMismatch {
                    path: destination.to_path_buf(),
                    expected: expected.to_ascii_lowercase(),
                    actual,
                });
            }
        }

        if let Err(error) = tokio::fs::rename(&partial, destination).await {
            let _ = tokio::fs::remove_file(&partial).await;
            return Err(Error::Io(std::io::Error::new(
                error.kind(),
                format!("cannot place {}: {error}", destination.display()),
            )));
        }
        Ok(())
    }

    async fn stream_to_partial(
        &self,
        url: &str,
        partial: &Path,
        size: Option<u64>,
        progress: Option<&SharedProgress>,
        cancel: Option<&CancelFlag>,
    ) -> Result<()> {
        let response = self
            .http
            .get(url)
            .send()
            .await
            .map_err(|e| Error::Http(format!("download request failed: {e}")))?;
        let status = response.status();
        if status == reqwest::StatusCode::NOT_FOUND {
            return Err(Error::NotFound(format!("download URL {url}")));
        }
        if !status.is_success() {
            return Err(Error::Http(format!(
                "download {url} returned HTTP {status}"
            )));
        }

        let mut file = tokio::fs::File::create(partial).await?;
        let mut stream = response.bytes_stream();
        let mut written = 0u64;
        while let Some(chunk) = stream.next().await {
            if cancel.is_some_and(CancelFlag::is_cancelled) {
                return Err(Error::Cancelled);
            }
            let chunk = chunk.map_err(|e| Error::Http(format!("download stream failed: {e}")))?;
            file.write_all(&chunk).await?;
            written += chunk.len() as u64;
            if let Some(sink) = progress {
                sink.emit(InstallProgressEvent::Bytes {
                    downloaded: written,
                    total: size.unwrap_or(0),
                });
            }
        }
        file.flush().await?;
        Ok(())
    }

    async fn get_json<T>(&self, path: &str, query: &[(&str, String)]) -> Result<T>
    where
        T: serde::de::DeserializeOwned,
    {
        let url = format!("{}{path}", self.base_url);
        let response = self
            .http
            .get(&url)
            .query(query)
            .send()
            .await
            .map_err(|e| Error::Http(format!("Modrinth request {path} failed: {e}")))?;
        let status = response.status();
        if status == reqwest::StatusCode::NOT_FOUND {
            return Err(Error::NotFound(format!("Modrinth resource {path}")));
        }
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            let body = body.trim();
            let detail: String = body.chars().take(300).collect();
            return Err(Error::Http(format!(
                "Modrinth {path} returned HTTP {status}: {detail}"
            )));
        }
        response.json::<T>().await.map_err(|e| {
            Error::InvalidMetadata(format!("Modrinth response {path} is malformed: {e}"))
        })
    }
}

impl std::fmt::Debug for ModrinthClient {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ModrinthClient")
            .field("base_url", &self.base_url)
            .finish()
    }
}

fn validate_identifier<'a>(value: &'a str, label: &str) -> Result<&'a str> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(Error::MissingInput(format!("{label} is empty")));
    }
    if trimmed.len() > 128
        || !trimmed
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_'))
    {
        return Err(Error::InvalidMetadata(format!(
            "invalid Modrinth {label} '{value}'"
        )));
    }
    Ok(trimmed)
}

fn ensure_http_url(raw: &str) -> Result<()> {
    let parsed = url::Url::parse(raw)
        .map_err(|e| Error::InvalidMetadata(format!("invalid download URL '{raw}': {e}")))?;
    if !matches!(parsed.scheme(), "https" | "http") || parsed.host().is_none() {
        return Err(Error::InvalidMetadata(format!(
            "unsupported download URL '{raw}'"
        )));
    }
    Ok(())
}

fn partial_path(destination: &Path) -> PathBuf {
    let mut name = destination.as_os_str().to_os_string();
    name.push(".part");
    PathBuf::from(name)
}

fn verify_existing(path: &Path, sha512: Option<&str>, size: Option<u64>) -> Result<bool> {
    let metadata = match std::fs::metadata(path) {
        Ok(metadata) if metadata.is_file() => metadata,
        _ => return Ok(false),
    };
    if let Some(expected) = size {
        if metadata.len() != expected {
            return Ok(false);
        }
    }
    if let Some(expected) = sha512.filter(|value| !value.is_empty()) {
        let actual = sha512_file(path)?;
        return Ok(actual.eq_ignore_ascii_case(expected));
    }
    Ok(metadata.len() > 0 || size == Some(0))
}

async fn sha512_async(path: &Path) -> Result<String> {
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || sha512_file(&path))
        .await
        .map_err(|e| Error::Other(format!("hashing task failed: {e}")))?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_hit_deserializes_real_payload() {
        let json = r#"{
            "project_id": "P7dR8mSH",
            "slug": "fabric-api",
            "title": "Fabric API",
            "description": "Lightweight and modular API",
            "categories": ["library", "fabric"],
            "client_side": "required",
            "server_side": "required",
            "project_type": "mod",
            "downloads": 123456,
            "follows": 100,
            "icon_url": "https://cdn.modrinth.com/data/P7dR8mSH/icon.png",
            "date_modified": "2024-01-01T00:00:00Z",
            "latest_version": "abc",
            "license": "mit",
            "versions": ["abc"],
            "gallery": [{"url": "https://cdn.modrinth.com/a.png", "featured": true, "ordering": 0}]
        }"#;
        let hit: SearchHit = serde_json::from_str(json).unwrap();
        assert_eq!(hit.project_id, "P7dR8mSH");
        assert_eq!(hit.latest_version.as_deref(), Some("abc"));
        assert_eq!(hit.license, "mit");
        assert_eq!(hit.downloads, 123456);
        assert_eq!(hit.gallery.len(), 1);
    }

    #[test]
    fn version_deserializes_dependencies_and_hashes() {
        let json = r#"{
            "id": "v1",
            "project_id": "p1",
            "name": "Release 1",
            "version_number": "1.0.0",
            "version_type": "release",
            "game_versions": ["1.20.1"],
            "loaders": ["fabric"],
            "date_published": "2024-01-01T00:00:00Z",
            "downloads": 10,
            "files": [{
                "url": "https://cdn.modrinth.com/a.jar",
                "filename": "a.jar",
                "primary": true,
                "size": 42,
                "hashes": {"sha1": "aa", "sha512": "bb"}
            }],
            "dependencies": [{"version_id": null, "project_id": "p2", "file_name": null, "dependency_type": "required"}]
        }"#;
        let version: Version = serde_json::from_str(json).unwrap();
        assert_eq!(version.project_id, "p1");
        assert_eq!(version.version_number, "1.0.0");
        assert_eq!(version.primary_file().unwrap().filename, "a.jar");
        assert_eq!(version.dependencies[0].project_id.as_deref(), Some("p2"));
        assert_eq!(
            version.dependencies[0].dependency_type,
            DependencyType::Required
        );
    }

    #[test]
    fn best_version_filters_and_sorts() {
        let make = |id: &str, published: &str, game: &str| Version {
            id: id.into(),
            game_versions: vec![game.into()],
            loaders: vec!["fabric".into()],
            date_published: Some(published.parse().unwrap()),
            files: vec![VersionFile {
                primary: true,
                ..VersionFile {
                    url: "https://example.invalid/a.jar".into(),
                    filename: "a.jar".into(),
                    primary: true,
                    size: 1,
                    hashes: FileHashes::default(),
                }
            }],
            ..serde_json::from_str::<Version>("{\"id\":\"x\"}").unwrap()
        };
        let versions = vec![
            make("old", "2023-01-01T00:00:00Z", "1.20.1"),
            make("new", "2024-01-01T00:00:00Z", "1.20.1"),
            make("other", "2025-01-01T00:00:00Z", "1.21.1"),
        ];
        assert_eq!(
            best_version(&versions, Some("1.20.1"), Some("fabric"))
                .unwrap()
                .id,
            "new"
        );
        assert_eq!(
            best_version(&versions, Some("1.21.1"), None).unwrap().id,
            "other"
        );
    }

    #[test]
    fn rejects_unsafe_identifiers() {
        assert!(validate_identifier("ok-slug_1", "project id").is_ok());
        assert!(validate_identifier("../etc", "project id").is_err());
        assert!(validate_identifier("a/b", "project id").is_err());
    }
}
