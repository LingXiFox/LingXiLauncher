use launcher_core::diagnostics::{CrashDiagnosticsService, CrashReportExporter};
use launcher_core::graphics;
use launcher_core::modrinth::ModrinthClient;
use launcher_core::mods::{InstalledMod, ModManager};
use launcher_core::performance::PerformanceService;
use launcher_core::{Error, Result};
use serde_json::json;

use crate::commands::mods::{load_instance, loader_from_version};
use crate::context::Context;
use crate::{GraphicsAction, PerformanceAction};

pub fn diagnose(
    context: &Context,
    instance: &str,
    exit_code: Option<i32>,
    markdown: bool,
) -> Result<()> {
    let service = CrashDiagnosticsService::new(context.layout.clone());
    let report = service.collect_with_exit(instance, exit_code)?;
    if context.json {
        println!("{}", CrashReportExporter::json(&report)?);
        return Ok(());
    }
    if markdown {
        println!("{}", CrashReportExporter::markdown(&report, true));
        return Ok(());
    }
    context.header("Crash diagnostics");
    context.field("Instance", &report.instance_id);
    context.field("Summary", &report.summary);
    context.field(
        "Abnormal exit",
        if report.abnormal_exit { "yes" } else { "no" },
    );
    context.field(
        "Exit code",
        report
            .exit_code
            .map(|code| code.to_string())
            .unwrap_or_else(|| "-".into()),
    );
    if report.diagnostics.is_empty() {
        context.line("No known failure signature was detected.");
    }
    for diagnostic in &report.diagnostics {
        context.line(format!(
            "{}[{}] {} ({:?}, {:?}){}",
            if diagnostic.is_root_cause { "* " } else { "  " },
            diagnostic.category.display_name(),
            diagnostic.explanation,
            diagnostic.severity,
            diagnostic.confidence,
            if diagnostic.is_secondary {
                " [secondary]"
            } else {
                ""
            }
        ));
        for recommendation in &diagnostic.recommendations {
            context.line(format!("    - {recommendation}"));
        }
    }
    Ok(())
}

pub async fn graphics(context: &Context, action: GraphicsAction) -> Result<()> {
    match action {
        GraphicsAction::Status { instance } => {
            let instance = load_instance(context, &instance)?;
            let snapshot = graphics::read(&instance.game_directory)?;
            let manager = ModManager::new(instance.clone(), context.layout.clone())?;
            let mods = manager.list()?;
            let iris = find_mod(&mods, "iris");
            let sodium = find_mod(&mods, "sodium");
            let service = PerformanceService::new(context.layout.clone());
            let recommendation = service.recommend_for(&instance);
            if context.json {
                context.json(&json!({
                    "instance": instance.id(),
                    "options": snapshot,
                    "iris": iris,
                    "sodium": sodium,
                    "recommendation": recommendation,
                }))?;
            } else {
                context.header("Graphics status");
                context.field("Instance", instance.id());
                context.field("options.txt", snapshot.path);
                context.field("Exists", if snapshot.exists { "yes" } else { "no" });
                context.field("Preset", &snapshot.settings.preset);
                context.field("Render distance", snapshot.settings.render_distance);
                context.field("Simulation distance", snapshot.settings.simulation_distance);
                context.field("Max FPS", snapshot.settings.max_fps);
                context.field(
                    "Iris",
                    iris.as_ref()
                        .map(|item| item.version_number.as_str())
                        .unwrap_or("not installed"),
                );
                context.field(
                    "Sodium",
                    sodium
                        .as_ref()
                        .map(|item| item.version_number.as_str())
                        .unwrap_or("not installed"),
                );
                context.field("Recommended preset", &recommendation.graphics_preset);
                context.field(
                    "Recommended memory",
                    format!("{} MiB", recommendation.memory_mib),
                );
            }
            Ok(())
        }
        GraphicsAction::Setup { instance, replace } => {
            let instance = load_instance(context, &instance)?;
            let version_id = instance.manifest.version_id.clone().ok_or_else(|| {
                Error::MissingInput("the instance has no assigned Minecraft version".into())
            })?;
            let loader = loader_from_version(&version_id).unwrap_or_default();
            if loader != "fabric" {
                return Err(Error::UnsupportedVersion(
                    "Iris setup currently requires a Fabric instance".into(),
                ));
            }
            let manager = ModManager::new(instance.clone(), context.layout.clone())?;
            let client = ModrinthClient::new()?;
            let mut installed = Vec::new();
            for slug in ["sodium", "iris"] {
                let existing = manager
                    .list()?
                    .into_iter()
                    .find(|item| item.slug.eq_ignore_ascii_case(slug));
                if let Some(existing) = existing {
                    if !replace {
                        return Err(Error::MissingInput(format!(
                            "{} is already installed; use --replace to reinstall it",
                            existing.title
                        )));
                    }
                    manager.remove(&existing.project_id)?;
                }
                let project = client.project(slug).await?;
                let game_versions = vec![version_id.clone()];
                let loaders = vec!["fabric".to_string()];
                let versions = client
                    .versions(&project.id, &game_versions, &loaders)
                    .await?;
                let version = launcher_core::modrinth::best_version(
                    &versions,
                    Some(&version_id),
                    Some("fabric"),
                )
                .cloned()
                .ok_or_else(|| {
                    Error::NotFound(format!("no Fabric build of {slug} for {version_id}"))
                })?;
                installed.push(manager.install_version(&version).await?);
            }
            if context.json {
                context.json(&installed)?;
            } else {
                context.header("Graphics mods installed");
                for item in &installed {
                    context.field(&item.title, &item.version_number);
                }
                context.field("Restart", "start the instance to let Iris load Sodium");
            }
            Ok(())
        }
    }
}

