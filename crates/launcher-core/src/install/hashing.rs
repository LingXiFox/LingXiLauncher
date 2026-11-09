use std::io::Read;
use std::path::Path;

use sha1::Digest;

use crate::error::{Error, Result};

pub fn sha1_file(path: &Path) -> Result<String> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = sha1::Sha1::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hex::encode(hasher.finalize()))
}

pub fn sha512_file(path: &Path) -> Result<String> {
    use sha2::Digest as _;
    let mut file = std::fs::File::open(path)?;
    let mut hasher = sha2::Sha512::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hex::encode(hasher.finalize()))
}

pub fn sha1_bytes(bytes: &[u8]) -> String {
    use sha1::Digest as _;
    let mut hasher = sha1::Sha1::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

/// Verifies size first (cheap) and then SHA-1 when provided.
pub fn verify_file(
    path: &Path,
    expected_sha1: Option<&str>,
    expected_size: Option<u64>,
) -> Result<bool> {
    let metadata = match std::fs::metadata(path) {
        Ok(metadata) if metadata.is_file() => metadata,
        _ => return Ok(false),
    };
    if metadata.len() == 0 {
        return Ok(false);
    }
    if let Some(size) = expected_size {
        if metadata.len() != size {
            return Ok(false);
        }
    }
    if let Some(expected) = expected_sha1 {
        let actual = sha1_file(path)?;
        if actual != expected.to_ascii_lowercase() {
            return Ok(false);
        }
    }
    Ok(true)
}

pub fn verify_or_error(
    path: &Path,
    expected_sha1: Option<&str>,
    expected_size: Option<u64>,
) -> Result<()> {
    if verify_file(path, expected_sha1, expected_size)? {
        return Ok(());
    }
    let actual = if path.is_file() {
        sha1_file(path).unwrap_or_else(|_| "unreadable".into())
    } else {
        "missing".into()
    };
    Err(Error::HashMismatch {
        path: path.to_path_buf(),
        expected: expected_sha1.unwrap_or("<size only>").to_string(),
        actual,
    })
}
