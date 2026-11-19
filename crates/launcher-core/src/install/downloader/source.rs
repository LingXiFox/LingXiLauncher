use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

/// A single host rewrite rule used by a built-in mirror.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostRewrite {
    /// Official host this rule applies to, e.g. `piston-meta.mojang.com`.
    pub host: String,
    /// Mirror base URL, e.g. `https://bmclapi2.bangbang93.com`.
    pub base: String,
    /// Optional path prefix prepended to the official path.
    #[serde(default)]
    pub prefix: Option<String>,
}

/// A trusted mirror shipped with the launcher (no external config required).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuiltinMirror {
    pub id: String,
    pub display_name: String,
    pub rules: Vec<HostRewrite>,
}

fn rule(host: &str, base: &str, prefix: Option<&str>) -> HostRewrite {
    HostRewrite {
        host: host.to_string(),
        base: base.to_string(),
        prefix: prefix.map(|p| p.to_string()),
    }
}

/// BMCLAPI: the community mirror operated by bangbang93, the de-facto standard
/// fallback for mainland China. It mirrors piston-meta, piston-data,
/// resources.download.minecraft.net and libraries.minecraft.net.
pub fn bmclapi() -> BuiltinMirror {
    BuiltinMirror {
        id: "bmclapi".to_string(),
        display_name: "BMCLAPI".to_string(),
        rules: vec![
            rule(
                "piston-meta.mojang.com",
                "https://bmclapi2.bangbang93.com",
                None,
            ),
            rule(
                "piston-data.mojang.com",
                "https://bmclapi2.bangbang93.com",
                None,
            ),
            rule(
                "launchermeta.mojang.com",
                "https://bmclapi2.bangbang93.com",
                None,
            ),
            rule(
                "launcher.mojang.com",
                "https://bmclapi2.bangbang93.com",
                None,
            ),
            rule(
                "resources.download.minecraft.net",
                "https://bmclapi2.bangbang93.com",
                Some("/assets"),
            ),
            rule(
                "libraries.minecraft.net",
                "https://bmclapi2.bangbang93.com",
                Some("/maven"),
            ),
        ],
    }
}

/// All mirrors the launcher knows about out of the box.
pub fn builtin_mirrors() -> Vec<BuiltinMirror> {
    vec![bmclapi()]
}

pub fn builtin_mirror(id: &str) -> Option<BuiltinMirror> {
    builtin_mirrors().into_iter().find(|m| m.id == id)
}

/// Rewrites an official URL onto a mirror, preserving the path and query.
pub fn rewrite_url(mirror: &BuiltinMirror, official: &str) -> Option<String> {
    let parsed = url::Url::parse(official).ok()?;
    let host = parsed.host_str()?;
    let rule = mirror
        .rules
        .iter()
        .find(|rule| rule.host.eq_ignore_ascii_case(host))?;
    let mut out = rule.base.trim_end_matches('/').to_string();
    if let Some(prefix) = &rule.prefix {
        out.push_str(prefix.trim_end_matches('/'));
    }
    out.push_str(parsed.path());
    if let Some(query) = parsed.query() {
        out.push('?');
        out.push_str(query);
    }
    Some(out)
}

/// Health bookkeeping used to rank sources and to trip the circuit breaker.
#[derive(Debug, Default, Clone)]
struct Health {
    consecutive_failures: u32,
    successes: u64,
    failures: u64,
    latency_ms: f64,
    open_until: Option<Instant>,
    probing: bool,
    generation: u64,
}

pub struct HealthRegistry {
    inner: Mutex<HashMap<String, Health>>,
    failure_threshold: u32,
    base_cooldown: Duration,
}

pub(super) struct Admission {
    registry: Arc<HealthRegistry>,
    source: String,
    generation: u64,
    probe: bool,
}

impl Admission {
    pub(super) fn is_probe(&self) -> bool {
        self.probe
    }

