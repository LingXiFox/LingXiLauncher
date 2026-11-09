use crate::error::{Error, Result};
use crate::models::version::{Rule, RuleAction};
use crate::platform::{Architecture, OsName, PlatformContext};

/// Evaluates Mojang rule lists. An empty list allows; otherwise the last matching
/// rule wins, starting from `false`.
pub fn is_allowed(rules: &[Rule], platform: &PlatformContext) -> Result<bool> {
    if rules.is_empty() {
        return Ok(true);
    }
    let mut allowed = false;
    for rule in rules {
        if rule_matches(rule, platform)? {
            allowed = rule.action == RuleAction::Allow;
        }
    }
    Ok(allowed)
}

fn rule_matches(rule: &Rule, platform: &PlatformContext) -> Result<bool> {
    if let Some(os) = &rule.os {
        if let Some(name) = &os.name {
            let expected = OsName::from_token(name)?;
            if expected != platform.os {
                return Ok(false);
            }
        }
        if let Some(arch) = &os.arch {
            let expected = Architecture::from_token(arch)?;
            if expected != platform.architecture {
                return Ok(false);
            }
        }
        if let Some(pattern) = &os.version {
            let regex = regex::Regex::new(pattern)
                .map_err(|e| Error::InvalidMetadata(format!("invalid OS version regex '{pattern}': {e}")))?;
            if !regex.is_match(&platform.os_version) {
                return Ok(false);
            }
        }
        if let Some(range) = &os.version_range {
            if let Some(min) = &range.min {
                if compare_versions(&platform.os_version, min)? < 0 {
                    return Ok(false);
                }
            }
            if let Some(max) = &range.max {
                if compare_versions(&platform.os_version, max)? > 0 {
                    return Ok(false);
                }
            }
        }
    }
    if let Some(features) = &rule.features {
        for (name, expected) in features {
            if platform.feature(name) != *expected {
                return Ok(false);
            }
        }
    }
    Ok(true)
}

/// Numeric dotted version comparison; the shorter side is zero padded.
pub fn compare_versions(lhs: &str, rhs: &str) -> Result<i32> {
    let left = split_version(lhs)?;
    let right = split_version(rhs)?;
    let len = left.len().max(right.len());
    for index in 0..len {
        let a = *left.get(index).unwrap_or(&0);
        let b = *right.get(index).unwrap_or(&0);
        if a != b {
            return Ok(if a < b { -1 } else { 1 });
        }
    }
    Ok(0)
}

fn split_version(value: &str) -> Result<Vec<u64>> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Ok(vec![0]);
    }
    trimmed
        .split('.')
        .map(|part| {
            part.parse::<u64>()
                .map_err(|_| Error::InvalidMetadata(format!("non-numeric version component in '{value}'")))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::version::RuleOs;
    use std::collections::BTreeMap;

    fn platform() -> PlatformContext {
        PlatformContext {
            os: OsName::Osx,
            architecture: Architecture::Arm64,
            host_architecture: Architecture::Arm64,
            os_version: "14.5".into(),
            features: BTreeMap::new(),
        }
    }

    #[test]
    fn empty_rules_allow() {
        assert!(is_allowed(&[], &platform()).unwrap());
    }

    #[test]
    fn last_match_wins() {
        let rules = vec![
            Rule { action: RuleAction::Allow, os: None, features: None },
            Rule { action: RuleAction::Disallow, os: Some(RuleOs { name: Some("osx".into()), ..Default::default() }), features: None },
        ];
        assert!(!is_allowed(&rules, &platform()).unwrap());
    }

    #[test]
    fn version_compare() {
        assert_eq!(compare_versions("14.5", "14.5.0").unwrap(), 0);
        assert_eq!(compare_versions("10.15", "11").unwrap(), -1);
    }
}
