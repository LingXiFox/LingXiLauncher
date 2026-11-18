use std::path::{Path, PathBuf};

use crate::error::Result;

use super::super::hashing::{sha1_file, verify_file};

/// Content addressed cache shared by every version and instance.
///
/// Layout: `<root>/<sha1[0..2]>/<sha1>`, mirroring the Mojang asset layout so
/// the same blob is never stored twice. Entries are written through a temporary
/// file and renamed, so a partially written object can never be observed.
pub struct ContentCache {
    root: PathBuf,
}

impl ContentCache {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn object_path(&self, sha1: &str) -> PathBuf {
        let lower = sha1.to_ascii_lowercase();
        let prefix = lower.get(..2).unwrap_or("xx");
        self.root.join(prefix).join(&lower)
    }

    /// Returns the cached object when it is present and still matches the hash.
    /// A corrupt or truncated entry is deleted so the next run re-downloads it.
    pub fn lookup(&self, sha1: &str, size: Option<u64>) -> Option<PathBuf> {
        let path = self.object_path(sha1);
        if !path.is_file() {
            return None;
        }
        match verify_file(&path, Some(sha1), size) {
            Ok(true) => Some(path),
            _ => {
                let _ = std::fs::remove_file(&path);
                None
            }
        }
    }

    /// Copies or links `source` into the cache. Returns the cached path.
    pub fn store(&self, sha1: &str, source: &Path) -> Result<PathBuf> {
        let destination = self.object_path(sha1);
        if destination.is_file() && verify_file(&destination, Some(sha1), None).unwrap_or(false) {
            return Ok(destination);
        }
        if let Some(parent) = destination.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let temp = destination.with_extension("cache-part");
        let _ = std::fs::remove_file(&temp);
        // Hard links keep the disk cost at zero when both paths are on the same
        // volume; the copy fallback covers caches on a different drive.
        if std::fs::hard_link(source, &temp).is_err() {
            std::fs::copy(source, &temp)?;
        }
        std::fs::rename(&temp, &destination)?;
        Ok(destination)
    }

    /// Repairs the cache entry for `sha1` from a verified file on disk.
    pub fn repair_from(&self, sha1: &str, source: &Path) -> Result<bool> {
        if !source.is_file() {
            return Ok(false);
        }
        let verified = verify_file(source, Some(sha1), None).unwrap_or(false);
        if !verified {
            return Ok(false);
        }
        self.store(sha1, source)?;
        Ok(true)
    }

    /// Drops entries that no longer match their name. Used by "verify" flows.
    pub fn sweep(&self) -> Result<usize> {
        let mut removed = 0usize;
        let Ok(entries) = std::fs::read_dir(&self.root) else {
            return Ok(0);
        };
        for bucket in entries.flatten() {
            let Ok(files) = std::fs::read_dir(bucket.path()) else {
                continue;
            };
            for file in files.flatten() {
                let path = file.path();
                let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                    continue;
                };
                let good = sha1_file(&path)
                    .map(|actual| actual.eq_ignore_ascii_case(name))
                    .unwrap_or(false);
                if !good && std::fs::remove_file(&path).is_ok() {
                    removed += 1;
                }
            }
        }
        Ok(removed)
    }

    /// Places a cached object at `destination` (hard link when possible).
    pub fn place(&self, object: &Path, destination: &Path) -> Result<()> {
        if let Some(parent) = destination.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let _ = std::fs::remove_file(destination);
        if std::fs::hard_link(object, destination).is_err() {
            std::fs::copy(object, destination)?;
        }
        Ok(())
    }
}
