pub mod downloader;
pub mod hashing;
pub mod loader;
pub mod models;
pub mod state;
pub mod vanilla;
pub mod zip;

pub use downloader::Downloader;
pub use hashing::{sha1_file, sha512_file, verify_file, verify_or_error};
pub use loader::{LoaderInstallResult, LoaderInstaller, LoaderKind, LoaderVersion};
pub use models::{
    CancelFlag, DownloadConfiguration, DownloadSourcePolicy, DownloadSummary, DownloadTask,
    InstallProgressEvent, InstallReport, MissingDependencyKind, NoopProgress, ProgressSink,
    SharedProgress, TrustedMirrorConfiguration,
};
pub use state::{InstallStateMap, InstallStatus};
pub use vanilla::VanillaInstaller;
