#[cfg(windows)]
use std::path::Path;
use std::path::PathBuf;

use launcher_core::platform::SecretStore;
use launcher_core::{Error, Result};

#[cfg(not(target_os = "macos"))]
use crate::ensure_private_dir;
use crate::quiet_command;

/// Stores refresh tokens in the platform credential store.
///
/// macOS uses the user's login Keychain, Windows uses DPAPI scoped to the
/// current user, and Linux uses the Secret Service through secret-tool.
/// Linux never falls back to a plaintext file unless the operator explicitly
/// opts in for a headless test environment.
pub struct NativeSecretStore {
    fallback_dir: PathBuf,
}

impl NativeSecretStore {
    pub fn new(fallback_dir: impl Into<PathBuf>) -> Self {
        Self {
            fallback_dir: fallback_dir.into(),
        }
    }

    #[cfg_attr(target_os = "macos", allow(dead_code))]
    fn fallback_path(&self, service: &str, account: &str) -> PathBuf {
        self.fallback_dir
            .join(format!("{}-{}.secret", encode(service), encode(account)))
    }
}

#[cfg_attr(target_os = "macos", allow(dead_code))]
fn encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len() * 2);
    for byte in value.as_bytes() {
        if byte.is_ascii_alphanumeric() || *byte == b'-' || *byte == b'_' {
            out.push(*byte as char);
        } else {
            out.push_str(&format!("{byte:02x}"));
        }
    }
    out
}

#[cfg(target_os = "macos")]
const LEGACY_KEYCHAIN_SERVICE: &str = "com.lingxifox.LingXiLauncher.microsoft";
#[cfg(target_os = "macos")]
const REFRESH_TOKEN_PREFIX: &str = "microsoft-refresh-token:v1:";

#[cfg(target_os = "macos")]
fn legacy_account(account: &str) -> Option<String> {
    let uuid = account.strip_prefix(REFRESH_TOKEN_PREFIX)?;
    if uuid.len() == 36
        && uuid.chars().enumerate().all(|(index, ch)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                ch == '-'
            } else {
                ch.is_ascii_hexdigit()
            }
        })
    {
        Some(uuid.to_ascii_lowercase())
    } else {
        None
    }
}

#[cfg(target_os = "macos")]
impl NativeSecretStore {
    fn keychain_get(&self, service: &str, account: &str) -> Result<Option<String>> {
        let output = quiet_command("/usr/bin/security")
            .args(["find-generic-password", "-s", service, "-a", account, "-w"])
            .output()?;
        if output.status.success() {
            let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
            return Ok(if value.is_empty() { None } else { Some(value) });
        }
        match output.status.code() {
            Some(44) => Ok(None),
            _ => Err(Error::Other("keychain read failed".into())),
        }
    }

    fn keychain_set(&self, service: &str, account: &str, secret: &str) -> Result<()> {
        let status = quiet_command("/usr/bin/security")
            .args([
                "add-generic-password",
                "-U",
                "-s",
                service,
                "-a",
                account,
                "-w",
                secret,
            ])
            .status()?;
        if status.success() {
            Ok(())
        } else {
            Err(Error::Other("keychain write failed".into()))
        }
    }

    fn keychain_delete(&self, service: &str, account: &str) -> Result<()> {
        let status = quiet_command("/usr/bin/security")
            .args(["delete-generic-password", "-s", service, "-a", account])
            .status()?;
        if status.success() || status.code() == Some(44) {
            Ok(())
        } else {
            Err(Error::Other("keychain delete failed".into()))
        }
    }
}

#[cfg(target_os = "macos")]
impl SecretStore for NativeSecretStore {
    fn get(&self, service: &str, account: &str) -> Result<Option<String>> {
        if let Some(value) = self.keychain_get(service, account)? {
            return Ok(Some(value));
        }
        // Swift releases stored refresh tokens under a different service name
        // and used the bare account UUID. Read it once, migrate it to the
        // current naming scheme, then remove the old entry.
        if let Some(legacy_account) = legacy_account(account) {
            if let Some(value) = self.keychain_get(LEGACY_KEYCHAIN_SERVICE, &legacy_account)? {
                self.keychain_set(service, account, &value)?;
                let _ = self.keychain_delete(LEGACY_KEYCHAIN_SERVICE, &legacy_account);
                return Ok(Some(value));
            }
        }
        Ok(None)
    }

    fn set(&self, service: &str, account: &str, secret: &str) -> Result<()> {
        self.keychain_set(service, account, secret)
    }

    fn delete(&self, service: &str, account: &str) -> Result<()> {
        self.keychain_delete(service, account)?;
        if let Some(legacy_account) = legacy_account(account) {
            let _ = self.keychain_delete(LEGACY_KEYCHAIN_SERVICE, &legacy_account);
        }
        Ok(())
    }
}

