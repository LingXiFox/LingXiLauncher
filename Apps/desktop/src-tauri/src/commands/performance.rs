use launcher_core::performance::{
    BenchmarkReport, PerformanceRecommendation, PerformanceService, SystemProfile,
};
use serde::Serialize;
use tauri::State;

use crate::commands::{command_error, CommandResult};
use crate::state::AppState;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PerformanceSystemView {
    pub cpu: Option<String>,
    pub memory_mib: Option<u64>,
    pub gpu: Option<String>,
    pub os: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PerformanceReportView {
    pub profile: Option<String>,
    pub summary: Option<String>,
    pub recommendations: Vec<String>,
    pub system: Option<PerformanceSystemView>,
    pub score: Option<u32>,
    pub benchmark_score: Option<u32>,
    pub recommendation: PerformanceRecommendation,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BenchmarkResultView {
    pub score: u32,
    pub summary: Option<String>,
    pub duration_ms: Option<u64>,
    pub sample: Option<Vec<u32>>,
}

fn system_view(profile: &SystemProfile) -> PerformanceSystemView {
    PerformanceSystemView {
        cpu: Some(profile.cpu_brand.clone()).filter(|value| !value.trim().is_empty()),
        memory_mib: Some(profile.physical_memory_mib),
        gpu: None,
        os: Some(format!("{} / {}", profile.os, profile.arch)),
    }
}

fn recommendation_lines(recommendation: &PerformanceRecommendation) -> Vec<String> {
    let mut lines = vec![
        format!("分配内存 {} MiB", recommendation.memory_mib),
        format!(
            "渲染距离 {} 区块，模拟距离 {} 区块",
            recommendation.render_distance, recommendation.simulation_distance
        ),
        format!(
            "图形预设 {}，最高帧率 {}",
            recommendation.graphics_preset, recommendation.max_fps
        ),
    ];
    if !recommendation.jvm_args.is_empty() {
        lines.push(format!("JVM 参数：{}", recommendation.jvm_args.join(" ")));
    }
    lines.extend(recommendation.notes.iter().cloned());
    lines
}

fn latest_score(
    service: &PerformanceService,
    instance: &launcher_core::models::instance::Instance,
) -> Option<u32> {
    service
        .list_reports_for(instance)
        .ok()
        .and_then(|reports| reports.into_iter().max_by_key(|report| report.generated_at))
        .map(|report| report.score)
}

#[tauri::command]
pub fn performance_report(
    state: State<'_, AppState>,
    instance_id: String,
) -> CommandResult<PerformanceReportView> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let service = PerformanceService::new(state.layout.clone());
    let profile = service.system_profile();
    let recommendation = service.recommend_for(&instance);
    let score = latest_score(&service, &instance);
    let summary = format!(
        "{} · {} 核心 · 可用磁盘 {} MiB",
        profile.cpu_brand, profile.cpu_cores, profile.disk_free_mib
    );
    Ok(PerformanceReportView {
        profile: Some(recommendation.graphics_preset.clone()),
        summary: Some(summary),
        recommendations: recommendation_lines(&recommendation),
        system: Some(system_view(&profile)),
        score,
        benchmark_score: score,
        recommendation,
    })
}

#[tauri::command]
pub fn run_benchmark(
    state: State<'_, AppState>,
    instance_id: String,
) -> CommandResult<BenchmarkResultView> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let service = PerformanceService::new(state.layout.clone());
    let report: BenchmarkReport = service.benchmark(&instance).map_err(command_error)?;
    let notes = if report.notes.is_empty() {
        format!(
            "评级 {} · 整数 {} ops/s · 浮点 {} ops/s · 内存带宽 {} MiB/s",
            report.grade,
            report.cpu_integer_ops_per_sec,
            report.cpu_float_ops_per_sec,
            report.memory_bandwidth_mib_s
        )
    } else {
        report.notes.join("；")
    };
    Ok(BenchmarkResultView {
        score: report.score,
        summary: Some(notes),
        duration_ms: Some(report.duration_ms),
        sample: None,
    })
}

#[tauri::command]
pub fn apply_performance(
    state: State<'_, AppState>,
    instance_id: String,
) -> CommandResult<PerformanceRecommendation> {
    let instance = state.instances.load(&instance_id).map_err(command_error)?;
    let service = PerformanceService::new(state.layout.clone());
    let recommendation = service.recommend_for(&instance);
    service
        .apply_to_instance(&instance, &recommendation)
        .map_err(command_error)?;
    Ok(recommendation)
}
