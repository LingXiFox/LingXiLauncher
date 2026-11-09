use std::io::Read;
use std::path::Path;

use crate::error::{Error, Result};
use crate::paths::PathSafety;

/// Extracts a zip with traversal/absolute/symlink guards. Excluded path prefixes
/// (for example `META-INF/`) are skipped. Returns the number of files written.
pub fn extract_zip(archive: &Path, destination: &Path, exclude: &[String]) -> Result<usize> {
    let file = std::fs::File::open(archive)?;
    let mut zip = zip::ZipArchive::new(file)?;
    std::fs::create_dir_all(destination)?;
    let mut written = 0usize;
    for index in 0..zip.len() {
        let mut entry = zip.by_index(index)?;
        let name = entry.name().to_string();
        if name.ends_with('/') {
            continue;
        }
        if entry.is_dir() {
            continue;
        }
        #[cfg(unix)]
        {
            if let Some(mode) = entry.unix_mode() {
                if mode & 0o170000 == 0o120000 {
                    return Err(Error::UnsafePath(format!(
                        "symlink entry in archive: {name}"
                    )));
                }
            }
        }
        if exclude.iter().any(|prefix| name.starts_with(prefix)) {
            continue;
        }
        let relative = PathSafety::validate_archive_entry(&name)?;
        let target = PathSafety::safe_join(destination, &relative.to_string_lossy())?;
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut output = std::fs::File::create(&target)?;
        std::io::copy(&mut entry, &mut output)?;
        written += 1;
    }
    Ok(written)
}

/// Reads a single entry into memory with a hard size ceiling.
pub fn read_entry(archive: &Path, name: &str, max_bytes: u64) -> Result<Vec<u8>> {
    let file = std::fs::File::open(archive)?;
    let mut zip = zip::ZipArchive::new(file)?;
    let mut entry = zip.by_name(name)?;
    if entry.size() > max_bytes {
        return Err(Error::InvalidMetadata(format!(
            "archive entry {name} exceeds {max_bytes} bytes"
        )));
    }
    let mut buffer = Vec::new();
    entry.read_to_end(&mut buffer)?;
    Ok(buffer)
}

/// Enumerates entry names without extracting (used by mrpack source tracing).
pub fn list_entries(archive: &Path) -> Result<Vec<String>> {
    let file = std::fs::File::open(archive)?;
    let mut zip = zip::ZipArchive::new(file)?;
    let mut names = Vec::new();
    for index in 0..zip.len() {
        let entry = zip.by_index(index)?;
        names.push(entry.name().to_string());
    }
    Ok(names)
}
