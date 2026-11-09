use std::path::PathBuf;

use launcher_core::install::verify_file;
use launcher_core::java::{JavaManager, JavaRuntime};
use launcher_core::manifest::ManifestService;
use launcher_core::models::version::VersionType;
use launcher_core::version::VersionResolver;
use launcher_core::{Error, Result};
use serde::Serialize;
use serde_json::json;

use crate::context::Context;
use crate::{JavaAction, VersionAction};

pub fn version_type_name(value: &VersionType) -> &'static str {
    match value {
        VersionType::Release => "release",
        VersionType::Snapshot => "snapshot",
        VersionType::OldBeta => "old_beta",
        VersionType::OldAlpha => "old_alpha",
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeView {
    path: String,
    version: String,
    major_version: u32,
    architecture: String,
    vendor: Option<String>,
    managed: bool,
}

impl From<&JavaRuntime> for RuntimeView {
    fn from(value: &JavaRuntime) -> Self {
        Self {
            path: value.executable.display().to_string(),
            version: value.version_string.clone(),
            major_version: value.major_version,
            architecture: value.architecture.jvm_name().to_string(),
            vendor: Some(value.vendor.clone()),
            managed: value.is_managed,
        }
    }
}

pub async fn version(context: &Context, action: VersionAction) -> Result<()> {
    match action {
        VersionAction::Inspect { id, java } => inspect_version(context, &id, java).await,
        VersionAction::List { kind } => list_versions(context, &kind).await,
    }
}

async fn list_versions(context: &Context, kind: &str) -> Result<()> {
    let manifest = ManifestService::new(context.layout.clone())?
        .manifest(false)
        .await?;
    let versions: Vec<_> = manifest
        .versions
        .iter()
        .filter(|version| match kind {
            "all" => true,
            "release" => matches!(version.version_type, VersionType::Release),
            "snapshot" => matches!(version.version_type, VersionType::Snapshot),
            "old_beta" => matches!(version.version_type, VersionType::OldBeta),
            "old_alpha" => matches!(version.version_type, VersionType::OldAlpha),
            other => other == version_type_name(&version.version_type),
        })
        .collect();
    if context.json {
        let rows: Vec<_> = versions
            .iter()
            .map(|version| {
                json!({
                    "id": version.id,
                    "type": version_type_name(&version.version_type),
                    "releaseTime": version.release_time,
                    "installed": context.layout.version_json(&version.id).map(|path| path.is_file()).unwrap_or(false),
                })
            })
            .collect();
        context.json(&rows)?;
        return Ok(());
    }
    context.header(&format!("Minecraft versions ({kind})"));
    for version in versions {
        let installed = context
            .layout
            .version_json(&version.id)
            .map(|path| path.is_file())
            .unwrap_or(false);
        context.line(format!(
            "{}  {}{}",
            version.id,
            version_type_name(&version.version_type),
            if installed { "  [installed]" } else { "" }
        ));
    }
    Ok(())
}

async fn inspect_version(context: &Context, id: &str, include_java: bool) -> Result<()> {
    let manifests = ManifestService::new(context.layout.clone())?;
    let summary = manifests.summary(id).await?;
    manifests.metadata_by_id(id).await?;
    let resolved = VersionResolver.resolve(id, &context.layout.game_root)?;
    let metadata_path = context.layout.version_json(id)?;
    let raw: serde_json::Value = std::fs::read(&metadata_path)
        .ok()
        .and_then(|data| serde_json::from_slice(&data).ok())
        .unwrap_or(serde_json::Value::Null);

    let mut missing = Vec::new();
    for library in &resolved.libraries {
        let Some(path) = library
            .downloads
            .as_ref()
            .and_then(|d| d.artifact.as_ref())
            .and_then(|a| a.path.as_ref())
        else {
            continue;
        };
        let target = context.layout.library_path(path)?;
        if !target.is_file() {
            missing.push(target.display().to_string());
        }
    }
    if let Some(jar) = resolved.client_jar.as_ref() {
        let target = context.layout.client_jar(&resolved.client_jar_version_id)?;
        if !target.is_file() {
            missing.push(
                jar.path
                    .clone()
                    .unwrap_or_else(|| target.display().to_string()),
            );
        }
    }

    let java_manager = JavaManager::new(context.layout.clone());
    let runtime = resolved
        .java_requirement
        .major_version
        .and_then(|major| java_manager.find(major))
        .or_else(|| java_manager.discover().into_iter().next());

    let client_jar = context.layout.client_jar(&resolved.client_jar_version_id)?;
    let client_jar_size = std::fs::metadata(&client_jar)
        .map(|meta| meta.len())
        .ok()
        .or_else(|| {
            raw.pointer("/downloads/client/size")
                .and_then(|value| value.as_u64())
        });
    let client_sha = raw
        .pointer("/downloads/client/sha1")
        .and_then(|value| value.as_str())
        .map(str::to_string)
        .or_else(|| {
            resolved
                .client_jar
                .as_ref()
                .and_then(|jar| jar.sha1.clone())
        });

    let report = json!({
        "versionID": resolved.id,
        "type": resolved.version_type.as_ref().map(version_type_name),
        "mainClass": resolved.main_class,
        "formatVersion": raw.get("formatVersion").and_then(|value| value.as_u64()),
        "javaComponent": resolved.java_requirement.component,
        "javaMajorVersion": resolved.java_requirement.major_version,
        "libraryCount": resolved.libraries.len(),
        "classpathEntryCount": resolved.libraries.iter().filter(|lib| lib.downloads.as_ref().and_then(|d| d.artifact.as_ref()).is_some()).count(),
        "jvmArgumentCount": resolved.jvm_arguments.len(),
        "gameArgumentCount": resolved.game_arguments.len(),
        "assetIndexID": resolved.asset_index_id,
        "clientJarSHA1": client_sha,
        "clientJarSize": client_jar_size,
        "clientJar": client_jar.display().to_string(),
        "inheritsFrom": resolved.inherits_from,
        "metadataPath": metadata_path.display().to_string(),
        "missing": missing,
        "java": if include_java { runtime.as_ref().map(RuntimeView::from) } else { None },
        "releaseTime": summary.release_time,
        "url": summary.url,
    });
    if context.json {
        context.json(&report)?;
        return Ok(());
    }
    context.header(&format!("Version {}", resolved.id));
    context.field(
        "Type",
        resolved
            .version_type
            .as_ref()
            .map(version_type_name)
            .unwrap_or("-"),
    );
    context.field("Main class", &resolved.main_class);
    context.field(
        "Java",
        resolved
            .java_requirement
            .major_version
            .map(|v| v.to_string())
            .unwrap_or_else(|| "-".into()),
    );
    context.field("Libraries", resolved.libraries.len());
    context.field("Asset index", &resolved.asset_index_id);
    context.field("Client jar", client_jar.display());
    context.field("Missing files", missing.len());
    for item in &missing {
        context.line(format!("  missing: {item}"));
    }
    if include_java {
        match runtime {
            Some(runtime) => {
                context.field("Java executable", runtime.executable.display());
                context.field("Java version", runtime.version_string);
                context.field("Java architecture", runtime.architecture.jvm_name());
            }
            None => context.field("Java", "not found"),
        }
    }
    Ok(())
}

#[derive(Clone, Debug)]
pub struct DoctorArgs {
    pub java: Option<PathBuf>,
    pub version: Option<String>,
}

pub async fn doctor(context: &Context, args: &DoctorArgs) -> Result<()> {
    let manager = JavaManager::new(context.layout.clone());
    let mut runtimes = manager.discover();
    if let Some(path) = args.java.as_ref() {
        let inspected = manager.inspect(path)?;
        runtimes.retain(|runtime| runtime.executable != inspected.executable);
        runtimes.insert(0, inspected);
    }
    if runtimes.is_empty() {
        return Err(Error::JavaUnusable(
            "no usable Java runtime was found".into(),
        ));
    }
    let selected = runtimes[0].clone();
    let mut diagnostics: Vec<String> = Vec::new();
    let mut missing: Vec<String> = Vec::new();
    let mut version_report = serde_json::Value::Null;
    if let Some(version_id) = args.version.as_deref() {
        let manifests = ManifestService::new(context.layout.clone())?;
        manifests.metadata_by_id(version_id).await?;
        let resolved = VersionResolver.resolve(version_id, &context.layout.game_root)?;
        if let Some(required) = resolved.java_requirement.major_version {
            if selected.major_version < required {
                diagnostics.push(format!(
                    "Minecraft {version_id} requires Java {required}+ but the selected runtime is Java {}",
                    selected.major_version
                ));
            }
        }
        for library in &resolved.libraries {
            let Some(path) = library
                .downloads
                .as_ref()
                .and_then(|d| d.artifact.as_ref())
                .and_then(|a| a.path.as_ref())
            else {
                continue;
            };
            let target = context.layout.library_path(path)?;
            if !target.is_file() {
                missing.push(target.display().to_string());
            }
        }
        version_report = json!({
            "id": resolved.id,
            "javaMajorVersion": resolved.java_requirement.major_version,
            "missing": missing,
        });
    }
    let usable = !runtimes.is_empty() && diagnostics.is_empty();
    if context.json {
        context.json(&json!({
            "java": runtimes.iter().map(RuntimeView::from).collect::<Vec<_>>(),
            "selected": RuntimeView::from(&selected),
            "version": version_report,
            "diagnostics": diagnostics,
            "usable": usable,
        }))?;
    } else {
        context.header("Java runtimes");
        for runtime in &runtimes {
            context.line(format!(
                "{}  Java {}  {}  {}",
                runtime.executable.display(),
                runtime.major_version,
                runtime.architecture.jvm_name(),
                runtime.vendor
            ));
        }
        context.field("Selected", selected.executable.display());
        if let Some(version_id) = args.version.as_deref() {
            context.field("Version", version_id);
            context.field("Missing files", missing.len());
        }
        for message in &diagnostics {
            context.line(format!("warning: {message}"));
        }
    }
    if !diagnostics.is_empty() {
        return Err(Error::JavaUnusable(diagnostics.join("; ")));
    }
    Ok(())
}

pub async fn java(context: &Context, action: JavaAction) -> Result<()> {
    let manager = JavaManager::new(context.layout.clone());
    match action {
        JavaAction::List => {
            let runtimes = manager.discover();
            if context.json {
                let rows: Vec<_> = runtimes.iter().map(RuntimeView::from).collect();
                context.json(&rows)?;
            } else {
                context.header("Java runtimes");
                for runtime in &runtimes {
                    context.line(format!(
                        "{}  Java {}  {}  {}",
                        runtime.executable.display(),
                        runtime.major_version,
                        runtime.architecture.jvm_name(),
                        runtime.vendor
                    ));
                }
            }
            Ok(())
        }
        JavaAction::Install { major } => {
            let runtime = manager
                .install_managed(major, context.progress(), context.cancel())
                .await?;
            if context.json {
                context.json(&RuntimeView::from(&runtime))?;
            } else {
                context.header(&format!("Java {major} installed"));
                context.field("Path", runtime.executable.display());
                context.field("Version", runtime.version_string);
            }
            Ok(())
        }
    }
}

pub struct VerifyArgs {
    pub instance: Option<String>,
    pub version: Option<String>,
    pub repair: bool,
}

pub async fn verify(context: &Context, args: &VerifyArgs) -> Result<()> {
    if args.instance.is_none() && args.version.is_none() {
        return Err(Error::MissingInput(
            "verify needs --instance <id> or --version <id>".into(),
        ));
    }
    if args.instance.is_some() && args.version.is_some() {
        return Err(Error::MissingInput(
            "verify accepts only one of --instance or --version".into(),
        ));
    }
    let (version_id, instance) = match args.instance.as_deref() {
        Some(id) => {
            let repository =
                launcher_core::models::instance::InstanceRepository::new(context.layout.clone());
            let instance = repository.load(id)?;
            let version = instance.manifest.version_id.clone().ok_or_else(|| {
                Error::MissingInput(format!("instance '{id}' has no assigned version"))
            })?;
            (version, Some(instance))
        }
        None => (args.version.clone().unwrap_or_default(), None),
    };
    let installer = context.installer();
    let plan = installer.plan(&version_id).await?;
    let mut missing = Vec::new();
    let mut checked = 0usize;
    for task in &plan.tasks {
        if !task.destination.is_file() {
            missing.push(task.destination.display().to_string());
            continue;
        }
        checked += 1;
        if !verify_file(&task.destination, task.sha1.as_deref(), task.size)? {
            missing.push(task.destination.display().to_string());
        }
    }
    if args.repair && !missing.is_empty() {
        installer
            .install(&version_id, context.progress(), context.cancel())
            .await?;
        if let Some(instance) = instance.as_ref() {
            if instance.manifest.version_id.as_deref() != Some(version_id.as_str()) {
                launcher_core::models::instance::InstanceRepository::new(context.layout.clone())
                    .assign_version(instance, &version_id)?;
            }
        }
    }
    if context.json {
        context.json(&json!({
            "version": version_id,
            "checked": checked,
            "missing": missing,
            "repaired": args.repair && !missing.is_empty(),
        }))?;
    } else {
        context.header(&format!("Verification for {version_id}"));
        context.field("Files checked", checked);
        context.field("Missing or corrupt", missing.len());
        for item in &missing {
            context.line(format!("  {item}"));
        }
        if args.repair && !missing.is_empty() {
            context.field("Repair", "completed");
        }
    }
    if !missing.is_empty() && !args.repair {
        return Err(Error::Other(format!(
            "{} files are missing or corrupt",
            missing.len()
        )));
    }
    Ok(())
}
