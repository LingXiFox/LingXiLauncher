//! Vanilla version installation: client jar, libraries, natives, assets and
//! logging configuration, all verified against Mojang metadata.

use std::collections::BTreeSet;
use std::io::Read;
use std::path::PathBuf;

use serde::Deserialize;

use crate::error::{Error, Result};
use crate::launch::native_artifact;
use crate::layout::{ensure_dir, GameDataLayout};
use crate::manifest::ManifestService;
use crate::models::launch::LaunchDiagnostic;
use crate::models::version::Artifact;
use crate::net::{classify_reqwest_error, describe_transfer_error, redact_url};
use crate::platform::PlatformContext;
use crate::version::rules::is_allowed;
use crate::version::{ResolvedVersion, VersionResolver};

use super::hashing::{sha1_bytes, verify_file};
use super::models::{
    BatchProgress, CancelFlag, DownloadConfiguration, DownloadSourcePolicy, DownloadTask,
    InstallProgressEvent, InstallReport, MissingDependency, MissingDependencyKind, SharedProgress,
    TrustedMirrorConfiguration,
};
use super::Downloader;

/// Shared reqwest client for small metadata fetches (asset indexes etc.).
/// P1-4: every metadata request gets an explicit connect/total timeout so a
/// hung connection cannot stall the install forever.
fn metadata_client() -> reqwest::Client {
    crate::net::client_builder()
        .user_agent(format!(
            "{}/{}",
            crate::models::launch::LAUNCHER_NAME,
            crate::models::launch::LAUNCHER_VERSION
        ))
        .connect_timeout(std::time::Duration::from_secs(20))
        .timeout(std::time::Duration::from_secs(120))
        .build()
        .expect("metadata client builds with static settings")
}

#[derive(Debug, Clone)]
struct NativeJar {
    path: PathBuf,
    excludes: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct VanillaInstallPlan {
    pub version: ResolvedVersion,
    pub tasks: Vec<DownloadTask>,
    native_jars: Vec<NativeJar>,
    pub asset_object_count: usize,
}

pub struct VanillaInstaller {
    layout: GameDataLayout,
    platform: PlatformContext,
    policy: DownloadSourcePolicy,
    mirror: Option<TrustedMirrorConfiguration>,
    configuration: DownloadConfiguration,
}

/// Files the launcher needs before the game can start, computed without any
/// asset index network round trip.
#[derive(Debug)]
struct CorePlan {
    tasks: Vec<DownloadTask>,
    native_jars: Vec<NativeJar>,
}

impl VanillaInstaller {
    pub fn new(
        layout: GameDataLayout,
        platform: PlatformContext,
        policy: DownloadSourcePolicy,
        mirror: Option<TrustedMirrorConfiguration>,
    ) -> Self {
        let configuration = DownloadConfiguration {
            // Cross-version and cross-instance reuse of verified objects.
            cache_directory: Some(layout.downloads_cache_directory()),
            ..DownloadConfiguration::default()
        };
        Self {
            layout,
            platform,
            policy,
            mirror,
            configuration,
        }
    }

    pub fn with_configuration(mut self, configuration: DownloadConfiguration) -> Self {
        self.configuration = configuration;
        self
    }

    /// Builds the complete download plan, fetching version metadata when needed.
    pub async fn plan(&self, version_id: &str) -> Result<VanillaInstallPlan> {
        let version = self.resolve_version(version_id).await?;
        let core = self.core_plan(&version)?;
        let (asset_tasks, asset_object_count) = self.asset_tasks(&version).await?;
        let mut tasks = core.tasks;
        tasks.extend(asset_tasks);
        Ok(VanillaInstallPlan {
            version,
            tasks,
            native_jars: core.native_jars,
            asset_object_count,
        })
    }

    /// Resolves a version, fetching its metadata when it is not cached yet.
    async fn resolve_version(&self, version_id: &str) -> Result<ResolvedVersion> {
        if !self.layout.version_json(version_id)?.is_file() {
            ManifestService::new(self.layout.clone())?
                .metadata_by_id(version_id)
                .await?;
        }
        VersionResolver.resolve(version_id, &self.layout.game_root)
    }

    /// Plans the client jar, libraries, natives and logging config.
    fn core_plan(&self, version: &ResolvedVersion) -> Result<CorePlan> {
        let mut tasks = Vec::new();
        self.add_client_jar(version, &mut tasks)?;
        let mut native_jars = Vec::new();
        self.add_libraries(version, &mut tasks, &mut native_jars)?;
        self.add_logging(version, &mut tasks)?;
        Ok(CorePlan { tasks, native_jars })
    }