    pub(super) fn success(self, latency: Duration) {
        let mut inner = self.registry.inner.lock().expect("health registry lock");
        let health = inner.get_mut(&self.source).expect("admitted source");
        if health.generation == self.generation {
            if self.probe {
                // Rank a recovered source on fresh observations, not old outages.
                health.failures = 0;
                health.successes = 0;
                health.latency_ms = 0.0;
            }
            HealthRegistry::success(health, latency);
        }
    }

    pub(super) fn failure(self) {
        let mut inner = self.registry.inner.lock().expect("health registry lock");
        let health = inner.get_mut(&self.source).expect("admitted source");
        if health.generation == self.generation {
            self.registry.failure(health);
        }
    }

    pub(super) fn defer(self) {
        if self.probe {
            let mut inner = self.registry.inner.lock().expect("health registry lock");
            let health = inner.get_mut(&self.source).expect("admitted source");
            if health.generation == self.generation {
                health.open_until = Some(Instant::now() + self.registry.base_cooldown);
            }
        }
    }
}

impl Drop for Admission {
    fn drop(&mut self) {
        if self.probe {
            let mut inner = self.registry.inner.lock().expect("health registry lock");
            if let Some(health) = inner.get_mut(&self.source) {
                health.probing = false;
            }
        }
    }
}

impl HealthRegistry {
    pub fn new(failure_threshold: u32, base_cooldown: Duration) -> Self {
        Self {
            inner: Mutex::new(HashMap::new()),
            failure_threshold: failure_threshold.max(1),
            base_cooldown,
        }
    }

    /// True while the source is not in an open circuit.
    pub fn is_available(&self, source: &str) -> bool {
        let guard = self.inner.lock().expect("health registry lock");
        guard.get(source).is_none_or(|health| {
            !health.probing
                && health
                    .open_until
                    .is_none_or(|until| Instant::now() >= until)
        })
    }

    pub(super) fn admit(self: &Arc<Self>, source: &str) -> Option<Admission> {
        let mut inner = self.inner.lock().expect("health registry lock");
        let health = inner.entry(source.to_owned()).or_default();
        let probe = health.open_until.is_some();
        if health.probing
            || health
                .open_until
                .is_some_and(|until| Instant::now() < until)
        {
            return None;
        }
        health.probing = probe;
        Some(Admission {
            registry: Arc::clone(self),
            source: source.to_owned(),
            generation: health.generation,
            probe,
        })
    }

    pub(super) fn priority(&self, source: &str) -> u32 {
        let guard = self.inner.lock().expect("health registry lock");
        match guard.get(source) {
            Some(health) if health.probing => 0,
            Some(health)
                if health
                    .open_until
                    .is_some_and(|until| Instant::now() >= until) =>
            {
                u32::MAX
            }
            Some(health) if health.open_until.is_some() => 0,
            health => (Self::health_score(health) * 100.0) as u32 + 1,
        }
    }

    pub fn record_success(&self, source: &str, latency: Duration) {
        let mut guard = self.inner.lock().expect("health registry lock");
        let health = guard.entry(source.to_string()).or_default();
        Self::success(health, latency);
    }

    fn success(health: &mut Health, latency: Duration) {
        health.successes += 1;
        health.consecutive_failures = 0;
        health.open_until = None;
        let sample = latency.as_secs_f64() * 1000.0;
        health.latency_ms = if health.latency_ms <= 0.0 {
            sample
        } else {
            health.latency_ms * 0.7 + sample * 0.3
        };
    }

    pub fn record_failure(&self, source: &str) {
        let mut guard = self.inner.lock().expect("health registry lock");
        let health = guard.entry(source.to_string()).or_default();
        self.failure(health);
    }

    fn failure(&self, health: &mut Health) {
        health.failures += 1;
        health.consecutive_failures += 1;
        if health.consecutive_failures >= self.failure_threshold {
            let exponent = (health.consecutive_failures - self.failure_threshold).min(4);
            let cooldown = self.base_cooldown * 2u32.pow(exponent);
            health.open_until = Some(Instant::now() + cooldown);
            health.generation += 1;
        }
    }

