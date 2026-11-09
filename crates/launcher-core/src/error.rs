use std::path::PathBuf;

/// Unified error type for the launcher core. Every variant maps to a stable
/// machine-readable code so the GUI and CLI can present the same diagnosis.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("invalid metadata: {0}")]
    InvalidMetadata(String),
    #[error("unsupported version: {0}")]
    UnsupportedVersion(String),
    #[error("unsafe path: {0}")]
    UnsafePath(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("missing input: {0}")]
    MissingInput(String),
    #[error("hash mismatch for {path}: expected {expected}, got {actual}")]
    HashMismatch {
        path: PathBuf,
        expected: String,
        actual: String,
    },
    #[error("java runtime unusable: {0}")]
    JavaUnusable(String),
    #[error("service unavailable: {0}")]
    Unavailable(String),
    #[error("authentication failed: {0}")]
    Authentication(String),
    #[error("cancelled")]
    Cancelled,
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("http error: {0}")]
    Http(String),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("zip error: {0}")]
    Zip(String),
    #[error("{0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn code(&self) -> &'static str {
        match self {
            Error::InvalidMetadata(_) => "invalid_metadata",
            Error::UnsupportedVersion(_) => "unsupported_version",
            Error::UnsafePath(_) => "unsafe_path",
            Error::NotFound(_) => "not_found",
            Error::MissingInput(_) => "missing_input",
            Error::HashMismatch { .. } => "hash_mismatch",
            Error::JavaUnusable(_) => "java_unusable",
            Error::Unavailable(_) => "unavailable",
            Error::Authentication(_) => "authentication",
            Error::Cancelled => "cancelled",
            Error::Io(_) => "io_error",
            Error::Http(_) => "http_error",
            Error::Json(_) => "invalid_json",
            Error::Zip(_) => "zip_error",
            Error::Other(_) => "internal_error",
        }
    }

    /// Process exit code, mirrored by the CLI.
    pub fn exit_code(&self) -> i32 {
        match self {
            Error::MissingInput(_) => 2,
            Error::InvalidMetadata(_)
            | Error::UnsupportedVersion(_)
            | Error::Json(_)
            | Error::UnsafePath(_)
            | Error::Zip(_) => 3,
            Error::NotFound(_) => 4,
            Error::JavaUnusable(_) => 5,
            Error::Unavailable(_) | Error::Http(_) => 6,
            Error::Authentication(_) => 7,
            Error::Io(_) => 8,
            Error::Cancelled => 130,
            Error::Other(_) => 1,
            Error::HashMismatch { .. } => 9,
        }
    }

    pub fn is_cancelled(&self) -> bool {
        matches!(self, Error::Cancelled)
    }
}

impl From<reqwest::Error> for Error {
    fn from(value: reqwest::Error) -> Self {
        Error::Http(value.to_string())
    }
}

impl From<zip::result::ZipError> for Error {
    fn from(value: zip::result::ZipError) -> Self {
        Error::Zip(value.to_string())
    }
}

impl From<url::ParseError> for Error {
    fn from(value: url::ParseError) -> Self {
        Error::InvalidMetadata(format!("invalid url: {value}"))
    }
}
