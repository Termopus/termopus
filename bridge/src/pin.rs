//! Bridge PIN for QR code access gating.
//! PIN is set once, stored as argon2 hash, verified on each session start.

use anyhow::{Context, Result};
use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier};
use argon2::password_hash::SaltString;
use std::path::PathBuf;

fn base_dir() -> PathBuf {
    let base = dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("claude-remote");
    std::fs::create_dir_all(&base).ok();
    base
}

fn pin_path() -> PathBuf {
    base_dir().join("bridge-pin.hash")
}

fn recovery_path() -> PathBuf {
    base_dir().join("bridge-recovery.hash")
}

/// Returns true if a PIN has been set.
pub fn has_pin() -> bool {
    pin_path().exists()
}

/// Set (or overwrite) the bridge PIN. Stores argon2 hash.
pub fn set_pin(pin: &str) -> Result<()> {
    let salt = SaltString::generate(&mut argon2::password_hash::rand_core::OsRng);
    let argon2 = Argon2::default();
    let hash = argon2
        .hash_password(pin.as_bytes(), &salt)
        .map_err(|e| anyhow::anyhow!("Failed to hash PIN: {}", e))?;
    std::fs::write(pin_path(), hash.to_string())
        .context("Failed to write PIN hash file")?;
    Ok(())
}

/// Verify a PIN against the stored hash. Returns false if no PIN is set.
pub fn verify_pin(pin: &str) -> Result<bool> {
    let path = pin_path();
    if !path.exists() {
        return Ok(false);
    }
    let stored = std::fs::read_to_string(&path)
        .context("Failed to read PIN hash file")?;
    let parsed = PasswordHash::new(&stored)
        .map_err(|e| anyhow::anyhow!("Invalid PIN hash: {}", e))?;
    Ok(Argon2::default().verify_password(pin.as_bytes(), &parsed).is_ok())
}

/// Clear the stored PIN (for reset from phone).
pub fn clear_pin() -> Result<()> {
    let path = pin_path();
    if path.exists() {
        std::fs::remove_file(&path)
            .context("Failed to remove PIN hash file")?;
    }
    Ok(())
}

/// Generate a random 8-character alphanumeric recovery code.
pub fn generate_recovery_code() -> String {
    use argon2::password_hash::rand_core::{OsRng, RngCore};
    const CHARSET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no 0/O/1/I to avoid confusion
    let mut code = String::with_capacity(8);
    for _ in 0..8 {
        let idx = (OsRng.next_u32() as usize) % CHARSET.len();
        code.push(CHARSET[idx] as char);
    }
    code
}

/// Store recovery code as argon2 hash.
pub fn set_recovery_code(code: &str) -> Result<()> {
    let salt = SaltString::generate(&mut argon2::password_hash::rand_core::OsRng);
    let argon2 = Argon2::default();
    let hash = argon2
        .hash_password(code.as_bytes(), &salt)
        .map_err(|e| anyhow::anyhow!("Failed to hash recovery code: {}", e))?;
    std::fs::write(recovery_path(), hash.to_string())
        .context("Failed to write recovery hash file")?;
    Ok(())
}

/// Verify a recovery code against stored hash.
pub fn verify_recovery_code(code: &str) -> Result<bool> {
    let path = recovery_path();
    if !path.exists() {
        return Ok(false);
    }
    let stored = std::fs::read_to_string(&path)
        .context("Failed to read recovery hash file")?;
    let parsed = PasswordHash::new(&stored)
        .map_err(|e| anyhow::anyhow!("Invalid recovery hash: {}", e))?;
    // Case-insensitive comparison (user might type lowercase)
    let normalized = code.to_uppercase();
    Ok(Argon2::default().verify_password(normalized.as_bytes(), &parsed).is_ok())
}

/// Clear the recovery code (when PIN is reset, new recovery code will be generated).
pub fn clear_recovery() -> Result<()> {
    let path = recovery_path();
    if path.exists() {
        std::fs::remove_file(&path)
            .context("Failed to remove recovery hash file")?;
    }
    Ok(())
}

