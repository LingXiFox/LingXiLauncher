use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::error::{Error, Result};

use super::super::hashing::{sha1_bytes, sha1_file, verify_file};

/// Content addressed cache shared by every version and instance.
///
/// Layout: `<root>/<sha1[0..2]>/<sha1>`, mirroring the Mojang asset layout so
/// the same blob is never stored twice. Entries are written through a temporary
/// file and renamed, so a partially written object can never be observed.
pub struct ContentCache {
    root: PathBuf,
}

// Keep an in-process sweep from unlinking an object that was just replaced.
static PUBLICATION: [Mutex<()>; 16] = [const { Mutex::new(()) }; 16];

fn publication(hash: &str) -> std::sync::MutexGuard<'static, ()> {
    PUBLICATION[hash
        .chars()
        .next()
        .and_then(|c| c.to_digit(16))
        .expect("valid SHA-1") as usize]
        .lock()
        .expect("cache publication lock")
}

pub(super) fn is_sha1(hash: &str) -> bool {
    hash.len() == 40 && hash.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// Copy to a private sibling and verify the exact bytes being published.
fn publish(
    source: &Path,
    destination: &Path,
    verify: impl FnOnce(&Path) -> Result<bool>,
) -> Result<bool> {
    publish_with(
        destination,
        |output| {
            io::copy(&mut std::fs::File::open(source)?, output)?;
            output.sync_data()?;
            Ok(())
        },
        verify,
    )
}

fn publish_with(
    destination: &Path,
    write: impl FnOnce(&mut std::fs::File) -> io::Result<()>,
    verify: impl FnOnce(&Path) -> Result<bool>,
) -> Result<bool> {
    let parent = destination
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    std::fs::create_dir_all(parent)?;
    let temp = parent.join(format!(".lingxi-cache-{}.part", uuid::Uuid::new_v4()));
    let mut output = std::fs::File::create_new(&temp)?;
    let result = (|| {
        write(&mut output)?;
        drop(output);
        if !verify(&temp)? {
            return Ok(false);
        }
        std::fs::rename(&temp, destination)?;
        Ok(true)
    })();
    if !matches!(result, Ok(true)) {
        let _ = std::fs::remove_file(&temp);
    }
    result
}

impl ContentCache {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn object_path(&self, sha1: &str) -> Option<PathBuf> {
        if !is_sha1(sha1) {
            return None;
        }
        let lower = sha1.to_ascii_lowercase();
        Some(self.root.join(&lower[..2]).join(&lower))
    }

    /// Returns the cached object when it is present and still matches the hash.
    /// Leave invalid entries in place until an atomic repair or explicit sweep.
    pub fn lookup(&self, sha1: &str, size: Option<u64>) -> Option<PathBuf> {
        let path = self.object_path(sha1)?;
        verify_file(&path, Some(sha1), size)
            .unwrap_or(false)
            .then_some(path)
    }

    /// Store an independent copy so writing to a game directory cannot mutate the cache.
    pub fn store(&self, sha1: &str, source: &Path) -> Result<PathBuf> {
        let destination = self
            .object_path(sha1)
            .ok_or_else(|| Error::InvalidMetadata("invalid cache SHA-1".into()))?;
        let _publication = publication(sha1);
        if verify_file(&destination, Some(sha1), None)? {
            return Ok(destination);
        }
        if !publish(source, &destination, |temp| {
            verify_file(temp, Some(sha1), None)
        })? {
            return Err(Error::InvalidMetadata(
                "cache source does not match its SHA-1".into(),
            ));
        }
        Ok(destination)
    }

    /// The buffer itself was SHA-checked; never copy from a mutable game file.
    pub(super) fn store_verified_bytes(&self, sha1: &str, bytes: &[u8]) -> Result<()> {
        let destination = self
            .object_path(sha1)
            .ok_or_else(|| Error::InvalidMetadata("invalid cache SHA-1".into()))?;
        let _publication = publication(sha1);
        publish_with(&destination, |output| output.write_all(bytes), |_| Ok(true))?;
        Ok(())
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
                if self.object_path(name).as_deref() != Some(&path) {
                    continue;
                }
                let _publication = publication(name);
                if sha1_file(&path).is_ok_and(|actual| !actual.eq_ignore_ascii_case(name))
                    && std::fs::remove_file(&path).is_ok()
                {
                    removed += 1;
                }
            }
        }
        Ok(removed)
    }

    /// Places a validated copy atomically without removing the previous file first.
    pub fn place(&self, object: &Path, destination: &Path) -> Result<()> {
        let hash = object
            .file_name()
            .and_then(|name| name.to_str())
            .filter(|name| self.object_path(name).as_deref() == Some(object))
            .ok_or_else(|| Error::InvalidMetadata("invalid cache object path".into()))?;
        if !self.materialize(hash, None, destination)? {
            return Err(Error::InvalidMetadata(
                "cache object is missing or corrupt".into(),
            ));
        }
        Ok(())
    }

    pub(super) fn materialize(
        &self,
        sha1: &str,
        size: Option<u64>,
        destination: &Path,
    ) -> Result<bool> {
        let Some(object) = self.object_path(sha1).filter(|path| path.is_file()) else {
            return Ok(false);
        };
        publish(&object, destination, |temp| {
            verify_file(temp, Some(sha1), size)
        })
    }

    pub(super) fn materialize_small(
        &self,
        sha1: &str,
        size: u64,
        destination: &Path,
    ) -> Result<bool> {
        use std::io::Read;

        let Some(object) = self.object_path(sha1) else {
            return Ok(false);
        };
        let mut bytes = Vec::new();
        std::fs::File::open(object)?
            .take(size + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() as u64 != size || !sha1_bytes(&bytes).eq_ignore_ascii_case(sha1) {
            return Ok(false);
        }
        publish_with(destination, |output| output.write_all(&bytes), |_| Ok(true))
    }
}
