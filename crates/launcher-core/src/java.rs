//! Java runtime discovery, inspection and managed runtime installation.
//! Managed runtimes come from Mojang's java-runtime product index.

use std::path::{Path, PathBuf};
use std::process::Command;

use serde::Deserialize;

use crate::error::{Error, Result};
use crate::install::hashing::sha1_file;
use crate::install::models::{
    CancelFlag, DownloadConfiguration, DownloadSourcePolicy, DownloadTask, InstallProgressEvent,
    MissingDependencyKind, SharedProgress,
};
use crate::install::Downloader;
use crate::layout::{ensure_dir, GameDataLayout};
use crate::platform::Architecture;

pub const JAVA_RUNTIME_INDEX: &str =
    "https://launchermeta.mojang.com/v1/products/java-runtime/2ec0cc96c44e5a76b9c8b7c39df7210883d12871/all.json";

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaRuntime {
    pub executable: PathBuf,
    pub version_string: String,
    pub major_version: u32,
    pub architecture: Architecture,
    pub vendor: String,
    pub is_64_bit: bool,
    pub is_managed: bool,
}

impl JavaRuntime {
    pub fn describe(&self) -> String {
        format!(
            "Java {} ({}, {})",
            self.version_string,
            self.vendor,
            match self.architecture {
                Architecture::Arm64 => "aarch64",
                Architecture::X86_64 => "x86_64",
                Architecture::X86 => "x86",
            }
        )
    }
}

pub struct JavaManager {
    layout: GameDataLayout,
}

impl JavaManager {
    pub fn new(layout: GameDataLayout) -> Self {
        Self { layout }
    }

    /// Every plausible runtime: managed installs, JAVA_HOME, PATH and the
    /// platform's standard JVM locations. Invalid candidates are skipped.
    pub fn discover(&self) -> Vec<JavaRuntime> {
        let mut candidates = Vec::new();
        for path in self.managed_executables() {
            candidates.push(path);
        }
        if let Ok(home) = std::env::var("JAVA_HOME") {
            candidates.push(PathBuf::from(home).join("bin").join(java_binary()));
        }
        if let Some(path) = which_java() {
            candidates.push(path);
        }
        #[cfg(target_os = "macos")]
        {
            if let Ok(output) = Command::new("/usr/libexec/java_home").arg("-V").output() {
                let _ = output;
            }
            if let Ok(entries) = std::fs::read_dir("/Library/Java/JavaVirtualMachines") {
                for entry in entries.flatten() {
                    candidates.push(entry.path().join("Contents/Home/bin/java"));
                }
            }
        }
        #[cfg(target_os = "windows")]
        {
            for base in [
                std::env::var_os("ProgramFiles"),
                std::env::var_os("ProgramFiles(x86)"),
            ]
            .into_iter()
            .flatten()
            {
                let root = PathBuf::from(base).join("Java");
                if let Ok(entries) = std::fs::read_dir(root) {
                    for entry in entries.flatten() {
                        candidates.push(entry.path().join("bin/java.exe"));
                    }
                }
            }
        }

        let mut seen = std::collections::HashSet::new();
        let mut runtimes = Vec::new();
        for candidate in candidates {
            let key = candidate.to_string_lossy().to_string();
            if !seen.insert(key) || !candidate.is_file() {
                continue;
            }
            if let Ok(runtime) = self.inspect(&candidate) {
                runtimes.push(runtime);
            }
        }
        runtimes.sort_by_key(|runtime| std::cmp::Reverse(runtime.major_version));
        runtimes
    }

    /// Best installed runtime for the requested major version, preferring the
    /// exact version and the native architecture.
    pub fn find(&self, major: u32) -> Option<JavaRuntime> {
        let runtimes = self.discover();
        runtimes
            .iter()
            .find(|r| r.major_version == major && r.architecture == Architecture::current())
            .or_else(|| runtimes.iter().find(|r| r.major_version == major))
            .or_else(|| runtimes.iter().find(|r| r.major_version > major))
            .cloned()
    }

    pub fn inspect(&self, executable: &Path) -> Result<JavaRuntime> {
        inspect_runtime(executable)
    }

    pub fn managed_executables(&self) -> Vec<PathBuf> {
        let root = self.layout.java_directory();
        let mut found = Vec::new();
        collect_java_binaries(&root, 6, &mut found);
        found
    }

