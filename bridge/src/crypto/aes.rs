use anyhow::{Context, Result};
use ring::aead::{Aad, LessSafeKey, Nonce, UnboundKey, AES_256_GCM, NONCE_LEN};
use ring::rand::{SecureRandom, SystemRandom};

/// AES-256-GCM authenticated encryption.
///
/// Provides encrypt/decrypt operations using the `ring` crate. Each encryption
/// generates a fresh random 12-byte nonce. The output format is:
///
///   nonce (12 bytes) || ciphertext || authentication tag (16 bytes)
///
/// This format is self-contained: the nonce is prepended so that decryption
/// does not require external state.
///
/// Note: ring::aead::SealingKey and OpeningKey manage their own key memory
/// internally and don't expose raw bytes for zeroization. ring zeros key
/// material in its own Drop implementations.
pub struct AesGcm {
    key: LessSafeKey,
    rng: SystemRandom,
}

impl AesGcm {
    /// Create a new AES-256-GCM cipher from a 32-byte key.
    ///
    /// Returns an error if the key is not exactly 32 bytes.
    pub fn new(key_bytes: &[u8]) -> Result<Self> {
        let unbound = UnboundKey::new(&AES_256_GCM, key_bytes)
            .map_err(|_| anyhow::anyhow!("Invalid AES-256-GCM key: expected 32 bytes"))?;

        Ok(Self {
            key: LessSafeKey::new(unbound),
            rng: SystemRandom::new(),
        })
    }

    /// Encrypt plaintext bytes.
    ///
    /// Returns: `nonce (12 bytes) || ciphertext || tag (16 bytes)`
    ///
    /// Each call generates a fresh random nonce from the OS CSPRNG.
    pub fn encrypt(&self, plaintext: &[u8]) -> Result<Vec<u8>> {
        // Generate a random 12-byte nonce
        let mut nonce_bytes = [0u8; NONCE_LEN];
        self.rng
            .fill(&mut nonce_bytes)
            .map_err(|_| anyhow::anyhow!("Failed to generate random nonce"))?;

        let nonce = Nonce::assume_unique_for_key(nonce_bytes);

        // ring's seal_in_place_append_tag expects a mutable buffer and appends the tag
        let mut in_out = plaintext.to_vec();

        self.key
            .seal_in_place_append_tag(nonce, Aad::empty(), &mut in_out)
            .map_err(|_| anyhow::anyhow!("AES-256-GCM encryption failed"))?;

        // Prepend the nonce to the ciphertext+tag
        let mut result = Vec::with_capacity(NONCE_LEN + in_out.len());
        result.extend_from_slice(&nonce_bytes);
        result.extend_from_slice(&in_out);

        Ok(result)
    }

