use base64::Engine;
use rand::RngCore;
use sha2::{Digest, Sha256};

use launcher_core::Result;

/// A PKCE verifier/challenge pair plus the OAuth state value.
#[derive(Debug, Clone)]
pub struct Pkce {
    pub verifier: String,
    pub challenge: String,
    pub state: String,
}

impl Pkce {
    pub fn generate() -> Result<Self> {
        let verifier = random_url_safe(32);
        let challenge = Self::challenge_for(&verifier);
        Ok(Self { verifier, challenge, state: random_url_safe(32) })
    }

    pub fn challenge_for(verifier: &str) -> String {
        let digest = Sha256::digest(verifier.as_bytes());
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(digest)
    }
}

/// `byte_count` random bytes encoded as URL-safe base64 without padding.
pub fn random_url_safe(byte_count: usize) -> String {
    let mut bytes = vec![0u8; byte_count];
    rand::thread_rng().fill_bytes(&mut bytes);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn challenge_matches_rfc7636_example() {
        assert_eq!(
            Pkce::challenge_for("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
    }

    #[test]
    fn generated_values_are_url_safe() {
        let pkce = Pkce::generate().unwrap();
        assert!(pkce.verifier.len() >= 43);
        assert!(pkce.verifier.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'));
        assert_eq!(pkce.state.len(), 43);
    }
}