    /// Resolves the asset index and turns it into asset object tasks.
    async fn asset_tasks(&self, version: &ResolvedVersion) -> Result<(Vec<DownloadTask>, usize)> {
        let mut tasks = Vec::new();
        let asset_object_count = self.add_assets(version, &mut tasks).await?;
        Ok((tasks, asset_object_count))
    }

    pub async fn install(
        &self,
        version_id: &str,
        progress: SharedProgress,
        cancel: CancelFlag,
    ) -> Result<InstallReport> {
        // P1-4: phase event goes out before the download plan is built.
        progress.emit(InstallProgressEvent::Phase {
            phase: "manifest".into(),
            message: format!("Fetching metadata for Minecraft {version_id}"),
        });
        let version = tokio::select! {
            biased;
            _ = cancel.cancelled() => return Err(Error::Cancelled),
            version = self.resolve_version(version_id) => version?,
        };
        let core = self.core_plan(&version)?;
        let installer =
            Downloader::new(self.policy, self.mirror.clone(), self.configuration.clone())?;
        progress.emit(InstallProgressEvent::Phase {
            phase: "download".into(),
            message: format!("Installing Minecraft {}", version.id),
        });
        // Core and assets share one request budget; only assets depend on the index.
        let [core_progress, asset_progress] = BatchProgress::pair(progress.clone());
        let core_transfer = async {
            let result = installer
                .download(core.tasks.clone(), core_progress.clone(), cancel.clone())
                .await;
            core_progress.finish();
            result
        };
        let asset_transfer = async {
            let (tasks, count) = tokio::select! {
                biased;
                _ = cancel.cancelled() => return Err(Error::Cancelled),
                assets = self.asset_tasks(&version) => assets?,
            };
            let result = installer
                .download(tasks.clone(), asset_progress.clone(), cancel.clone())
                .await;
            asset_progress.finish();
            Ok((tasks, count, result?))
        };
        let (core_summary, asset_batch) = tokio::join!(biased; core_transfer, asset_transfer);
        let mut summary = core_summary?;
        let (asset_tasks, asset_object_count, asset_summary) = asset_batch?;
        summary.absorb(asset_summary);
        let plan = VanillaInstallPlan {
            version,
            tasks: core.tasks.into_iter().chain(asset_tasks).collect(),
            native_jars: core.native_jars,
            asset_object_count,
        };
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        let mut diagnostics = Vec::new();
        for failure in &summary.failures {
            diagnostics.push(LaunchDiagnostic {
                severity: "error".into(),
                message: format!("{}: {}", failure.destination.display(), failure.message),
            });
        }
        let extracted_natives = if summary.failures.is_empty() {
            self.extract_natives(plan.clone(), progress.clone(), cancel.clone())
                .await?
        } else {
            0
        };

        let missing_after_install = self.missing_dependencies(&plan)?;
        if !missing_after_install.is_empty() {
            diagnostics.push(LaunchDiagnostic {
                severity: "error".into(),
                message: format!(
                    "{} files are still missing after installation",
                    missing_after_install.len()
                ),
            });
        }
        // P0-2: an incomplete install must surface as a real failure to the GUI
        // instead of a success report that happens to carry a diagnostics list.
        // Verified files stay cached (the downloader never touched them), so a
        // retry resumes from the cache.
        if !summary.failures.is_empty() {
            let mut reasons: Vec<String> = summary
                .failures
                .iter()
                .map(|f| format!("{}: {}", f.destination.display(), f.message))
                .collect();
            reasons.extend(
                missing_after_install
                    .iter()
                    .map(|m| format!("{}: {}", m.path.display(), m.reason)),
            );
            return Err(Error::InstallFailed {
                version_id: plan.version.id.clone(),
                reasons,
            });
        }
        if !missing_after_install.is_empty() {
            let reasons: Vec<String> = missing_after_install
                .iter()
                .map(|m| format!("{}: {}", m.path.display(), m.reason))
                .collect();
            return Err(Error::InstallFailed {
                version_id: plan.version.id.clone(),
                reasons,
            });
        }
        Ok(InstallReport {
            version_id: plan.version.id.clone(),
            instance_id: String::new(),
            game_directory: self.layout.game_root.clone(),
            downloaded_files: summary.downloaded.len(),
            downloaded_bytes: summary.downloaded.iter().map(|f| f.bytes).sum(),
            cache_hits: summary.cache_hits,
            asset_object_count: plan.asset_object_count,
            extracted_natives,
            missing_after_install,
            diagnostics,
            java_requirement: plan.version.java_requirement.clone(),
            source_policy: self.policy.as_str().to_string(),
            platform_architecture: self.platform.architecture.jvm_name().to_string(),
        })
    }