    /// Higher is better. Unknown sources start in the middle of the pack so the
    /// launcher keeps probing them instead of freezing on stale data.
    pub fn score(&self, source: &str) -> f64 {
        let guard = self.inner.lock().expect("health registry lock");
        Self::health_score(guard.get(source))
    }

    fn health_score(health: Option<&Health>) -> f64 {
        let Some(health) = health else {
            return 50.0;
        };
        let total = health.successes + health.failures;
        if total == 0 {
            return 50.0;
        }
        let success_rate = health.successes as f64 / total as f64;
        let latency_penalty = (health.latency_ms / 100.0).min(30.0);
        (success_rate * 100.0 - latency_penalty).clamp(0.0, 100.0)
    }

    pub fn ordered(&self, sources: &[String]) -> Vec<String> {
        let mut list = sources.to_vec();
        list.sort_by(|a, b| {
            self.score(b)
                .partial_cmp(&self.score(a))
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        list
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bmclapi_rewrites_every_official_host() {
        let mirror = bmclapi();
        let cases = [
            (
                "https://piston-meta.mojang.com/v1/packages/abc/1.21.4.json",
                "https://bmclapi2.bangbang93.com/v1/packages/abc/1.21.4.json",
            ),
            (
                "https://resources.download.minecraft.net/ab/abcdef",
                "https://bmclapi2.bangbang93.com/assets/ab/abcdef",
            ),
            (
                "https://libraries.minecraft.net/org/yaml/snakeyaml/1.33/snakeyaml-1.33.jar",
                "https://bmclapi2.bangbang93.com/maven/org/yaml/snakeyaml/1.33/snakeyaml-1.33.jar",
            ),
        ];
        for (official, expected) in cases {
            assert_eq!(rewrite_url(&mirror, official).as_deref(), Some(expected));
        }
    }

    #[test]
    fn unknown_hosts_are_left_alone() {
        let mirror = bmclapi();
        assert!(rewrite_url(&mirror, "https://example.com/file.bin").is_none());
    }

    #[test]
    fn breaker_opens_after_repeated_failures_and_recovers() {
        let registry = HealthRegistry::new(2, Duration::from_millis(30));
        assert!(registry.is_available("official"));
        registry.record_failure("official");
        assert!(registry.is_available("official"));
        registry.record_failure("official");
        assert!(!registry.is_available("official"));
        std::thread::sleep(Duration::from_millis(40));
        assert!(registry.is_available("official"));
        registry.record_success("official", Duration::from_millis(5));
        // The recovered source still ranks below a pristine one but above a
        // source that never succeeded at all.
        registry.record_failure("broken");
        registry.record_failure("broken");
        registry.record_failure("broken");
        assert!(registry.score("official") > registry.score("broken"));
    }

    #[test]
    fn healthy_sources_rank_above_failing_ones() {
        let registry = HealthRegistry::new(5, Duration::from_secs(1));
        for _ in 0..4 {
            registry.record_success("official", Duration::from_millis(20));
            registry.record_failure("mirror");
        }
        let ordered = registry.ordered(&["mirror".to_string(), "official".to_string()]);
        assert_eq!(ordered, vec!["official".to_string(), "mirror".to_string()]);
    }

    #[test]
    fn only_one_due_probe_and_stale_success_cannot_close_a_circuit() {
        let registry = Arc::new(HealthRegistry::new(1, Duration::from_secs(30)));
        let stale = registry.admit("mirror").unwrap();
        registry.admit("mirror").unwrap().failure();
        stale.success(Duration::ZERO);
        assert!(registry.admit("mirror").is_none());

        registry
            .inner
            .lock()
            .unwrap()
            .get_mut("mirror")
            .unwrap()
            .open_until = Some(Instant::now());
        assert!(registry.priority("mirror") > registry.priority("other"));
        let probe = registry.admit("mirror").unwrap();
        assert!(probe.is_probe());
        assert!(registry.admit("mirror").is_none());
        drop(probe); // Cancellation must not consume the recovery slot.
        registry
            .admit("mirror")
            .unwrap()
            .success(Duration::from_millis(5));
        assert!(!registry.admit("mirror").unwrap().is_probe());
    }
}
