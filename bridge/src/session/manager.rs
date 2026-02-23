//! Multi-session manager for Termopus bridge.
//!
//! Coordinates multiple Claude Code sessions, allowing users to:
//! - Switch between sessions
//! - Create new sessions
//! - Terminate individual sessions

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use crate::config::storage::{self, SessionConfig};

/// Commands sent from the GUI to a specific session's background task.
#[derive(Debug)]
pub enum SessionCommand {
    /// Send text input to Claude (from GUI setup input bar)
    SendInput(String),
    /// Terminate this session (stop Claude, disconnect relay)
    Terminate,
    /// Graceful shutdown (app is closing)
    Shutdown,
    /// Phone requests handoff — kill stream-json, open interactive terminal
    Handoff,
    /// Phone requests take-back — kill terminal, respawn stream-json
    TakeBack,
}

/// Handle for communicating with a running session task.
pub struct SessionHandle {
    /// Send commands to the session's background task
    pub cmd_tx: mpsc::Sender<SessionCommand>,
    /// Join handle for the spawned tokio task
    pub join_handle: JoinHandle<()>,
}

/// Thread-safe map of session handles (kept separate from BridgeManager to avoid
/// holding the manager lock while sending commands or awaiting tasks).
pub type SessionHandles = Arc<tokio::sync::Mutex<HashMap<String, SessionHandle>>>;

/// Real-time Claude Code status, updated from stream-json events.
#[derive(Debug, Clone, PartialEq)]
pub enum ClaudeStatus {
    /// Claude is idle, waiting for user input
    Idle,
    /// Claude is thinking (processing)
    Thinking,
    /// Claude is generating a response (text streaming)
    Responding,
    /// Claude is running a tool
    ToolRunning { tool_name: String },
    /// Claude is awaiting user input (hook waiting for phone approval)
    AwaitingInput,
    /// Claude process has exited
    Exited,
    /// Claude is being respawned (model/mode switch or crash recovery)
    Respawning,
    /// Session handed off to computer — interactive terminal running
    HandedOff,
}

impl ClaudeStatus {
    /// Serialize to a string for the phone protocol.
    pub fn as_str(&self) -> &str {
        match self {
            Self::Idle => "idle",
            Self::Thinking => "thinking",
            Self::Responding => "responding",
            Self::ToolRunning { .. } => "tool_running",
            Self::AwaitingInput => "awaiting_input",
            Self::Exited => "exited",
            Self::Respawning => "respawning",
            Self::HandedOff => "handed_off",
        }
    }
}

/// Per-session live state, updated from stream-json events in real-time.
/// NOT persisted — rebuilt on bridge restart from Claude's state.
#[derive(Debug, Clone)]
pub struct SessionLiveState {
    pub claude_status: ClaudeStatus,
    pub active_agents: u32,
    pub last_activity: String,
    pub model: Option<String>,
    pub permission_mode: Option<String>,
    pub thinking_since: Option<Instant>,
    pub updated_at: Instant,
}

impl SessionLiveState {
    pub fn new() -> Self {
        Self {
            claude_status: ClaudeStatus::Idle,
            active_agents: 0,
            last_activity: String::new(),
            model: None,
            permission_mode: None,
            thinking_since: None,
            updated_at: Instant::now(),
        }
    }

    /// Build the JSON payload sent to the phone on state transitions.
    pub fn to_json(&self, session_id: &str) -> serde_json::Value {
        let thinking_elapsed_secs = self.thinking_since
            .map(|t| t.elapsed().as_secs())
            .unwrap_or(0);

        let mut val = serde_json::json!({
            "type": "LiveStateUpdate",
            "sessionId": session_id,
            "claudeStatus": self.claude_status.as_str(),
            "activeAgents": self.active_agents,
            "lastActivity": self.last_activity,
            "thinkingElapsedSecs": thinking_elapsed_secs,
        });

        if let Some(ref m) = self.model {
            val["model"] = serde_json::Value::String(m.clone());
        }
        if let Some(ref p) = self.permission_mode {
            val["permissionMode"] = serde_json::Value::String(p.clone());
        }
        if let ClaudeStatus::ToolRunning { ref tool_name } = self.claude_status {
            val["toolName"] = serde_json::Value::String(tool_name.clone());
        }
        val
    }
}