#[cfg(windows)]
impl NativeSecretStore {
    fn run_powershell(
        &self,
        script: &str,
        path: &Path,
        input: Option<&str>,
    ) -> Result<std::process::Output> {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = quiet_command("powershell")
            .args(["-NoProfile", "-NonInteractive", "-Command", script])
            .env("LINGXI_DPAPI_PATH", path)
            .env("LINGXI_DPAPI_ENTROPY", "LingXiLauncher")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        if let Some(text) = input {
            child
                .stdin
                .as_mut()
                .expect("stdin")
                .write_all(text.as_bytes())?;
        }
        Ok(child.wait_with_output()?)
    }

    fn read_protected(&self, path: &Path, with_entropy: bool) -> Result<Option<String>> {
        if !path.is_file() {
            return Ok(None);
        }
        let script = if with_entropy {
            r#"Add-Type -AssemblyName System.Security
$protected = [IO.File]::ReadAllBytes($env:LINGXI_DPAPI_PATH)
$entropy = [Text.Encoding]::UTF8.GetBytes($env:LINGXI_DPAPI_ENTROPY)
$plain = [Security.Cryptography.ProtectedData]::Unprotect($protected, $entropy, 'CurrentUser')
[Console]::Out.Write([Convert]::ToBase64String($plain))"#
        } else {
            r#"Add-Type -AssemblyName System.Security
$protected = [IO.File]::ReadAllBytes($env:LINGXI_DPAPI_PATH)
$plain = [Security.Cryptography.ProtectedData]::Unprotect($protected, $null, 'CurrentUser')
[Console]::Out.Write([Convert]::ToBase64String($plain))"#
        };
        let output = self.run_powershell(script, path, None)?;
        if !output.status.success() {
            return Ok(None);
        }
        use base64::Engine as _;
        let encoded = String::from_utf8_lossy(&output.stdout);
        let bytes = match base64::engine::general_purpose::STANDARD.decode(encoded.trim()) {
            Ok(bytes) => bytes,
            Err(_) => return Ok(None),
        };
        let value = String::from_utf8_lossy(&bytes).to_string();
        Ok(if value.is_empty() { None } else { Some(value) })
    }

    fn legacy_path(account: &str) -> Option<PathBuf> {
        let uuid = account.strip_prefix(REFRESH_TOKEN_PREFIX)?;
        if uuid.len() != 36 {
            return None;
        }
        let base = std::env::var_os("APPDATA")?;
        Some(
            PathBuf::from(base)
                .join("LingXiLauncher")
                .join("credentials")
                .join(format!("{}.bin", uuid.to_ascii_lowercase())),
        )
    }
}

#[cfg(windows)]
const REFRESH_TOKEN_PREFIX: &str = "microsoft-refresh-token:v1:";

#[cfg(windows)]
impl SecretStore for NativeSecretStore {
    fn get(&self, service: &str, account: &str) -> Result<Option<String>> {
        let path = self.fallback_path(service, account);
        if let Some(value) = self.read_protected(&path, true)? {
            return Ok(Some(value));
        }
        // Older Rust builds used DPAPI without an entropy blob.
        if let Some(value) = self.read_protected(&path, false)? {
            self.set(service, account, &value)?;
            return Ok(Some(value));
        }
        // Swift releases wrote to %APPDATA%/LingXiLauncher/credentials.
        if let Some(legacy) = Self::legacy_path(account) {
            if let Some(value) = self.read_protected(&legacy, true)? {
                self.set(service, account, &value)?;
                let _ = std::fs::remove_file(legacy);
                return Ok(Some(value));
            }
        }
        Ok(None)
    }

    fn set(&self, service: &str, account: &str, secret: &str) -> Result<()> {
        ensure_private_dir(&self.fallback_dir)?;
        let path = self.fallback_path(service, account);
        let temporary = path.with_extension("tmp");
        let script = r#"Add-Type -AssemblyName System.Security
$plain = [Console]::In.ReadToEnd()
$bytes = [Text.Encoding]::UTF8.GetBytes($plain)
$entropy = [Text.Encoding]::UTF8.GetBytes($env:LINGXI_DPAPI_ENTROPY)
$protected = [Security.Cryptography.ProtectedData]::Protect($bytes, $entropy, 'CurrentUser')
[IO.File]::WriteAllBytes($env:LINGXI_DPAPI_PATH, $protected)"#;
        let output = self.run_powershell(script, &temporary, Some(secret))?;
        if !output.status.success() {
            let _ = std::fs::remove_file(&temporary);
            return Err(Error::Other("credential write failed".into()));
        }
        if path.exists() {
            let _ = std::fs::remove_file(&path);
        }
        std::fs::rename(&temporary, &path)?;
        Ok(())
    }

