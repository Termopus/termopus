//! Session management module for Termopus bridge.
//!
//! Manages multiple Claude Code sessions, each with its own:
//! - Relay WebSocket connection
//! - Tmux session for terminal output
//! - Output buffer

pub mod manager;
pub mod stream_json;
pub mod task;
pub mod transcript;
pub mod transcript_watcher;

pub use manager::create_shared_manager;