fn find_mod(mods: &[InstalledMod], slug: &str) -> Option<InstalledMod> {
    mods.iter()
        .find(|item| {
            item.slug.eq_ignore_ascii_case(slug)
                || item.title.eq_ignore_ascii_case(slug)
                || item.file_name.to_ascii_lowercase().contains(slug)
        })
        .cloned()
}

pub fn performance(context: &Context, action: PerformanceAction) -> Result<()> {
    let service = PerformanceService::new(context.layout.clone());
    match action {
        PerformanceAction::Status { instance } => {
            let instance = load_instance(context, &instance)?;
            let profile = service.system_profile();
            let recommendation = service.recommend_for(&instance);
            if context.json {
                context.json(&json!({
                    "instance": instance.id(),
                    "profile": profile,
                    "recommendation": recommendation,
                    "memoryMiB": instance.manifest.memory_mib,
                }))?;
            } else {
                context.header("Performance status");
                context.field("Instance", instance.id());
                context.field("OS", format!("{} {}", profile.os, profile.arch));
                context.field(
                    "CPU",
                    format!("{} ({} threads)", profile.cpu_brand, profile.cpu_cores),
                );
                context.field("Memory", format!("{} MiB", profile.physical_memory_mib));
                context.field("Disk free", format!("{} MiB", profile.disk_free_mib));
                context.field(
                    "Current heap",
                    instance
                        .manifest
                        .memory_mib
                        .map(|value| format!("{value} MiB"))
                        .unwrap_or_else(|| "automatic".into()),
                );
                context.field(
                    "Recommended heap",
                    format!("{} MiB", recommendation.memory_mib),
                );
                context.field("Recommended preset", &recommendation.graphics_preset);
                context.field("Render distance", recommendation.render_distance);
                for note in &recommendation.notes {
                    context.line(format!("note: {note}"));
                }
            }
            Ok(())
        }
        PerformanceAction::Benchmark { instance } => {
            let instance = load_instance(context, &instance)?;
            let report = service.benchmark(&instance)?;
            if context.json {
                context.json(&report)?;
            } else {
                context.header("Benchmark");
                context.field("Score", report.score);
                context.field("Grade", &report.grade);
                context.field("Duration", format!("{} ms", report.duration_ms));
                context.field("CPU integer", report.cpu_integer_ops_per_sec);
                context.field("CPU float", report.cpu_float_ops_per_sec);
                context.field(
                    "Memory bandwidth",
                    format!("{} MiB/s", report.memory_bandwidth_mib_s),
                );
            }
            Ok(())
        }
        PerformanceAction::Tune { instance, apply } => tune(context, &service, &instance, apply),
        PerformanceAction::Apply { instance } => tune(context, &service, &instance, true),
        PerformanceAction::Reports { instance } => {
            let instance = load_instance(context, &instance)?;
            let reports = service.list_reports_for(&instance)?;
            if context.json {
                context.json(&reports)?;
            } else {
                context.header("Benchmark reports");
                if reports.is_empty() {
                    context.line("No benchmark reports found.");
                }
                for report in reports {
                    context.line(format!(
                        "{}  score {}  grade {}  {} ms",
                        report.generated_at.to_rfc3339(),
                        report.score,
                        report.grade,
                        report.duration_ms
                    ));
                }
            }
            Ok(())
        }
    }
}

fn tune(
    context: &Context,
    service: &PerformanceService,
    instance: &str,
    apply: bool,
) -> Result<()> {
    let instance = load_instance(context, instance)?;
    let recommendation = service.recommend_for(&instance);
    let updated = if apply {
        Some(service.apply_to_instance(&instance, &recommendation)?)
    } else {
        None
    };
    if context.json {
        context.json(&json!({
            "recommendation": recommendation,
            "applied": apply,
            "memoryMiB": updated.as_ref().and_then(|instance| instance.manifest.memory_mib),
        }))?;
    } else {
        context.header(if apply {
            "Performance tuning applied"
        } else {
            "Performance recommendation"
        });
        context.field("Heap", format!("{} MiB", recommendation.memory_mib));
        context.field("Preset", &recommendation.graphics_preset);
        context.field("Render distance", recommendation.render_distance);
        context.field("Simulation distance", recommendation.simulation_distance);
        context.field("Max FPS", recommendation.max_fps);
        context.field("JVM flags", recommendation.jvm_args.join(" "));
        for note in &recommendation.notes {
            context.line(format!("note: {note}"));
        }
    }
    Ok(())
}