    /// Installs a managed runtime for `major` from Mojang's product index.
    pub async fn install_managed(
        &self,
        major: u32,
        progress: SharedProgress,
        cancel: CancelFlag,
    ) -> Result<JavaRuntime> {
        let platform = runtime_platform();
        let client = reqwest::Client::builder()
            .user_agent(format!(
                "{}/{}",
                crate::models::launch::LAUNCHER_NAME,
                crate::models::launch::LAUNCHER_VERSION
            ))
            .timeout(std::time::Duration::from_secs(120))
            .build()?;
        progress.emit(InstallProgressEvent::Phase {
            phase: "java".into(),
            message: format!("Resolving Java {major} runtime"),
        });
        let index: RuntimeIndex = client
            .get(JAVA_RUNTIME_INDEX)
            .send()
            .await
            .map_err(|e| Error::Http(format!("Java runtime index request failed: {e}")))?
            .json()
            .await
            .map_err(|e| Error::Http(format!("Java runtime index is malformed: {e}")))?;
        let component = component_for_major(major);
        let entries = index
            .get(platform)
            .and_then(|platforms| platforms.get(component))
            .or_else(|| {
                index.get(platform).and_then(|p| {
                    p.iter()
                        .find(|(name, _)| name.contains(&major.to_string()))
                        .map(|(_, v)| v)
                })
            })
            .ok_or_else(|| {
                Error::Unavailable(format!("no managed Java {major} runtime for {platform}"))
            })?;
        let entry = entries.first().ok_or_else(|| {
            Error::Unavailable(format!("managed Java {major} runtime index is empty"))
        })?;

        let manifest: RuntimeManifest = client
            .get(&entry.manifest.url)
            .send()
            .await
            .map_err(|e| Error::Http(format!("Java runtime manifest request failed: {e}")))?
            .json()
            .await
            .map_err(|e| Error::Http(format!("Java runtime manifest is malformed: {e}")))?;

        let root = self
            .layout
            .java_directory()
            .join(component)
            .join(platform)
            .join(component);
        ensure_dir(&root)?;
        let mut tasks = Vec::new();
        for (relative, file) in &manifest.files {
            if file.kind != "file" {
                continue;
            }
            let Some(raw) = file.downloads.as_ref().and_then(|d| d.raw.as_ref()) else {
                continue;
            };
            let destination = crate::paths::PathSafety::safe_join(&root, relative)?;
            if let Some(parent) = destination.parent() {
                ensure_dir(parent)?;
            }
            tasks.push(DownloadTask::new(
                destination,
                Some(raw.url.clone()),
                Some(raw.sha1.clone()),
                Some(raw.size),
                MissingDependencyKind::Java,
            ));
        }
        if tasks.is_empty() {
            return Err(Error::Unavailable(
                "managed Java runtime manifest has no files".into(),
            ));
        }
        let downloader = Downloader::new(
            DownloadSourcePolicy::Official,
            None,
            DownloadConfiguration::default(),
        )?;
        let summary = downloader
            .download(tasks, progress.clone(), cancel.clone())
            .await?;
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        if !summary.failures.is_empty() {
            return Err(Error::Unavailable(format!(
                "{} Java runtime files failed to download",
                summary.failures.len()
            )));
        }
        for (relative, file) in &manifest.files {
            if file.kind == "directory" {
                ensure_dir(&crate::paths::PathSafety::safe_join(&root, relative)?)?;
            }
            if file.kind == "file" && file.executable.unwrap_or(false) {
                let path = crate::paths::PathSafety::safe_join(&root, relative)?;
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    if let Ok(metadata) = std::fs::metadata(&path) {
                        let mut permissions = metadata.permissions();
                        permissions.set_mode(permissions.mode() | 0o755);
                        let _ = std::fs::set_permissions(&path, permissions);
                    }
                }
            }
        }
        let executable = root.join("bin").join(java_binary());
        let mut runtime = inspect_runtime(&executable)?;
        runtime.is_managed = true;
        Ok(runtime)
    }
}

fn java_binary() -> &'static str {
    if cfg!(windows) {
        "java.exe"
    } else {
        "java"
    }
}

fn which_java() -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for directory in std::env::split_paths(&path) {
        let candidate = directory.join(java_binary());
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

fn collect_java_binaries(root: &Path, depth: usize, found: &mut Vec<PathBuf>) {
    if depth == 0 || !root.is_dir() {
        return;
    }
    if let Ok(entries) = std::fs::read_dir(root) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                collect_java_binaries(&path, depth - 1, found);
            } else if path
                .file_name()
                .map(|n| n == java_binary())
                .unwrap_or(false)
            {
                found.push(path);
            }
        }
    }
}

