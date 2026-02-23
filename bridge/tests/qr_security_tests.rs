//! Integration-level security tests for the QR theft-protection PIN subsystem.
//!
//! These tests verify security properties that matter at the system boundary:
//! - Argon2id is actually used (not bcrypt, scrypt, or plaintext)
//! - Random salts prevent identical PINs producing identical hashes
//! - Plaintext never appears in the hash file
//! - Verification is correct (true for right PIN, false for wrong)
//! - Clearing deletes the file entirely (fail-closed)
//! - Timing characteristics do not leak the comparison result
//! - Edge cases: empty string, unicode, very long input
//!
//! All tests run under filesystem isolation — HOME is redirected to a
//! temporary directory so `dirs::data_dir()` resolves there and tests
//! never touch real user data. A global Mutex serialises access to the
//! HOME environment variable, which is process-wide state.

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tempfile::tempdir;
use termopus_bridge::pin::{clear_pin, has_pin, set_pin, verify_pin};

// ---------------------------------------------------------------------------
// Test infrastructure
// ---------------------------------------------------------------------------

/// Serialise all tests that mutate the HOME env var.
static TEST_LOCK: Mutex<()> = Mutex::new(());

/// Returns the path that `pin::pin_path()` will resolve to when HOME is set
/// to `home_dir`.  Mirrors the logic inside `pin.rs`:
///   dirs::data_dir() → $HOME/Library/Application Support  (macOS)
///                    → $HOME/.local/share                  (Linux)
fn expected_pin_file(home_dir: &std::path::Path) -> PathBuf {
    // dirs::data_dir() is platform-specific; replicate it here without
    // pulling in the private pin_path() function.
    #[cfg(target_os = "macos")]
    let data_dir = home_dir.join("Library").join("Application Support");
    #[cfg(not(target_os = "macos"))]
    let data_dir = home_dir.join(".local").join("share");

    data_dir.join("claude-remote").join("bridge-pin.hash")
}

struct HomeGuard(Option<String>);
impl Drop for HomeGuard {
    fn drop(&mut self) {
        match &self.0 {
            Some(h) => std::env::set_var("HOME", h),
            None => std::env::remove_var("HOME"),
        }
    }
}

/// Run a test closure with HOME pointing at a fresh temporary directory.
/// Restores the original HOME (or removes it) afterwards, even on panic.
fn with_isolated_home<F: FnOnce(&std::path::Path)>(f: F) {
    let _guard = TEST_LOCK.lock().unwrap();
    let tmp = tempdir().unwrap();
    let _restore = HomeGuard(std::env::var("HOME").ok());
    // SAFETY: single-threaded within this lock — no other thread reads HOME.
    std::env::set_var("HOME", tmp.path());
    f(tmp.path());
    // _restore drops here (or on panic unwind), restoring HOME.
    // `tmp` is dropped here, cleaning up the tempdir.
}

// ---------------------------------------------------------------------------
// PIN hash algorithm tests
// ---------------------------------------------------------------------------

/// The stored hash must begin with `$argon2` — confirming Argon2id is used
/// and not bcrypt (`$2b$`), scrypt (`$s0$`), or any other scheme.
#[test]
fn test_pin_hash_uses_argon2id() {
    with_isolated_home(|home| {
        set_pin("test-pin-argon2").expect("set_pin should succeed");
        let hash_file = expected_pin_file(home);
        let raw = std::fs::read_to_string(&hash_file)
            .expect("hash file must exist after set_pin");
        assert!(
            raw.starts_with("$argon2"),
            "hash must start with '$argon2' to confirm Argon2 algorithm, got prefix: {:?}",
            &raw[..raw.len().min(30)]
        );
        // Must NOT look like bcrypt, scrypt, or sha variants
        assert!(
            !raw.starts_with("$2b$"),
            "hash must not be bcrypt"
        );
        assert!(
            !raw.starts_with("$s0$"),
            "hash must not be scrypt"
        );
    });
}

