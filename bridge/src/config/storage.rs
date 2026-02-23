use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use keyring::Entry;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

/// Configuration for a single saved session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionConfig {
    /// Unique session identifier (hex-encoded random bytes)
    pub id: String,
    /// WebSocket URL of the relay server
    pub relay: String,
    /// Base64-encoded X25519 public key of the paired phone
    pub peer_public_key: String,
    /// When the session was created
    pub created_at: DateTime<Utc>,
}

/// Top-level config file structure.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct ConfigFile {
    /// All saved sessions
    #[serde(default)]
    sessions: Vec<SessionConfig>,
}

/// Application configuration (separate from sessions).
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AppConfig {
    /// Last active session ID (restored on startup)
    pub last_active_session: Option<String>,
    /// Whether to auto-reconnect to the last session on startup
    #[serde(default = "default_auto_reconnect")]
    pub auto_reconnect: bool,
    /// Window width (persisted)
    #[serde(default = "default_window_width")]
    pub window_width: f32,
    /// Window height (persisted)
    #[serde(default = "default_window_height")]
    pub window_height: f32,
}

fn default_auto_reconnect() -> bool {
    true
}

fn default_window_width() -> f32 {
    800.0
}

fn default_window_height() -> f32 {
    600.0
}

/// Get the configuration directory path.
///
/// - macOS: `~/Library/Application Support/claude-remote/`
/// - Linux: `~/.config/claude-remote/`
/// - Windows: `%APPDATA%\claude-remote\`
fn config_dir() -> Result<PathBuf> {
    let base = dirs::config_dir()
        .context("Could not determine config directory for this platform")?;
    Ok(base.join("claude-remote"))
}

/// Get the path to the sessions.toml file.
fn sessions_file() -> Result<PathBuf> {
    Ok(config_dir()?.join("sessions.toml"))
}

/// Get the path to the app config file.
fn app_config_file() -> Result<PathBuf> {
    Ok(config_dir()?.join("config.toml"))
}

/// Ensure the config directory exists.
fn ensure_dirs() -> Result<()> {
    let dir = config_dir()?;
    fs::create_dir_all(&dir)
        .context(format!("Failed to create config directory: {:?}", dir))?;
    Ok(())
}

/// Load the config file, or return an empty default if it doesn't exist.
fn load_config() -> Result<ConfigFile> {
    let path = sessions_file()?;
    if !path.exists() {
        return Ok(ConfigFile::default());
    }

    let content = fs::read_to_string(&path)
        .context(format!("Failed to read sessions file: {:?}", path))?;
    let config: ConfigFile = toml::from_str(&content)
        .context("Failed to parse sessions.toml")?;
    Ok(config)
}

/// Save the config file to disk.
fn save_config(config: &ConfigFile) -> Result<()> {
    ensure_dirs()?;
    let path = sessions_file()?;
    let content = toml::to_string_pretty(config)
        .context("Failed to serialize config to TOML")?;
    fs::write(&path, content)
        .context(format!("Failed to write sessions file: {:?}", path))?;
    Ok(())
}

/// Save a session configuration to disk and Keychain.
///
/// If a session with the same ID already exists, it is replaced.
/// Sensitive fields (peer_public_key, relay URL) are stored in the OS
/// keychain for tamper resistance. The TOML file retains them as a
/// migration fallback for existing sessions.
pub fn save_session(session: &SessionConfig) -> Result<()> {
    let mut config = load_config()?;

    // Remove existing session with the same ID (if any)
    config.sessions.retain(|s| s.id != session.id);

    // Add the new session
    config.sessions.push(session.clone());

    save_config(&config)?;

    // Store sensitive fields in Keychain (best-effort — TOML is the fallback)
    if let Err(e) = keychain_set(&session.id, "peer_key", &session.peer_public_key) {
        tracing::warn!("Failed to save peer_key to Keychain: {}", e);
    }
    if let Err(e) = keychain_set(&session.id, "relay", &session.relay) {
        tracing::warn!("Failed to save relay to Keychain: {}", e);
    }

    tracing::info!("Session saved: {}", session.id);
    Ok(())
}