impl Default for SessionLiveState {
    fn default() -> Self {
        Self::new()
    }
}

/// Status of a session.
#[derive(Debug, Clone, PartialEq)]
pub enum SessionStatus {
    /// Session is initializing (generating QR, etc.)
    Initializing,
    /// Waiting for phone to scan QR code
    WaitingForPairing,
    /// Connecting to relay
    Connecting,
    /// Fully connected and running
    Connected,
    /// Session is disconnected but can be reconnected
    Disconnected,
    /// Session encountered an error
    Error(String),
}

/// An active session being managed by the bridge.
#[derive(Debug, Clone)]
pub struct ActiveSession {
    /// Session ID (unique identifier)
    pub id: String,
    /// Human-readable session name
    pub name: String,
    /// Current session status
    pub status: SessionStatus,
    /// Real-time Claude Code state (updated from stream-json events)
    pub live_state: SessionLiveState,
    /// Latest terminal output (for display)
    pub terminal_output: String,
    /// Relay server URL
    pub relay_url: String,
    /// QR data for pairing (JSON string)
    pub qr_data: Option<String>,
    /// Whether Claude Code is authenticated in this session
    pub claude_authenticated: bool,
    /// Setup issues for this session (title, description)
    pub setup_issues: Vec<(String, String)>,
    /// QR lock disabled — show QR immediately without identity verification
    pub qr_locked: bool,
    /// PIN input state for GUI (not persisted)
    pub pin_input: String,
    /// Error message for PIN entry
    pub pin_error: Option<String>,
}

impl ActiveSession {
    /// Create a new session in initializing state.
    pub fn new(id: String, name: String, relay_url: String) -> Self {
        Self {
            id,
            name,
            status: SessionStatus::Initializing,
            live_state: SessionLiveState::new(),
            terminal_output: String::new(),
            relay_url,
            qr_data: None,
            claude_authenticated: false,
            setup_issues: Vec::new(),
            qr_locked: false,
            pin_input: String::new(),
            pin_error: None,
        }
    }

    /// Create from a saved session config.
    pub fn from_config(config: &SessionConfig) -> Self {
        let name = format!("Session {}", &config.id[..8.min(config.id.len())]);
        Self {
            id: config.id.clone(),
            name,
            status: SessionStatus::Disconnected,
            live_state: SessionLiveState::new(),
            terminal_output: String::new(),
            relay_url: config.relay.clone(),
            qr_data: None,
            claude_authenticated: false,
            setup_issues: Vec::new(),
            qr_locked: false,
            pin_input: String::new(),
            pin_error: None,
        }
    }
}

/// Manages multiple sessions.
pub struct BridgeManager {
    /// All active sessions
    sessions: HashMap<String, ActiveSession>,
    /// Currently active session ID
    active_session_id: Option<String>,
    /// Counter for auto-naming sessions
    next_session_number: u32,
}

impl BridgeManager {
    /// Create a new bridge manager.
    pub fn new() -> Self {
        Self {
            sessions: HashMap::new(),
            active_session_id: None,
            next_session_number: 1,
        }
    }

    /// Generate the next session name and increment the counter.
    pub fn next_session_name(&mut self) -> String {
        let name = format!("Session {}", self.next_session_number);
        self.next_session_number += 1;
        name
    }

    /// Load saved sessions from config.
    pub fn load_saved_sessions(&mut self) {
        if let Ok(saved_sessions) = storage::list_sessions() {
            for config in saved_sessions {
                let session = ActiveSession::from_config(&config);
                self.sessions.insert(config.id.clone(), session);
            }
        }
    }

    /// Add a new session.
    pub fn add_session(&mut self, session: ActiveSession) {
        let id = session.id.clone();
        self.sessions.insert(id.clone(), session);

        // If this is the first session, make it active
        if self.active_session_id.is_none() {
            self.active_session_id = Some(id);
        }
    }

