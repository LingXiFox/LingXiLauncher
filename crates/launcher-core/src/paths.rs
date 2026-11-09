use std::path::{Component, Path, PathBuf};

use crate::error::{Error, Result};

/// Guards every filesystem path that is derived from untrusted input
/// (version ids, instance names, archive entries, user supplied roots).
pub struct PathSafety;

impl PathSafety {
    pub fn validate_component(value: &str) -> Result<&str> {
        if value.is_empty() {
            return Err(Error::UnsafePath("empty path component".into()));
        }
        if value == "." || value == ".." {
            return Err(Error::UnsafePath(format!("reserved component {value}")));
        }
        if value.contains(['/', '\\', '\0', '\n', '\r']) || value.chars().any(|c| c.is_control()) {
            return Err(Error::UnsafePath(format!("illegal component {value}")));
        }
        Ok(value)
    }

    /// Joins `relative` onto `base`, rejecting absolute paths, backslashes,
    /// control characters, `.`/`..` and anything escaping `base`.
    pub fn safe_join(base: &Path, relative: &str) -> Result<PathBuf> {
        if relative.is_empty() {
            return Err(Error::UnsafePath("empty relative path".into()));
        }
        if relative.starts_with('/') || relative.starts_with('\\') || relative.contains('\\') {
            return Err(Error::UnsafePath(format!("absolute or backslash path {relative}")));
        }
        if relative.contains('\0') || relative.chars().any(|c| c.is_control()) {
            return Err(Error::UnsafePath(format!("control characters in {relative}")));
        }
        let mut out = base.to_path_buf();
        for part in relative.split('/') {
            if part.is_empty() || part == "." || part == ".." {
                return Err(Error::UnsafePath(format!("illegal segment in {relative}")));
            }
            out.push(part);
        }
        let normalized = normalize(&out);
        let base_norm = normalize(base);
        if !normalized.starts_with(&base_norm) {
            return Err(Error::UnsafePath(format!("escapes base: {relative}")));
        }
        Ok(normalized)
    }

    /// Validates a zip archive entry and returns a relative safe path.
    pub fn validate_archive_entry(name: &str) -> Result<PathBuf> {
        if name.is_empty() {
            return Err(Error::UnsafePath("empty archive entry".into()));
        }
        if name.starts_with('/') || name.contains('\\') {
            return Err(Error::UnsafePath(format!("absolute archive entry {name}")));
        }
        if name.contains('\0') || name.chars().any(|c| c.is_control()) {
            return Err(Error::UnsafePath(format!("control characters in {name}")));
        }
        if name.len() >= 2 && name.as_bytes()[1] == b':' {
            return Err(Error::UnsafePath(format!("drive letter in {name}")));
        }
        let mut out = PathBuf::new();
        for part in name.split('/') {
            if part.is_empty() || part == "." {
                continue;
            }
            if part == ".." {
                return Err(Error::UnsafePath(format!("traversal in {name}")));
            }
            out.push(part);
        }
        if out.as_os_str().is_empty() {
            return Err(Error::UnsafePath(format!("empty archive entry {name}")));
        }
        Ok(out)
    }
}

fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_traversal() {
        assert!(PathSafety::safe_join(Path::new("/tmp/base"), "../etc").is_err());
        assert!(PathSafety::safe_join(Path::new("/tmp/base"), "/etc/passwd").is_err());
        assert!(PathSafety::safe_join(Path::new("/tmp/base"), "a/../../b").is_err());
        assert!(PathSafety::safe_join(Path::new("/tmp/base"), "a/b").is_ok());
    }

    #[test]
    fn archive_entries() {
        assert!(PathSafety::validate_archive_entry("../../x").is_err());
        assert!(PathSafety::validate_archive_entry("C:/x").is_err());
        assert!(PathSafety::validate_archive_entry("mods/foo.jar").is_ok());
    }
}