/// Load a session by its ID.
///
/// Tries the OS keychain first for `peer_public_key` and `relay`, falling
/// back to the TOML file for migration from older versions.
pub fn load_session(session_id: &str) -> Result<SessionConfig> {
    let config = load_config()?;

    let mut session = config
        .sessions
        .into_iter()
        .find(|s| s.id == session_id)
        .context(format!("Session not found: {}", session_id))?;

    // Prefer Keychain values (tamper-resistant) over TOML values
    if let Ok(Some(peer_key)) = keychain_get(session_id, "peer_key") {
        session.peer_public_key = peer_key;
    }
    if let Ok(Some(relay)) = keychain_get(session_id, "relay") {
        session.relay = relay;
    }

    Ok(session)
}

/// Load the most recently created session (the "default" session).
///
/// This is used when `claude-remote start` is called without specifying
/// a session ID.
pub fn load_default_session() -> Result<SessionConfig> {
    let config = load_config()?;

    config
        .sessions
        .into_iter()
        .max_by_key(|s| s.created_at)
        .context("No saved sessions found. Run 'claude-remote pair' first.")
}

/// List all saved sessions, sorted by creation date (newest first).
pub fn list_sessions() -> Result<Vec<SessionConfig>> {
    let config = load_config()?;
    let mut sessions = config.sessions;
    sessions.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    Ok(sessions)
}

/// Remove a session by its ID.
pub fn remove_session(session_id: &str) -> Result<()> {
    let mut config = load_config()?;
    let initial_len = config.sessions.len();

    config.sessions.retain(|s| s.id != session_id);

    if config.sessions.len() == initial_len {
        anyhow::bail!("Session not found: {}", session_id);
    }

    save_config(&config)?;

    // Clean up Keychain entries for this session
    if let Err(e) = keychain_delete_session(session_id) {
        tracing::warn!("Failed to clean Keychain for session {}: {}", session_id, e);
    }

    // Clean up any legacy keypair file from older versions that persisted
    // secret keys to disk. New sessions use EphemeralSecret (never persisted).
    let legacy_kp_path = config_dir()?.join("keys").join(format!("{}.toml", session_id));
    if legacy_kp_path.exists() {
        let _ = fs::remove_file(&legacy_kp_path);
    }

    tracing::info!("Session removed: {}", session_id);
    Ok(())
}

/// Get the config directory path (for display purposes).
pub fn config_dir_display() -> String {
    config_dir()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| "<unknown>".to_string())
}

/// Load the application configuration.
pub fn load_app_config() -> Result<AppConfig> {
    let path = app_config_file()?;
    if !path.exists() {
        return Ok(AppConfig::default());
    }

    let content = fs::read_to_string(&path)
        .context(format!("Failed to read app config file: {:?}", path))?;
    let config: AppConfig = toml::from_str(&content)
        .context("Failed to parse config.toml")?;
    Ok(config)
}

/// Save the application configuration.
pub fn save_app_config(config: &AppConfig) -> Result<()> {
    ensure_dirs()?;
    let path = app_config_file()?;
    let content = toml::to_string_pretty(config)
        .context("Failed to serialize app config to TOML")?;
    fs::write(&path, content)
        .context(format!("Failed to write app config file: {:?}", path))?;
    tracing::info!("App config saved");
    Ok(())
}

/// Update the last active session in the config.
pub fn set_last_active_session(session_id: Option<&str>) -> Result<()> {
    let mut config = load_app_config().unwrap_or_default();
    config.last_active_session = session_id.map(|s| s.to_string());
    save_app_config(&config)
}

/// Get the last active session ID.
pub fn get_last_active_session() -> Option<String> {
    load_app_config()
        .ok()
        .and_then(|c| c.last_active_session)
}