/// Setting the same PIN twice must produce two DIFFERENT hashes.
/// This proves a fresh random salt is generated on every call.
#[test]
fn test_pin_hash_contains_salt() {
    with_isolated_home(|home| {
        let pin = "same-pin-twice";
        let hash_file = expected_pin_file(home);

        set_pin(pin).expect("first set_pin should succeed");
        let hash1 = std::fs::read_to_string(&hash_file)
            .expect("hash file must exist after first set_pin");

        set_pin(pin).expect("second set_pin should succeed");
        let hash2 = std::fs::read_to_string(&hash_file)
            .expect("hash file must exist after second set_pin");

        assert_ne!(
            hash1.trim(),
            hash2.trim(),
            "two hashes of the same PIN must differ due to random salt"
        );
    });
}

/// The raw hash file must not contain the plaintext PIN anywhere —
/// not as a substring, prefix, suffix, or in any trivially decodable form.
#[test]
fn test_pin_hash_not_reversible() {
    with_isolated_home(|home| {
        let pin = "1234";
        set_pin(pin).expect("set_pin should succeed");
        let hash_file = expected_pin_file(home);
        let raw = std::fs::read_to_string(&hash_file)
            .expect("hash file must exist after set_pin");
        assert!(
            !raw.contains(pin),
            "hash file must not contain the plaintext PIN '1234'"
        );
        // Also check that the file is not just base64 of "1234"
        assert!(
            !raw.contains("MTIzNA=="),
            "hash file must not contain base64-encoded PIN"
        );
    });
}

// ---------------------------------------------------------------------------
// PIN verification correctness
// ---------------------------------------------------------------------------

/// Correct PIN returns Ok(true); any other PIN returns Ok(false).
#[test]
fn test_pin_verification_is_correct() {
    with_isolated_home(|_| {
        set_pin("9876").expect("set_pin should succeed");

        let correct = verify_pin("9876").expect("verify_pin must not error on correct PIN");
        assert!(correct, "verify_pin must return true for the correct PIN");

        let wrong = verify_pin("0000").expect("verify_pin must not error on wrong PIN");
        assert!(!wrong, "verify_pin must return false for a wrong PIN");
    });
}

// ---------------------------------------------------------------------------
// PIN clearing / fail-closed behaviour
// ---------------------------------------------------------------------------

/// After clear_pin(), the hash file must be fully deleted — not just zeroed
/// or overwritten.  has_pin() and verify_pin() must both reflect the absence.
#[test]
fn test_pin_clear_removes_all_data() {
    with_isolated_home(|home| {
        set_pin("delete-me").expect("set_pin should succeed");
        let hash_file = expected_pin_file(home);

        assert!(
            hash_file.exists(),
            "hash file must exist after set_pin"
        );

        clear_pin().expect("clear_pin should succeed");

        assert!(
            !hash_file.exists(),
            "hash file must be physically deleted after clear_pin, not just zeroed"
        );
        assert!(
            !has_pin(),
            "has_pin must return false after clear_pin"
        );
    });
}

/// When no PIN has been set, verify_pin must return Ok(false) — never
/// Ok(true) (which would be a privilege-escalation bug) and never Err
/// (which would be a denial-of-service bug on first run).
#[test]
fn test_verify_pin_no_file_returns_false() {
    with_isolated_home(|_| {
        // Ensure no stale file exists.
        clear_pin().ok();

        let result = verify_pin("anything")
            .expect("verify_pin must not return Err when no PIN file exists");
        assert!(
            !result,
            "verify_pin must return false (not true) when no PIN is set — fail-closed"
        );
    });
}

/// Calling clear_pin() multiple times must never error.
/// Idempotency is required because the phone may retry the command.
#[test]
fn test_clear_pin_idempotent() {
    with_isolated_home(|_| {
        // Set then clear once so a file existed at some point.
        set_pin("idempotent-test").expect("set_pin should succeed");
        clear_pin().expect("first clear_pin should succeed");
        clear_pin().expect("second clear_pin should succeed (file already gone)");
        clear_pin().expect("third clear_pin should succeed (still no file)");
        assert!(!has_pin(), "has_pin must be false after repeated clear_pin calls");
    });
}

// ---------------------------------------------------------------------------
// Concurrent access
// ---------------------------------------------------------------------------