    fn delete(&self, service: &str, account: &str) -> Result<()> {
        let path = self.fallback_path(service, account);
        if path.exists() {
            std::fs::remove_file(path)?;
        }
        if let Some(legacy) = Self::legacy_path(account) {
            if legacy.exists() {
                let _ = std::fs::remove_file(legacy);
            }
        }
        Ok(())
    }
}

#[cfg(not(any(target_os = "macos", windows)))]
impl NativeSecretStore {
    fn secret_tool_available() -> bool {
        quiet_command("secret-tool")
            .arg("--version")
            .output()
            .map(|output| output.status.success())
            .unwrap_or(false)
    }

    fn allow_plaintext_fallback() -> bool {
        matches!(
            std::env::var("LINGXI_ALLOW_PLAINTEXT_SECRETS").as_deref(),
            Ok("1") | Ok("true")
        )
    }
}

#[cfg(not(any(target_os = "macos", windows)))]
impl SecretStore for NativeSecretStore {
    fn get(&self, service: &str, account: &str) -> Result<Option<String>> {
        if Self::secret_tool_available() {
            let output = quiet_command("secret-tool")
                .args(["lookup", "service", service, "account", account])
                .output()?;
            if output.status.success() {
                let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
                return Ok(if value.is_empty() { None } else { Some(value) });
            }
            return Ok(None);
        }
        if !Self::allow_plaintext_fallback() {
            return Err(Error::Unavailable(
                "no Secret Service provider found; install libsecret-tools/secret-tool".into(),
            ));
        }
        let path = self.fallback_path(service, account);
        match std::fs::read_to_string(path) {
            Ok(value) => Ok(if value.is_empty() { None } else { Some(value) }),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    fn set(&self, service: &str, account: &str, secret: &str) -> Result<()> {
        if Self::secret_tool_available() {
            use std::io::Write;
            use std::process::Stdio;
            let mut child = quiet_command("secret-tool")
                .args([
                    "store",
                    "--label",
                    "LingXi Launcher Microsoft refresh token",
                    "service",
                    service,
                    "account",
                    account,
                ])
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::piped())
                .spawn()?;
            child
                .stdin
                .as_mut()
                .expect("stdin")
                .write_all(secret.as_bytes())?;
            let output = child.wait_with_output()?;
            if output.status.success() {
                return Ok(());
            }
            return Err(Error::Unavailable(
                "Secret Service rejected the refresh token; unlock the login keyring and retry"
                    .into(),
            ));
        }
        if !Self::allow_plaintext_fallback() {
            return Err(Error::Unavailable(
                "no Secret Service provider found; install libsecret-tools/secret-tool".into(),
            ));
        }
        ensure_private_dir(&self.fallback_dir)?;
        let path = self.fallback_path(service, account);
        std::fs::write(&path, secret)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        }
        Ok(())
    }

    fn delete(&self, service: &str, account: &str) -> Result<()> {
        if Self::secret_tool_available() {
            let output = quiet_command("secret-tool")
                .args(["clear", "service", service, "account", account])
                .output()?;
            if !output.status.success() && output.status.code() != Some(1) {
                return Err(Error::Other("Secret Service delete failed".into()));
            }
            return Ok(());
        }
        if !Self::allow_plaintext_fallback() {
            return Err(Error::Unavailable(
                "no Secret Service provider found; install libsecret-tools/secret-tool".into(),
            ));
        }
        let path = self.fallback_path(service, account);
        if path.exists() {
            std::fs::remove_file(path)?;
        }
        Ok(())
    }
}

/// In-memory store for tests and headless verification.
#[derive(Default)]
pub struct MemorySecretStore {
    values: std::sync::Mutex<std::collections::HashMap<(String, String), String>>,
}

impl SecretStore for MemorySecretStore {
    fn get(&self, service: &str, account: &str) -> Result<Option<String>> {
        Ok(self
            .values
            .lock()
            .expect("secret lock")
            .get(&(service.to_string(), account.to_string()))
            .cloned())
    }

    fn set(&self, service: &str, account: &str, secret: &str) -> Result<()> {
        self.values.lock().expect("secret lock").insert(
            (service.to_string(), account.to_string()),
            secret.to_string(),
        );
        Ok(())
    }

    fn delete(&self, service: &str, account: &str) -> Result<()> {
        self.values
            .lock()
            .expect("secret lock")
            .remove(&(service.to_string(), account.to_string()));
        Ok(())
    }
}
