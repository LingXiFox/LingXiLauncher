use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize};

use crate::error::{Error, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VersionType {
    Release,
    Snapshot,
    OldBeta,
    OldAlpha,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct LatestVersions {
    pub release: String,
    pub snapshot: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct VersionManifest {
    pub latest: LatestVersions,
    pub versions: Vec<VersionSummary>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct VersionSummary {
    pub id: String,
    #[serde(rename = "type")]
    pub version_type: VersionType,
    pub url: String,
    #[serde(default)]
    pub sha1: String,
    #[serde(default, rename = "releaseTime")]
    pub release_time: Option<DateTime<Utc>>,
    #[serde(default)]
    pub time: Option<DateTime<Utc>>,
    #[serde(default, rename = "complianceLevel")]
    pub compliance_level: Option<u32>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct VersionMetadata {
    pub id: String,
    #[serde(rename = "type", default)]
    pub version_type: Option<VersionType>,
    #[serde(default, rename = "mainClass")]
    pub main_class: Option<String>,
    #[serde(default)]
    pub assets: Option<String>,
    #[serde(default, rename = "assetIndex")]
    pub asset_index: Option<AssetIndex>,
    #[serde(default)]
    pub downloads: Option<Downloads>,
    #[serde(default, rename = "javaVersion")]
    pub java_version: Option<JavaVersion>,
    #[serde(default)]
    pub libraries: Vec<Library>,
    #[serde(default)]
    pub arguments: Option<Arguments>,
    #[serde(default, rename = "minecraftArguments")]
    pub minecraft_arguments: Option<String>,
    #[serde(default)]
    pub logging: Option<Logging>,
    #[serde(default, rename = "inheritsFrom")]
    pub inherits_from: Option<String>,
    #[serde(default, rename = "default-user-jvm")]
    pub default_user_jvm: Option<Vec<ArgumentEntry>>,
    #[serde(default, rename = "minimumLauncherVersion")]
    pub minimum_launcher_version: Option<u32>,
    #[serde(default, rename = "releaseTime")]
    pub release_time: Option<DateTime<Utc>>,
    #[serde(default, rename = "complianceLevel")]
    pub compliance_level: Option<u32>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct AssetIndex {
    pub id: String,
    #[serde(default)]
    pub sha1: String,
    #[serde(default)]
    pub size: u64,
    #[serde(default, rename = "totalSize")]
    pub total_size: u64,
    pub url: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct Downloads {
    #[serde(default)]
    pub client: Option<Artifact>,
    #[serde(default)]
    pub server: Option<Artifact>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct Artifact {
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default)]
    pub sha1: Option<String>,
    #[serde(default)]
    pub size: Option<u64>,
    #[serde(default)]
    pub id: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct JavaVersion {
    #[serde(default)]
    pub component: String,
    #[serde(rename = "majorVersion")]
    pub major_version: u32,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct Library {
    pub name: String,
    #[serde(default)]
    pub rules: Vec<Rule>,
    #[serde(default)]
    pub downloads: Option<LibraryDownloads>,
    #[serde(default)]
    pub natives: Option<BTreeMap<String, String>>,
    #[serde(default)]
    pub extract: Option<Extract>,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub sha1: Option<String>,
    #[serde(default)]
    pub size: Option<u64>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct LibraryDownloads {
    #[serde(default)]
    pub artifact: Option<Artifact>,
    #[serde(default)]
    pub classifiers: Option<BTreeMap<String, Artifact>>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct Extract {
    #[serde(default)]
    pub exclude: Vec<String>,
}

#[derive(Debug, Clone)]
pub enum ArgumentEntry {
    Plain(String),
    Conditional { rules: Vec<Rule>, values: Vec<String> },
}

impl Serialize for ArgumentEntry {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        match self {
            ArgumentEntry::Plain(value) => serializer.serialize_str(value),
            ArgumentEntry::Conditional { rules, values } => {
                let mut map = serializer.serialize_map(Some(2))?;
                map.serialize_entry("rules", rules)?;
                if values.len() == 1 {
                    map.serialize_entry("value", &values[0])?;
                } else {
                    map.serialize_entry("value", values)?;
                }
                map.end()
            }
        }
    }
}

impl<'de> Deserialize<'de> for ArgumentEntry {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Raw {
            Plain(String),
            Complex {
                #[serde(default)]
                rules: Vec<Rule>,
                value: StringOrList,
            },
        }
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum StringOrList {
            One(String),
            Many(Vec<String>),
        }
        match Raw::deserialize(deserializer)? {
            Raw::Plain(value) => Ok(ArgumentEntry::Plain(value)),
            Raw::Complex { rules, value } => Ok(ArgumentEntry::Conditional {
                rules,
                values: match value {
                    StringOrList::One(v) => vec![v],
                    StringOrList::Many(v) => v,
                },
            }),
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct Arguments {
    #[serde(default)]
    pub game: Vec<ArgumentEntry>,
    #[serde(default)]
    pub jvm: Vec<ArgumentEntry>,
    #[serde(default, rename = "default-user-jvm")]
    pub default_user_jvm: Vec<ArgumentEntry>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Logging {
    #[serde(default)]
    pub client: Option<LoggingClient>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct LoggingClient {
    pub argument: String,
    pub file: LoggingFile,
    #[serde(rename = "type")]
    pub log_type: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct LoggingFile {
    pub id: String,
    pub url: String,
    pub path: String,
    #[serde(default)]
    pub sha1: String,
    #[serde(default)]
    pub size: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum RuleAction {
    Allow,
    Disallow,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Rule {
    pub action: RuleAction,
    #[serde(default)]
    pub os: Option<RuleOs>,
    #[serde(default)]
    pub features: Option<BTreeMap<String, bool>>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RuleOs {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub version: Option<String>,
    #[serde(default)]
    pub arch: Option<String>,
    #[serde(default, rename = "versionRange")]
    pub version_range: Option<VersionRange>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct VersionRange {
    #[serde(default)]
    pub min: Option<String>,
    #[serde(default)]
    pub max: Option<String>,
}

/// Maven coordinates with a normalized relative path used for library files.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MavenCoordinates {
    pub group: String,
    pub artifact: String,
    pub version: String,
    pub classifier: Option<String>,
}

impl MavenCoordinates {
    pub fn parse(name: &str) -> Result<Self> {
        let parts: Vec<&str> = name.split(':').collect();
        if parts.len() < 3 || parts.len() > 4 {
            return Err(Error::InvalidMetadata(format!("invalid maven coordinate {name}")));
        }
        if parts.iter().any(|p| p.is_empty()) {
            return Err(Error::InvalidMetadata(format!("invalid maven coordinate {name}")));
        }
        Ok(Self {
            group: parts[0].to_string(),
            artifact: parts[1].to_string(),
            version: parts[2].to_string(),
            classifier: parts.get(3).map(|s| s.to_string()),
        })
    }

    pub fn relative_path(&self) -> String {
        let file = match &self.classifier {
            Some(classifier) => format!("{}-{}-{}.jar", self.artifact, self.version, classifier),
            None => format!("{}-{}.jar", self.artifact, self.version),
        };
        format!("{}/{}/{}/{}", self.group.replace('.', "/"), self.artifact, self.version, file)
    }
}

/// The effective artifact of a library after applying rules and Maven fallbacks.
#[derive(Debug, Clone)]
pub struct EffectiveArtifact {
    pub url: String,
    pub relative_path: String,
    pub sha1: Option<String>,
    pub size: Option<u64>,
}

impl Library {
    pub fn maven(&self) -> Result<MavenCoordinates> {
        MavenCoordinates::parse(&self.name)
    }

    /// `downloads.artifact` wins; otherwise the Maven URL is rebuilt from
    /// `url` (or the default Mojang library host) plus coordinates.
    pub fn effective_artifact(&self) -> Result<Option<EffectiveArtifact>> {
        if let Some(artifact) = self.downloads.as_ref().and_then(|d| d.artifact.as_ref()) {
            if artifact.url.is_empty() {
                return Ok(None);
            }
            let relative = artifact
                .path
                .clone()
                .unwrap_or_else(|| self.maven().map(|m| m.relative_path()).unwrap_or_default());
            return Ok(Some(EffectiveArtifact {
                url: artifact.url.clone(),
                relative_path: relative,
                sha1: artifact.sha1.clone(),
                size: artifact.size,
            }));
        }
        let maven = self.maven()?;
        let base = self.url.clone().unwrap_or_else(|| "https://libraries.minecraft.net/".to_string());
        let base = if base.ends_with('/') { base } else { format!("{base}/") };
        Ok(Some(EffectiveArtifact {
            url: format!("{base}{}", maven.relative_path()),
            relative_path: maven.relative_path(),
            sha1: self.sha1.clone(),
            size: self.size,
        }))
    }

    pub fn natives_classifier(&self, os: &str) -> Option<String> {
        let natives = self.natives.as_ref()?;
        let key = match os {
            "osx" => "osx",
            "windows" => "windows",
            _ => "linux",
        };
        natives.get(key).cloned()
    }
}