    fn add_client_jar(
        &self,
        version: &ResolvedVersion,
        tasks: &mut Vec<DownloadTask>,
    ) -> Result<()> {
        let Some(artifact) = version.client_jar.as_ref() else {
            return Err(Error::InvalidMetadata(format!(
                "version {} has no client download",
                version.id
            )));
        };
        if artifact.url.is_empty() {
            return Err(Error::InvalidMetadata(format!(
                "version {} has an empty client URL",
                version.id
            )));
        }
        let destination = self.layout.client_jar(&version.client_jar_version_id)?;
        if let Some(parent) = destination.parent() {
            ensure_dir(parent)?;
        }
        tasks.push(DownloadTask::new(
            destination,
            Some(artifact.url.clone()),
            artifact.sha1.clone(),
            artifact.size,
            MissingDependencyKind::ClientJar,
        ));
        Ok(())
    }

    fn add_libraries(
        &self,
        version: &ResolvedVersion,
        tasks: &mut Vec<DownloadTask>,
        native_jars: &mut Vec<NativeJar>,
    ) -> Result<()> {
        let mut seen = BTreeSet::new();
        for library in &version.libraries {
            if !is_allowed(&library.rules, &self.platform)? {
                continue;
            }
            if let Some(artifact) = library.effective_artifact()? {
                let destination = self.layout.library_path(&artifact.relative_path)?;
                if let Some(parent) = destination.parent() {
                    ensure_dir(parent)?;
                }
                let key = destination.to_string_lossy().to_string();
                if seen.insert(key) {
                    tasks.push(DownloadTask::new(
                        destination,
                        Some(artifact.url),
                        artifact.sha1,
                        artifact.size,
                        MissingDependencyKind::Library,
                    ));
                }
            }
            if let Some(classifier) = library.natives_classifier(self.platform.os.as_str()) {
                if let Some(artifact) = native_artifact(library, &classifier, &self.platform)? {
                    let destination = self.layout.library_path(&artifact.relative_path)?;
                    if let Some(parent) = destination.parent() {
                        ensure_dir(parent)?;
                    }
                    let key = destination.to_string_lossy().to_string();
                    if seen.insert(key) {
                        tasks.push(DownloadTask::new(
                            destination.clone(),
                            Some(artifact.url),
                            artifact.sha1,
                            artifact.size,
                            MissingDependencyKind::Native,
                        ));
                    }
                    native_jars.push(NativeJar {
                        path: destination,
                        excludes: library
                            .extract
                            .as_ref()
                            .map(|e| e.exclude.clone())
                            .unwrap_or_default(),
                    });
                }
            }
        }
        Ok(())
    }

    fn add_logging(&self, version: &ResolvedVersion, tasks: &mut Vec<DownloadTask>) -> Result<()> {
        let Some(logging) = &version.client_logging else {
            return Ok(());
        };
        let destination = self.layout.log_configs_directory().join(&logging.file.id);
        ensure_dir(&self.layout.log_configs_directory())?;
        tasks.push(DownloadTask::new(
            destination,
            Some(logging.file.url.clone()),
            Some(logging.file.sha1.clone()),
            Some(logging.file.size),
            MissingDependencyKind::LogConfig,
        ));
        Ok(())
    }

