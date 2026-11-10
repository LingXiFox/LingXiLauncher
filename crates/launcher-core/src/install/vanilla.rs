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
use crate::platform::PlatformContext;
use crate::version::rules::is_allowed;
use crate::version::{ResolvedVersion, VersionResolver};

use super::models::{
    CancelFlag, DownloadConfiguration, DownloadSourcePolicy, DownloadTask, InstallProgressEvent,
    InstallReport, MissingDependency, MissingDependencyKind, SharedProgress,
    TrustedMirrorConfiguration,
};
use super::Downloader;

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

impl VanillaInstaller {
    pub fn new(
        layout: GameDataLayout,
        platform: PlatformContext,
        policy: DownloadSourcePolicy,
        mirror: Option<TrustedMirrorConfiguration>,
    ) -> Self {
        Self {
            layout,
            platform,
            policy,
            mirror,
            configuration: DownloadConfiguration::default(),
        }
    }

    pub fn with_configuration(mut self, configuration: DownloadConfiguration) -> Self {
        self.configuration = configuration;
        self
    }

    /// Builds the complete download plan, fetching version metadata when needed.
    pub async fn plan(&self, version_id: &str) -> Result<VanillaInstallPlan> {
        if !self.layout.version_json(version_id)?.is_file() {
            ManifestService::new(self.layout.clone())?
                .metadata_by_id(version_id)
                .await?;
        }
        let version = VersionResolver.resolve(version_id, &self.layout.game_root)?;
        let mut tasks = Vec::new();
        self.add_client_jar(&version, &mut tasks)?;
        let mut native_jars = Vec::new();
        self.add_libraries(&version, &mut tasks, &mut native_jars)?;
        self.add_logging(&version, &mut tasks)?;
        let asset_object_count = self.add_assets(&version, &mut tasks).await?;
        Ok(VanillaInstallPlan {
            version,
            tasks,
            native_jars,
            asset_object_count,
        })
    }

    pub async fn install(
        &self,
        version_id: &str,
        progress: SharedProgress,
        cancel: CancelFlag,
    ) -> Result<InstallReport> {
        let plan = self.plan(version_id).await?;
        let installer =
            Downloader::new(self.policy, self.mirror.clone(), self.configuration.clone())?;
        progress.emit(InstallProgressEvent::Phase {
            phase: "download".into(),
            message: format!("Installing Minecraft {}", plan.version.id),
        });
        let summary = installer
            .download(plan.tasks.clone(), progress.clone(), cancel.clone())
            .await?;
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
            progress.emit(InstallProgressEvent::Phase {
                phase: "natives".into(),
                message: "Extracting native libraries".into(),
            });
            self.extract_natives(&plan, progress.clone(), &cancel)?
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
        tasks.push(DownloadTask::new(
            index_path.clone(),
            Some(index.url.clone()),
            Some(index.sha1.clone()),
            Some(index.size),
            MissingDependencyKind::AssetIndex,
        ));

        let bytes = if index_path.is_file() {
            std::fs::read(&index_path)?
        } else {
            let response = reqwest::Client::builder()
                .user_agent(format!(
                    "{}/{}",
                    crate::models::launch::LAUNCHER_NAME,
                    crate::models::launch::LAUNCHER_VERSION
                ))
                .build()?
                .get(&index.url)
                .send()
                .await
                .map_err(|e| Error::Http(format!("asset index request failed: {e}")))?;
            if !response.status().is_success() {
                return Err(Error::Http(format!(
                    "asset index returned HTTP {}",
                    response.status()
                )));
            }
            response
                .bytes()
                .await
                .map_err(|e| Error::Http(e.to_string()))?
                .to_vec()
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

    fn extract_natives(
        &self,
        plan: &VanillaInstallPlan,
        progress: SharedProgress,
        cancel: &CancelFlag,
    ) -> Result<usize> {
        let target = self.layout.natives_directory(
            &plan.version.natives_version_id,
            self.platform.architecture.jvm_name(),
        )?;
        ensure_dir(&target)?;
        let mut extracted = 0usize;
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
                let mut entry = archive
                    .by_index(index)
                    .map_err(|e| Error::Zip(format!("{}: {e}", jar.path.display())))?;
                if entry.is_dir() {
                    continue;
                }
                let name = entry.name().to_string();
                if name.starts_with("META-INF/") || name.ends_with('/') {
                    continue;
                }
                if jar.excludes.iter().any(|prefix| name.starts_with(prefix)) {
                    continue;
                }
                let Some(file_name) = name.rsplit('/').next() else {
                    continue;
                };
                let destination = target.join(file_name);
                if !destination.starts_with(&target) {
                    continue;
                }
                let mut data = Vec::with_capacity(entry.size() as usize);
                entry.read_to_end(&mut data)?;
                std::fs::write(&destination, &data)?;
                extracted += 1;
            }
            progress.emit(InstallProgressEvent::FileFinished {
                path: jar.path.display().to_string(),
                bytes: std::fs::metadata(&jar.path).map(|m| m.len()).unwrap_or(0),
                source: "natives".into(),
            });
        }
        Ok(extracted)
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