    /// Get a session by ID.
    pub fn get_session(&self, id: &str) -> Option<&ActiveSession> {
        self.sessions.get(id)
    }

    /// Get a mutable session by ID.
    pub fn get_session_mut(&mut self, id: &str) -> Option<&mut ActiveSession> {
        self.sessions.get_mut(id)
    }

    /// Get the currently active session.
    pub fn active_session(&self) -> Option<&ActiveSession> {
        self.active_session_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
    }

    /// Get the currently active session mutably.
    pub fn active_session_mut(&mut self) -> Option<&mut ActiveSession> {
        if let Some(id) = self.active_session_id.clone() {
            self.sessions.get_mut(&id)
        } else {
            None
        }
    }

    /// Get the active session ID.
    pub fn active_session_id(&self) -> Option<&str> {
        self.active_session_id.as_deref()
    }

    /// Set the active session.
    pub fn set_active_session(&mut self, id: &str) -> bool {
        if self.sessions.contains_key(id) {
            self.active_session_id = Some(id.to_string());

            // Save as last active session
            let _ = storage::set_last_active_session(Some(id));

            true
        } else {
            false
        }
    }

    /// Remove a session.
    pub fn remove_session(&mut self, id: &str) -> Option<ActiveSession> {
        let session = self.sessions.remove(id);

        // If we removed the active session, select another one
        if self.active_session_id.as_deref() == Some(id) {
            self.active_session_id = self.sessions.keys().next().cloned();
        }

        session
    }

    /// Get all sessions sorted by name.
    pub fn all_sessions(&self) -> Vec<&ActiveSession> {
        let mut sessions: Vec<_> = self.sessions.values().collect();
        sessions.sort_by(|a, b| a.name.cmp(&b.name));
        sessions
    }

    /// Get the number of sessions.
    pub fn session_count(&self) -> usize {
        self.sessions.len()
    }

    /// Update a session's status.
    pub fn update_status(&mut self, id: &str, status: SessionStatus) {
        if let Some(session) = self.sessions.get_mut(id) {
            session.status = status;
        }
    }

    /// Update a session's terminal output.
    pub fn update_terminal_output(&mut self, id: &str, output: String) {
        if let Some(session) = self.sessions.get_mut(id) {
            session.terminal_output = output;
        }
    }

    /// Update a session's live state and return the JSON for sending to phone.
    pub fn update_live_state(
        &mut self,
        id: &str,
        f: impl FnOnce(&mut SessionLiveState),
    ) -> Option<serde_json::Value> {
        if let Some(session) = self.sessions.get_mut(id) {
            f(&mut session.live_state);
            session.live_state.updated_at = Instant::now();
            Some(session.live_state.to_json(id))
        } else {
            None
        }
    }

    /// Append a formatted event line to a session's terminal output.
    /// Shows live events in the GUI.
    /// Caps at 500 lines to prevent unbounded memory growth.
    pub fn append_event_line(&mut self, id: &str, line: &str) {
        if let Some(session) = self.sessions.get_mut(id) {
            if !session.terminal_output.is_empty() {
                session.terminal_output.push('\n');
            }
            session.terminal_output.push_str(line);

            // Cap at 500 lines — drop oldest lines
            let line_count = session.terminal_output.lines().count();
            if line_count > 500 {
                let drop = line_count - 500;
                if let Some(pos) = session.terminal_output
                    .match_indices('\n')
                    .nth(drop - 1)
                    .map(|(i, _)| i + 1)
                {
                    session.terminal_output = session.terminal_output[pos..].to_string();
                }
            }
        }
    }

    pub fn set_qr_locked(&mut self, session_id: &str, locked: bool) {
        if let Some(session) = self.sessions.get_mut(session_id) {
            session.qr_locked = locked;
        }
    }

}

impl Default for BridgeManager {
    fn default() -> Self {
        Self::new()
    }
}