    /// P1-4/P2-11/P2-13: fetch and validate the asset index with an explicit
    /// timeout, verify cached copies against their SHA-1, write back atomically,
    /// and enqueue only the asset objects (the index itself is no longer a
    /// download task, so it is never fetched twice).
    async fn add_assets(
        &self,
        version: &ResolvedVersion,
        tasks: &mut Vec<DownloadTask>,
    ) -> Result<usize> {
        let Some(index) = &version.asset_index else {
            return Ok(0);
        };
        let index_path = self.layout.asset_index_path(&index.id)?;
        if let Some(parent) = index_path.parent() {
            ensure_dir(parent)?;
        }

        // A cached index counts only when it matches the recorded SHA-1 and
        // size (P2-13); corrupt files fall through to a clean re-fetch.
        let mut bytes: Option<Vec<u8>> = None;
        if index_path.is_file() {
            let cached = std::fs::read(&index_path)?;
            if verify_file(&index_path, Some(index.sha1.as_str()), Some(index.size))? {
                bytes = Some(cached);
            } else {
                tracing::debug!(
                    "cached asset index {} failed validation, refetching",
                    index.id
                );
                std::fs::remove_file(&index_path).ok();
            }
        }

        let bytes = match bytes {
            Some(bytes) => bytes,
            None => {
                let response = metadata_client()
                    .get(&index.url)
                    .send()
                    .await
                    .map_err(|e| {
                        Error::Http(describe_transfer_error(
                            "asset index",
                            &index.url,
                            classify_reqwest_error(&e),
                            &e.to_string(),
                        ))
                    })?;
                if !response.status().is_success() {
                    return Err(Error::Http(format!(
                        "asset index {}: HTTP {} for {}",
                        index.id,
                        response.status(),
                        redact_url(&index.url)
                    )));
                }
                let downloaded = response.bytes().await.map_err(|e| {
                    Error::Http(describe_transfer_error(
                        "asset index body",
                        &index.url,
                        classify_reqwest_error(&e),
                        &e.to_string(),
                    ))
                })?;
                // Validate before caching: never persist an unverified index.
                if downloaded.len() as u64 != index.size {
                    return Err(Error::Http(format!(
                        "asset index {} size mismatch: expected {}, got {}",
                        index.id,
                        index.size,
                        downloaded.len()
                    )));
                }
                let actual = sha1_bytes(&downloaded);
                if !actual.eq_ignore_ascii_case(&index.sha1) {
                    return Err(Error::HashMismatch {
                        path: index_path.clone(),
                        expected: index.sha1.clone(),
                        actual,
                    });
                }
                let temp = index_path.with_extension("json.part");
                std::fs::write(&temp, &downloaded)?;
                std::fs::rename(&temp, &index_path)?;
                downloaded.to_vec()
            }
        };
        let parsed: AssetIndexFile = serde_json::from_slice(&bytes).map_err(|e| {
            Error::InvalidMetadata(format!("asset index {} is malformed: {e}", index.id))
        })?;
        ensure_dir(&self.layout.asset_objects_directory())?;
        let mut seen = BTreeSet::new();
        for object in parsed.objects.values() {
            if object.hash.len() < 2 || !seen.insert(object.hash.clone()) {
                continue;
            }
            let destination = self.layout.asset_object_path(&object.hash)?;
            if let Some(parent) = destination.parent() {
                ensure_dir(parent)?;
            }
            tasks.push(DownloadTask::new(
                destination,
                Some(format!(
                    "https://resources.download.minecraft.net/{}/{}",
                    &object.hash[..2],
                    object.hash
                )),
                Some(object.hash.clone()),
                Some(object.size),
                MissingDependencyKind::Asset,
            ));
        }
        Ok(parsed.objects.len())
    }

    async fn extract_natives(
        &self,
        plan: VanillaInstallPlan,
        progress: SharedProgress,
        cancel: CancelFlag,
    ) -> Result<usize> {
        let layout = self.layout.clone();
        let architecture = self.platform.architecture.jvm_name().to_string();
        tokio::task::spawn_blocking(move || {
            extract_natives_blocking(&layout, &architecture, &plan, &progress, &cancel)
        })
        .await
        .map_err(|error| Error::Other(format!("native extraction task failed: {error}")))?
    }