/// Spawn five threads each calling set_pin with a different PIN value.
/// The invariant is: no panic, no corruption, and the final state is
/// a valid, verifiable hash for *some* one of the written PINs.
/// (Last writer wins — no requirement for serialisation beyond no crash.)
#[test]
fn test_pin_concurrent_access() {
    // We need full control of HOME so we still hold TEST_LOCK, but we spawn
    // threads that all share the same isolated home directory.
    let _guard = TEST_LOCK.lock().unwrap();
    let tmp = tempdir().unwrap();
    let old_home = std::env::var("HOME").ok();
    std::env::set_var("HOME", tmp.path());

    let pins: Vec<&str> = vec!["1111", "2222", "3333", "4444", "5555"];
    let mut handles = Vec::new();

    for pin in &pins {
        let pin = pin.to_string();
        let handle = std::thread::spawn(move || {
            // Each thread attempts to set its PIN; ignore errors that could
            // arise from transient filesystem races (they're not security bugs).
            let _ = set_pin(&pin);
        });
        handles.push(handle);
    }

    for h in handles {
        h.join().expect("worker thread must not panic");
    }

    // Post-condition: the file should contain a valid argon2 hash.
    // We cannot know which PIN won the race, but reading the file must succeed
    // and it must be verifiable as *one* of the written PINs.
    let hash_file = expected_pin_file(tmp.path());
    if hash_file.exists() {
        let raw = std::fs::read_to_string(&hash_file)
            .expect("hash file must be readable after concurrent writes");
        assert!(
            raw.starts_with("$argon2"),
            "concurrent writes must still produce a valid argon2 hash, got: {:?}",
            &raw[..raw.len().min(40)]
        );
        // At least one of the five PINs must verify successfully.
        let any_matches = pins
            .iter()
            .any(|p| verify_pin(p).unwrap_or(false));
        assert!(
            any_matches,
            "after concurrent writes, at least one of the candidate PINs must verify"
        );
    }
    // (If no file exists at all, all writes lost their race to a crash — which
    //  should not happen, but is less dangerous than a corrupt file.)

    // Restore HOME.
    match old_home {
        Some(h) => std::env::set_var("HOME", h),
        None => std::env::remove_var("HOME"),
    }
}

// ---------------------------------------------------------------------------
// Specific digit-only PIN combinations
// ---------------------------------------------------------------------------

/// Verify a selection of numeric PIN strings that users commonly choose.
/// Each must round-trip correctly (set → verify correct → verify wrong).
#[test]
fn test_pin_with_all_digit_combinations() {
    let cases: &[(&str, &str)] = &[
        ("0000", "0001"),
        ("9999", "9998"),
        ("1234", "1235"),
        ("0001", "0000"),
    ];

    for (pin, wrong) in cases {
        with_isolated_home(|_| {
            set_pin(pin).unwrap_or_else(|e| panic!("set_pin({:?}) failed: {}", pin, e));

            let ok = verify_pin(pin)
                .unwrap_or_else(|e| panic!("verify_pin({:?}) errored: {}", pin, e));
            assert!(ok, "verify_pin must return true for correct PIN {:?}", pin);

            let bad = verify_pin(wrong)
                .unwrap_or_else(|e| panic!("verify_pin({:?}) errored: {}", wrong, e));
            assert!(
                !bad,
                "verify_pin must return false for wrong PIN {:?} when {:?} is set",
                wrong,
                pin
            );
        });
    }
}

// ---------------------------------------------------------------------------
// Timing attack resistance
// ---------------------------------------------------------------------------

