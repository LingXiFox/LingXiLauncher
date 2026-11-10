//! Machine profiling, graphics recommendations and a small synthetic
//! benchmark for the launcher.
//!
//! Everything here uses the standard library plus small platform commands
//! (`sysctl`, `df`, `wmic`, PowerShell). No third-party system-info crate is
//! required.

use std::cmp::Reverse;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::layout::{ensure_dir, GameDataLayout};
use crate::models::instance::{Instance, InstanceRepository, MAX_MEMORY_MIB, MIN_MEMORY_MIB};
use crate::paths::PathSafety;

const BENCHMARK_PHASE_MS: u64 = 100;
const MAX_RECOMMENDED_MEMORY_MIB: u32 = 16 * 1024;
const G1_FLAGS: [&str; 9] = [
    "-XX:+UseG1GC",
    "-XX:+ParallelRefProcEnabled",
    "-XX:MaxGCPauseMillis=200",
    "-XX:+UnlockExperimentalVMOptions",
    "-XX:+DisableExplicitGC",
    "-XX:G1NewSizePercent=30",
    "-XX:G1MaxNewSizePercent=40",
    "-XX:G1HeapRegionSize=8M",
    "-XX:G1ReservePercent=20",
];

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SystemProfile {
    /// `std::env::consts::OS`, e.g. `macos`, `linux`, `windows`.
    pub os: String,
    /// `std::env::consts::ARCH`, e.g. `aarch64`, `x86_64`.
    pub arch: String,
    pub cpu_brand: String,
    pub cpu_cores: usize,
    pub physical_memory_mib: u64,
    /// Free space on the volume that holds the launcher data root.
    pub disk_free_mib: u64,
    pub apple_silicon: bool,
}

