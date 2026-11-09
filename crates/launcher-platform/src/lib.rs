//! Native platform services: OS keychain access, file manager integration and
//! desktop notifications. Kept separate from `launcher-core` so the domain crate
//! stays free of host-specific process handling.

use std::path::PathBuf;

use launcher_core::platform::{PlatformContext, Runtime, SecretStore, SystemServices};
use launcher_core::Result;

pub mod secrets;
pub mod system;

pub use secrets::NativeSecretStore;
pub use system::NativeSystemServices;

/// Builds the runtime bundle used by the CLI and the Tauri shell.
pub fn native_runtime(secret_fallback_dir: impl Into<PathBuf>) -> Result<(PlatformContext, Runtime)> {
    let context = PlatformContext::current();
    let secrets: std::sync::Arc<dyn SecretStore> =
        std::sync::Arc::new(NativeSecretStore::new(secret_fallback_dir));
    let system: std::sync::Arc<dyn SystemServices> = std::sync::Arc::new(NativeSystemServices);
    Ok((context, Runtime { secrets, system }))
}

/// Runs a command without a console window on Windows.
pub(crate) fn quiet_command(program: impl AsRef<std::ffi::OsStr>) -> std::process::Command {
    let mut command = std::process::Command::new(program);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000);
    }
    command
}

/// Ensures a directory exists and is only accessible by the current user.
pub(crate) fn ensure_private_dir(path: &std::path::Path) -> Result<()> {
    std::fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700));
    }
    Ok(())
}