/// Save the Claude Code session ID for crash recovery.
///
/// Written after the Init event so the bridge can resume with `--resume {uuid}`
/// if it restarts while Claude is running.
pub fn save_claude_session_id(session_id: &str, claude_sid: &str) -> Result<()> {
    ensure_dirs()?;
    let dir = config_dir()?.join("sessions");
    fs::create_dir_all(&dir)?;
    let path = dir.join(format!("{}.claude_sid", session_id));
    fs::write(&path, claude_sid)?;
    tracing::debug!("Saved claude_session_id for {}: {}", &session_id[..8.min(session_id.len())], &claude_sid[..8.min(claude_sid.len())]);
    Ok(())
}

/// Load a previously saved Claude Code session ID (for crash recovery).
pub fn load_claude_session_id(session_id: &str) -> Option<String> {
    let path = config_dir().ok()?.join("sessions").join(format!("{}.claude_sid", session_id));
    fs::read_to_string(path).ok().filter(|s| !s.trim().is_empty())
}

/// Clear the saved Claude Code session ID (e.g. on clean exit).
pub fn clear_claude_session_id(session_id: &str) {
    if let Ok(dir) = config_dir() {
        let path = dir.join("sessions").join(format!("{}.claude_sid", session_id));
        let _ = fs::remove_file(path);
    }
}

/// Maximum age for a `.claude_sid` file to be considered for crash recovery.
/// Files older than this are stale (e.g. leftover from a much earlier crash)
/// and are cleaned up instead of resumed.
const CRASH_RECOVERY_MAX_AGE_SECS: u64 = 300; // 5 minutes

/// Find an orphaned session that crashed before cleaning up.
///
/// Scans the sessions directory for `.claude_sid` files — their existence
/// means the bridge exited without a clean shutdown. Returns the bridge
/// session ID (the filename stem) so `spawn_session` can reuse it, allowing
/// `load_claude_session_id()` to find the file and pass `--resume` to Claude.
///
/// Security mitigations:
/// - **Time-bound**: ignores files older than 5 minutes (limits tampering window)
/// - **Single-use**: caller should delete the file after reading via `consume_claude_session_id()`
///
/// Returns at most one orphaned session (the most recently modified).
pub fn find_orphaned_session() -> Option<String> {
    let dir = config_dir().ok()?.join("sessions");
    if !dir.exists() {
        return None;
    }
    let now = std::time::SystemTime::now();
    let mut best: Option<(String, std::time::SystemTime)> = None;
    if let Ok(entries) = fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if let Some(session_id) = name.strip_suffix(".claude_sid") {
                let mtime = match entry.metadata().and_then(|m| m.modified()) {
                    Ok(t) => t,
                    Err(_) => continue,
                };
                // Time-bound: skip files older than 5 minutes
                let age_secs = now.duration_since(mtime).map(|d| d.as_secs()).unwrap_or(u64::MAX);
                if age_secs > CRASH_RECOVERY_MAX_AGE_SECS {
                    tracing::debug!("Ignoring stale .claude_sid for {} ({}s old)", &session_id[..8.min(session_id.len())], age_secs);
                    // Clean up stale file
                    let _ = fs::remove_file(entry.path());
                    continue;
                }
                if best.as_ref().map_or(true, |(_, t)| mtime > *t) {
                    best = Some((session_id.to_string(), mtime));
                }
            }
        }
    }
    best.map(|(id, _)| id)
}

/// Migrate a crash recovery file from an old session ID to a new one.
///
/// Renames `old_id.claude_sid` → `new_id.claude_sid` so the new session
/// can find the Claude UUID via `load_claude_session_id(new_id)`.
/// This allows using a fresh relay room (new ID) while preserving the
/// Claude conversation (UUID inside the file).
pub fn migrate_crash_recovery(old_id: &str, new_id: &str) -> bool {
    let dir = match config_dir() {
        Ok(d) => d.join("sessions"),
        Err(_) => return false,
    };
    let old_path = dir.join(format!("{}.claude_sid", old_id));
    let new_path = dir.join(format!("{}.claude_sid", new_id));
    match fs::rename(&old_path, &new_path) {
        Ok(()) => {
            tracing::info!("Migrated crash recovery: {} → {}", &old_id[..8.min(old_id.len())], &new_id[..8.min(new_id.len())]);
            true
        }
        Err(e) => {
            tracing::warn!("Failed to migrate crash recovery file: {}", e);
            false
        }
    }
}

