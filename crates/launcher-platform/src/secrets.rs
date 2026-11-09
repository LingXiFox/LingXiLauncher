use std::path::PathBuf;

use launcher_core::platform::SecretStore;
use launcher_core::{Error, Result};

#[cfg(not(target_os = "macos"))]
use crate::ensure_private_dir;
use crate::quiet_command;

/// Stores refresh tokens in the macOS Keychain. On Windows the DPAPI user store
/// is used through PowerShell; on other systems a 0600 file is the fallback.
pub struct NativeSecretStore {
    #[cfg_attr(target_os = "macos", allow(dead_code))]
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
impl SecretStore for NativeSecretStore {
    fn get(&self, service: &str, account: &str) -> Result<Option<String>> {
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

    fn set(&self, service: &str, account: &str, secret: &str) -> Result<()> {
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

    fn delete(&self, service: &str, account: &str) -> Result<()> {
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

#[cfg(windows)]
impl NativeSecretStore {
    fn run_powershell(&self, script: &str, input: Option<&str>) -> Result<std::process::Output> {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = quiet_command("powershell")
            .args(["-NoProfile", "-NonInteractive", "-Command", script])
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
}

#[cfg(windows)]
impl SecretStore for NativeSecretStore {
    fn get(&self, service: &str, account: &str) -> Result<Option<String>> {
        let path = self.fallback_path(service, account);
        if !path.exists() {
            return Ok(None);
        }
        let script = format!(
            "$p='{}'; $s=Get-Content -Raw -LiteralPath $p | ConvertTo-SecureString; $b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s); try {{ [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }} finally {{ [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }}",
            path.display()
        );
        let output = self.run_powershell(&script, None)?;
        if output.status.success() {
            let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
            Ok(if value.is_empty() { None } else { Some(value) })
        } else {
            Err(Error::Other("credential read failed".into()))
        }
    }

    fn set(&self, service: &str, account: &str, secret: &str) -> Result<()> {
        ensure_private_dir(&self.fallback_dir)?;
        let path = self.fallback_path(service, account);
        let script = format!(
            "$p='{}'; $s=[Console]::In.ReadToEnd(); ConvertFrom-SecureString (ConvertTo-SecureString $s -AsPlainText -Force) | Set-Content -NoNewline -LiteralPath $p",
            path.display()
        );
        let output = self.run_powershell(&script, Some(secret))?;
        if output.status.success() {
            Ok(())
        } else {
            Err(Error::Other("credential write failed".into()))
        }
    }

    fn delete(&self, service: &str, account: &str) -> Result<()> {
        let path = self.fallback_path(service, account);
        if path.exists() {
            std::fs::remove_file(path)?;
        }
        Ok(())
    }
}

#[cfg(not(any(target_os = "macos", windows)))]
impl SecretStore for NativeSecretStore {
    fn get(&self, service: &str, account: &str) -> Result<Option<String>> {
        let path = self.fallback_path(service, account);
        match std::fs::read_to_string(path) {
            Ok(value) => Ok(if value.is_empty() { None } else { Some(value) }),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    fn set(&self, service: &str, account: &str, secret: &str) -> Result<()> {
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
