use std::path::Path;

use launcher_auth::{AuthConfig, MicrosoftAuthService};
use launcher_core::java::JavaManager;
use launcher_core::launch::{LaunchContext, LaunchIdentity, LaunchPlanBuilder, LaunchService};
use launcher_core::models::account::{
    AccountKind, ActiveAccountStore, LocalAccountStore, MicrosoftAccountStore,
};
use launcher_core::models::instance::{Instance, InstanceManifest, InstanceRepository};
use launcher_core::models::launch::GameProcessEvent;
use launcher_core::version::VersionResolver;
use launcher_core::{Error, Result};
use serde_json::json;

use crate::context::Context;
use crate::LaunchArgs;

pub async fn launch(context: &Context, args: &LaunchArgs) -> Result<()> {
    let identity_text = args.identity.as_deref().ok_or_else(|| {
        Error::MissingInput(
            "launch requires --identity local:<name> or --identity microsoft:<uuid|name>".into(),
        )
    })?;
    let (instance, ephemeral) = resolve_instance(context, args)?;
    let version_id = instance
        .manifest
        .version_id
        .clone()
        .or_else(|| args.version.clone())
        .ok_or_else(|| {
            Error::MissingInput(
                "launch needs --version or an instance with an assigned version".into(),
            )
        })?;
    let resolved = VersionResolver.resolve(&version_id, &context.layout.game_root)?;
    let java = select_java(context, args, &instance, &resolved)?;
    let identity = resolve_identity(context, identity_text).await?;
    let mut platform = context.platform.clone();
    platform.architecture = java.architecture;
    let mut launch_context = LaunchContext::new(
        instance.directory.clone(),
        instance.game_directory.clone(),
        java.executable.clone(),
        platform,
        identity,
    );
    if let Some(memory) = instance.manifest.memory_mib {
        launch_context
            .additional_jvm_arguments
            .push(format!("-Xmx{memory}M"));
    }
    if let Some(arguments) = instance.manifest.jvm_arguments.as_ref() {
        launch_context
            .additional_jvm_arguments
            .extend(arguments.iter().cloned());
    }

    if args.dry_run {
        let preview =
            LaunchPlanBuilder::preview(&instance, &resolved, &context.layout, &launch_context)?;
        if context.json {
            context.json(&preview)?;
        } else {
            context.header(&format!("Launch preview for {}", resolved.id));
            context.field(
                "Identity",
                format!(
                    "{} ({})",
                    preview.identity_display_name,
                    preview.identity_mode.as_str()
                ),
            );
            context.field("Java", preview.java_executable.display());
            context.field("Main class", &preview.main_class);
            context.field("Classpath entries", preview.classpath_entry_count);
            context.field("Game directory", preview.game_directory.display());
            context.field("JVM arguments", preview.jvm_arguments.join(" "));
            context.field("Game arguments", preview.game_arguments.join(" "));
            context.field("Missing dependencies", preview.missing_dependencies.len());
            for diagnostic in &preview.diagnostics {
                context.line(format!("diagnostic: {diagnostic:?}"));
            }
        }
        return Ok(());
    }

    let plan = LaunchPlanBuilder::build(&instance, &resolved, &context.layout, &launch_context)?;
    let log_path = instance.logs_directory().join("game.log");
    let mut running = LaunchService::launch(&plan, Some(log_path)).await?;
    if context.json {
        context.json(&json!({ "pid": running.process_id, "version": resolved.id, "instance": instance.id() }))?;
    } else {
        context.header(&format!(
            "Launched Minecraft {} (pid {})",
            resolved.id, running.process_id
        ));
        context.field("Instance", instance.id());
        context.field("Identity", launch_context.identity.display_name());
    }
    if !ephemeral {
        let mut manifest = instance.manifest.clone();
        manifest.last_launched_at = Some(chrono::Utc::now());
        manifest.last_identity_mode = Some(launch_context.identity.mode);
        let _ = InstanceRepository::new(context.layout.clone()).save(&manifest);
    }
    while let Ok(event) = running.events.recv().await {
        match event {
            GameProcessEvent::Stdout { line } => {
                if context.json {
                    eprintln!("{line}");
                } else {
                    println!("{line}");
                }
            }
            GameProcessEvent::Stderr { line } => {
                eprintln!("{line}");
            }
            GameProcessEvent::Exited { exit } => {
                if context.json {
                    context.json(&json!({
                        "pid": running.process_id,
                        "exitCode": exit.code,
                        "reason": format!("{:?}", exit.reason),
                        "success": exit.is_success,
                    }))?;
                } else {
                    context.field(
                        "Exit code",
                        exit.code
                            .map(|code| code.to_string())
                            .unwrap_or_else(|| "-".into()),
                    );
                    context.field("Success", if exit.is_success { "yes" } else { "no" });
                }
                if !exit.is_success {
                    return Err(Error::Other(format!(
                        "game exited with {}",
                        exit.code
                            .map(|code| code.to_string())
                            .unwrap_or_else(|| "a signal".into())
                    )));
                }
                break;
            }
        }
    }
    Ok(())
}

