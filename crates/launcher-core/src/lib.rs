//! Shared launcher domain: version metadata, instances, authentication,
//! installation and launch planning. GUI and CLI are thin shells over this crate.

pub mod diagnostics;
pub mod error;
pub mod graphics;
pub mod install;
pub mod java;
pub mod launch;
pub mod layout;
pub mod manifest;
pub mod models;
pub mod modpack;
pub mod modrinth;
pub mod mods;
pub mod paths;
pub mod performance;
pub mod platform;
pub mod resourcepacks;
pub mod shaders;
pub mod version;
pub mod worlds;

pub use error::{Error, Result};
pub use layout::GameDataLayout;
pub use platform::{Architecture, OsName, PlatformContext, Runtime, SecretStore, SystemServices};