    fn missing_dependencies(&self, plan: &VanillaInstallPlan) -> Result<Vec<MissingDependency>> {
        let mut missing = Vec::new();
        let client_jar = self
            .layout
            .client_jar(&plan.version.client_jar_version_id)?;
        if !client_jar.is_file() {
            missing.push(MissingDependency {
                kind: MissingDependencyKind::ClientJar,
                name: format!("{}:client", plan.version.client_jar_version_id),
                path: client_jar,
                reason: "client jar is not installed".into(),
                url: None,
            });
        }
        for task in &plan.tasks {
            if !task.destination.is_file() {
                missing.push(MissingDependency {
                    kind: task.kind,
                    name: task
                        .destination
                        .file_name()
                        .map(|n| n.to_string_lossy().to_string())
                        .unwrap_or_default(),
                    path: task.destination.clone(),
                    reason: "download did not produce this file".into(),
                    url: task.official_url.clone(),
                });
            }
        }
        Ok(missing)
    }
}

fn extract_natives_blocking(
    layout: &GameDataLayout,
    architecture: &str,
    plan: &VanillaInstallPlan,
    progress: &SharedProgress,
    cancel: &CancelFlag,
) -> Result<usize> {
    let target = layout.natives_directory(&plan.version.natives_version_id, architecture)?;
    ensure_dir(&target)?;
    let (total_files, total_bytes) = native_extraction_totals(plan)?;
    if total_files == 0 {
        return Ok(0);
    }
    progress.emit(InstallProgressEvent::Phase {
        phase: "natives".into(),
        message: "Extracting native libraries".into(),
    });
    progress.emit(InstallProgressEvent::Plan {
        total_files,
        total_bytes,
        cache_hits: 0,
    });

    let mut extracted_bytes = 0;
    let mut extracted_names = BTreeSet::new();
    for jar in &plan.native_jars {
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        if !jar.path.is_file() {
            continue;
        }
        let file = std::fs::File::open(&jar.path)?;
        let mut archive = zip::ZipArchive::new(file)
            .map_err(|e| Error::Zip(format!("{}: {e}", jar.path.display())))?;
        for index in 0..archive.len() {
            if cancel.is_cancelled() {
                return Err(Error::Cancelled);
            }
            let mut entry = archive
                .by_index(index)
                .map_err(|e| Error::Zip(format!("{}: {e}", jar.path.display())))?;
            let name = entry.name().to_string();
            let Some(file_name) = native_entry_name(&name, entry.is_dir(), &jar.excludes) else {
                continue;
            };
            let destination = target.join(file_name);
            if !destination.starts_with(&target) {
                continue;
            }
            progress.emit(InstallProgressEvent::FileStarted {
                path: destination.to_string_lossy().to_string(),
                size: entry.size(),
            });
            let mut data = Vec::with_capacity(entry.size() as usize);
            entry.read_to_end(&mut data)?;
            std::fs::write(&destination, &data)?;
            extracted_bytes += data.len() as u64;
            extracted_names.insert(file_name.to_string());
            progress.emit(InstallProgressEvent::FileFinished {
                path: destination.to_string_lossy().to_string(),
                bytes: data.len() as u64,
                source: "native".into(),
            });
            progress.emit(InstallProgressEvent::Bytes {
                downloaded: extracted_bytes,
                total: total_bytes,
            });
        }
    }
    Ok(extracted_names.len())
}

fn native_extraction_totals(plan: &VanillaInstallPlan) -> Result<(usize, u64)> {
    let mut total_files = 0;
    let mut total_bytes = 0;
    for jar in &plan.native_jars {
        if !jar.path.is_file() {
            continue;
        }
        let file = std::fs::File::open(&jar.path)?;
        let mut archive = zip::ZipArchive::new(file)
            .map_err(|e| Error::Zip(format!("{}: {e}", jar.path.display())))?;
        for index in 0..archive.len() {
            let entry = archive
                .by_index(index)
                .map_err(|e| Error::Zip(format!("{}: {e}", jar.path.display())))?;
            if native_entry_name(entry.name(), entry.is_dir(), &jar.excludes).is_some() {
                total_files += 1;
                total_bytes += entry.size();
            }
        }
    }
    Ok((total_files, total_bytes))
}

fn native_entry_name<'a>(name: &'a str, is_dir: bool, excludes: &[String]) -> Option<&'a str> {
    if is_dir || name.starts_with("META-INF/") || name.ends_with('/') {
        return None;
    }
    if excludes.iter().any(|prefix| name.starts_with(prefix)) {
        return None;
    }
    name.rsplit('/')
        .next()
        .filter(|file_name| !file_name.is_empty())
}

#[derive(Deserialize)]
struct AssetIndexFile {
    #[serde(default)]
    objects: std::collections::HashMap<String, AssetObject>,
}

#[derive(Deserialize)]
struct AssetObject {
    hash: String,
    #[serde(default)]
    size: u64,
}

/// Client artifact accessor used by step-by-step installers.
pub fn client_artifact(version: &ResolvedVersion) -> Option<&Artifact> {
    version.client_jar.as_ref()
}
