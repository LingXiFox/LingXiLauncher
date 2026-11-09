use std::path::PathBuf;
use std::sync::Arc;

use launcher_core::install::{
    CancelFlag, DownloadSourcePolicy, InstallProgressEvent, ProgressSink, SharedProgress,
    TrustedMirrorConfiguration, VanillaInstaller,
};
use launcher_core::{Error, GameDataLayout, PlatformContext, Result, Runtime};
use launcher_platform::native_runtime;

/// Shared process context: paths, host capabilities and output policy.
pub struct Context {
    pub layout: GameDataLayout,
    pub platform: PlatformContext,
    pub runtime: Runtime,
    pub json: bool,
    pub source: DownloadSourcePolicy,
    pub mirror: Option<TrustedMirrorConfiguration>,
}

impl Context {
    pub fn new(
        root: Option<PathBuf>,
        data_root: Option<PathBuf>,
        json: bool,
        source: Option<&str>,
        mirror_config: Option<&PathBuf>,
    ) -> Result<Self> {
        let mut layout = GameDataLayout::from_environment();
        if let Some(root) = root {
            layout.game_root = root;
        }
        if let Some(data_root) = data_root {
            layout.data_root = data_root;
        }
        let source = match source {
            Some(value) => DownloadSourcePolicy::parse(value)?,
            None => DownloadSourcePolicy::Official,
        };
        if matches!(source, DownloadSourcePolicy::Mirror) && mirror_config.is_none() {
            return Err(Error::MissingInput(
                "the mirror source requires --mirror-config <path>".into(),
            ));
        }
        let mirror = mirror_config
            .map(|path| TrustedMirrorConfiguration::load(path))
            .transpose()?;
        let (platform, runtime) = native_runtime(layout.accounts_directory())?;
        Ok(Self {
            layout,
            platform,
            runtime,
            json,
            source,
            mirror,
        })
    }

    pub fn installer(&self) -> VanillaInstaller {
        VanillaInstaller::new(
            self.layout.clone(),
            self.platform.clone(),
            self.source,
            self.mirror.clone(),
        )
    }

    pub fn progress(&self) -> SharedProgress {
        Arc::new(CliProgress)
    }

    pub fn cancel(&self) -> CancelFlag {
        CancelFlag::new()
    }

    pub fn header(&self, title: &str) {
        if !self.json {
            println!("{title}");
        }
    }

    pub fn field(&self, label: &str, value: impl std::fmt::Display) {
        if !self.json {
            println!("{label}: {value}");
        }
    }

    pub fn line(&self, value: impl std::fmt::Display) {
        if !self.json {
            println!("{value}");
        }
    }

    pub fn json<T: serde::Serialize>(&self, value: &T) -> Result<()> {
        if self.json {
            println!("{}", serde_json::to_string(value)?);
        }
        Ok(())
    }
}

/// Progress is written to stderr so stdout stays machine readable.
struct CliProgress;

impl ProgressSink for CliProgress {
    fn emit(&self, event: InstallProgressEvent) {
        match event {
            InstallProgressEvent::Phase { phase, message } => {
                eprintln!("[{phase}] {message}");
            }
            InstallProgressEvent::Plan {
                total_files,
                total_bytes,
                cache_hits,
            } => {
                eprintln!(
                    "[plan] {total_files} files, {total_bytes} bytes, {cache_hits} from cache"
                );
            }
            InstallProgressEvent::FileStarted { .. } | InstallProgressEvent::Bytes { .. } => {}
            InstallProgressEvent::FileFinished { .. } => {}
            InstallProgressEvent::FileFailed { path, message } => {
                eprintln!("[failed] {path}: {message}");
            }
        }
    }
}

pub fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} {}", UNITS[unit])
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}