/// Returns true if a recovery code has been set.
pub fn has_recovery_code() -> bool {
    recovery_path().exists()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    static TEST_LOCK: Mutex<()> = Mutex::new(());

    /// RAII guard that restores HOME on drop (including panic unwind).
    struct HomeGuard(Option<String>);
    impl Drop for HomeGuard {
        fn drop(&mut self) {
            match &self.0 {
                Some(h) => std::env::set_var("HOME", h),
                None => std::env::remove_var("HOME"),
            }
        }
    }

    fn with_temp_home<F: FnOnce()>(f: F) {
        let _guard = TEST_LOCK.lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let _restore = HomeGuard(std::env::var("HOME").ok());
        std::env::set_var("HOME", tmp.path());
        f();
        // _restore drops here (or on panic unwind), restoring HOME
    }

    #[test]
    fn test_no_pin_initially() {
        with_temp_home(|| {
            assert!(!has_pin(), "has_pin should return false when no file exists");
        });
    }

    #[test]
    fn test_set_and_has_pin() {
        with_temp_home(|| {
            set_pin("1234").expect("set_pin should succeed");
            assert!(has_pin(), "has_pin should return true after set_pin");
        });
    }

    #[test]
    fn test_set_and_verify_correct() {
        with_temp_home(|| {
            set_pin("correct-pin").expect("set_pin should succeed");
            let result = verify_pin("correct-pin").expect("verify_pin should not error");
            assert!(result, "verify_pin should return true for correct PIN");
        });
    }

    #[test]
    fn test_verify_wrong_pin() {
        with_temp_home(|| {
            set_pin("1234").expect("set_pin should succeed");
            let result = verify_pin("5678").expect("verify_pin should not error");
            assert!(!result, "verify_pin should return false for wrong PIN");
        });
    }

    #[test]
    fn test_verify_no_pin_set() {
        with_temp_home(|| {
            let result = verify_pin("anything").expect("verify_pin should not error when no file");
            assert!(!result, "verify_pin should return false when no PIN file exists");
        });
    }

    #[test]
    fn test_clear_pin() {
        with_temp_home(|| {
            set_pin("1234").expect("set_pin should succeed");
            assert!(has_pin(), "has_pin should be true before clear_pin");
            clear_pin().expect("clear_pin should succeed");
            assert!(!has_pin(), "has_pin should return false after clear_pin");
        });
    }

    #[test]
    fn test_clear_pin_no_file() {
        with_temp_home(|| {
            // clear_pin should succeed even when no file exists
            clear_pin().expect("clear_pin should not error when no file exists");
            assert!(!has_pin(), "has_pin should still be false after clearing non-existent PIN");
        });
    }

    #[test]
    fn test_overwrite_pin() {
        with_temp_home(|| {
            set_pin("1234").expect("first set_pin should succeed");
            set_pin("5678").expect("second set_pin (overwrite) should succeed");

            let new_correct = verify_pin("5678").expect("verify_pin should not error");
            assert!(new_correct, "verify_pin should return true for the new PIN");

            let old_wrong = verify_pin("1234").expect("verify_pin should not error");
            assert!(!old_wrong, "verify_pin should return false for the old PIN after overwrite");
        });
    }

    #[test]
    fn test_pin_stored_as_argon2_hash() {
        with_temp_home(|| {
            set_pin("my-secret-pin").expect("set_pin should succeed");
            let raw = std::fs::read_to_string(pin_path()).expect("should be able to read hash file");
            assert!(
                raw.starts_with("$argon2"),
                "stored hash should start with '$argon2', got: {:?}",
                &raw[..raw.len().min(20)]
            );
        });
    }

    #[test]
    fn test_pin_not_stored_plaintext() {
        with_temp_home(|| {
            set_pin("1234").expect("set_pin should succeed");
            let raw = std::fs::read_to_string(pin_path()).expect("should be able to read hash file");
            assert!(
                !raw.contains("1234"),
                "stored file must not contain the plaintext PIN"
            );
        });
    }

    #[test]
    fn test_empty_pin() {
        with_temp_home(|| {
            set_pin("").expect("set_pin with empty string should succeed");
            let result = verify_pin("").expect("verify_pin with empty string should not error");
            assert!(result, "verify_pin should return true for correct empty PIN");

            let wrong = verify_pin("notempty").expect("verify_pin should not error");
            assert!(!wrong, "verify_pin should return false for non-empty PIN when empty was set");
        });
    }

    #[test]
    fn test_long_pin() {
        with_temp_home(|| {
            let long_pin = "a".repeat(100);
            set_pin(&long_pin).expect("set_pin with 100-char PIN should succeed");
            let result = verify_pin(&long_pin).expect("verify_pin with 100-char PIN should not error");
            assert!(result, "verify_pin should return true for correct long PIN");

            let wrong = verify_pin(&"b".repeat(100)).expect("verify_pin should not error");
            assert!(!wrong, "verify_pin should return false for different long PIN");
        });
    }

    #[test]
    fn test_special_chars_pin() {
        with_temp_home(|| {
            set_pin("!@#$%^&*").expect("set_pin with special chars should succeed");
            let result = verify_pin("!@#$%^&*").expect("verify_pin should not error");
            assert!(result, "verify_pin should return true for correct special-char PIN");

            let wrong = verify_pin("!@#$%^&").expect("verify_pin should not error");
            assert!(!wrong, "verify_pin should return false for slightly different special-char PIN");
        });
    }

    #[test]
    fn test_unicode_pin() {
        with_temp_home(|| {
            set_pin("日本語").expect("set_pin with unicode PIN should succeed");
            let result = verify_pin("日本語").expect("verify_pin should not error");
            assert!(result, "verify_pin should return true for correct unicode PIN");

            let wrong = verify_pin("日本").expect("verify_pin should not error");
            assert!(!wrong, "verify_pin should return false for different unicode PIN");
        });
    }

    #[test]
    fn test_verify_corrupt_hash_file_returns_error() {
        with_temp_home(|| {
            // First set a valid PIN so the directory structure exists
            set_pin("1234").unwrap();

            // Overwrite with garbage
            let path = base_dir().join("bridge-pin.hash");
            std::fs::write(&path, "not-a-valid-argon2-hash").unwrap();

            // verify_pin should return Err, not Ok(false) or Ok(true)
            let result = verify_pin("1234");
            assert!(result.is_err(), "Corrupt hash should return Err, got: {:?}", result);
        });
    }

    #[test]
    fn test_verify_empty_hash_file_returns_error() {
        with_temp_home(|| {
            set_pin("1234").unwrap();

            let path = base_dir().join("bridge-pin.hash");
            std::fs::write(&path, "").unwrap();

            let result = verify_pin("1234");
            assert!(result.is_err(), "Empty hash file should return Err, got: {:?}", result);
        });
    }
}
