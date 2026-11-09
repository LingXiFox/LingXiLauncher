//! Shared launcher domain: version metadata, instances, authentication,
//! installation and launch planning. GUI and CLI are thin shells over this crate.

pub mod error;
pub mod install;
pub mod layout;
pub mod models;
pub mod paths;
pub mod platform;
pub mod version;

pub use error::{Error, Result};
pub use layout::GameDataLayout;
pub use platform::{Architecture, OsName, PlatformContext, Runtime, SecretStore, SystemServices};
