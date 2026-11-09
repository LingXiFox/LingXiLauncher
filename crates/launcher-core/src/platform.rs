use std::collections::BTreeMap;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OsName {
    Osx,
    Linux,
    Windows,
}

impl OsName {
    pub fn as_str(&self) -> &'static str {
        match self {
            OsName::Osx => "osx",
            OsName::Linux => "linux",
            OsName::Windows => "windows",
        }
    }

    pub fn current() -> Self {
        if cfg!(target_os = "macos") {
            OsName::Osx
        } else if cfg!(target_os = "windows") {
            OsName::Windows
        } else {
            OsName::Linux
        }
    }

    pub fn from_token(value: &str) -> Result<Self> {
        match value.to_ascii_lowercase().as_str() {
            "osx" | "macos" | "darwin" => Ok(OsName::Osx),
            "linux" => Ok(OsName::Linux),
            "windows" | "win32" => Ok(OsName::Windows),
            other => Err(Error::InvalidMetadata(format!("unknown os name {other}"))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Architecture {
    Arm64,
    X86_64,
    X86,
}

impl Architecture {
    /// JVM style name (`aarch64`, `x86_64`, `x86`).
    pub fn jvm_name(&self) -> &'static str {
        match self {
            Architecture::Arm64 => "aarch64",
            Architecture::X86_64 => "x86_64",
            Architecture::X86 => "x86",
        }
    }

    pub fn current() -> Self {
        #[cfg(target_arch = "aarch64")]
        {
            Architecture::Arm64
        }
        #[cfg(target_arch = "x86_64")]
        {
            Architecture::X86_64
        }
        #[cfg(target_arch = "x86")]
        {
            Architecture::X86
        }
    }

    pub fn from_token(value: &str) -> Result<Self> {
        match value.to_ascii_lowercase().as_str() {
            "arm64" | "aarch64" => Ok(Architecture::Arm64),
            "x86_64" | "amd64" | "x86-64" => Ok(Architecture::X86_64),
            "x86" | "i386" | "i686" => Ok(Architecture::X86),
            other => Err(Error::InvalidMetadata(format!(
                "unknown architecture {other}"
            ))),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlatformContext {
    pub os: OsName,
    /// Architecture the JVM is running as.
    pub architecture: Architecture,
    pub host_architecture: Architecture,
    /// Numeric dotted OS version, empty when unknown.
    pub os_version: String,
    pub features: BTreeMap<String, bool>,
}

impl PlatformContext {
    pub fn current() -> Self {
        Self {
            os: OsName::current(),
            architecture: Architecture::current(),
            host_architecture: Architecture::current(),
            os_version: os_version_string(),
            features: BTreeMap::new(),
        }
    }

    pub fn is_translated(&self) -> bool {
        self.host_architecture == Architecture::Arm64 && self.architecture == Architecture::X86_64
    }

    pub fn feature(&self, name: &str) -> bool {
        self.features.get(name).copied().unwrap_or(false)
    }
}

#[cfg(target_os = "macos")]
fn os_version_string() -> String {
    let output = std::process::Command::new("sw_vers")
        .arg("-productVersion")
        .output();
    output
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}

#[cfg(not(target_os = "macos"))]
fn os_version_string() -> String {
    String::new()
}

/// Secret storage abstraction (Keychain on macOS, Credential Manager on Windows).
pub trait SecretStore: Send + Sync {
    fn get(&self, service: &str, account: &str) -> Result<Option<String>>;
    fn set(&self, service: &str, account: &str, secret: &str) -> Result<()>;
    fn delete(&self, service: &str, account: &str) -> Result<()>;
}

/// Thin system integration surface used by the core without linking GUI frameworks.
pub trait SystemServices: Send + Sync {
    fn open_url(&self, url: &str) -> Result<()>;
    fn reveal_in_file_manager(&self, path: &std::path::Path) -> Result<()>;
    fn notify(&self, title: &str, body: &str) -> Result<()>;
}

/// Bundles every host capability the core needs. Front-ends construct one and
/// hand it to services; tests can supply in-memory implementations.
#[derive(Clone)]
pub struct Runtime {
    pub secrets: Arc<dyn SecretStore>,
    pub system: Arc<dyn SystemServices>,
}

impl std::fmt::Debug for Runtime {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Runtime").finish_non_exhaustive()
    }
}