fn resolve_instance(context: &Context, args: &LaunchArgs) -> Result<(Instance, bool)> {
    if let Some(id) = args.instance.as_deref() {
        if args.version.is_some() {
            return Err(Error::MissingInput(
                "launch accepts --instance or --version, not both".into(),
            ));
        }
        let instance = InstanceRepository::new(context.layout.clone()).load(id)?;
        return Ok((instance, false));
    }
    let version = args.version.as_deref().ok_or_else(|| {
        Error::MissingInput("launch needs --instance <id> or --version <id>".into())
    })?;
    let manifest =
        InstanceManifest::new("ephemeral", "Ephemeral launch", Some(version.to_string()));
    Ok((
        Instance {
            manifest,
            directory: context.layout.game_root.clone(),
            game_directory: context.layout.game_root.clone(),
        },
        true,
    ))
}

fn select_java(
    context: &Context,
    args: &LaunchArgs,
    instance: &Instance,
    resolved: &launcher_core::version::ResolvedVersion,
) -> Result<launcher_core::java::JavaRuntime> {
    if let Some(path) = args.java.as_ref() {
        return JavaManager::new(context.layout.clone()).inspect(path);
    }
    let manager = JavaManager::new(context.layout.clone());
    if let Some(record) = instance.manifest.java_runtime.as_ref() {
        let path = Path::new(&record.executable);
        if path.is_file() {
            if let Ok(runtime) = manager.inspect(path) {
                return Ok(runtime);
            }
        }
    }
    let required = resolved.java_requirement.major_version.unwrap_or(8).max(8);
    manager
        .find(required)
        .or_else(|| manager.discover().into_iter().next())
        .ok_or_else(|| Error::JavaUnusable(format!("no Java {required}+ runtime was found")))
}

async fn resolve_identity(context: &Context, value: &str) -> Result<LaunchIdentity> {
    let (kind, target) = value.split_once(':').ok_or_else(|| {
        Error::MissingInput("identity must look like local:<name> or microsoft:<uuid|name>".into())
    })?;
    match kind {
        "local" => {
            let store = LocalAccountStore::new(context.layout.clone());
            let account = store.load(target).or_else(|_| {
                let active = ActiveAccountStore::new(context.layout.clone()).load();
                match active {
                    Some(reference)
                        if reference.kind == AccountKind::Local
                            && reference.identifier == target =>
                    {
                        store.load(target)
                    }
                    _ => Err(Error::NotFound(format!(
                        "local account '{target}' does not exist"
                    ))),
                }
            })?;
            Ok(LaunchIdentity::local_offline(&account.profile()))
        }
        "microsoft" => {
            let store = MicrosoftAccountStore::new(context.layout.clone());
            let account = match uuid::Uuid::parse_str(target) {
                Ok(id) => store.load(id)?,
                Err(_) => store
                    .list()?
                    .into_iter()
                    .find(|account| account.player_name.eq_ignore_ascii_case(target))
                    .ok_or_else(|| {
                        Error::NotFound(format!("Microsoft account '{target}' is not signed in"))
                    })?,
            };
            let auth = MicrosoftAuthService::new(
                AuthConfig::default(),
                context.layout.clone(),
                context.runtime.secrets.clone(),
            )?;
            let session = auth.session_for(account.id).await?;
            Ok(LaunchIdentity::microsoft(&account, session.access_token))
        }
        other => Err(Error::MissingInput(format!(
            "unknown identity kind '{other}'"
        ))),
    }
}