fn inspect_runtime(executable: &Path) -> Result<JavaRuntime> {
    let output = Command::new(executable)
        .args(["-XshowSettings:properties", "-version"])
        .output()
        .map_err(|e| {
            Error::JavaUnusable(format!("cannot execute {}: {e}", executable.display()))
        })?;
    let text = format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let property = |key: &str| -> Option<String> {
        text.lines().find_map(|line| {
            line.trim()
                .strip_prefix(&format!("{key} = "))
                .map(|v| v.trim().to_string())
        })
    };
    let version_string = property("java.version").or_else(|| {
        text.lines()
            .find_map(|line| {
                line.strip_prefix("openjdk version \"")
                    .map(|v| v.trim_end_matches('"').to_string())
            })
            .or_else(|| {
                text.lines().find_map(|line| {
                    line.strip_prefix("java version \"")
                        .map(|v| v.trim_end_matches('"').to_string())
                })
            })
    });
    let version_string = version_string.ok_or_else(|| {
        Error::JavaUnusable(format!(
            "{} did not report a Java version",
            executable.display()
        ))
    })?;
    let major_version = parse_major(&version_string).ok_or_else(|| {
        Error::JavaUnusable(format!("cannot parse Java version '{version_string}'"))
    })?;
    let architecture = match property("os.arch").as_deref() {
        Some("aarch64") | Some("arm64") => Architecture::Arm64,
        Some("x86_64") | Some("amd64") => Architecture::X86_64,
        Some("x86") | Some("i386") => Architecture::X86,
        _ => Architecture::current(),
    };
    let vendor = property("java.vendor").unwrap_or_else(|| "Unknown".into());
    Ok(JavaRuntime {
        executable: executable.to_path_buf(),
        version_string,
        major_version,
        architecture,
        vendor,
        is_64_bit: architecture != Architecture::X86,
        is_managed: false,
    })
}

pub fn parse_major(version: &str) -> Option<u32> {
    let mut parts = version.split(['.', '-', '+', '_']);
    let first: u32 = parts.next()?.parse().ok()?;
    if first == 1 {
        parts.next()?.parse().ok()
    } else {
        Some(first)
    }
}

fn runtime_platform() -> &'static str {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        "mac-os-arm64"
    }
    #[cfg(all(target_os = "macos", not(target_arch = "aarch64")))]
    {
        "mac-os"
    }
    #[cfg(all(target_os = "windows", target_arch = "x86_64"))]
    {
        "windows-x64"
    }
    #[cfg(all(target_os = "windows", not(target_arch = "x86_64")))]
    {
        "windows-x86"
    }
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        "linux"
    }
    #[cfg(all(target_os = "linux", not(target_arch = "x86_64")))]
    {
        "linux-i386"
    }
}

fn component_for_major(major: u32) -> &'static str {
    match major {
        0..=8 => "jre-legacy",
        9..=16 => "java-runtime-alpha",
        17..=20 => "java-runtime-gamma",
        _ => "java-runtime-delta",
    }
}

#[derive(Deserialize)]
#[serde(transparent)]
struct RuntimeIndex(
    std::collections::HashMap<String, std::collections::HashMap<String, Vec<RuntimeIndexEntry>>>,
);

impl std::ops::Deref for RuntimeIndex {
    type Target = std::collections::HashMap<
        String,
        std::collections::HashMap<String, Vec<RuntimeIndexEntry>>,
    >;
    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

#[allow(dead_code)]
#[derive(Deserialize)]
struct RuntimeIndexEntry {
    manifest: RuntimeManifestRef,
    #[serde(default)]
    version: Option<RuntimeVersion>,
}

#[allow(dead_code)]
#[derive(Deserialize)]
struct RuntimeManifestRef {
    url: String,
    #[serde(default)]
    sha1: String,
    #[serde(default)]
    size: u64,
}

#[allow(dead_code)]
#[derive(Deserialize)]
struct RuntimeVersion {
    #[serde(default)]
    name: String,
}

#[derive(Deserialize)]
struct RuntimeManifest {
    files: std::collections::HashMap<String, RuntimeFile>,
}

#[derive(Deserialize)]
struct RuntimeFile {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    downloads: Option<RuntimeDownloads>,
    #[serde(default)]
    executable: Option<bool>,
}

#[derive(Deserialize)]
struct RuntimeDownloads {
    #[serde(default)]
    raw: Option<RuntimeDownload>,
}

#[derive(Deserialize)]
struct RuntimeDownload {
    url: String,
    #[serde(default)]
    sha1: String,
    #[serde(default)]
    size: u64,
}

/// Verifies an existing managed runtime directory (used by doctor).
pub fn verify_managed_runtime(root: &Path) -> Result<()> {
    let executable = root.join("bin").join(java_binary());
    if !executable.is_file() {
        return Err(Error::JavaUnusable(format!(
            "managed runtime at {} has no java executable",
            root.display()
        )));
    }
    let _ = sha1_file(&executable)?;
    Ok(())
}