/// Thread-safe wrapper around BridgeManager.
pub type SharedBridgeManager = Arc<tokio::sync::RwLock<BridgeManager>>;

/// Create a new shared bridge manager.
pub fn create_shared_manager() -> SharedBridgeManager {
    Arc::new(tokio::sync::RwLock::new(BridgeManager::new()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_add_and_get_session() {
        let mut manager = BridgeManager::new();
        let session = ActiveSession::new(
            "test-id".to_string(),
            "Test Session".to_string(),
            "wss://relay.test.com".to_string(),
        );

        manager.add_session(session);

        assert_eq!(manager.session_count(), 1);
        assert!(manager.get_session("test-id").is_some());
        assert_eq!(manager.active_session_id(), Some("test-id"));
    }

    #[test]
    fn test_switch_active_session() {
        let mut manager = BridgeManager::new();

        manager.add_session(ActiveSession::new(
            "session-1".to_string(),
            "Session 1".to_string(),
            "wss://relay.test.com".to_string(),
        ));
        manager.add_session(ActiveSession::new(
            "session-2".to_string(),
            "Session 2".to_string(),
            "wss://relay.test.com".to_string(),
        ));

        assert!(manager.set_active_session("session-2"));
        assert_eq!(manager.active_session_id(), Some("session-2"));
    }

    #[test]
    fn test_remove_session() {
        let mut manager = BridgeManager::new();

        manager.add_session(ActiveSession::new(
            "session-1".to_string(),
            "Session 1".to_string(),
            "wss://relay.test.com".to_string(),
        ));

        let removed = manager.remove_session("session-1");
        assert!(removed.is_some());
        assert_eq!(manager.session_count(), 0);
    }

    #[test]
    fn test_session_starts_qr_locked() {
        let session = ActiveSession::new(
            "s1".to_string(),
            "Session 1".to_string(),
            "wss://relay.test.com".to_string(),
        );
        assert!(session.qr_locked);
    }

    #[test]
    fn test_set_qr_locked_unlock() {
        let mut manager = BridgeManager::new();
        manager.add_session(ActiveSession::new(
            "s1".to_string(),
            "Session 1".to_string(),
            "wss://relay.test.com".to_string(),
        ));
        manager.set_qr_locked("s1", false);
        assert!(!manager.get_session("s1").unwrap().qr_locked);
    }

    #[test]
    fn test_set_qr_locked_relock() {
        let mut manager = BridgeManager::new();
        manager.add_session(ActiveSession::new(
            "s1".to_string(),
            "Session 1".to_string(),
            "wss://relay.test.com".to_string(),
        ));
        manager.set_qr_locked("s1", false);
        manager.set_qr_locked("s1", true);
        assert!(manager.get_session("s1").unwrap().qr_locked);
    }

    #[test]
    fn test_set_qr_locked_nonexistent_session() {
        let mut manager = BridgeManager::new();
        // Must not panic on a missing session
        manager.set_qr_locked("nonexistent", false);
    }

    #[test]
    fn test_pin_input_initially_empty() {
        let session = ActiveSession::new(
            "s1".to_string(),
            "Session 1".to_string(),
            "wss://relay.test.com".to_string(),
        );
        assert!(session.pin_input.is_empty());
    }

    #[test]
    fn test_pin_error_initially_none() {
        let session = ActiveSession::new(
            "s1".to_string(),
            "Session 1".to_string(),
            "wss://relay.test.com".to_string(),
        );
        assert!(session.pin_error.is_none());
    }

    #[test]
    fn test_session_from_config_starts_locked() {
        use crate::config::storage::SessionConfig;
        use chrono::Utc;

        let config = SessionConfig {
            id: "abcdef1234567890".to_string(),
            relay: "wss://relay.test.com".to_string(),
            peer_public_key: "dGVzdA==".to_string(),
            created_at: Utc::now(),
        };
        let session = ActiveSession::from_config(&config);
        assert!(session.qr_locked);
        assert!(session.pin_input.is_empty());
        assert!(session.pin_error.is_none());
    }
}
