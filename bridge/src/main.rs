// Hide the console window on Windows — Termopus is a GUI app (system tray).
// Without this, a black cmd window appears behind the GUI on every launch.
#![cfg_attr(windows, windows_subsystem = "windows")]

use anyhow::Result;
use clap::Parser;
use std::sync::Arc;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

mod config;
mod crypto;
mod file_transfer;
mod gui;
mod hooks;
mod parser;
mod platform;
mod qr;
mod relay;
mod http_tunnel;
mod safe_tools;
mod session;
mod setup;
mod pin;
mod touch_id;

#[derive(Parser)]
#[command(name = "termopus")]
#[command(about = "Control Claude Code from your phone - just run and scan")]
#[command(version)]
struct Cli {
    /// List saved sessions
    #[arg(short, long)]
    sessions: bool,

    /// Remove a saved session by ID
    #[arg(short, long)]
    remove: Option<String>,

    /// Run without GUI — prints QR code in the terminal.
    /// Useful for headless servers, SSH sessions, or when no display is available.
    #[arg(long)]
    headless: bool,

    /// Relay server URL.
    /// Deploy relay_worker/ and use the deployed URL.
    /// Example: wss://termopus-relay.yourname.workers.dev
    #[arg(long, default_value = "wss://YOUR_RELAY_URL")]
    relay: String,
}

/// Enrich PATH so that tools like `claude`, `npm` are found when
/// the app is launched from Finder (double-click) where the user's shell
/// profile is NOT sourced and PATH is minimal.
fn enrich_path() {
    let home = crate::platform::home_dir().unwrap_or_default();
    let extra_dirs = crate::platform::extra_path_dirs(&home);
    let sep = crate::platform::path_separator();

    let current_path = std::env::var("PATH").unwrap_or_default();
    let mut paths: Vec<String> = current_path.split(sep).map(|s| s.to_string()).collect();

    for dir in &extra_dirs {
        if !paths.contains(dir) && std::path::Path::new(dir).exists() {
            paths.push(dir.clone());
        }
    }

    std::env::set_var("PATH", paths.join(sep));
}

fn main() -> Result<()> {
    // Enrich PATH for GUI launches (Finder/double-click doesn't inherit shell PATH)
    enrich_path();

    let cli = Cli::parse();

    // Initialize logging
    let log_level = if std::env::var("RUST_LOG").is_ok() {
        std::env::var("RUST_LOG").unwrap()
    } else {
        "error".to_string()
    };

    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::new(log_level))
        .with(tracing_subscriber::fmt::layer().without_time())
        .init();

    // Handle utility commands first (these work without async)
    if cli.sessions {
        return commands::list_sessions();
    }

    if let Some(session_id) = cli.remove {
        return commands::remove_session(&session_id);
    }

    if cli.headless {
        commands::run_headless_mode(&cli.relay)
    } else {
        commands::run_gui_mode(&cli.relay)
    }
}

mod commands {
    use super::*;
    use crate::config::storage;
    use crate::gui;
    use crate::qr::generator::QrGenerator;
    use crate::session::manager::{
        ActiveSession, SessionHandle, SessionHandles, SessionStatus, SharedBridgeManager,
    };
    use crate::session::{self, create_shared_manager};
    use std::collections::HashMap;