    /// Decrypt ciphertext produced by `encrypt()`.
    ///
    /// Input format: `nonce (12 bytes) || ciphertext || tag (16 bytes)`
    ///
    /// Returns the original plaintext, or an error if authentication fails.
    pub fn decrypt(&self, data: &[u8]) -> Result<Vec<u8>> {
        // Minimum length: 12 (nonce) + 16 (tag) = 28 bytes
        if data.len() < NONCE_LEN + 16 {
            anyhow::bail!(
                "Ciphertext too short: {} bytes (minimum {})",
                data.len(),
                NONCE_LEN + 16
            );
        }

        // Split nonce from ciphertext+tag
        let (nonce_bytes, ciphertext_and_tag) = data.split_at(NONCE_LEN);
        let nonce_arr: [u8; NONCE_LEN] = nonce_bytes
            .try_into()
            .context("Invalid nonce length")?;
        let nonce = Nonce::assume_unique_for_key(nonce_arr);

        // Decrypt in place
        let mut in_out = ciphertext_and_tag.to_vec();
        let plaintext = self
            .key
            .open_in_place(nonce, Aad::empty(), &mut in_out)
            .map_err(|_| anyhow::anyhow!("AES-256-GCM decryption failed: authentication error"))?;

        Ok(plaintext.to_vec())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_key() -> [u8; 32] {
        // Fixed key for deterministic testing
        let mut key = [0u8; 32];
        for (i, byte) in key.iter_mut().enumerate() {
            *byte = i as u8;
        }
        key
    }

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let cipher = AesGcm::new(&test_key()).unwrap();
        let plaintext = b"Hello, world! This is a secret message.";

        let encrypted = cipher.encrypt(plaintext).unwrap();

        // Encrypted should be longer than plaintext (nonce + tag overhead)
        assert!(encrypted.len() > plaintext.len());
        assert_eq!(encrypted.len(), 12 + plaintext.len() + 16);

        let decrypted = cipher.decrypt(&encrypted).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_different_nonces_each_time() {
        let cipher = AesGcm::new(&test_key()).unwrap();
        let plaintext = b"Same plaintext";

        let enc1 = cipher.encrypt(plaintext).unwrap();
        let enc2 = cipher.encrypt(plaintext).unwrap();

        // Same plaintext should produce different ciphertext (different nonces)
        assert_ne!(enc1, enc2);

        // But both should decrypt to the same plaintext
        assert_eq!(cipher.decrypt(&enc1).unwrap(), plaintext);
        assert_eq!(cipher.decrypt(&enc2).unwrap(), plaintext);
    }

    #[test]
    fn test_tampered_ciphertext_fails() {
        let cipher = AesGcm::new(&test_key()).unwrap();
        let plaintext = b"Tamper test";

        let mut encrypted = cipher.encrypt(plaintext).unwrap();

        // Flip a bit in the ciphertext (after the nonce)
        encrypted[15] ^= 0x01;

        let result = cipher.decrypt(&encrypted);
        assert!(result.is_err());
    }

    #[test]
    fn test_wrong_key_fails() {
        let key1 = test_key();
        let mut key2 = test_key();
        key2[0] = 0xFF; // Different key

        let cipher1 = AesGcm::new(&key1).unwrap();
        let cipher2 = AesGcm::new(&key2).unwrap();

        let plaintext = b"Wrong key test";
        let encrypted = cipher1.encrypt(plaintext).unwrap();

        let result = cipher2.decrypt(&encrypted);
        assert!(result.is_err());
    }

    #[test]
    fn test_too_short_ciphertext() {
        let cipher = AesGcm::new(&test_key()).unwrap();

        let result = cipher.decrypt(&[0u8; 10]);
        assert!(result.is_err());
    }

    #[test]
    fn test_empty_plaintext() {
        let cipher = AesGcm::new(&test_key()).unwrap();
        let plaintext = b"";

        let encrypted = cipher.encrypt(plaintext).unwrap();
        assert_eq!(encrypted.len(), 12 + 0 + 16); // nonce + empty + tag

        let decrypted = cipher.decrypt(&encrypted).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_invalid_key_length() {
        let result = AesGcm::new(&[0u8; 16]); // 16 bytes instead of 32
        assert!(result.is_err());
    }

    #[test]
    fn test_large_plaintext() {
        let cipher = AesGcm::new(&test_key()).unwrap();
        let plaintext = vec![0xABu8; 65536]; // 64 KB

        let encrypted = cipher.encrypt(&plaintext).unwrap();
        let decrypted = cipher.decrypt(&encrypted).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_encrypt_decrypt_with_kdf_derived_key() {
        // End-to-end: ECDH shared secret -> HKDF -> AES key -> encrypt -> decrypt
        // This simulates the actual runtime flow
        use super::super::kdf::derive_aes_key;

        let shared_secret = [0x42u8; 32]; // simulated ECDH output
        let key = derive_aes_key(&shared_secret).unwrap();
        let cipher = AesGcm::new(&*key).unwrap();

        let plaintext = b"Hello from bridge! This is a rekey test message.";
        let encrypted = cipher.encrypt(plaintext).unwrap();

        // Encrypted should be different from plaintext
        assert_ne!(encrypted, plaintext.to_vec());

        // Decrypt should recover original
        let decrypted = cipher.decrypt(&encrypted).unwrap();
        assert_eq!(decrypted, plaintext.to_vec());
    }

    #[test]
    fn test_different_keys_cannot_decrypt() {
        // Verify that a message encrypted with key A cannot be decrypted with key B
        // This proves key renegotiation actually changes the encryption
        use super::super::kdf::derive_aes_key;

        let key_a = derive_aes_key(&[1u8; 32]).unwrap();
        let key_b = derive_aes_key(&[2u8; 32]).unwrap();

        let cipher_a = AesGcm::new(&*key_a).unwrap();
        let cipher_b = AesGcm::new(&*key_b).unwrap();

        let plaintext = b"secret message";
        let encrypted = cipher_a.encrypt(plaintext).unwrap();

        // Decrypting with wrong key should fail
        let result = cipher_b.decrypt(&encrypted);
        assert!(result.is_err(), "Wrong key must fail to decrypt");
    }

    #[test]
    fn test_rekey_produces_different_encryption() {
        // Simulate rekey: same plaintext encrypted with old vs new key
        // must produce different ciphertext
        use super::super::kdf::derive_aes_key;

        let old_key = derive_aes_key(&[0xAAu8; 32]).unwrap();
        let new_key = derive_aes_key(&[0xBBu8; 32]).unwrap();

        let cipher_old = AesGcm::new(&*old_key).unwrap();
        let cipher_new = AesGcm::new(&*new_key).unwrap();

        let plaintext = b"test message for rekey verification";
        let enc_old = cipher_old.encrypt(plaintext).unwrap();
        let enc_new = cipher_new.encrypt(plaintext).unwrap();

        // Different keys produce different ciphertext
        assert_ne!(enc_old, enc_new, "Different keys must produce different ciphertext");

        // But each decrypts with its own key
        assert_eq!(cipher_old.decrypt(&enc_old).unwrap(), plaintext.to_vec());
        assert_eq!(cipher_new.decrypt(&enc_new).unwrap(), plaintext.to_vec());

        // Cross-decryption must fail
        assert!(cipher_old.decrypt(&enc_new).is_err());
        assert!(cipher_new.decrypt(&enc_old).is_err());
    }
}