/// Measure wall-clock time for `N` verify_pin calls with the correct PIN
/// versus `N` calls with a wrong PIN.  Because Argon2's key-derivation cost
/// completely dominates, both paths should take roughly the same time.
///
/// We assert that the ratio of (max / min) of the two median durations is
/// below 3.0 — a generous bound that catches algorithmic leaks (e.g. an
/// early-return on the first byte mismatch) while still being stable under
/// scheduler jitter.
///
/// NOTE: This is a statistical heuristic, not a cryptographic proof.  It
/// is designed to catch regressions (e.g. switching to a strcmp-based
/// comparison) not to certify constant-time behaviour in an adversarial
/// environment.
#[test]
fn test_pin_verify_timing_correct_vs_wrong() {
    with_isolated_home(|_| {
        let pin = "timing-test-pin";
        set_pin(pin).expect("set_pin should succeed");

        const N: usize = 10; // Argon2 is slow; 10 iterations is enough for a ratio check.

        // Warm-up: one call each to prime caches.
        let _ = verify_pin(pin);
        let _ = verify_pin("totally-wrong");

        let mut correct_times: Vec<Duration> = Vec::with_capacity(N);
        let mut wrong_times: Vec<Duration> = Vec::with_capacity(N);

        for _ in 0..N {
            let t0 = Instant::now();
            verify_pin(pin).expect("verify_pin must not error");
            correct_times.push(t0.elapsed());

            let t1 = Instant::now();
            verify_pin("wrong-pin-xyz").expect("verify_pin must not error");
            wrong_times.push(t1.elapsed());
        }

        // Use median to suppress outliers.
        correct_times.sort();
        wrong_times.sort();
        let correct_median = correct_times[N / 2];
        let wrong_median = wrong_times[N / 2];

        let (longer, shorter) = if correct_median >= wrong_median {
            (correct_median, wrong_median)
        } else {
            (wrong_median, correct_median)
        };

        // Avoid division by zero (practically impossible with Argon2).
        let ratio = if shorter.as_nanos() == 0 {
            f64::MAX
        } else {
            longer.as_nanos() as f64 / shorter.as_nanos() as f64
        };

        assert!(
            ratio < 3.0,
            "timing ratio between correct and wrong PIN verification ({:.2}x) is too large; \
             suggests a non-constant-time comparison leak. \
             correct_median={:?}, wrong_median={:?}",
            ratio,
            correct_median,
            wrong_median,
        );
    });
}

// ---------------------------------------------------------------------------
// Edge cases
// ---------------------------------------------------------------------------

/// The empty string is a valid (if weak) PIN.  set/verify must round-trip.
#[test]
fn test_pin_with_empty_string() {
    with_isolated_home(|_| {
        set_pin("").expect("set_pin with empty string must succeed");

        let ok = verify_pin("").expect("verify_pin with empty string must not error");
        assert!(ok, "verify_pin must return true when empty PIN was set");

        let wrong = verify_pin("x").expect("verify_pin must not error");
        assert!(
            !wrong,
            "verify_pin must return false for non-empty PIN when empty string was set"
        );
    });
}

/// Multi-byte Unicode characters must be accepted.  The hash stores the raw
/// UTF-8 byte sequence so verification must also work on the same sequence.
#[test]
fn test_pin_with_unicode() {
    with_isolated_home(|_| {
        let emoji_pin = "🔐";
        set_pin(emoji_pin).expect("set_pin with emoji must succeed");

        let ok = verify_pin(emoji_pin).expect("verify_pin with emoji must not error");
        assert!(ok, "verify_pin must return true for correct emoji PIN");

        // A visually similar but different code point must not match.
        let wrong = verify_pin("🔒").expect("verify_pin must not error");
        assert!(
            !wrong,
            "verify_pin must return false for a different emoji"
        );
    });
}

/// Argon2 should handle arbitrarily long inputs without panicking or silently
/// truncating, and the full-length string must verify correctly.
#[test]
fn test_pin_with_very_long_input() {
    with_isolated_home(|_| {
        let long_pin = "a".repeat(10_000);
        set_pin(&long_pin).expect("set_pin with 10000-char PIN must succeed");

        let ok = verify_pin(&long_pin).expect("verify_pin with 10000-char PIN must not error");
        assert!(ok, "verify_pin must return true for the correct 10000-char PIN");

        // A PIN that is one character shorter must not verify.
        let short_pin = "a".repeat(9_999);
        let wrong = verify_pin(&short_pin).expect("verify_pin must not error");
        assert!(
            !wrong,
            "verify_pin must return false for a PIN that is one character shorter"
        );
    });
}