    /// Run in headless mode — prints QR in terminal, single session.
    pub fn run_headless_mode(relay_url: &str) -> Result<()> {
        storage::sweep_legacy_keys().unwrap_or_else(|e| {
            tracing::warn!("Legacy key sweep failed: {}", e);
        });

        match crate::hooks::config::find_hook_binary() {
            Ok(hook_path) => {
                if let Err(e) = crate::hooks::config::configure_hooks(&hook_path) {
                    tracing::error!("Failed to configure hooks: {}", e);
                }
            }
            Err(e) => {
                tracing::warn!("Hook binary not found, running without hooks: {}", e);
            }
        }

        let manager = create_shared_manager();
        let handles: SessionHandles = Arc::new(tokio::sync::Mutex::new(HashMap::new()));
        let rt = Arc::new(tokio::runtime::Runtime::new()?);

        // Spawn a single session
        spawn_session_inner(&rt, &manager, &handles, relay_url, None);

        let session_id = {
            let mgr = manager.blocking_read();
            mgr.active_session_id().unwrap_or_default().to_string()
        };

        println!("\x1b[1;36mTermopus Bridge\x1b[0m (headless mode)");
        println!("Session: {}", &session_id[..12.min(session_id.len())]);
        println!("Relay:   {}", relay_url);
        println!();

        // Block on async loop: wait for QR, print it, then wait for Ctrl+C
        let mgr_clone = Arc::clone(&manager);
        let sid = session_id.clone();
        let result = rt.block_on(async move {
            let mut qr_printed = false;
            let mut last_status = SessionStatus::Initializing;

            loop {
                tokio::select! {
                    _ = tokio::signal::ctrl_c() => {
                        println!("\n\x1b[33mShutting down...\x1b[0m");
                        break;
                    }
                    _ = tokio::time::sleep(std::time::Duration::from_millis(200)) => {
                        let mgr = mgr_clone.read().await;
                        if let Some(session) = mgr.get_session(&sid) {
                            // Print QR once when available
                            if !qr_printed {
                                if let Some(ref qr_data) = session.qr_data {
                                    match QrGenerator::generate(qr_data) {
                                        Ok(qr) => {
                                            qr.print_to_terminal();
                                            println!("\x1b[1mScan the QR code above with the Termopus app\x1b[0m");
                                            println!("Press Ctrl+C to stop\n");
                                            qr_printed = true;
                                        }
                                        Err(e) => {
                                            eprintln!("Failed to generate QR: {}", e);
                                        }
                                    }
                                }
                            }

                            // Print status changes
                            if session.status != last_status {
                                last_status = session.status.clone();
                                match &last_status {
                                    SessionStatus::WaitingForPairing => {}
                                    SessionStatus::Connecting => {
                                        println!("\x1b[33m> Phone connecting...\x1b[0m");
                                    }
                                    SessionStatus::Connected => {
                                        println!("\x1b[32m> Phone connected!\x1b[0m");
                                    }
                                    SessionStatus::Disconnected => {
                                        println!("\x1b[31m> Phone disconnected\x1b[0m");
                                    }
                                    SessionStatus::Error(msg) => {
                                        println!("\x1b[31m> Error: {}\x1b[0m", msg);
                                    }
                                    _ => {}
                                }
                            }
                        }
                    }
                }
            }
            Ok::<(), anyhow::Error>(())
        });

        crate::hooks::config::remove_hooks().ok();
        result
    }

    /// Run in GUI mode with native window (multi-session)
    pub fn run_gui_mode(relay_url: &str) -> Result<()> {
        // Sweep legacy key files from older versions that persisted secrets to disk
        storage::sweep_legacy_keys().unwrap_or_else(|e| {
            tracing::warn!("Legacy key sweep failed: {}", e);
        });

        // Configure Claude Code hooks once at app startup
        match crate::hooks::config::find_hook_binary() {
            Ok(hook_path) => {
                if let Err(e) = crate::hooks::config::configure_hooks(&hook_path) {
                    tracing::error!("Failed to configure hooks: {}", e);
                }
            }
            Err(e) => {
                tracing::warn!("Hook binary not found, running without hooks: {}", e);
            }
        }

        let manager = create_shared_manager();
        let handles: SessionHandles = Arc::new(tokio::sync::Mutex::new(HashMap::new()));

        // Create a tokio runtime for session tasks
        let rt = Arc::new(tokio::runtime::Runtime::new()?);

        // Channel for GUI to request new sessions
        let (new_session_tx, new_session_rx) = std::sync::mpsc::channel::<()>();

        // Crash recovery: check for an orphaned session from a previous unclean exit.
        // Generate a fresh relay room (new session ID) but migrate the .claude_sid
        // file so the new session can --resume the Claude conversation.
        let crash_recovery_id = if let Some(old_id) = storage::find_orphaned_session() {
            let new_id = generate_session_id();
            tracing::info!("Crash recovery: migrating {} → {}", &old_id[..8.min(old_id.len())], &new_id[..8]);
            if storage::migrate_crash_recovery(&old_id, &new_id) {
                Some(new_id)
            } else {
                None
            }
        } else {
            None
        };
        // Use the migrated ID (which has the .claude_sid file) or generate fresh.
        spawn_session_inner(&rt, &manager, &handles, relay_url, crash_recovery_id);

        // Orchestrator thread: listens for "new session" requests from GUI
        let rt_clone = Arc::clone(&rt);
        let manager_clone = Arc::clone(&manager);
        let handles_clone = Arc::clone(&handles);
        let relay_url_owned = relay_url.to_string();
        std::thread::spawn(move || {
            for _ in new_session_rx {
                spawn_session(&rt_clone, &manager_clone, &handles_clone, &relay_url_owned);
            }
        });

        // Run GUI (blocks until window closed)
        let result = gui::run_gui_multi(
            manager.clone(),
            handles.clone(),
            new_session_tx,
            relay_url.to_string(),
        )
        .map_err(|e| anyhow::anyhow!("GUI error: {}", e));

        // Remove hooks at app shutdown (rules are per-session via --append-system-prompt)
        crate::hooks::config::remove_hooks().ok();

        result
    }

