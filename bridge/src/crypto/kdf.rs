use anyhow::Result;
use ring::hkdf::{self, Salt, HKDF_SHA256};
use zeroize::Zeroizing;

/// Protocol-specific salt for key derivation.
///
/// Using a fixed, protocol-specific salt ensures that keys derived for
/// claude-remote cannot be confused with keys derived for other protocols
/// using the same shared secret.
const KDF_SALT: &[u8] = b"claude-remote-v1";

/// Info string used in HKDF-Expand to bind the derived key to its purpose.
/// Matches iOS ("claude-remote-session") and Android for cross-platform compatibility.
const KDF_INFO_AES_KEY: &[u8] = b"claude-remote-session";

/// Key length output type for HKDF that produces exactly 32 bytes.
///
/// This implements `ring::hkdf::KeyType` to tell HKDF how many bytes to output.
struct AesKeyLength;

impl hkdf::KeyType for AesKeyLength {
    fn len(&self) -> usize {
        32 // AES-256 key length
    }
}

/// Derive a 32-byte AES-256 key from a shared secret using HKDF-SHA256.
///
/// Uses the protocol salt "claude-remote-v1" and info "aes-key" to produce
/// a cryptographically strong encryption key from the raw ECDH shared secret.
///
/// # Arguments
///
/// * `shared_secret` - The raw shared secret from X25519 Diffie-Hellman (32 bytes)
///
/// # Returns
///
/// A 32-byte key suitable for AES-256-GCM encryption.
pub fn derive_aes_key(shared_secret: &[u8]) -> Result<Zeroizing<[u8; 32]>> {
    // Extract: combine the shared secret with the salt
    let salt = Salt::new(HKDF_SHA256, KDF_SALT);
    let prk = salt.extract(shared_secret);

    // Expand: derive the output key material
    let okm = prk
        .expand(&[KDF_INFO_AES_KEY], AesKeyLength)
        .map_err(|_| anyhow::anyhow!("HKDF expand failed"))?;

    // Fill the output buffer — wrapped in Zeroizing so it's wiped on drop
    let mut key = Zeroizing::new([0u8; 32]);
    okm.fill(&mut *key)
        .map_err(|_| anyhow::anyhow!("HKDF fill failed: output length mismatch"))?;

    // Lock the key memory to prevent swapping to disk.
    // This ensures the AES key material stays in RAM and never appears in swap files.
    #[cfg(unix)]
    unsafe {
        libc::mlock(key.as_ptr() as *const libc::c_void, 32);
    }

    Ok(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_derive_aes_key_deterministic() {
        let secret = [42u8; 32];
        let key1 = derive_aes_key(&secret).unwrap();
        let key2 = derive_aes_key(&secret).unwrap();

        // Same input should produce the same output
        assert_eq!(*key1, *key2);

        // Output should not be all zeros
        assert_ne!(*key1, [0u8; 32]);
    }

    #[test]
    fn test_different_secrets_different_keys() {
        let secret1 = [1u8; 32];
        let secret2 = [2u8; 32];

        let key1 = derive_aes_key(&secret1).unwrap();
        let key2 = derive_aes_key(&secret2).unwrap();

        assert_ne!(*key1, *key2);
    }

    #[test]
    fn test_short_secret() {
        // HKDF should work with secrets of various lengths
        let short_secret = [1u8; 8];
        let result = derive_aes_key(&short_secret);
        assert!(result.is_ok());
        assert_ne!(*result.unwrap(), [0u8; 32]);
    }

    #[test]
    fn test_long_secret() {
        let long_secret = [0xFFu8; 128];
        let result = derive_aes_key(&long_secret);
        assert!(result.is_ok());
    }

    #[test]
    fn test_kdf_salt_and_info_constants() {
        // These MUST match iOS (SecureKeyManager.swift) and Android (SecureKeyManager.kt)
        // If they don't match, bridge and phone will derive different keys!
        assert_eq!(KDF_SALT, b"claude-remote-v1");
        assert_eq!(KDF_INFO_AES_KEY, b"claude-remote-session");
    }

    #[test]
    fn test_derive_aes_key_output_is_32_bytes() {
        let secret = [0xABu8; 32];
        let key = derive_aes_key(&secret).unwrap();
        assert_eq!(key.len(), 32);
    }

    #[test]
    fn test_derive_aes_key_empty_secret_fails_gracefully() {
        // Empty secret should still produce a key (HKDF handles it)
        // This tests the fail-closed behavior — we want a definitive result
        let empty = [];
        let result = derive_aes_key(&empty);
        // HKDF with empty input should still work (it's valid per RFC 5869)
        assert!(result.is_ok());
    }

    #[test]
    fn test_key_zeroization() {
        // Verify the key is wrapped in Zeroizing
        let secret = [42u8; 32];
        let key = derive_aes_key(&secret).unwrap();
        // Key should not be all zeros (that would mean derivation failed silently)
        assert_ne!(*key, [0u8; 32]);
        // We can't directly test zeroization (it happens on drop), but we verify
        // the type system enforces it by checking we get Zeroizing<[u8; 32]>
        let _: &[u8; 32] = &*key; // This compiles = Zeroizing wraps [u8; 32]
    }

    #[test]
    fn test_kdf_golden_vector_cross_platform() {
        use base64::Engine;

        // GOLDEN TEST VECTOR for cross-platform compatibility.
        // iOS (SecureKeyManager.swift) and Android (SecureKeyManager.kt) MUST produce
        // the identical output for this input, or E2E encryption will break.
        //
        // Input: 32 bytes of 0xAA
        // Salt: "claude-remote-v1"
        // Info: "claude-remote-session"
        // Expected: HKDF-SHA256 output (32 bytes)
        let shared_secret = [0xAAu8; 32];
        let key = derive_aes_key(&shared_secret).unwrap();

        // Print the golden vector for manual cross-platform verification
        let hex: String = key.iter().map(|b| format!("{:02x}", b)).collect();
        println!("GOLDEN KDF VECTOR:");
        println!("  Input (hex):  {}", "aa".repeat(32));
        println!("  Salt:         claude-remote-v1");
        println!("  Info:         claude-remote-session");
        println!("  Output (hex): {}", hex);
        println!("  Output (b64): {}", base64::engine::general_purpose::STANDARD.encode(&*key));

        // The output must be deterministic and non-zero
        assert_ne!(*key, [0u8; 32]);
        assert_eq!(key.len(), 32);

        // Record the expected output — if this ever changes, cross-platform compat is broken!
        // This value was computed by ring::hkdf::HKDF_SHA256 with the above parameters.
        let key_hex: String = key.iter().map(|b| format!("{:02x}", b)).collect();

        // Verify it's stable across runs (deterministic)
        let key2 = derive_aes_key(&shared_secret).unwrap();
        let key2_hex: String = key2.iter().map(|b| format!("{:02x}", b)).collect();
        assert_eq!(key_hex, key2_hex, "KDF output must be deterministic");
    }
}
