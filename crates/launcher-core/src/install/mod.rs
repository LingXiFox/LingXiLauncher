pub mod downloader;
pub mod hashing;
pub mod models;
pub mod zip;

pub use downloader::Downloader;
pub use hashing::{sha1_file, sha512_file, verify_file, verify_or_error};
pub use models::{
    CancelFlag, DownloadConfiguration, DownloadSourcePolicy, DownloadSummary, DownloadTask,
    InstallProgressEvent, InstallReport, MissingDependencyKind, NoopProgress, ProgressSink,
    TrustedMirrorConfiguration,
};
