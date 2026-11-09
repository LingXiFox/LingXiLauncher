use std::collections::BTreeMap;

use crate::error::{Error, Result};
use crate::models::launch::REDACTION_PLACEHOLDER;
use crate::models::version::ArgumentEntry;
use crate::platform::PlatformContext;

use super::rules::is_allowed;

/// Expands structured argument entries into a real argv.
///
/// Conditional entries whose rules do not match are skipped entirely (their
/// placeholders are never expanded). Every value stays a separate argument.
pub fn expand(
    entries: &[ArgumentEntry],
    platform: &PlatformContext,
    variables: &BTreeMap<String, String>,
    sensitive_keys: &[&str],
) -> Result<Vec<String>> {
    let mut out = Vec::new();
    for entry in entries {
        match entry {
            ArgumentEntry::Plain(value) => out.push(substitute(value, variables, sensitive_keys)?),
            ArgumentEntry::Conditional { rules, values } => {
                if is_allowed(rules, platform)? {
                    for value in values {
                        out.push(substitute(value, variables, sensitive_keys)?);
                    }
                }
            }
        }
    }
    Ok(out)
}

pub fn substitute(
    template: &str,
    variables: &BTreeMap<String, String>,
    sensitive_keys: &[&str],
) -> Result<String> {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    while let Some(start) = rest.find("${") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        let Some(end) = after.find('}') else {
            return Err(Error::InvalidMetadata(format!(
                "unterminated placeholder in '{template}'"
            )));
        };
        let name = &after[..end];
        if name.is_empty() {
            return Err(Error::InvalidMetadata(format!(
                "empty placeholder in '{template}'"
            )));
        }
        let Some(value) = variables.get(name) else {
            return Err(Error::InvalidMetadata(format!(
                "unknown placeholder '${{{name}}}'"
            )));
        };
        if sensitive_keys.contains(&name) {
            out.push_str(REDACTION_PLACEHOLDER);
        } else {
            out.push_str(value);
        }
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform::{Architecture, OsName};

    fn platform() -> PlatformContext {
        PlatformContext {
            os: OsName::Osx,
            architecture: Architecture::Arm64,
            host_architecture: Architecture::Arm64,
            os_version: "14.0".into(),
            features: BTreeMap::new(),
        }
    }

    #[test]
    fn substitutes_and_redacts() {
        let mut vars = BTreeMap::new();
        vars.insert("version_name".to_string(), "1.21".to_string());
        vars.insert("auth_access_token".to_string(), "secret".to_string());
        let out = substitute(
            "--version ${version_name} ${auth_access_token}",
            &vars,
            &["auth_access_token"],
        )
        .unwrap();
        assert_eq!(out, "--version 1.21 <redacted>");
        assert!(substitute("${nope}", &vars, &[]).is_err());
        assert!(substitute("${broken", &vars, &[]).is_err());
    }

    #[test]
    fn expansion_keeps_argument_boundaries() {
        let entries = vec![
            ArgumentEntry::Plain("--x".into()),
            ArgumentEntry::Plain("${a} b".into()),
        ];
        let mut vars = BTreeMap::new();
        vars.insert("a".into(), "1".into());
        let argv = expand(&entries, &platform(), &vars, &[]).unwrap();
        assert_eq!(argv, vec!["--x", "1 b"]);
    }
}