impl SystemProfile {
    /// Probes the machine. `probe` is used for the disk-free measurement and
    /// usually points at the launcher data root.
    pub fn detect(probe: &Path) -> Self {
        let probe = if probe.exists() {
            probe.to_path_buf()
        } else {
            std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
        };
        Self {
            os: std::env::consts::OS.to_string(),
            arch: std::env::consts::ARCH.to_string(),
            cpu_brand: cpu_brand(),
            cpu_cores: std::thread::available_parallelism()
                .map(|count| count.get())
                .unwrap_or(1),
            physical_memory_mib: physical_memory_mib(),
            disk_free_mib: disk_free_mib(&probe),
            apple_silicon: cfg!(all(target_os = "macos", target_arch = "aarch64")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PerformanceRecommendation {
    pub memory_mib: u32,
    /// GC flags only. Heap size is always carried by `memory_mib`; this list
    /// never contains `-Xmx` or `-Xms`.
    pub jvm_args: Vec<String>,
    pub render_distance: u32,
    pub simulation_distance: u32,
    /// `fast`, `fancy` or `fabulous`.
    pub graphics_preset: String,
    pub max_fps: u32,
    pub notes: Vec<String>,
}

/// Read-only summary of a benchmark written by the Swift launcher.
///
/// The Swift report schema stores process timings rather than the synthetic
/// operations/sec score used by the Rust runner. It is intentionally kept as a
/// separate type so legacy data can be displayed and preserved without
/// inventing a score that was never measured.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LegacyBenchmarkSummary {
    pub id: String,
    pub created_at: String,
    pub instance_id: String,
    pub minecraft_version: String,
    pub loader: String,
    pub samples: u64,
    pub startup_average_ms: Option<f64>,
    pub cpu_average: Option<f64>,
    pub resident_peak_bytes: Option<u64>,
    pub notes: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SwiftBenchmarkReport {
    id: String,
    created_at: String,
    instance_id: String,
    minecraft_version: String,
    loader: String,
    aggregate: SwiftBenchmarkAggregate,
    #[serde(default)]
    notes: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SwiftBenchmarkAggregate {
    #[serde(default)]
    samples: u64,
    #[serde(default)]
    startup_average: Option<f64>,
    #[serde(default)]
    cpu_average: Option<f64>,
    #[serde(default)]
    resident_peak_bytes: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BenchmarkReport {
    pub generated_at: DateTime<Utc>,
    pub instance_id: String,
    /// Synthetic score in `0..=100`.
    pub score: u32,
    /// `S`, `A`, `B`, `C`, `D` or `E`.
    pub grade: String,
    pub cpu_integer_ops_per_sec: u64,
    pub cpu_float_ops_per_sec: u64,
    pub memory_bandwidth_mib_s: u64,
    pub duration_ms: u64,
    pub profile: SystemProfile,
    pub notes: Vec<String>,
}

/// Profiling, recommendations and benchmark reports for one launcher data
/// layout.
pub struct PerformanceService {
    layout: GameDataLayout,
    repository: InstanceRepository,
}

impl PerformanceService {
    pub fn new(layout: GameDataLayout) -> Self {
        Self {
            repository: InstanceRepository::new(layout.clone()),
            layout,
        }
    }

    pub fn layout(&self) -> &GameDataLayout {
        &self.layout
    }

    pub fn system_profile(&self) -> SystemProfile {
        SystemProfile::detect(&self.layout.data_root)
    }

    /// Pure recommendation from a profile and the instance's current memory
    /// setting (`None` means "not configured yet").
    pub fn recommend(
        profile: &SystemProfile,
        instance_memory_mib: Option<u32>,
    ) -> PerformanceRecommendation {
        let total_mib = profile.physical_memory_mib;
        let mut notes = Vec::new();
        let tier = memory_tier(total_mib);
        let mut memory_mib = match instance_memory_mib {
            Some(current) if current >= MIN_MEMORY_MIB => current,
            Some(current) => {
                notes.push(format!(
                    "Configured memory ({current} MiB) is below the minimum; using {tier} MiB."
                ));
                tier
            }
            None => tier,
        };

        if total_mib > 0 {
            let cap = (total_mib / 2)
                .max(1024)
                .min(MAX_RECOMMENDED_MEMORY_MIB as u64) as u32;
            if memory_mib > cap {
                notes.push(format!(
                    "Reduced heap from {memory_mib} MiB to {cap} MiB to leave memory for the OS."
                ));
                memory_mib = cap;
            }
        } else {
            notes.push(
                "Physical memory could not be detected; using a conservative 2048 MiB heap."
                    .to_string(),
            );
        }
        memory_mib = round_to_256(memory_mib)
            .clamp(1024, MAX_MEMORY_MIB)
            .min(MAX_RECOMMENDED_MEMORY_MIB);
        if let Some(current) = instance_memory_mib {
            if current != memory_mib {
                notes.push(format!(
                    "Adjusted configured memory from {current} MiB to {memory_mib} MiB."
                ));
            }
        }

        if profile.apple_silicon {
            notes.push(format!(
                "Apple Silicon ({}) detected; heap and render distance are tuned for unified memory.",
                profile.cpu_brand
            ));
        }
        if total_mib > 0 && total_mib <= 8 * 1024 {
            notes.push(
                "8 GB class machine: the recommended heap leaves headroom for macOS and the GPU."
                    .to_string(),
            );
        }
        if memory_mib < 2048 {
            notes.push("Heap is below 2048 MiB; G1 tuning flags were omitted.".to_string());
        }

        let jvm_args = if memory_mib >= 2048 {
            G1_FLAGS.iter().map(|flag| (*flag).to_string()).collect()
        } else {
            Vec::new()
        };
        let render_distance: u32 = match memory_mib {
            8192.. => 16,
            6144..=8191 => 14,
            4096..=6143 => 12,
            3072..=4095 => 10,
            2048..=3071 => 8,
            _ => 6,
        };
        let simulation_distance = render_distance.saturating_sub(2).clamp(4, 12);
        let graphics_preset = if memory_mib >= 6144 && total_mib >= 32 * 1024 {
            "fabulous"
        } else if memory_mib <= 3072 || (total_mib > 0 && total_mib <= 8 * 1024) {
            "fast"
        } else {
            "fancy"
        };
        let max_fps = if total_mib >= 32 * 1024 {
            144
        } else if total_mib >= 16 * 1024 {
            120
        } else {
            60
        };

        PerformanceRecommendation {
            memory_mib,
            jvm_args,
            render_distance,
            simulation_distance,
            graphics_preset: graphics_preset.to_string(),
            max_fps,
            notes,
        }
    }

    pub fn recommend_for(&self, instance: &Instance) -> PerformanceRecommendation {
        Self::recommend(&self.system_profile(), instance.manifest.memory_mib)
    }

    /// Persists memory/JVM settings on the instance and updates the graphics
    /// keys in its `options.txt`.
    pub fn apply_to_instance(
        &self,
        instance: &Instance,
        recommendation: &PerformanceRecommendation,
    ) -> Result<Instance> {
        if !(MIN_MEMORY_MIB..=MAX_MEMORY_MIB).contains(&recommendation.memory_mib) {
            return Err(Error::InvalidMetadata(format!(
                "recommended memory {} MiB is outside {}..={} MiB",
                recommendation.memory_mib, MIN_MEMORY_MIB, MAX_MEMORY_MIB
            )));
        }
        if recommendation
            .jvm_args
            .iter()
            .any(|argument| argument.starts_with("-Xmx") || argument.starts_with("-Xms"))
        {
            return Err(Error::InvalidMetadata(
                "-Xmx/-Xms must not appear in recommended JVM arguments".into(),
            ));
        }
        if !matches!(
            recommendation.graphics_preset.as_str(),
            "fast" | "fancy" | "fabulous"
        ) {
            return Err(Error::InvalidMetadata(format!(
                "unknown graphics preset '{}'",
                recommendation.graphics_preset
            )));
        }
        if !(2..=32).contains(&recommendation.render_distance) {
            return Err(Error::InvalidMetadata(format!(
                "render distance {} is outside 2..=32",
                recommendation.render_distance
            )));
        }
        if !(2..=32).contains(&recommendation.simulation_distance) {
            return Err(Error::InvalidMetadata(format!(
                "simulation distance {} is outside 2..=32",
                recommendation.simulation_distance
            )));
        }
        if !(1..=1000).contains(&recommendation.max_fps) {
            return Err(Error::InvalidMetadata(format!(
                "max FPS {} is outside 1..=1000",
                recommendation.max_fps
            )));
        }

        let updated = self.repository.set_performance(
            instance,
            Some(recommendation.memory_mib),
            recommendation.jvm_args.clone(),
        )?;
        let values = [
            ("renderDistance", recommendation.render_distance.to_string()),
            (
                "simulationDistance",
                recommendation.simulation_distance.to_string(),
            ),
            ("maxFps", recommendation.max_fps.to_string()),
            ("graphics", recommendation.graphics_preset.clone()),
        ];
        set_options_values(&instance.game_directory, &values)?;
        Ok(updated)
    }

    /// Runs a roughly 300 ms synthetic CPU/memory benchmark and writes a JSON
    /// report below `<dataRoot>/performance/reports`.
    pub fn benchmark(&self, instance: &Instance) -> Result<BenchmarkReport> {
        let profile = self.system_profile();
        let started = Instant::now();
        let integer_ops = integer_benchmark(Duration::from_millis(BENCHMARK_PHASE_MS));
        let float_ops = float_benchmark(Duration::from_millis(BENCHMARK_PHASE_MS));
        let buffer_size =
            if profile.physical_memory_mib > 0 && profile.physical_memory_mib < 4 * 1024 {
                4 * 1024 * 1024
            } else {
                8 * 1024 * 1024
            };
        let memory_bandwidth =
            memory_benchmark(Duration::from_millis(BENCHMARK_PHASE_MS), buffer_size);
        let duration_ms = started.elapsed().as_millis() as u64;
        let score = score_benchmark(integer_ops, float_ops, memory_bandwidth);
        let report = BenchmarkReport {
            generated_at: Utc::now(),
            instance_id: instance.id().to_string(),
            score,
            grade: grade_for(score).to_string(),
            cpu_integer_ops_per_sec: integer_ops,
            cpu_float_ops_per_sec: float_ops,
            memory_bandwidth_mib_s: memory_bandwidth,
            duration_ms,
            profile,
            notes: vec![
                "Synthetic benchmark: scores are relative to the launcher's reference machine, not an absolute hardware rating."
                    .to_string(),
            ],
        };
        self.write_report(&report)?;
        Ok(report)
    }

    pub fn reports_directory(&self) -> PathBuf {
        self.layout.data_root.join("performance").join("reports")
    }

    /// Reads every valid report, newest first. Unreadable or corrupt files are
    /// skipped rather than failing the whole list.
    pub fn list_reports(&self) -> Result<Vec<BenchmarkReport>> {
        let directory = self.reports_directory();
        if !directory.is_dir() {
            return Ok(Vec::new());
        }
        let mut reports = Vec::new();
        for entry in std::fs::read_dir(&directory)? {
            let entry = match entry {
                Ok(entry) => entry,
                Err(_) => continue,
            };
            let path = entry.path();
            if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
                continue;
            }
            if let Ok(text) = std::fs::read_to_string(&path) {
                if let Ok(report) = serde_json::from_str::<BenchmarkReport>(&text) {
                    reports.push(report);
                }
            }
        }
        reports.sort_by_key(|report| Reverse(report.generated_at));
        Ok(reports)
    }

    pub fn list_reports_for(&self, instance: &Instance) -> Result<Vec<BenchmarkReport>> {
        let mut reports = self.list_reports()?;
        reports.retain(|report| report.instance_id == instance.id());
        Ok(reports)
    }

    /// Lists Swift-era benchmark reports without modifying them. Rust reports
    /// are intentionally excluded; callers can combine both lists.
    pub fn list_legacy_reports_for(
        &self,
        instance: &Instance,
    ) -> Result<Vec<LegacyBenchmarkSummary>> {
        let directory = self.reports_directory();
        if !directory.is_dir() {
            return Ok(Vec::new());
        }
        let mut reports = Vec::new();
        for entry in std::fs::read_dir(&directory)? {
            let entry = match entry {
                Ok(entry) => entry,
                Err(_) => continue,
            };
            let path = entry.path();
            if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
                continue;
            }
            let text = match std::fs::read_to_string(&path) {
                Ok(text) => text,
                Err(_) => continue,
            };
            let report = match serde_json::from_str::<SwiftBenchmarkReport>(&text) {
                Ok(report) => report,
                Err(_) => continue,
            };
            if report.instance_id != instance.id() {
                continue;
            }
            reports.push(LegacyBenchmarkSummary {
                id: report.id,
                created_at: report.created_at,
                instance_id: report.instance_id,
                minecraft_version: report.minecraft_version,
                loader: report.loader,
                samples: report.aggregate.samples,
                startup_average_ms: report.aggregate.startup_average,
                cpu_average: report.aggregate.cpu_average,
                resident_peak_bytes: report.aggregate.resident_peak_bytes,
                notes: report.notes,
            });
        }
        reports.sort_by(|left, right| right.created_at.cmp(&left.created_at));
        Ok(reports)
    }

    fn write_report(&self, report: &BenchmarkReport) -> Result<PathBuf> {
        let directory = self.reports_directory();
        ensure_dir(&directory)?;
        let stamp = report.generated_at.format("%Y%m%d-%H%M%S-%3f").to_string();
        let mut file_name = format!("{stamp}.json");
        let mut attempts = 0u32;
        while directory.join(&file_name).exists() {
            attempts = attempts.saturating_add(1);
            file_name = format!("{stamp}-{attempts}.json");
        }
        let path = PathSafety::safe_join(&directory, &file_name)?;
        let json = serde_json::to_string_pretty(report)?;
        write_atomic(&path, json.as_bytes())?;
        Ok(path)
    }
}

fn memory_tier(total_mib: u64) -> u32 {
    if total_mib == 0 {
        2048
    } else if total_mib >= 48 * 1024 {
        8192
    } else if total_mib >= 32 * 1024 {
        6144
    } else if total_mib >= 16 * 1024 {
        4096
    } else if total_mib >= 8 * 1024 {
        3072
    } else if total_mib >= 4 * 1024 {
        2048
    } else {
        1024
    }
}

fn round_to_256(value: u32) -> u32 {
    value.saturating_add(128) / 256 * 256
}

fn score_benchmark(integer_ops: u64, float_ops: u64, memory_mib_s: u64) -> u32 {
    let integer = (integer_ops as f64 / 300_000_000.0).min(2.0);
    let float = (float_ops as f64 / 120_000_000.0).min(2.0);
    let memory = (memory_mib_s as f64 / 2500.0).min(2.0);
    let composite = integer * 0.4 + float * 0.3 + memory * 0.3;
    ((composite / 2.0) * 100.0).round().clamp(0.0, 100.0) as u32
}

fn grade_for(score: u32) -> &'static str {
    match score {
        90..=100 => "S",
        80..=89 => "A",
        65..=79 => "B",
        50..=64 => "C",
        35..=49 => "D",
        _ => "E",
    }
}

fn integer_benchmark(duration: Duration) -> u64 {
    let started = Instant::now();
    let mut state = 0x9e37_79b9_7f4a_7c15u64;
    let mut operations = 0u64;
    while started.elapsed() < duration {
        for _ in 0..4096 {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state = state.wrapping_mul(0x2545_f491_4f6c_dd1d);
            operations = operations.wrapping_add(4);
        }
        std::hint::black_box(state);
    }
    let seconds = started.elapsed().as_secs_f64().max(0.001);
    (operations as f64 / seconds) as u64
}

fn float_benchmark(duration: Duration) -> u64 {
    let started = Instant::now();
    let mut accumulator = 1.0f64;
    let mut seed = 1.0f64;
    let mut operations = 0u64;
    while started.elapsed() < duration {
        for _ in 0..4096 {
            accumulator = accumulator.mul_add(1.000_000_119_209_289_6, 0.000_000_1);
            seed = seed.mul_add(0.999_999_880_790_710_4, 0.5);
            operations = operations.saturating_add(2);
        }
        std::hint::black_box((accumulator, seed));
    }
    let seconds = started.elapsed().as_secs_f64().max(0.001);
    (operations as f64 / seconds) as u64
}

fn memory_benchmark(duration: Duration, buffer_bytes: usize) -> u64 {
    let buffer_bytes = buffer_bytes.max(1024 * 1024);
    let mut buffer = vec![0u8; buffer_bytes];
    for (index, value) in buffer.iter_mut().enumerate() {
        *value = (index as u8).wrapping_mul(31).wrapping_add(7);
    }
    let started = Instant::now();
    let mut processed = 0u64;
    let mut checksum = 0u64;
    while started.elapsed() < duration {
        let mut sum = 0u64;
        for &value in &buffer {
            sum = sum.wrapping_add(value as u64);
        }
        checksum = checksum.wrapping_add(sum);
        processed = processed.saturating_add(buffer.len() as u64);
    }
    std::hint::black_box(checksum);
    let seconds = started.elapsed().as_secs_f64().max(0.001);
    (processed as f64 / 1_048_576.0 / seconds) as u64
}

fn set_options_values(game_directory: &Path, values: &[(&str, String)]) -> Result<()> {
    ensure_dir(game_directory)?;
    let path = game_directory.join("options.txt");
    let content = std::fs::read_to_string(&path).unwrap_or_default();
    let mut lines: Vec<String> = content.split('\n').map(str::to_string).collect();
    let mut seen = vec![false; values.len()];
    let mut output = Vec::with_capacity(lines.len() + values.len());
    for line in lines.drain(..) {
        let trimmed = line.trim_start();
        let matched = values.iter().position(|(key, _)| {
            trimmed
                .strip_prefix(key)
                .and_then(|rest| rest.strip_prefix(':'))
                .is_some()
        });
        match matched {
            Some(index) => {
                if !seen[index] {
                    output.push(format!("{}:{}", values[index].0, values[index].1));
                    seen[index] = true;
                }
            }
            None => output.push(line),
        }
    }
    let trailing_newline = output.last().map(String::is_empty).unwrap_or(false);
    if trailing_newline {
        output.pop();
    }
    for (index, (key, value)) in values.iter().enumerate() {
        if !seen[index] {
            output.push(format!("{key}:{value}"));
        }
    }
    if trailing_newline {
        output.push(String::new());
    }
    write_atomic(&path, output.join("\n").as_bytes())
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        ensure_dir(parent)?;
    }
    let temporary = path.with_file_name(format!(
        ".{}.tmp-{}",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("data"),
        uuid::Uuid::new_v4().simple()
    ));
    std::fs::write(&temporary, bytes)?;
    if let Err(error) = std::fs::rename(&temporary, path) {
        let _ = std::fs::remove_file(&temporary);
        return Err(error.into());
    }
    Ok(())
}

#[cfg_attr(not(any(target_os = "macos", target_os = "windows")), allow(dead_code))]
fn command_stdout(program: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(program).args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if text.is_empty() {
        None
    } else {
        Some(text)
    }
}

#[cfg_attr(not(any(target_os = "macos", target_os = "windows")), allow(dead_code))]
fn clean_brand(text: &str) -> Option<String> {
    text.lines()
        .map(|line| line.trim().trim_matches('\0').trim())
        .find(|line| !line.is_empty() && !line.eq_ignore_ascii_case("Name"))
        .map(|line| line.to_string())
}

fn cpu_brand() -> String {
    #[cfg(target_os = "macos")]
    {
        if let Some(brand) = command_stdout("sysctl", &["-n", "machdep.cpu.brand_string"])
            .and_then(|text| clean_brand(&text))
        {
            return brand;
        }
        if cfg!(target_arch = "aarch64") {
            return "Apple Silicon".to_string();
        }
        if let Some(model) =
            command_stdout("sysctl", &["-n", "hw.model"]).and_then(|text| clean_brand(&text))
        {
            return format!("Mac ({model})");
        }
    }

    #[cfg(target_os = "linux")]
    {
        if let Some(brand) = linux_cpu_brand() {
            return brand;
        }
    }

    #[cfg(windows)]
    {
        if let Some(brand) =
            command_stdout("wmic", &["cpu", "get", "name"]).and_then(|text| clean_brand(&text))
        {
            return brand;
        }
        if let Some(brand) = command_stdout(
            "powershell",
            &[
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "(Get-CimInstance Win32_Processor).Name",
            ],
        )
        .and_then(|text| clean_brand(&text))
        {
            return brand;
        }
        if let Ok(identifier) = std::env::var("PROCESSOR_IDENTIFIER") {
            let identifier = identifier.trim();
            if !identifier.is_empty() {
                return identifier.to_string();
            }
        }
    }

    format!("{} {}", std::env::consts::OS, std::env::consts::ARCH)
}

#[cfg(target_os = "linux")]
fn linux_cpu_brand() -> Option<String> {
    let content = std::fs::read_to_string("/proc/cpuinfo").ok()?;
    for key in ["model name", "Hardware", "Processor", "cpu model"] {
        for line in content.lines() {
            if let Some((name, value)) = line.split_once(':') {
                if name.trim().eq_ignore_ascii_case(key) {
                    let value = value.trim();
                    if !value.is_empty() {
                        return Some(value.to_string());
                    }
                }
            }
        }
    }
    None
}

fn physical_memory_mib() -> u64 {
    #[cfg(target_os = "macos")]
    {
        for key in ["hw.memsize", "hw.physmem"] {
            if let Some(text) = command_stdout("sysctl", &["-n", key]) {
                if let Ok(bytes) = text.trim().parse::<u64>() {
                    return bytes / 1024 / 1024;
                }
            }
        }
    }

    #[cfg(target_os = "linux")]
    {
        if let Ok(content) = std::fs::read_to_string("/proc/meminfo") {
            for line in content.lines() {
                if let Some(rest) = line.strip_prefix("MemTotal:") {
                    if let Some(kib) = rest
                        .split_whitespace()
                        .next()
                        .and_then(|value| value.parse::<u64>().ok())
                    {
                        return kib / 1024;
                    }
                }
            }
        }
    }

    #[cfg(windows)]
    {
        if let Some(text) = command_stdout(
            "wmic",
            &["computersystem", "get", "TotalPhysicalMemory", "/value"],
        ) {
            for line in text.lines() {
                if let Some((name, value)) = line.split_once('=') {
                    if name.trim().eq_ignore_ascii_case("TotalPhysicalMemory") {
                        if let Ok(bytes) = value.trim().parse::<u64>() {
                            return bytes / 1024 / 1024;
                        }
                    }
                }
            }
        }
        if let Some(text) = command_stdout(
            "powershell",
            &[
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory",
            ],
        ) {
            if let Ok(bytes) = text.trim().parse::<u64>() {
                return bytes / 1024 / 1024;
            }
        }
    }

    0
}

#[cfg(unix)]
fn disk_free_mib(probe: &Path) -> u64 {
    let output = match Command::new("df").args(["-k", "-P"]).arg(probe).output() {
        Ok(output) => output,
        Err(_) => return 0,
    };
    if !output.status.success() {
        return 0;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    for line in text.lines().skip(1).collect::<Vec<_>>().into_iter().rev() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() >= 4 {
            if let Ok(kib) = fields[3].parse::<u64>() {
                return kib / 1024;
            }
        }
    }
    0
}

#[cfg(windows)]
fn disk_free_mib(probe: &Path) -> u64 {
    let text = probe.to_string_lossy();
    let mut chars = text.chars();
    let drive = match (chars.next(), chars.next()) {
        (Some(letter), Some(':')) if letter.is_ascii_alphabetic() => {
            format!("{}:", letter.to_ascii_uppercase())
        }
        _ => "C:".to_string(),
    };
    let script =
        format!("(Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='{drive}'\").FreeSpace");
    if let Some(text) = command_stdout(
        "powershell",
        &["-NoProfile", "-NonInteractive", "-Command", &script],
    ) {
        if let Ok(bytes) = text.trim().parse::<u64>() {
            return bytes / 1024 / 1024;
        }
    }
    0
}

#[cfg(not(any(unix, windows)))]
fn disk_free_mib(_probe: &Path) -> u64 {
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_tiers_match_guidance() {
        assert_eq!(memory_tier(8 * 1024), 3072);
        assert_eq!(memory_tier(16 * 1024), 4096);
        assert_eq!(memory_tier(32 * 1024), 6144);
        assert_eq!(memory_tier(64 * 1024), 8192);
    }

    #[test]
    fn recommendation_never_contains_heap_flags() {
        let profile = SystemProfile {
            os: "macos".into(),
            arch: "aarch64".into(),
            cpu_brand: "Apple M1".into(),
            cpu_cores: 8,
            physical_memory_mib: 16 * 1024,
            disk_free_mib: 50_000,
            apple_silicon: true,
        };
        let recommendation = PerformanceService::recommend(&profile, None);
        assert_eq!(recommendation.memory_mib, 4096);
        assert!(recommendation
            .jvm_args
            .iter()
            .all(|argument| !argument.starts_with("-Xmx") && !argument.starts_with("-Xms")));
        assert!(recommendation
            .jvm_args
            .iter()
            .any(|argument| argument == "-XX:+UseG1GC"));
    }

    #[test]
    fn small_memory_omits_g1_flags() {
        let profile = SystemProfile {
            os: "linux".into(),
            arch: "x86_64".into(),
            cpu_brand: "Test CPU".into(),
            cpu_cores: 2,
            physical_memory_mib: 2 * 1024,
            disk_free_mib: 0,
            apple_silicon: false,
        };
        let recommendation = PerformanceService::recommend(&profile, Some(512));
        assert_eq!(recommendation.memory_mib, 1024);
        assert!(recommendation.jvm_args.is_empty());
    }
    #[test]
    fn legacy_swift_benchmark_is_read_without_rewriting() {
        let root = std::env::temp_dir().join(format!(
            "lingxi-performance-legacy-{}",
            uuid::Uuid::new_v4().simple()
        ));
        let layout = GameDataLayout::new(root.join("game"), root.join("data"));
        let instance = InstanceRepository::new(layout.clone())
            .create("legacy", "Legacy", Some("1.21.11"))
            .expect("instance");
        let reports = layout.data_root.join("performance").join("reports");
        std::fs::create_dir_all(&reports).expect("reports dir");
        let path = reports.join("legacy.json");
        let payload = r#"{
            "id": "legacy-1",
            "createdAt": "2026-01-01T00:00:00Z",
            "instanceId": "legacy",
            "minecraftVersion": "1.21.11",
            "loader": "fabric",
            "aggregate": {
                "samples": 3,
                "startupAverage": 1234.5,
                "cpuAverage": 42.0,
                "residentPeakBytes": 123456
            },
            "notes": ["old"]
        }"#;
        std::fs::write(&path, payload).expect("write report");
        let service = PerformanceService::new(layout);
        let summaries = service
            .list_legacy_reports_for(&instance)
            .expect("legacy reports");
        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0].id, "legacy-1");
        assert_eq!(summaries[0].samples, 3);
        assert_eq!(summaries[0].startup_average_ms, Some(1234.5));
        assert_eq!(summaries[0].cpu_average, Some(42.0));
        assert_eq!(summaries[0].resident_peak_bytes, Some(123456));
        assert_eq!(std::fs::read_to_string(&path).expect("unchanged"), payload);
        let _ = std::fs::remove_dir_all(root);
    }
}
