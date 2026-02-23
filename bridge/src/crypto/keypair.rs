use p256::{
    ecdh::EphemeralSecret,
    elliptic_curve::sec1::{FromEncodedPoint, ToEncodedPoint},
    EncodedPoint, PublicKey,
};
use rand::rngs::OsRng;
use zeroize::Zeroizing;

use base64::Engine;

/// A P-256 (secp256r1) session keypair for one-time Diffie-Hellman key exchange.
///
/// Uses `EphemeralSecret` instead of `SecretKey` to enforce that private key
/// material cannot be serialized, persisted, or reused across sessions.
/// The secret is consumed on ECDH — after `derive_shared_secret()` is called,
/// the private key is gone from memory.
///
/// Uses the NIST P-256 curve to match iOS (Secure Enclave) and Android
/// (StrongBox) key types. Public keys are serialized in X9.63 uncompressed
/// format (0x04 || x || y, 65 bytes).
///
/// # Zeroization
///
/// `EphemeralSecret` wraps `ScalarPrimitive<C>` which implements `Drop` with
/// automatic zeroization of the scalar bytes. No manual `Zeroize` call is
/// needed — the secret key material is wiped from memory when consumed or
/// when this struct is dropped.
pub struct SessionKeyPair {
    /// Consumed on ECDH — `None` after `derive_shared_secret()`.
    secret: Option<EphemeralSecret>,
    /// Retained for pairing messages (survives ECDH).
    public: PublicKey,
}

impl SessionKeyPair {
    /// Generate a new random P-256 keypair using the OS CSPRNG.
    pub fn generate() -> Self {
        let secret = EphemeralSecret::random(&mut OsRng);
        let public = PublicKey::from(&secret);
        Self {
            secret: Some(secret),
            public,
        }
    }

    /// Return the public key in X9.63 uncompressed format as base64.
    ///
    /// The output is 65 bytes: 0x04 || x (32 bytes) || y (32 bytes).
    /// This format matches iOS `SecKeyCopyExternalRepresentation` output.
    pub fn public_key_base64(&self) -> String {
        let encoded = self.public.to_encoded_point(false);
        base64::engine::general_purpose::STANDARD.encode(encoded.as_bytes())
    }

    /// Return the raw X9.63 uncompressed public key bytes (65 bytes).
    ///
    /// Format: 0x04 || x (32 bytes) || y (32 bytes)
    pub fn public_key_bytes(&self) -> Vec<u8> {
        let encoded = self.public.to_encoded_point(false);
        encoded.as_bytes().to_vec()
    }

    /// Perform P-256 ECDH key agreement with a peer's public key,
    /// consuming the ephemeral secret. Can only be called once per keypair.
    ///
    /// The peer public key must be in X9.63 uncompressed format (65 bytes):
    /// 0x04 || x || y.
    ///
    /// Returns the raw 32-byte shared secret. This should be fed through a KDF
    /// (see `kdf::derive_aes_key`) before use as an encryption key.
    ///
    /// # Errors
    ///
    /// Returns `Err` if called more than once (ephemeral secret already consumed).
    pub fn derive_shared_secret(&mut self, peer_public_bytes: &[u8]) -> Result<Zeroizing<Vec<u8>>, String> {
        let secret = self
            .secret
            .take()
            .ok_or_else(|| "EphemeralSecret already consumed — ECDH can only be performed once".to_string())?;

        let peer_point = EncodedPoint::from_bytes(peer_public_bytes)
            .map_err(|e| format!("Invalid peer public key encoding: {}", e))?;

        let peer_public = Option::from(p256::PublicKey::from_encoded_point(&peer_point))
            .ok_or_else(|| "Peer public key is not a valid P-256 point".to_string())?;

        let shared_secret = secret.diffie_hellman(&peer_public);

        Ok(Zeroizing::new(shared_secret.raw_secret_bytes().to_vec()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_keypair() {
        let kp = SessionKeyPair::generate();
        let public = kp.public_key_bytes();
        // P-256 uncompressed public key should be 65 bytes starting with 0x04
        assert_eq!(public.len(), 65);
        assert_eq!(public[0], 0x04);
    }

    #[test]
    fn test_public_key_base64_roundtrip() {
        let kp = SessionKeyPair::generate();
        let b64 = kp.public_key_base64();
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(&b64)
            .unwrap();
        assert_eq!(decoded.len(), 65);
        assert_eq!(decoded, kp.public_key_bytes());
    }

    #[test]
    fn test_ecdh_shared_secret() {
        let mut alice = SessionKeyPair::generate();
        let mut bob = SessionKeyPair::generate();

        let alice_public = alice.public_key_bytes();
        let bob_public = bob.public_key_bytes();

        let shared_alice = alice.derive_shared_secret(&bob_public).unwrap();
        let shared_bob = bob.derive_shared_secret(&alice_public).unwrap();

        // Both sides should derive the same shared secret
        assert_eq!(shared_alice, shared_bob);
        assert_eq!(shared_alice.len(), 32);
    }

    #[test]
    fn test_different_keypairs_different_keys() {
        let kp1 = SessionKeyPair::generate();
        let kp2 = SessionKeyPair::generate();
        assert_ne!(kp1.public_key_bytes(), kp2.public_key_bytes());
    }

    #[test]
    fn test_double_ecdh_returns_err() {
        let mut alice = SessionKeyPair::generate();
        let bob = SessionKeyPair::generate();
        let bob_public = bob.public_key_bytes();
        // First call succeeds
        assert!(alice.derive_shared_secret(&bob_public).is_ok());
        // Second call returns Err
        assert!(alice.derive_shared_secret(&bob_public).is_err());
    }
}