// ---------------------------------------------------------------------------
// Keychain storage (macOS Keychain / Linux secret-service)
// ---------------------------------------------------------------------------

const KEYRING_SERVICE: &str = "com.termopus.bridge";

/// Store a value in the OS keychain, keyed by session ID and key name.
pub fn keychain_set(session_id: &str, key: &str, value: &str) -> Result<()> {
    let entry = Entry::new(KEYRING_SERVICE, &format!("{}:{}", key, session_id))
        .map_err(|e| anyhow::anyhow!("Keychain entry error: {}", e))?;
    entry
        .set_password(value)
        .map_err(|e| anyhow::anyhow!("Keychain set error: {}", e))?;
    Ok(())
}

/// Retrieve a value from the OS keychain. Returns `None` if the entry does not exist.
pub fn keychain_get(session_id: &str, key: &str) -> Result<Option<String>> {
    let entry = Entry::new(KEYRING_SERVICE, &format!("{}:{}", key, session_id))
        .map_err(|e| anyhow::anyhow!("Keychain entry error: {}", e))?;
    match entry.get_password() {
        Ok(value) => Ok(Some(value)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(anyhow::anyhow!("Keychain get error: {}", e)),
    }
}

/// Delete all keychain entries associated with a session.
pub fn keychain_delete_session(session_id: &str) -> Result<()> {
    for key in &["peer_key", "relay"] {
        if let Ok(entry) = Entry::new(KEYRING_SERVICE, &format!("{}:{}", key, session_id)) {
            let _ = entry.delete_password(); // Ignore if not found
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Legacy key file sweep
// ---------------------------------------------------------------------------

/// Delete ALL legacy keypair files from the keys/ directory.
///
/// Called once on bridge startup to clean up old private key material that was
/// persisted to disk by earlier versions. New sessions use EphemeralSecret
/// (never persisted).
pub fn sweep_legacy_keys() -> Result<()> {
    let keys_dir = config_dir()?.join("keys");
    if !keys_dir.exists() {
        return Ok(());
    }

    let mut count = 0;
    for entry in std::fs::read_dir(&keys_dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_file() {
            tracing::warn!("Removing legacy key file: {}", path.display());
            let _ = std::fs::remove_file(&path);
            count += 1;
        }
    }

    if count > 0 {
        tracing::info!("Swept {} legacy key file(s)", count);
    }

    // Remove the keys/ directory if empty
    let _ = std::fs::remove_dir(&keys_dir);

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::sync::Mutex;

    /// Mutex to serialize tests that operate on the shared config_dir()/keys path.
    static KEYS_DIR_LOCK: Mutex<()> = Mutex::new(());

    /// Set up a temporary config directory for testing.
    fn setup_test_dir() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        env::set_var("XDG_CONFIG_HOME", dir.path());
        dir
    }

    #[test]
    fn test_session_config_serialization() {
        let session = SessionConfig {
            id: "test123".to_string(),
            relay: "wss://relay.example.com".to_string(),
            peer_public_key: "dGVzdA==".to_string(),
            created_at: Utc::now(),
        };

        let json = serde_json::to_string(&session).unwrap();
        let deserialized: SessionConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.id, session.id);
        assert_eq!(deserialized.relay, session.relay);
    }

    #[test]
    fn test_config_file_toml_roundtrip() {
        let config = ConfigFile {
            sessions: vec![
                SessionConfig {
                    id: "session1".to_string(),
                    relay: "wss://relay.example.com".to_string(),
                    peer_public_key: "key1".to_string(),
                    created_at: Utc::now(),
                },
                SessionConfig {
                    id: "session2".to_string(),
                    relay: "wss://relay2.example.com".to_string(),
                    peer_public_key: "key2".to_string(),
                    created_at: Utc::now(),
                },
            ],
        };

        let toml_str = toml::to_string_pretty(&config).unwrap();
        let deserialized: ConfigFile = toml::from_str(&toml_str).unwrap();
        assert_eq!(deserialized.sessions.len(), 2);
        assert_eq!(deserialized.sessions[0].id, "session1");
        assert_eq!(deserialized.sessions[1].id, "session2");
    }

    #[test]
    fn test_sweep_legacy_keys_removes_files() {
        let _lock = KEYS_DIR_LOCK.lock().unwrap();
        // Use the real config_dir() since sweep_legacy_keys() uses it internally
        let keys_dir = config_dir().unwrap().join("keys");
        let existed_before = keys_dir.exists();
        std::fs::create_dir_all(&keys_dir).unwrap();

        // Create fake legacy key files
        std::fs::write(keys_dir.join("session1.key"), "fake-private-key-1").unwrap();
        std::fs::write(keys_dir.join("session2.key"), "fake-private-key-2").unwrap();
        std::fs::write(keys_dir.join("session3.pem"), "fake-cert").unwrap();

        assert!(keys_dir.exists());
        assert_eq!(std::fs::read_dir(&keys_dir).unwrap().count(), 3);

        // Sweep should remove all files
        sweep_legacy_keys().unwrap();

        // keys/ directory should be gone (or empty)
        assert!(!keys_dir.exists() || std::fs::read_dir(&keys_dir).unwrap().count() == 0);

        // Restore prior state if keys_dir didn't exist before
        if !existed_before {
            let _ = std::fs::remove_dir(&keys_dir);
        }
    }

    #[test]
    fn test_sweep_legacy_keys_no_dir_is_ok() {
        let _lock = KEYS_DIR_LOCK.lock().unwrap();
        // Ensure keys/ doesn't exist — use real config_dir()
        let keys_dir = config_dir().unwrap().join("keys");
        let saved: Vec<_> = if keys_dir.exists() {
            // Temporarily move any existing files so we can test "no dir"
            let files: Vec<_> = std::fs::read_dir(&keys_dir)
                .unwrap()
                .filter_map(|e| e.ok())
                .map(|e| {
                    let content = std::fs::read(e.path()).unwrap();
                    (e.file_name(), content)
                })
                .collect();
            let _ = std::fs::remove_dir_all(&keys_dir);
            files
        } else {
            vec![]
        };

        // keys/ directory doesn't exist — should succeed silently
        let result = sweep_legacy_keys();
        assert!(result.is_ok());

        // Restore any saved files
        if !saved.is_empty() {
            std::fs::create_dir_all(&keys_dir).unwrap();
            for (name, content) in saved {
                std::fs::write(keys_dir.join(name), content).unwrap();
            }
        }
    }

    #[test]
    fn test_sweep_legacy_keys_empty_dir() {
        let _lock = KEYS_DIR_LOCK.lock().unwrap();
        // Use real config_dir()
        let keys_dir = config_dir().unwrap().join("keys");
        let existed_before = keys_dir.exists();
        std::fs::create_dir_all(&keys_dir).unwrap();

        // Remove any files that might be there so it's truly empty for the test
        if let Ok(entries) = std::fs::read_dir(&keys_dir) {
            for entry in entries.flatten() {
                let _ = std::fs::remove_file(entry.path());
            }
        }

        // Empty directory — should succeed and remove the dir
        sweep_legacy_keys().unwrap();
        assert!(!keys_dir.exists() || std::fs::read_dir(&keys_dir).unwrap().count() == 0);

        // Restore prior state
        if !existed_before {
            let _ = std::fs::remove_dir(&keys_dir);
        }
    }
}