    /// Spawn a new session task.
    ///
    /// If `resume_id` is provided, reuse that session ID (for crash recovery).
    /// Otherwise generate a fresh one.
    fn spawn_session(
        rt: &Arc<tokio::runtime::Runtime>,
        manager: &SharedBridgeManager,
        handles: &SessionHandles,
        relay_url: &str,
    ) {
        spawn_session_inner(rt, manager, handles, relay_url, None);
    }

    fn spawn_session_inner(
        rt: &Arc<tokio::runtime::Runtime>,
        manager: &SharedBridgeManager,
        handles: &SessionHandles,
        relay_url: &str,
        resume_id: Option<String>,
    ) {
        let session_id = resume_id.unwrap_or_else(generate_session_id);
        let (cmd_tx, cmd_rx) = tokio::sync::mpsc::channel(32);

        // Register session in manager and make it active
        let name = {
            let mut mgr = manager.blocking_write();
            let name = mgr.next_session_name();
            let session = ActiveSession::new(
                session_id.clone(),
                name.clone(),
                relay_url.to_string(),
            );
            mgr.add_session(session);
            mgr.set_active_session(&session_id);
            name
        };

        tracing::info!("Spawning session '{}' ({})", name, &session_id[..8]);

        let mgr_clone = Arc::clone(manager);
        let sid = session_id.clone();
        let relay = relay_url.to_string();

        let join_handle = rt.spawn(async move {
            session::task::run_session(sid, relay, mgr_clone, cmd_rx).await;
        });

        // Store handle
        let handle = SessionHandle {
            cmd_tx,
            join_handle,
        };
        handles.blocking_lock().insert(session_id, handle);
    }

    pub fn list_sessions() -> Result<()> {
        let sessions = storage::list_sessions()?;

        if sessions.is_empty() {
            println!("No saved sessions.");
            return Ok(());
        }

        println!("\x1b[1mSaved sessions:\x1b[0m\n");
        for (i, session) in sessions.iter().enumerate() {
            let marker = if i == 0 { " \x1b[32m(default)\x1b[0m" } else { "" };
            println!(
                "  \x1b[1m{}\x1b[0m{}\n    Relay: {}\n    Created: {}\n",
                session.id, marker, session.relay, session.created_at
            );
        }
        Ok(())
    }

    pub fn remove_session(session_id: &str) -> Result<()> {
        storage::remove_session(session_id)?;
        println!("\x1b[32m✓\x1b[0m Session removed: {}", session_id);
        Ok(())
    }

    fn generate_session_id() -> String {
        use rand::Rng;
        let bytes: [u8; 16] = rand::thread_rng().gen();
        hex::encode(bytes)
    }
}
