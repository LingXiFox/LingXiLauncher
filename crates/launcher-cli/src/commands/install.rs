use std::path::PathBuf;

use launcher_core::install::{
    DownloadConfiguration, InstallReport, LoaderInstallResult, LoaderInstaller, VanillaInstaller,
};
use launcher_core::java::JavaManager;
use launcher_core::models::instance::{Instance, InstanceRepository};
use launcher_core::{Error, Result};
use serde_json::json;

use crate::context::Context;
use crate::InstallAction;

pub async fn install(context: &Context, action: InstallAction) -> Result<()> {
    match action {
        InstallAction::Vanilla {
            version,
            instance,
            name,
            concurrency,
        } => {
            let repository = InstanceRepository::new(context.layout.clone());
            let instance = match repository.load(&instance) {
                Ok(instance) => instance,
                Err(Error::NotFound(_)) => repository.create(
                    &instance,
                    name.as_deref().unwrap_or(&version),
                    Some(&version),
                )?,
                Err(error) => return Err(error),
            };
            let report = run_vanilla(context, &version, concurrency).await?;
            if instance.manifest.version_id.as_deref() != Some(version.as_str()) {
                repository.assign_version(&instance, &version)?;
            }
            print_report(context, &report, instance.id());
            Ok(())
        }
        InstallAction::Fabric {
            version,
            instance,
            loader,
            name,
            update,
        } => {
            let repository = InstanceRepository::new(context.layout.clone());
            let instance =
                prepare_instance(&repository, &instance, &version, name.as_deref(), update)?;
            ensure_vanilla(context, &version).await?;
            let installer = LoaderInstaller::new(context.layout.clone())?;
            let result = installer
                .install_fabric(
                    &instance,
                    &version,
                    loader.as_deref(),
                    context.progress(),
                    context.cancel(),
                )
                .await?;
            print_loader(context, &result);
            Ok(())
        }
        InstallAction::Neoforge {
            version,
            instance,
            loader,
            name,
            update,
        } => {
            let repository = InstanceRepository::new(context.layout.clone());
            let instance =
                prepare_instance(&repository, &instance, &version, name.as_deref(), update)?;
            ensure_vanilla(context, &version).await?;
            let java = instance
                .manifest
                .java_runtime
                .as_ref()
                .map(|runtime| PathBuf::from(&runtime.executable))
                .filter(|path| path.is_file())
                .or_else(|| {
                    JavaManager::new(context.layout.clone())
                        .find(21)
                        .map(|runtime| runtime.executable)
                })
                .unwrap_or_else(|| PathBuf::from(if cfg!(windows) { "java.exe" } else { "java" }));
            let installer = LoaderInstaller::new(context.layout.clone())?;
            let result = installer
                .install_neoforge(
                    &instance,
                    &version,
                    &loader,
                    &java,
                    context.progress(),
                    context.cancel(),
                )
                .await?;
            print_loader(context, &result);
            Ok(())
        }
    }
}

fn prepare_instance(
    repository: &InstanceRepository,
    id: &str,
    version: &str,
    name: Option<&str>,
    update: bool,
) -> Result<Instance> {
    match repository.load(id) {
        Ok(instance) => {
            if !update {
                return Err(Error::MissingInput(format!(
                    "instance '{id}' already exists; pass --update to reinstall its loader"
                )));
            }
            Ok(instance)
        }
        Err(Error::NotFound(_)) => {
            let label = name.unwrap_or(version);
            repository.create(id, label, Some(version))
        }
        Err(error) => Err(error),
    }
}

async fn ensure_vanilla(context: &Context, version: &str) -> Result<()> {
    let metadata = context.layout.version_json(version)?;
    let jar = context.layout.client_jar(version)?;
    if metadata.is_file() && jar.is_file() {
        return Ok(());
    }
    run_vanilla(context, version, None).await.map(|_| ())
}

async fn run_vanilla(
    context: &Context,
    version: &str,
    concurrency: Option<usize>,
) -> Result<InstallReport> {
    let mut installer: VanillaInstaller = context.installer();
    if let Some(concurrency) = concurrency {
        if !(1..=32).contains(&concurrency) {
            return Err(Error::MissingInput(
                "--concurrency must be between 1 and 32".into(),
            ));
        }
        installer = installer.with_configuration(DownloadConfiguration {
            concurrency,
            ..DownloadConfiguration::default()
        });
    }
    installer
        .install(version, context.progress(), context.cancel())
        .await
}

fn print_report(context: &Context, report: &InstallReport, instance_id: &str) {
    if context.json {
        let _ = context.json(&json!({
            "instance": instance_id,
            "version": report.version_id,
            "downloadedFiles": report.downloaded_files,
            "downloadedBytes": report.downloaded_bytes,
            "cacheHits": report.cache_hits,
            "assetObjects": report.asset_object_count,
            "extractedNatives": report.extracted_natives,
            "missingAfterInstall": report.missing_after_install,
            "complete": report.is_complete(),
            "sourcePolicy": report.source_policy,
        }));
    } else {
        context.header(&format!("Minecraft {} installed", report.version_id));
        context.field("Instance", instance_id);
        context.field("Files downloaded", report.downloaded_files);
        context.field("Bytes downloaded", report.downloaded_bytes);
        context.field("Cache hits", report.cache_hits);
        context.field("Missing after install", report.missing_after_install.len());
        context.field("Complete", if report.is_complete() { "yes" } else { "no" });
    }
}

fn print_loader(context: &Context, result: &LoaderInstallResult) {
    if context.json {
        let _ = context.json(result);
    } else {
        context.header(&format!("{:?} loader installed", result.loader));
        context.field("Minecraft", &result.game_version);
        context.field("Loader version", &result.loader_version);
        context.field("Version id", &result.version_id);
        context.field("Instance", &result.instance_id);
    }
}
