//! Per-session async task.
//!
//! Each session runs as an independent tokio task with its own:
//! - Relay WebSocket connection
//! - Claude Code process (stream-json)
//! - Hook watcher
//! - Command channel from the GUI

use anyhow::Result;
use rand::Rng;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

use crate::config::storage::{self, SessionConfig};
use crate::crypto::keypair::SessionKeyPair;
use crate::file_transfer::FileTransferManager;
use crate::file_transfer::send::PreparedFile;
use crate::relay::messages::RelayMessage;
use crate::relay::websocket::RelayClient;
use crate::http_tunnel::HttpProxy;
use crate::session::manager::{ClaudeStatus, SessionCommand, SessionStatus, SharedBridgeManager};
use crate::session::stream_json::{StreamEvent, StreamJsonSession};

/// Format current local time as `[HH:MM:SS]` for event monitor log lines.
fn event_ts() -> String {
    let now = chrono::Local::now();
    now.format("[%H:%M:%S]").to_string()
}

/// Extract port from text containing a localhost URL, server command, or output.
/// Matches host:port patterns and keyword-based patterns like "port = 8000",
/// "--port 3000", "http.server 8080", etc.
fn extract_port_from_text(text: &str) -> Option<u16> {
    // Direct host:port patterns (most reliable)
    for pattern in &["localhost:", "127.0.0.1:", "0.0.0.0:", "[::]:"] {
        if let Some(idx) = text.find(pattern) {
            let after = &text[idx + pattern.len()..];
            let port_str: String = after.chars().take_while(|c| c.is_ascii_digit()).collect();
            if let Ok(port) = port_str.parse::<u16>() {
                if port >= 1024 {
                    return Some(port);
                }
            }
        }
    }
    // Keyword patterns — skip non-digit chars between keyword and number
    let lower = text.to_lowercase();
    for keyword in &["port", "http.server", "--port", "-p "] {
        if let Some(idx) = lower.find(keyword) {
            let after = &lower[idx + keyword.len()..];
            // Skip whitespace, '=', ':', etc. to find the number
            let digits_start = after.find(|c: char| c.is_ascii_digit());
            if let Some(start) = digits_start {
                let port_str: String = after[start..].chars()
                    .take_while(|c| c.is_ascii_digit()).collect();
                if let Ok(port) = port_str.parse::<u16>() {
                    if port >= 1024 {
                        return Some(port);
                    }
                }
            }
        }
    }
    None
}

/// Run a single session from pairing through bridge loop to cleanup.
///
/// This function is spawned as a tokio task for each session. It:
/// 1. Generates a keypair and QR data for pairing
/// 2. Connects to the relay and waits for the phone to pair
/// 3. Runs the bridge loop (relay messages + hooks)
/// 4. Cleans up on exit
pub async fn run_session(
    session_id: String,
    relay_url: String,
    manager: SharedBridgeManager,
    mut cmd_rx: mpsc::Receiver<SessionCommand>,
) {
    tracing::info!("Session {} starting", &session_id[..8.min(session_id.len())]);

    match run_session_inner(&session_id, &relay_url, &manager, &mut cmd_rx).await {
        Ok(()) => {
            tracing::info!("Session {} finished cleanly", &session_id[..8.min(session_id.len())]);
        }
        Err(e) => {
            tracing::error!("Session {} error: {}", &session_id[..8.min(session_id.len())], e);
            let mut mgr = manager.write().await;
            mgr.update_status(&session_id, SessionStatus::Error(format!("{}", e)));
        }
    }

    // Always ensure session is marked disconnected on exit
    {
        let mut mgr = manager.write().await;
        if let Some(session) = mgr.get_session_mut(&session_id) {
            if !matches!(session.status, SessionStatus::Error(_)) {
                session.status = SessionStatus::Disconnected;
            }
            session.claude_authenticated = false;
        }
    }

    // Rules injected via --append-system-prompt — no cleanup needed.

    tracing::info!("Session {} ended", &session_id[..8.min(session_id.len())]);
}

async fn run_session_inner(
    session_id: &str,
    relay_url: &str,
    manager: &SharedBridgeManager,
    cmd_rx: &mut mpsc::Receiver<SessionCommand>,
) -> Result<()> {
    // Crash recovery: load (but don't delete yet) a saved Claude session ID.
    // The file is deleted only after Claude successfully spawns with --resume,
    // so relay failures don't discard the resume capability.
    let resume_claude_sid = storage::load_claude_session_id(session_id);
    if let Some(ref sid) = resume_claude_sid {
        tracing::info!("[{}] Crash recovery: will resume Claude session {}",
            &session_id[..8.min(session_id.len())], &sid[..8.min(sid.len())]);
    }

    // ── Prepare Claude spawn inputs BEFORE pairing ──────────────────────
    // env_vars and rules_file are needed by the spawn future, so we set
    // them up eagerly. The spawn itself is kicked off in parallel with
    // relay pairing to save 2-5 s of startup latency.
    let working_dir = std::env::var("HOME")
        .unwrap_or_else(|_| "/tmp".to_string());
    let outbox = crate::file_transfer::protocol::outbox_dir(session_id)
        .map(|p| p.display().to_string())
        .unwrap_or_default();
    let received = crate::file_transfer::protocol::received_dir(session_id)
        .map(|p| p.display().to_string())
        .unwrap_or_default();
    let env_vars: Vec<(String, String)> = vec![
        ("TERMOPUS_SESSION_ID".to_string(), session_id.to_string()),
        ("TERMOPUS_OUTBOX".to_string(), outbox),
        ("TERMOPUS_RECEIVED".to_string(), received),
    ];
    let rules = crate::hooks::config::build_termopus_rules();
    let rules_file = format!("/tmp/termopus-rules-{}.md", &session_id[..12.min(session_id.len())]);
    if let Err(e) = std::fs::write(&rules_file, &rules) {
        tracing::error!("Failed to write rules file {}: {}", rules_file, e);
    }

    // Spawn Claude immediately — before relay connect + pairing.
    // StreamJsonSession::spawn() forks the child process and returns fast,
    // but the `claude` binary takes 2-5 s to initialize internally.
    // By spawning here, Claude warms up in the background while we connect
    // to the relay and wait for the phone to pair — saving that startup time.
    let stream_session = match StreamJsonSession::spawn(
        &working_dir,
        resume_claude_sid.as_deref(),
        env_vars,
        Some(&rules_file),
    ).await {
        Ok(sjs) => {
            tracing::info!("[{}] Stream-JSON session spawned (warming up during pairing)",
                &session_id[..12.min(session_id.len())]);
            // Single-use: delete .claude_sid now that Claude spawned successfully.
            // A fresh one will be re-saved after the Init event.
            if resume_claude_sid.is_some() {
                storage::clear_claude_session_id(session_id);
                tracing::info!("[{}] Consumed crash recovery file (single-use)",
                    &session_id[..12.min(session_id.len())]);
            }
            sjs
        }
        Err(e) => {
            tracing::error!("[{}] Failed to spawn stream-json session: {}",
                &session_id[..12.min(session_id.len())], e);
            return Err(e);
        }
    };

    // Generate keypair and QR data
    let keypair = SessionKeyPair::generate();

    let computer_name = hostname::get()
        .ok()
        .and_then(|h| h.into_string().ok())
        .unwrap_or_else(|| "Computer".to_string());

    let qr_data = serde_json::json!({
        "v": 1,
        "relay": relay_url,
        "session": session_id,
        "pubkey": keypair.public_key_base64(),
        "exp": chrono::Utc::now().timestamp() + 300,
        "name": computer_name,
    });

    // Update manager with QR data and pairing status
    {
        let mut mgr = manager.write().await;
        if let Some(session) = mgr.get_session_mut(session_id) {
            session.qr_data = Some(qr_data.to_string());
            session.status = SessionStatus::WaitingForPairing;
        }
    }

    // Connect to relay
    let mut client = RelayClient::new(relay_url, session_id, Some(keypair)).await?;

    // Wait for phone's public key (pairing)
    let phone_public_key = client.wait_for_pairing().await?;

    // Derive shared secret for E2E encryption
    client.derive_shared_secret(&phone_public_key)?;

    // Save session config to disk
    {
        use base64::Engine as _;
        let peer_key_b64 =
            base64::engine::general_purpose::STANDARD.encode(&phone_public_key);
        let session_config = SessionConfig {
            id: session_id.to_string(),
            relay: relay_url.to_string(),
            peer_public_key: peer_key_b64,
            created_at: chrono::Utc::now(),
        };
        let _ = storage::save_session(&session_config);
        let _ = storage::set_last_active_session(Some(session_id));
    }

    // Update status to connected
    {
        let mut mgr = manager.write().await;
        mgr.update_status(session_id, SessionStatus::Connected);
    }

    // Run preflight check
    let preflight = crate::setup::preflight_check().await;
    if !preflight.is_ready() {
        let issues: Vec<(String, String)> = preflight.fix_instructions();

        {
            let mut mgr = manager.write().await;
            if let Some(session) = mgr.get_session_mut(session_id) {
                session.setup_issues = issues;
            }
        }

        // Wait for setup issues to be resolved
        // Keep WebSocket alive while waiting
        let mut interval = tokio::time::interval(Duration::from_millis(500));
        let mut setup_succeeded = false;

        loop {
            tokio::select! {
                _ = interval.tick() => {
                    // Re-check preflight periodically
                    let new_preflight = crate::setup::preflight_check().await;
                    if new_preflight.is_ready() {
                        setup_succeeded = true;
                        break;
                    } else {
                        let issues = new_preflight.fix_instructions();
                        let mut mgr = manager.write().await;
                        if let Some(session) = mgr.get_session_mut(session_id) {
                            session.setup_issues = issues;
                        }
                    }
                }
                msg = client.receive_message() => {
                    match msg {
                        Ok(_) => { /* Keep alive */ }
                        Err(e) => {
                            tracing::warn!("WebSocket error during setup: {}", e);
                            anyhow::bail!("Connection lost during setup: {}", e);
                        }
                    }
                }
                cmd = cmd_rx.recv() => {
                    match cmd {
                        Some(SessionCommand::Terminate) | Some(SessionCommand::Shutdown) | None => {
                            return Ok(());
                        }
                        _ => {}
                    }
                }
            }
        }

        if !setup_succeeded {
            anyhow::bail!("Setup did not complete");
        }

        // Clear setup issues
        {
            let mut mgr = manager.write().await;
            if let Some(session) = mgr.get_session_mut(session_id) {
                session.setup_issues.clear();
            }
        }
    }

    // Mark authenticated immediately — claude -p with --input-format stream-json
    // doesn't emit the init event until it receives the first user message.
    // The phone needs claude_authenticated=true to show the chat UI.
    // Full capabilities (model, tools, etc.) arrive with the Init event
    // after the first message is sent.
    {
        let mut mgr = manager.write().await;
        if let Some(session) = mgr.get_session_mut(session_id) {
            session.claude_authenticated = true;
        }
    }

    // Run bridge loop
    run_bridge_loop(session_id, client, manager, cmd_rx, resume_claude_sid, stream_session).await
}

/// The main bridge loop: connects Claude Code process to relay messages.
async fn run_bridge_loop(
    session_id: &str,
    mut client: RelayClient,
    manager: &SharedBridgeManager,
    cmd_rx: &mut mpsc::Receiver<SessionCommand>,
    resume_claude_sid: Option<String>,
    stream_session_init: StreamJsonSession,
) -> Result<()> {
    tracing::info!("[{}] Starting bridge loop (stream-json)", &session_id[..12.min(session_id.len())]);

    // Set up hook watcher
    let (hook_dir, _hook_watcher, mut hook_rx) =
        match crate::hooks::HookDirectory::new(session_id) {
            Ok(dir) => match crate::hooks::watcher::HookWatcher::start(&dir) {
                Ok((watcher, rx)) => (Some(dir), Some(watcher), Some(rx)),
                Err(e) => {
                    tracing::warn!("Failed to start hook watcher: {}", e);
                    (None, None, None)
                }
            },
            Err(e) => {
                tracing::warn!("Failed to create hook directory: {}", e);
                (None, None, None)
            }
        };

    // File transfer manager (per-session directories)
    let mut file_manager = FileTransferManager::new(session_id);
    let mut http_proxy: Option<HttpProxy> = None;
    // Channel for HTTP proxy responses (spawned tasks → select loop).
    let (proxy_tx, mut proxy_rx) = tokio::sync::mpsc::channel::<RelayMessage>(32);

    // Set up outbox watcher (computer -> phone file transfer)
    // Uses a 2-second debounce to batch multiple files arriving in quick succession.
    // Rules: 1–3 files → send individually, 4+ files → auto-zip, directories → always zip.
    let outbox_dir = crate::file_transfer::protocol::outbox_dir(session_id);
    // Create directory BEFORE watcher to avoid false Create events
    if let Some(ref dir) = outbox_dir {
        let _ = std::fs::create_dir_all(dir);
    }
    let outbox_startup_time = Instant::now();
    let (outbox_tx, mut outbox_rx) = mpsc::channel::<std::path::PathBuf>(32);
    let _outbox_watcher = if let Some(ref dir) = outbox_dir {
        use notify::{Watcher, RecursiveMode, event::EventKind};
        let tx = outbox_tx.clone();
        let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            if let Ok(event) = res {
                if matches!(event.kind, EventKind::Create(_)) {
                    for path in event.paths {
                        // Skip temp zip files we create ourselves
                        if path.file_name().map(|n| n.to_string_lossy().starts_with("_termopus_")).unwrap_or(false) {
                            continue;
                        }
                        if path.is_file() || path.is_dir() {
                            let _ = tx.blocking_send(path);
                        }
                    }
                }
            }
        }).ok();
        if let Some(ref mut w) = watcher {
            let _ = w.watch(dir, RecursiveMode::NonRecursive);
        }
        watcher
    } else {
        None
    };
    // Pending outbox paths collected during debounce window.
    let mut outbox_pending: Vec<std::path::PathBuf> = Vec::new();
    let mut outbox_debounce: Option<tokio::time::Instant> = None;


    // Track phone peer connection state for message queuing.
    // Starts true because the PeerConnected message is consumed during
    // wait_for_pairing() — if we got here, the peer is already connected.
    let mut peer_connected = true;

    // Queue for FileOffer messages that couldn't be delivered while peer was offline.
    // When peer reconnects, we flush these offers so the phone receives them.
    let mut pending_offers: Vec<crate::parser::ParsedMessage> = Vec::new();

    let mut last_ctrl_c_time = Instant::now() - Duration::from_secs(10);
    let mut current_permission_mode = String::from("default");
    let mut current_model = String::new();
    let mut respawning = false;

    // Track whether the initial device authentication has completed.
    // Used to distinguish first-time auth (no rekey needed) from reconnect auth
    // (trigger key renegotiation for per-connection forward secrecy).
    let mut initial_auth_done = false;

    // Stream-JSON session — spawned in parallel with pairing by run_session_inner.
    let mut stream_session = stream_session_init;

    // Stream-JSON thinking state machine
    let mut thinking_since: Option<Instant> = None;
    let mut total_output_tokens: u64 = 0;
    let mut context_window: u64 = 200_000; // Updated from init event
    let mut total_input_tokens: u64 = 0;
    let mut cache_read_tokens: u64 = 0;
    let mut cache_creation_tokens: u64 = 0;
    let mut session_cost_usd: f64 = 0.0;
    let mut sj_permission_denials: Vec<String> = Vec::new();
    // Claude's internal session_id (learned from Init event). Used for IPC symlink cleanup.
    // Pre-seed from crash recovery so catchup works before the first Init event.
    let mut claude_session_id: Option<String> = resume_claude_sid.clone();

    // Maps request_id -> (tool_name, tool_input, created_at) for pending PreToolUse events.
    // Uses IndexMap for FIFO eviction (oldest first) when the cap is reached.
    // Entries are removed on ActionResponse (allow/deny/always), timeout, or eviction.
    let mut pending_pretool_events: indexmap::IndexMap<String, (String, serde_json::Value, Instant)> = indexmap::IndexMap::new();

    // Session-scoped tool allow list (NOT persisted to settings.local.json).
    // Matches Claude Code behavior: Edit/Write/Task "Always" = session only.
    // Bash "Always" = permanent (written to settings.local.json separately).
    let mut session_allow_tools: std::collections::HashSet<String> = std::collections::HashSet::new();

    // Browser tunnel permission: session-scoped auto-allow (set by "Always" button).
    let mut browser_tunnel_always_allow = false;
    // Port waiting for user's tunnel permission response.
    let mut pending_tunnel_port: Option<u16> = None;

    // Pending device authorization approvals — maps fingerprint -> request time.
    // When a new device connects, the bridge forwards the request to the phone.
    // If the phone doesn't respond within 30 seconds, the device is denied (fail-closed).
    let mut pending_device_approvals: std::collections::HashMap<String, Instant> = std::collections::HashMap::new();
    const DEVICE_APPROVAL_TIMEOUT_SECS: u64 = 30;

    // Pending AskUserQuestion — stores request_id while waiting for user's answer.
    // When set, the next ReceivedMessage::Text is treated as the answer (not a new prompt).
    let mut pending_ask_request_id: Option<String> = None;

    // Respawn retry limiter: prevents infinite restart loops when Claude keeps exiting.
    // Reset to 0 on every successful Init event.
    let mut consecutive_respawn_failures: u32 = 0;
    const MAX_RESPAWN_RETRIES: u32 = 3;
    // True when Claude exited and max retries exceeded. Next user message spawns fresh.
    let mut claude_dead = false;

    // Accumulates all assistant response text for the current turn.
    // Scanned for port numbers at end-of-turn (Result event) to catch cases where
    // the port isn't in the Bash command/output (e.g. `python3 server.py`).
    let mut turn_response_text = String::new();
    let mut turn_used_bash = false;

    // ── Handoff state ──
    let mut handed_off = false;
    let mut terminal_child: Option<tokio::process::Child> = None;
    let mut transcript_watcher_stop: Option<tokio::sync::oneshot::Sender<()>> = None;
    let mut transcript_watcher_rx: Option<tokio::sync::mpsc::Receiver<crate::session::transcript_watcher::WatcherMessage>> = None;

    // Text buffer — accumulates token-by-token deltas, flushed every 500ms.
    let mut text_buffer = String::new();
    // Local flag: tracks whether we've sent the Thinking→Responding transition
    // for the current turn. Avoids acquiring the manager RwLock on every TextDelta
    // token (hundreds per response). Reset on Result / AssistantMessage events.
    let mut text_delta_streaming = false;
    let mut text_flush_interval = tokio::time::interval(Duration::from_millis(500));
    text_flush_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    // Thinking status ticker — updates elapsed time / token count every 1s.
    let mut thinking_ticker = tokio::time::interval(Duration::from_secs(1));
    thinking_ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    // PreToolUse timeout cleanup — evicts stale entries every 30s.
    let mut pretool_cleanup = tokio::time::interval(Duration::from_secs(30));

    // ── WS reconnect state (non-blocking backoff) ──
    const MAX_BACKOFF_SECS: u64 = 30;
    let mut reconnect_deadline: Option<tokio::time::Instant> = None;
    let mut reconnect_attempt: usize = 0;
    let mut send_failed = false;

    loop {
        if send_failed {
            tracing::warn!("[{}] Send failure detected, triggering reconnect",
                &session_id[..12.min(session_id.len())]);
            send_failed = false;
            reconnect_deadline = Some(tokio::time::Instant::now() + Duration::from_millis(100));
            continue;
        }

        tokio::select! {
            // Branch: WS reconnect timer fired — attempt reconnect
            _ = async {
                match reconnect_deadline {
                    Some(deadline) => tokio::time::sleep_until(deadline).await,
                    None => std::future::pending().await,
                }
            } => {
                reconnect_deadline = None;
                match client.reconnect().await {
                    Ok(()) => {
                        tracing::info!("[{}] Reconnected to relay", &session_id[..12.min(session_id.len())]);
                        reconnect_attempt = 0;
                    }
                    Err(re) => {
                        reconnect_attempt += 1;
                        let base_secs = std::cmp::min(
                            1u64.checked_shl(reconnect_attempt as u32).unwrap_or(MAX_BACKOFF_SECS),
                            MAX_BACKOFF_SECS,
                        );
                        let jitter: f64 = rand::thread_rng().gen_range(0.0..0.5);
                        let delay = Duration::from_secs_f64(base_secs as f64 * (1.0 + jitter));
                        tracing::warn!("[{}] Reconnect attempt {} failed: {}", &session_id[..12.min(session_id.len())], reconnect_attempt, re);
                        tracing::info!("[{}] Reconnect attempt {} in {:.1}s",
                            &session_id[..12.min(session_id.len())], reconnect_attempt + 1, delay.as_secs_f64());
                        reconnect_deadline = Some(tokio::time::Instant::now() + delay);
                    }
                }
            }

            // Branch 2: relay messages from phone (disabled during reconnect backoff)
            message = client.receive_message(), if reconnect_deadline.is_none() => {
                use crate::relay::websocket::ReceivedMessage;
                match message {
                    Ok(msg) => {
                        // If Claude died after max retries and user sends a text,
                        // do a fresh spawn (no --resume) and forward the message.
                        if claude_dead {
                            if let ReceivedMessage::Text(ref text) = msg {
                                tracing::info!("Claude dead — fresh spawn on user message");
                                claude_dead = false;
                                consecutive_respawn_failures = 0;
                                // Respawn without --resume (fresh session)
                                match stream_session.respawn_with_session(
                                    None::<&str>.or(claude_session_id.as_deref()), None, None
                                ).await {
                                    Ok(()) => {
                                        let _ = stream_session.send_message(text).await;
                                    }
                                    Err(e) => {
                                        tracing::error!("Failed fresh spawn: {}", e);
                                        let notify = crate::parser::ParsedMessage::System {
                                            content: format!("Failed to start Claude Code: {}", e),
                                        };
                                        let _ = client.send_message(&notify).await;
                                    }
                                }
                                continue;
                            }
                        }
                        if respawning {
                            tracing::warn!("Blocked input while Claude is respawning");
                            let notify = crate::parser::ParsedMessage::System {
                                content: "Input blocked — Claude Code is restarting...".to_string(),
                            };
                            let _ = client.send_message(&notify).await;
                            continue;
                        }
                        let result = match &msg {
                            ReceivedMessage::Text(text) => {
                                // AskUserQuestion answer: user picked an option on the phone.
                                // Deny the PreToolUse (tool can't execute in -p mode) with
                                // the user's answer in the reason so Claude gets the response.
                                if let Some(req_id) = pending_ask_request_id.take() {
                                    if let Some(ref dir) = hook_dir {
                                        let reason = format!(
                                            "User answered via mobile: {}",
                                            text
                                        );
                                        let response = crate::hooks::PreToolUseResponse::deny(&reason);
                                        if let Err(e) = dir.write_pre_tool_response(&req_id, &response) {
                                            tracing::error!("Failed to write AskUserQuestion answer: {}", e);
                                        } else {
                                            tracing::info!("AskUserQuestion answered: {} (request_id={})", text, req_id);
                                        }
                                    }
                                    manager.write().await.append_event_line(
                                        session_id, &format!("{} User: answered question: \"{}\"", event_ts(), text));
                                    Ok(())
                                // Block /exit and /quit — they would exit Claude and expose shell
                                } else if is_blocked_text(text) {
                                    tracing::warn!("SECURITY: Blocked exit command from phone: {:?}", text);
                                    let notify = crate::parser::ParsedMessage::System {
                                        content: "The /exit command is disabled on mobile for security.".to_string(),
                                    };
                                    let _ = client.send_message(&notify).await;
                                    Ok(())
                                // ── Handoff to computer ──
                                } else if text.trim() == "handoff" && !handed_off {
                                    tracing::info!("[{}] Handoff to computer requested", &session_id[..12.min(session_id.len())]);
                                    let csid = claude_session_id.clone()
                                        .or_else(|| stream_session.session_id().map(|s| s.to_string()));
                                    if let Some(ref csid) = csid {
                                        // Validate session ID is safe for osascript interpolation (UUID chars only)
                                        let is_safe_id = csid.chars().all(|c| c.is_ascii_hexdigit() || c == '-');
                                        if !is_safe_id {
                                            tracing::error!("[{}] Invalid session ID for handoff: {:?}", &session_id[..12.min(session_id.len())], csid);
                                            let msg = crate::parser::ParsedMessage::System {
                                                content: "Cannot handoff — invalid session ID".to_string(),
                                            };
                                            let _ = client.send_message(&msg).await;
                                            return Ok(());
                                        }

                                        let _ = stream_session.kill().await;
                                        handed_off = true;
                                        // Update live state and send to phone
                                        {
                                            let json = manager.write().await.update_live_state(session_id, |ls| {
                                                ls.claude_status = crate::session::manager::ClaudeStatus::HandedOff;
                                                ls.last_activity = "Handed off to computer".to_string();
                                            });
                                            if let Some(ref j) = json {
                                                let _ = client.send_raw_json(j).await;
                                            }
                                        }
                                        // Launch interactive terminal via osascript
                                        let resume_cmd = format!("claude --resume {}", csid);
                                        let apple_script = format!(
                                            "tell application \"Terminal\" to do script \"{}\"",
                                            resume_cmd
                                        );
                                        match tokio::process::Command::new("osascript")
                                            .args(["-e", &apple_script])
                                            .spawn()
                                        {
                                            Ok(child) => {
                                                terminal_child = Some(child);
                                                tracing::info!("[{}] Terminal launched: {}", &session_id[..12.min(session_id.len())], resume_cmd);
                                            }
                                            Err(e) => {
                                                tracing::error!("[{}] Failed to launch terminal: {}", &session_id[..12.min(session_id.len())], e);
                                            }
                                        }
                                        // Start transcript watcher
                                        if let Some(transcript_path) = crate::session::transcript::find_transcript(csid) {
                                            let (stop_tx, stop_rx) = tokio::sync::oneshot::channel();
                                            let rx = crate::session::transcript_watcher::watch_transcript(transcript_path, stop_rx);
                                            transcript_watcher_stop = Some(stop_tx);
                                            transcript_watcher_rx = Some(rx);
                                        }
                                        // Notify phone
                                        let handoff_msg = serde_json::json!({
                                            "type": "HandoffActive",
                                            "sessionId": session_id,
                                            "claudeSessionId": csid,
                                            "command": resume_cmd,
                                        });
                                        let _ = client.send_raw_json(&handoff_msg).await;
                                    } else {
                                        let msg = crate::parser::ParsedMessage::System {
                                            content: "Cannot handoff — no active Claude session".to_string(),
                                        };
                                        let _ = client.send_message(&msg).await;
                                    }
                                    Ok(())
                                // ── Take back from computer ──
                                } else if text.trim() == "takeback" && handed_off {
                                    tracing::info!("[{}] Take back control requested", &session_id[..12.min(session_id.len())]);
                                    // Stop transcript watcher
                                    if let Some(stop) = transcript_watcher_stop.take() {
                                        let _ = stop.send(());
                                    }
                                    transcript_watcher_rx = None;
                                    // Kill terminal process (best effort)
                                    if let Some(mut child) = terminal_child.take() {
                                        let _ = child.kill().await;
                                    }
                                    // Kill any interactive claude --resume processes (only if we have a valid session ID)
                                    if let Some(ref csid) = claude_session_id {
                                        let _ = tokio::process::Command::new("pkill")
                                            .args(["-f", &format!("claude --resume {}", csid)])
                                            .status()
                                            .await;
                                    }
                                    // Respawn stream-json
                                    handed_off = false;
                                    let resume_id = claude_session_id.clone();
                                    match stream_session.respawn_with_session(resume_id.as_deref(), None, None).await {
                                        Ok(()) => {
                                            tracing::info!("[{}] Take back: stream-json respawned", &session_id[..12.min(session_id.len())]);
                                            // Update live state back to Idle and send to phone
                                            {
                                                let json = manager.write().await.update_live_state(session_id, |ls| {
                                                    ls.claude_status = crate::session::manager::ClaudeStatus::Idle;
                                                    ls.last_activity = "Took back control".to_string();
                                                });
                                                if let Some(ref j) = json {
                                                    let _ = client.send_raw_json(j).await;
                                                }
                                            }
                                            // Send catchup
                                            if let Some(ref csid) = claude_session_id {
                                                let csid_clone = csid.clone();
                                                let messages = tokio::task::spawn_blocking(move || {
                                                    crate::session::transcript::read_transcript_tail(&csid_clone, 20)
                                                }).await.unwrap_or_default();
                                                if !messages.is_empty() {
                                                    let catchup = serde_json::json!({
                                                        "type": "Catchup",
                                                        "sessionId": session_id,
                                                        "messages": messages,
                                                    });
                                                    let _ = client.send_raw_json(&catchup).await;
                                                }
                                            }
                                            // Notify phone
                                            let takeback_msg = serde_json::json!({
                                                "type": "HandoffEnded",
                                                "sessionId": session_id,
                                            });
                                            let _ = client.send_raw_json(&takeback_msg).await;
                                        }
                                        Err(e) => {
                                            tracing::error!("[{}] Take back failed: {}", &session_id[..12.min(session_id.len())], e);
                                            let msg = crate::parser::ParsedMessage::System {
                                                content: format!("Failed to resume session: {}", e),
                                            };
                                            let _ = client.send_message(&msg).await;
                                        }
                                    }
                                    Ok(())
                                } else if handed_off {
                                    // During handoff, stream-json is killed — ignore non-command text
                                    tracing::debug!("[{}] Ignoring text during handoff: {:?}",
                                        &session_id[..12.min(session_id.len())], &text[..60.min(text.len())]);
                                    Ok(())
                                } else {
                                    // GUI event monitor — show user input
                                    let preview: String = text.chars().take(60).collect();
                                    let ellipsis = if text.len() > 60 { "..." } else { "" };
                                    manager.write().await.append_event_line(
                                        session_id, &format!("{} User: \"{}{}\"", event_ts(), preview, ellipsis));
                                    stream_session.send_message(text).await
                                }
                            }
                            ReceivedMessage::RawInput(input) => {
                                // Block dangerous control sequences and exit commands
                                if is_dangerous_key(input) {
                                    tracing::warn!("SECURITY: Blocked dangerous raw input: {}", input);
                                    Ok(())
                                } else if is_blocked_text(input) {
                                    tracing::warn!("SECURITY: Blocked exit text via raw input: {:?}", input);
                                    Ok(())
                                } else {
                                    Ok(()) // stream-json doesn't use raw input
                                }
                            }
                            ReceivedMessage::Key(_) => {
                                // Stream-json key handling:
                                // - C-c: interrupt() sends SIGINT
                                // - Escape: treated as C-c (Stop) by the phone UI
                                // - Other keys: silently dropped (stream-json has no PTY)
                                if let Some(key_name) = msg.as_key_input() {
                                    if is_dangerous_key(&key_name) {
                                        tracing::warn!("SECURITY: Blocked dangerous key: {}", key_name);
                                        Ok(())
                                    } else if key_name == "C-c" || key_name == "Escape" {
                                        // Clear pending AskUserQuestion — the tool call is being cancelled
                                        pending_ask_request_id = None;
                                        // Clear thinking indicator so phone doesn't stay stuck.
                                        // Empty Thinking status removes the spinner on the phone.
                                        thinking_since = None;
                                        let clear_thinking = crate::parser::ParsedMessage::Thinking {
                                            status: String::new(),
                                        };
                                        let _ = client.send_message(&clear_thinking).await;
                                        // Rate-limit Ctrl+C to max 1 per 3 seconds.
                                        if last_ctrl_c_time.elapsed() > Duration::from_secs(3) {
                                            last_ctrl_c_time = Instant::now();
                                            stream_session.interrupt().map_err(|e| anyhow::anyhow!("{}", e))
                                        } else {
                                            tracing::debug!("Rate-limited Ctrl+C (too fast)");
                                            Ok(())
                                        }
                                    } else {
                                        Ok(()) // stream-json has no PTY for other keys
                                    }
                                } else {
                                    Ok(())
                                }
                            }
                            ReceivedMessage::ActionResponse { ref action_id, ref response } => {
                                if action_id.starts_with("ptool-") {
                                    // PreToolUse-originated action — write PreToolUseResponse
                                    let request_id = &action_id["ptool-".len()..];
                                    let resp_lower = response.to_lowercase();
                                    let is_allow = matches!(resp_lower.as_str(), "allow" | "always" | "yes" | "y");
                                    let is_always = resp_lower == "always";

                                    let ptool_response = if is_allow {
                                        crate::hooks::PreToolUseResponse::allow()
                                    } else {
                                        crate::hooks::PreToolUseResponse::deny("Denied by phone user")
                                    };

                                    if let Some(ref dir) = hook_dir {
                                        if let Err(e) = dir.write_pre_tool_response(request_id, &ptool_response) {
                                            tracing::error!("Failed to write PreToolUse response: {}", e);
                                        }
                                    }

                                    // "Always" — Bash: persist to settings.local.json (permanent).
                                    //            Other tools: session-scoped only (matches Claude Code behavior).
                                    if is_always {
                                        if let Some((tool_name, tool_input, _)) = pending_pretool_events.shift_remove(request_id) {
                                            if tool_name == "Bash" {
                                                // Bash: write command-family rule to settings.local.json
                                                let rule = crate::hooks::permissions::build_rule_for_tool(&tool_name, &tool_input);
                                                match crate::hooks::permissions::add_allow_rule(&rule) {
                                                    Ok(()) => {
                                                        tracing::info!("Added permanent Bash rule: {}", rule);
                                                        let msg = crate::parser::ParsedMessage::System {
                                                            content: format!("Permission rule added: {}", rule),
                                                        };
                                                        let _ = client.send_message(&msg).await;
                                                        // Sync updated rules to phone
                                                        let (allow, deny) = crate::hooks::permissions::read_rules();
                                                        let _ = client.send_message(&crate::parser::ParsedMessage::PermissionRulesSync {
                                                            allow, deny,
                                                        }).await;
                                                    }
                                                    Err(e) => tracing::error!("Failed to add rule: {}", e),
                                                }
                                            } else {
                                                // Non-Bash (Edit, Write, Task, etc.): session-scoped only.
                                                // Bridge auto-responds to future PreToolUse for this tool.
                                                session_allow_tools.insert(tool_name.clone());
                                                tracing::info!("Added session-scoped allow: {}", tool_name);
                                                let msg = crate::parser::ParsedMessage::System {
                                                    content: format!("Allowed {} for this session", tool_name),
                                                };
                                                let _ = client.send_message(&msg).await;
                                            }
                                        }
                                    } else {
                                        pending_pretool_events.shift_remove(request_id);
                                    }

                                    // GUI event monitor
                                    let decision = if is_always { "always-allow" } else if is_allow { "allow" } else { "deny" };
                                    manager.write().await.append_event_line(
                                        session_id, &format!("{} Phone: {} (PreToolUse)", event_ts(), decision));
                                    Ok(())
                                } else if action_id.starts_with("tunnel-") {
                                    // Browser tunnel permission response
                                    let resp_lower = response.to_lowercase();
                                    match resp_lower.as_str() {
                                        "allow" => {
                                            if let Some(port) = pending_tunnel_port.take() {
                                                tracing::info!("Tunnel allowed for port {}", port);
                                                http_proxy = Some(HttpProxy::new(port));
                                                let _ = client.send_relay_message(&RelayMessage::HttpTunnelStatus {
                                                    active: true,
                                                    port: Some(port),
                                                    error: None,
                                                }).await;
                                            }
                                        }
                                        "always" => {
                                            if let Some(port) = pending_tunnel_port.take() {
                                                tracing::info!("Tunnel always-allowed for port {}", port);
                                                browser_tunnel_always_allow = true;
                                                http_proxy = Some(HttpProxy::new(port));
                                                let _ = client.send_relay_message(&RelayMessage::HttpTunnelStatus {
                                                    active: true,
                                                    port: Some(port),
                                                    error: None,
                                                }).await;
                                                let msg = crate::parser::ParsedMessage::System {
                                                    content: "Browser tunnel auto-allowed for this session".to_string(),
                                                };
                                                let _ = client.send_message(&msg).await;
                                            }
                                        }
                                        _ => {
                                            tracing::info!("Tunnel denied");
                                            pending_tunnel_port = None;
                                            let msg = crate::parser::ParsedMessage::System {
                                                content: "Browser tunnel declined".to_string(),
                                            };
                                            let _ = client.send_message(&msg).await;
                                        }
                                    }
                                    manager.write().await.append_event_line(
                                        session_id, &format!("{} Phone: {} (tunnel)", event_ts(), resp_lower));
                                    Ok(())
                                } else if action_id.starts_with("device-approve-") {
                                    // Device authorization response from phone
                                    let fingerprint = &action_id["device-approve-".len()..];
                                    let resp_lower = response.to_lowercase();
                                    let authorized = matches!(resp_lower.as_str(), "approve" | "allow" | "yes" | "y");

                                    // Remove from pending (prevents timeout from also denying)
                                    pending_device_approvals.remove(fingerprint);

                                    if let Err(e) = client.send_device_authorize_response(fingerprint, authorized).await {
                                        tracing::error!("Failed to send device_authorize_response: {}", e);
                                        let err_msg = crate::parser::ParsedMessage::System {
                                            content: "Failed to send device authorization — connection may need to be retried".to_string(),
                                        };
                                        let _ = client.send_message(&err_msg).await;
                                    }

                                    let decision = if authorized { "approved" } else { "denied" };
                                    let short_fp = &fingerprint[..16.min(fingerprint.len())];
                                    let msg = crate::parser::ParsedMessage::System {
                                        content: format!("Device {} — fingerprint: {}…", decision, short_fp),
                                    };
                                    let _ = client.send_message(&msg).await;

                                    manager.write().await.append_event_line(
                                        session_id, &format!("{} Phone: device {} ({}…)", event_ts(), decision, short_fp));
                                    tracing::info!("[{}] Device {} by phone: {}…",
                                        &session_id[..12.min(session_id.len())], decision, short_fp);
                                    Ok(())
                                } else {
                                    Ok(()) // Unknown action prefix — no-op
                                }
                            }
                            ReceivedMessage::Command { command, args } => {
                                // Block /exit and /quit — they would expose raw shell
                                let cmd_lower = command.to_lowercase();
                                if cmd_lower.starts_with("exit") || cmd_lower.starts_with("quit") {
                                    tracing::warn!("SECURITY: Blocked /{} command from phone", command);
                                    let notify = crate::parser::ParsedMessage::System {
                                        content: format!("The /{} command is disabled on mobile for security.", command),
                                    };
                                    let _ = client.send_message(&notify).await;
                                    Ok(())
                                } else if cmd_lower == "permissions" {
                                    // Permission mode switching via Shift+Tab (BTab).
                                    // Claude Code's Shift+Tab cycles: default → acceptEdits → plan → default
                                    // We calculate how many BTab presses to reach the target mode.
                                    let target = args.as_deref()
                                        .and_then(|a| a.strip_prefix("set "))
                                        .unwrap_or("default")
                                        .trim();

                                    let presses = btab_presses_needed(&current_permission_mode, target);
                                    if presses == 0 {
                                        tracing::info!("Already in mode {}, no BTab needed", target);
                                    } else if presses > 0 {
                                        // Kill + respawn with --permission-mode
                                        tracing::info!("Switching {} → {} via respawn", current_permission_mode, target);
                                        if let Err(e) = stream_session.respawn(None, Some(target)).await {
                                            tracing::error!("Failed to respawn for permission change: {}", e);
                                        }
                                        // Optimistically update so rapid switches don't miscalculate
                                        current_permission_mode = target.to_string();
                                    } else {
                                        // Negative = mode not in cycle (dontAsk, bypassPermissions)
                                        let notify = crate::parser::ParsedMessage::System {
                                            content: format!("Cannot switch to '{}' mode from the phone. It can only be set at Claude Code startup.", target),
                                        };
                                        let _ = client.send_message(&notify).await;
                                    }
                                    Ok(())
                                } else if cmd_lower == "resume" {
                                    // Resume: if no args, read sessions-index.json and
                                    // send the list to phone for native picker.
                                    // If args contain a session ID, respawn with that session.
                                    if let Some(ref a) = args {
                                        let sid = a.trim();
                                        if !sid.is_empty() {
                                            tracing::info!("[{}] Resuming selected session: {}",
                                                &session_id[..12.min(session_id.len())], &sid[..8.min(sid.len())]);
                                            // Update live state: Respawning
                                            let json = manager.write().await.update_live_state(session_id, |ls| {
                                                ls.claude_status = ClaudeStatus::Respawning;
                                                ls.last_activity = "Resuming session".to_string();
                                            });
                                            if let Some(ref j) = json {
                                                let _ = client.send_raw_json(j).await;
                                            }
                                            // Resolve the session's project directory for correct CWD
                                            if let Some(project_dir) = find_project_dir_for_session(sid) {
                                                tracing::info!("[{}] Resume: setting CWD to {}", &session_id[..12.min(session_id.len())], &project_dir);
                                                stream_session.set_working_dir(project_dir);
                                            }
                                            // Reset retry counter for user-initiated resume
                                            consecutive_respawn_failures = 0;
                                            claude_dead = false;
                                            match stream_session.respawn_with_session(Some(sid), None, None).await {
                                                Ok(()) => {
                                                    // Track the resumed session so auto-restart works
                                                    claude_session_id = Some(sid.to_string());

                                                    // Send conversation history as catchup so phone shows old messages
                                                    let sid_clone = sid.to_string();
                                                    let messages = tokio::task::spawn_blocking(move || {
                                                        crate::session::transcript::read_transcript_tail(&sid_clone, 20)
                                                    }).await.unwrap_or_default();
                                                    if !messages.is_empty() {
                                                        tracing::info!("[{}] Resume catchup: {} messages",
                                                            &session_id[..12.min(session_id.len())], messages.len());
                                                        let catchup = serde_json::json!({
                                                            "type": "Catchup",
                                                            "sessionId": session_id,
                                                            "messages": messages,
                                                        });
                                                        let _ = client.send_raw_json(&catchup).await;
                                                    }
                                                }
                                                Err(e) => {
                                                    tracing::error!("Failed to resume session {}: {}", &sid[..8.min(sid.len())], e);
                                                    let msg = crate::parser::ParsedMessage::System {
                                                        content: format!("Failed to resume session: {}", e),
                                                    };
                                                    let _ = client.send_message(&msg).await;
                                                }
                                            }
                                        }
                                    } else {
                                        let cwd: Option<&str> = None; // CWD comes from Init event
                                        match read_sessions_index(cwd) {
                                            Ok(sessions) => {
                                                let msg = crate::parser::ParsedMessage::SessionList { sessions };
                                                if let Err(e) = client.send_message(&msg).await {
                                                    tracing::error!("Failed to send session list: {}", e);
                                                }
                                            }
                                            Err(e) => {
                                                let msg = crate::parser::ParsedMessage::System {
                                                    content: format!("Could not read sessions: {}", e),
                                                };
                                                let _ = client.send_message(&msg).await;
                                            }
                                        }
                                    }
                                    Ok(())
                                } else if cmd_lower == "plugins" {
                                    match read_plugins() {
                                        Ok(plugins) => {
                                            let msg = crate::parser::ParsedMessage::PluginList { plugins };
                                            if let Err(e) = client.send_message(&msg).await {
                                                tracing::error!("Failed to send plugin list: {}", e);
                                            }
                                        }
                                        Err(e) => {
                                            let msg = crate::parser::ParsedMessage::System {
                                                content: format!("Could not read plugins: {}", e),
                                            };
                                            let _ = client.send_message(&msg).await;
                                        }
                                    }
                                    Ok(())
                                } else if cmd_lower == "skills" {
                                    match read_skills() {
                                        Ok(skills) => {
                                            let msg = crate::parser::ParsedMessage::SkillList { skills };
                                            if let Err(e) = client.send_message(&msg).await {
                                                tracing::error!("Failed to send skill list: {}", e);
                                            }
                                        }
                                        Err(e) => {
                                            let msg = crate::parser::ParsedMessage::System {
                                                content: format!("Could not read skills: {}", e),
                                            };
                                            let _ = client.send_message(&msg).await;
                                        }
                                    }
                                    Ok(())
                                } else if cmd_lower == "rules" {
                                    let cwd: Option<&str> = None; // CWD comes from Init event
                                    match read_rules(cwd) {
                                        Ok(rules) => {
                                            let msg = crate::parser::ParsedMessage::RulesList { rules };
                                            if let Err(e) = client.send_message(&msg).await {
                                                tracing::error!("Failed to send rules list: {}", e);
                                            }
                                        }
                                        Err(e) => {
                                            let msg = crate::parser::ParsedMessage::System {
                                                content: format!("Could not read rules: {}", e),
                                            };
                                            let _ = client.send_message(&msg).await;
                                        }
                                    }
                                    Ok(())
                                } else if cmd_lower == "memory" {
                                    let cwd: Option<&str> = None; // CWD comes from Init event
                                    match read_memory(cwd) {
                                        Ok(entries) => {
                                            let msg = crate::parser::ParsedMessage::MemoryContent { entries };
                                            if let Err(e) = client.send_message(&msg).await {
                                                tracing::error!("Failed to send memory content: {}", e);
                                            }
                                        }
                                        Err(e) => {
                                            let msg = crate::parser::ParsedMessage::System {
                                                content: format!("Could not read memory: {}", e),
                                            };
                                            let _ = client.send_message(&msg).await;
                                        }
                                    }
                                    Ok(())
                                } else if cmd_lower == "permission-rules" {
                                    if let Some(ref args_str) = args {
                                        let parts: Vec<&str> = args_str.splitn(3, ' ').collect();
                                        if parts.first().map(|s| s.to_lowercase()).as_deref() == Some("remove") && parts.len() >= 3 {
                                            let list = parts[1]; // "allow" or "deny"
                                            let rule = parts[2];
                                            if let Err(e) = crate::hooks::permissions::remove_rule(rule, list) {
                                                tracing::error!("Failed to remove rule: {}", e);
                                            }
                                        }
                                    }
                                    // Always respond with current rules
                                    let (allow, deny) = crate::hooks::permissions::read_rules();
                                    let _ = client.send_message(&crate::parser::ParsedMessage::PermissionRulesSync { allow, deny }).await;
                                    Ok(())
                                } else if cmd_lower == "compact" {
                                    // Optimize Chat: respawn with --resume to restart context
                                    let json = manager.write().await.update_live_state(session_id, |ls| {
                                        ls.claude_status = ClaudeStatus::Respawning;
                                        ls.last_activity = "Restarting session".to_string();
                                    });
                                    if let Some(ref j) = json {
                                        let _ = client.send_raw_json(j).await;
                                    }
                                    let msg = crate::parser::ParsedMessage::System {
                                        content: "Restarting session (context will be compacted if needed)...".to_string(),
                                    };
                                    let _ = client.send_message(&msg).await;
                                    consecutive_respawn_failures = 0;
                                    stream_session.respawn(None, Some(&current_permission_mode)).await
                                } else if cmd_lower == "clear" {
                                    // Start Fresh: spawn a brand-new session (no --resume)
                                    let json = manager.write().await.update_live_state(session_id, |ls| {
                                        ls.claude_status = ClaudeStatus::Respawning;
                                        ls.last_activity = "Starting fresh".to_string();
                                    });
                                    if let Some(ref j) = json {
                                        let _ = client.send_raw_json(j).await;
                                    }
                                    let msg = crate::parser::ParsedMessage::System {
                                        content: "Clearing context and starting fresh...".to_string(),
                                    };
                                    let _ = client.send_message(&msg).await;
                                    claude_session_id = None;
                                    storage::clear_claude_session_id(session_id);
                                    // Reset cost counters
                                    session_cost_usd = 0.0;
                                    total_input_tokens = 0;
                                    total_output_tokens = 0;
                                    cache_read_tokens = 0;
                                    cache_creation_tokens = 0;
                                    consecutive_respawn_failures = 0;
                                    stream_session.spawn_fresh(Some(&current_permission_mode)).await
                                } else if cmd_lower == "cost" || cmd_lower == "stats" {
                                    // Statistics: report tracked accumulators (no Claude interaction)
                                    let stats = format!(
                                        "Session Statistics:\n\
                                         Cost: ${:.4}\n\
                                         Input tokens: {}\n\
                                         Output tokens: {}\n\
                                         Cache read: {}\n\
                                         Cache creation: {}\n\
                                         Context window: {}",
                                        session_cost_usd,
                                        total_input_tokens,
                                        total_output_tokens,
                                        cache_read_tokens,
                                        cache_creation_tokens,
                                        context_window,
                                    );
                                    let msg = crate::parser::ParsedMessage::System { content: stats };
                                    let _ = client.send_message(&msg).await;
                                    Ok(())
                                } else if cmd_lower == "rewind" {
                                    // Undo Last: send immediate feedback then ask Claude
                                    let msg = crate::parser::ParsedMessage::System {
                                        content: "Asking Claude to undo...".to_string(),
                                    };
                                    let _ = client.send_message(&msg).await;
                                    stream_session.send_message(
                                        "Undo your last action — revert the most recent code change you made."
                                    ).await
                                } else if cmd_lower == "plan" {
                                    // Plan Mode: send immediate feedback then instruct Claude
                                    let msg = crate::parser::ParsedMessage::System {
                                        content: "Entering plan mode...".to_string(),
                                    };
                                    let _ = client.send_message(&msg).await;
                                    stream_session.send_message(
                                        "Enter plan mode: analyze and create a detailed plan before making any code changes. Do not edit files until I approve the plan."
                                    ).await
                                } else if cmd_lower == "status" {
                                    // Status: report session info (no Claude interaction)
                                    let model_name = stream_session.model().unwrap_or("unknown");
                                    let csid = claude_session_id.as_deref().unwrap_or("none");
                                    let status_msg = format!(
                                        "Session Status:\n\
                                         Session ID: {}\n\
                                         Claude Session: {}\n\
                                         Model: {}\n\
                                         Permission Mode: {}\n\
                                         Cost: ${:.4}",
                                        &session_id[..12.min(session_id.len())],
                                        &csid[..12.min(csid.len())],
                                        model_name,
                                        current_permission_mode,
                                        session_cost_usd,
                                    );
                                    let msg = crate::parser::ParsedMessage::System { content: status_msg };
                                    let _ = client.send_message(&msg).await;
                                    Ok(())
                                } else if cmd_lower == "debug" {
                                    // Debug: forward as-is (harmless)
                                    let cmd = format!("/{}", command);
                                    stream_session.send_message(&cmd).await
                                } else if cmd_lower == "reset_pin" || cmd_lower == "reset_bridge_pin" {
                                    match crate::pin::clear_pin() {
                                        Ok(()) => {
                                            let msg = crate::parser::ParsedMessage::System {
                                                content: "Bridge PIN has been reset. You'll be asked to set a new PIN on next session pairing.".to_string(),
                                            };
                                            let _ = client.send_message(&msg).await;
                                            tracing::info!("Bridge PIN cleared by phone request");
                                        }
                                        Err(e) => {
                                            let msg = crate::parser::ParsedMessage::System {
                                                content: format!("Failed to reset PIN: {}", e),
                                            };
                                            let _ = client.send_message(&msg).await;
                                        }
                                    }
                                    Ok(())
                                } else if cmd_lower == "delete_session" {
                                    // Delete session: kill Claude, clean up storage, exit loop
                                    tracing::info!("[{}] Delete session command received", &session_id[..12.min(session_id.len())]);
                                    let _ = stream_session.kill().await;
                                    storage::clear_claude_session_id(session_id);
                                    let _ = storage::remove_session(session_id);
                                    // Send final live state (exited) before breaking
                                    let json = manager.write().await.update_live_state(session_id, |ls| {
                                        ls.claude_status = ClaudeStatus::Exited;
                                        ls.last_activity = "Session deleted".to_string();
                                    });
                                    if let Some(ref j) = json {
                                        let _ = client.send_raw_json(j).await;
                                    }
                                    manager.write().await.remove_session(session_id);
                                    break;
                                } else if command == "open_folder" {
                                    // Open session file directory on the computer
                                    if let Some(dir) = crate::file_transfer::protocol::session_dir(session_id) {
                                        let _ = std::fs::create_dir_all(&dir);
                                        #[cfg(target_os = "macos")]
                                        let _ = std::process::Command::new("open").arg(&dir).spawn();
                                        #[cfg(target_os = "linux")]
                                        let _ = std::process::Command::new("xdg-open").arg(&dir).spawn();
                                        let msg = crate::parser::ParsedMessage::System {
                                            content: format!("Opened folder: {}", dir.display()),
                                        };
                                        let _ = client.send_message(&msg).await;
                                    }
                                    Ok(())
                                } else if command == "send" {
                                    if let Some(ref path_str) = args {
                                        let path = std::path::Path::new(path_str.trim());
                                        // Validate: path must exist and resolve within the working directory
                                        let allowed_base = std::fs::canonicalize(stream_session.working_dir());
                                        let canonical = std::fs::canonicalize(path);
                                        match (allowed_base, canonical) {
                                            (Ok(base), Ok(resolved)) if resolved.starts_with(&base) => {
                                                let tx_id = uuid::Uuid::new_v4().to_string();
                                                match PreparedFile::from_path(tx_id, &resolved) {
                                                    Ok(prepared) => {
                                                        let offer = file_manager.prepare_send(prepared);
                                                        let _ = client.send_message(&offer).await;
                                                    }
                                                    Err(e) => {
                                                        let msg = crate::parser::ParsedMessage::System {
                                                            content: format!("Failed to read file: {}", e),
                                                        };
                                                        let _ = client.send_message(&msg).await;
                                                    }
                                                }
                                            }
                                            (Ok(_), Ok(_)) => {
                                                let msg = crate::parser::ParsedMessage::System {
                                                    content: "Path is outside the project directory".to_string(),
                                                };
                                                let _ = client.send_message(&msg).await;
                                            }
                                            _ => {
                                                let msg = crate::parser::ParsedMessage::System {
                                                    content: format!("File not found: {}", path_str),
                                                };
                                                let _ = client.send_message(&msg).await;
                                            }
                                        }
                                    }
                                    Ok(())
                                } else {
                                    let cmd = match args {
                                        Some(a) => format!("/{} {}", command, a),
                                        None => format!("/{}", command),
                                    };
                                    stream_session.send_message(&cmd).await
                                }
                            }
                            ReceivedMessage::SetModel { model } => {
                                // Guard: if Claude hasn't started yet (no Init),
                                // just store the desired model for the next spawn.
                                if claude_session_id.is_none() {
                                    tracing::info!("Model set to {} (Claude not started yet, will apply on next spawn)", model);
                                    current_model = model.to_string();
                                    Ok(())
                                } else {
                                    // Update live state: Respawning for model switch
                                    {
                                        let json = manager.write().await.update_live_state(session_id, |ls| {
                                            ls.claude_status = ClaudeStatus::Respawning;
                                            ls.thinking_since = None;
                                            ls.last_activity = "Switching model".to_string();
                                        });
                                        if let Some(ref j) = json {
                                            let _ = client.send_raw_json(j).await;
                                        }
                                    }
                                    current_model = model.to_string();
                                    // Kill + respawn with --model
                                    stream_session.respawn(Some(model), None).await
                                }
                            }
                            ReceivedMessage::Config { key, value } => {
                                let cmd = format!("/config set {} {}", key, value);
                                stream_session.send_message(&cmd).await
                            }
                            ReceivedMessage::PeerConnected => {
                                peer_connected = true;
                                tracing::info!("[{}] Peer connected (waiting for auth)", &session_id[..12.min(session_id.len())]);
                                Ok(())
                            }
                            ReceivedMessage::PhoneAuthenticated => {
                                tracing::info!("[{}] Phone authenticated — sending state", &session_id[..12.min(session_id.len())]);

                                // Send StateSnapshot — current live state in one message
                                {
                                    let snapshot_json = {
                                        let mgr = manager.read().await;
                                        mgr.get_session(session_id).map(|session| {
                                            let mut ss = session.live_state.to_json(session_id);
                                            ss["type"] = serde_json::Value::String("StateSnapshot".to_string());
                                            ss
                                        })
                                    }; // lock dropped here
                                    if let Some(ref ss) = snapshot_json {
                                        if let Err(e) = client.send_raw_json(ss).await {
                                            tracing::error!("[{}] Critical send failed (StateSnapshot): {}", &session_id[..12.min(session_id.len())], e);
                                            send_failed = true;
                                        }
                                    }
                                }

                                // If currently handed off, re-send HandoffActive so phone restores observer mode
                                if handed_off {
                                    if let Some(ref csid) = claude_session_id {
                                        let handoff_msg = serde_json::json!({
                                            "type": "HandoffActive",
                                            "sessionId": session_id,
                                            "claudeSessionId": csid,
                                            "command": format!("claude --resume {}", csid),
                                        });
                                        if let Err(e) = client.send_raw_json(&handoff_msg).await {
                                            tracing::error!("[{}] Critical send failed (HandoffActive): {}", &session_id[..12.min(session_id.len())], e);
                                            send_failed = true;
                                        }
                                    }
                                }

                                // Send Catchup — last 20 messages from Claude's transcript
                                // Use spawn_blocking to avoid stalling the async event loop
                                if let Some(ref csid) = claude_session_id {
                                    let csid_clone = csid.clone();
                                    let messages = tokio::task::spawn_blocking(move || {
                                        crate::session::transcript::read_transcript_tail(&csid_clone, 20)
                                    }).await.unwrap_or_default();
                                    if !messages.is_empty() {
                                        tracing::info!("[{}] Sending catchup: {} messages",
                                            &session_id[..12.min(session_id.len())], messages.len());
                                        let catchup = serde_json::json!({
                                            "type": "Catchup",
                                            "sessionId": session_id,
                                            "messages": messages,
                                        });
                                        if let Err(e) = client.send_raw_json(&catchup).await {
                                            tracing::error!("[{}] Critical send failed (Catchup): {}", &session_id[..12.min(session_id.len())], e);
                                            send_failed = true;
                                        }
                                    }
                                }

                                // Flush any FileOffers that were queued while peer was offline
                                if !pending_offers.is_empty() {
                                    tracing::info!(
                                        "[{}] Flushing {} pending offer(s)",
                                        &session_id[..12.min(session_id.len())],
                                        pending_offers.len()
                                    );
                                    let offers: Vec<_> = pending_offers.drain(..).collect();
                                    for offer in offers {
                                        if let Err(e) = client.send_message(&offer).await {
                                            tracing::error!(
                                                "[{}] Failed to send queued offer: {}",
                                                &session_id[..12.min(session_id.len())],
                                                e
                                            );
                                            // Re-queue on failure so we can retry on next reconnect
                                            pending_offers.push(offer);
                                            break; // Stop flushing if relay connection is broken
                                        }
                                    }
                                }

                                // Sync HTTP tunnel state so phone knows if tunnel is active after reconnect
                                if let Some(ref proxy) = http_proxy {
                                    let _ = client.send_relay_message(&RelayMessage::HttpTunnelStatus {
                                        active: true,
                                        port: Some(proxy.port()),
                                        error: None,
                                    }).await;
                                }

                                // Sync model + permission mode so phone shows correct values
                                {
                                    let model_to_send = if current_model.is_empty() {
                                        "opus".to_string()
                                    } else {
                                        current_model.clone()
                                    };
                                    if let Err(e) = client.send_message(&crate::parser::ParsedMessage::ConfigSync {
                                        model: Some(model_to_send),
                                        permission_mode: Some(current_permission_mode.clone()),
                                    }).await {
                                        tracing::error!("[{}] Critical send failed (ConfigSync on reconnect): {}", &session_id[..12.min(session_id.len())], e);
                                        send_failed = true;
                                    }
                                }

                                // Sync session-scoped allow tools so phone knows which tools are auto-allowed
                                if !session_allow_tools.is_empty() {
                                    let tools: Vec<String> = session_allow_tools.iter().cloned().collect();
                                    let msg = crate::parser::ParsedMessage::System {
                                        content: format!("Auto-allowed tools this session: {}", tools.join(", ")),
                                    };
                                    let _ = client.send_message(&msg).await;
                                }

                                // Key renegotiation on reconnect for per-connection forward secrecy.
                                // Skip on first auth (initial pairing already established fresh keys).
                                if initial_auth_done {
                                    tracing::info!("[{}] Reconnected — renegotiating session key...",
                                        &session_id[..12.min(session_id.len())]);
                                    match client.renegotiate_key().await {
                                        Ok((mut new_keypair, peer_public_bytes, buffered)) => {
                                            match new_keypair.derive_shared_secret(&peer_public_bytes) {
                                                Ok(shared) => {
                                                    match crate::crypto::kdf::derive_aes_key(&shared) {
                                                        Ok(aes_key) => {
                                                            match crate::crypto::aes::AesGcm::new(aes_key.as_ref()) {
                                                                Ok(new_crypto) => {
                                                                    client.set_crypto(new_crypto);
                                                                    tracing::info!("[{}] Session key renegotiated successfully",
                                                                        &session_id[..12.min(session_id.len())]);
                                                                    // Process messages buffered during rekey (only on success)
                                                                    for buf in &buffered {
                                                                        match client.parse_decrypted(buf) {
                                                                            Ok(msg) => {
                                                                                tracing::info!("[{}] Processing buffered message: {:?}",
                                                                                    &session_id[..12.min(session_id.len())], msg);
                                                                                if let Some(input) = msg.as_key_input() {
                                                                                    if let Err(e) = stream_session.send_message(&input).await {
                                                                                        tracing::error!("[{}] Failed to send buffered message to Claude: {}",
                                                                                            &session_id[..12.min(session_id.len())], e);
                                                                                    }
                                                                                }
                                                                            }
                                                                            Err(e) => {
                                                                                tracing::warn!("[{}] Failed to parse buffered message: {}",
                                                                                    &session_id[..12.min(session_id.len())], e);
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                                Err(e) => {
                                                                    tracing::error!("[{}] Rekey AES init failed: {} — keeping old key",
                                                                        &session_id[..12.min(session_id.len())], e);
                                                                    tracing::warn!("[{}] Forcing reconnect to avoid crypto desync",
                                                                        &session_id[..12.min(session_id.len())]);
                                                                    reconnect_deadline = Some(tokio::time::Instant::now() + Duration::from_millis(500));
                                                                }
                                                            }
                                                        }
                                                        Err(e) => {
                                                            tracing::error!("[{}] Rekey KDF failed: {} — keeping old key",
                                                                &session_id[..12.min(session_id.len())], e);
                                                            tracing::warn!("[{}] Forcing reconnect to avoid crypto desync",
                                                                &session_id[..12.min(session_id.len())]);
                                                            reconnect_deadline = Some(tokio::time::Instant::now() + Duration::from_millis(500));
                                                        }
                                                    }
                                                }
                                                Err(e) => {
                                                    tracing::error!("[{}] Rekey ECDH failed: {} — keeping old key",
                                                        &session_id[..12.min(session_id.len())], e);
                                                    tracing::warn!("[{}] Forcing reconnect to avoid crypto desync",
                                                        &session_id[..12.min(session_id.len())]);
                                                    reconnect_deadline = Some(tokio::time::Instant::now() + Duration::from_millis(500));
                                                }
                                            }
                                        }
                                        Err(e) => {
                                            tracing::error!("[{}] Key renegotiation failed: {} — keeping old key",
                                                &session_id[..12.min(session_id.len())], e);
                                            tracing::warn!("[{}] Forcing reconnect to avoid crypto desync",
                                                &session_id[..12.min(session_id.len())]);
                                            reconnect_deadline = Some(tokio::time::Instant::now() + Duration::from_millis(500));
                                        }
                                    }
                                }
                                initial_auth_done = true;

                                Ok(())
                            }
                            ReceivedMessage::PeerDisconnected => {
                                peer_connected = false;
                                tracing::info!("[{}] Peer disconnected", &session_id[..12.min(session_id.len())]);
                                Ok(())
                            }
                            ReceivedMessage::FileTransferStart {
                                transfer_id, filename, mime_type,
                                total_size, total_chunks, direction, checksum,
                            } => {
                                if let Err(e) = file_manager.handle_start(
                                    transfer_id.clone(), filename.clone(), mime_type.clone(),
                                    *total_size, *total_chunks, checksum.clone(),
                                    direction, &mut client,
                                ).await {
                                    tracing::error!("File transfer start error: {}", e);
                                }
                                Ok(())
                            }
                            ReceivedMessage::FileChunk { transfer_id, sequence, data } => {
                                match file_manager.handle_chunk(
                                    transfer_id, *sequence, data, &mut client,
                                ).await {
                                    Ok(Some(saved_path)) => {
                                        // File fully received — tell Claude about it
                                        let msg = format!(
                                            "The user just sent a file from their phone. It has been saved to: {}",
                                            saved_path
                                        );
                                        if let Err(e) = stream_session.send_message(&msg).await {
                                            tracing::error!("Failed to notify Claude of received file: {}", e);
                                        }
                                    }
                                    Ok(None) => {} // transfer still in progress
                                    Err(e) => {
                                        tracing::error!("File chunk error: {}", e);
                                    }
                                }
                                Ok(())
                            }
                            ReceivedMessage::FileTransferAck { transfer_id, received_through } => {
                                let msgs = file_manager.handle_send_ack(transfer_id, *received_through);
                                for (i, relay_msg) in msgs.iter().enumerate() {
                                    // Timeout prevents hanging if relay can't absorb data
                                    match tokio::time::timeout(
                                        Duration::from_secs(10),
                                        client.send_relay_message(relay_msg),
                                    ).await {
                                        Ok(Ok(())) => {}
                                        Ok(Err(e)) => {
                                            tracing::error!("Failed to send file chunk: {}", e);
                                            break;
                                        }
                                        Err(_) => {
                                            tracing::error!("File chunk send timed out");
                                            break;
                                        }
                                    }
                                    // Yield every 10 chunks to avoid starving other tasks
                                    if (i + 1) % 10 == 0 {
                                        tokio::task::yield_now().await;
                                    }
                                }
                                Ok(())
                            }
                            ReceivedMessage::FileTransferCancel { transfer_id, reason } => {
                                tracing::info!("File transfer cancelled: {} - {}", transfer_id, reason);
                                file_manager.cancel(transfer_id);
                                Ok(())
                            }
                            ReceivedMessage::FileTransferComplete { transfer_id, success, error } => {
                                if *success {
                                    tracing::info!("File transfer {} completed successfully", transfer_id);
                                } else {
                                    tracing::warn!("File transfer {} failed: {:?}", transfer_id, error);
                                }
                                file_manager.cancel(transfer_id);
                                Ok(())
                            }
                            ReceivedMessage::HttpTunnelOpen { port } => {
                                tracing::info!("Phone requested HTTP tunnel to port {}", port);
                                http_proxy = Some(HttpProxy::new(*port));
                                let _ = client.send_relay_message(&RelayMessage::HttpTunnelStatus {
                                    active: true,
                                    port: Some(*port),
                                    error: None,
                                }).await;
                                Ok(())
                            }
                            ReceivedMessage::HttpTunnelClose => {
                                tracing::info!("Phone requested HTTP tunnel close");
                                http_proxy = None;
                                let _ = client.send_relay_message(&RelayMessage::HttpTunnelStatus {
                                    active: false,
                                    port: None,
                                    error: None,
                                }).await;
                                Ok(())
                            }
                            ReceivedMessage::HttpRequest { request_id, method, path, headers, body } => {
                                if let Some(ref proxy) = http_proxy {
                                    // Clone values for the spawned task (match borrows msg).
                                    let http_client = proxy.client().clone();
                                    let port = proxy.port();
                                    let tx = proxy_tx.clone();
                                    let rid = request_id.clone();
                                    let m = method.clone();
                                    let p = path.clone();
                                    let h = headers.clone();
                                    let b = body.clone();
                                    tokio::spawn(async move {
                                        let response = HttpProxy::proxy_request_with(
                                            &http_client, port,
                                            &rid, &m, &p, &h, b.as_deref(),
                                        ).await;
                                        let _ = tx.send(RelayMessage::HttpResponse {
                                            request_id: response.request_id,
                                            status: response.status,
                                            headers: response.headers,
                                            body: response.body,
                                        }).await;
                                    });
                                } else {
                                    tracing::warn!("Received HTTP request but no tunnel is open");
                                    let _ = client.send_relay_message(&RelayMessage::HttpResponse {
                                        request_id: request_id.clone(),
                                        status: 503,
                                        headers: std::collections::HashMap::new(),
                                        body: base64::Engine::encode(
                                            &base64::engine::general_purpose::STANDARD,
                                            "No HTTP tunnel is open",
                                        ),
                                    }).await;
                                }
                                Ok(())
                            }
                            ReceivedMessage::DeviceAuthorizeRequest { fingerprint } => {
                                tracing::info!("[{}] Device authorization request — forwarding to phone: {}",
                                    &session_id[..12.min(session_id.len())],
                                    &fingerprint[..16.min(fingerprint.len())]);

                                // Deduplicate: skip if we already have a pending request for this fingerprint
                                if pending_device_approvals.contains_key(fingerprint.as_str()) {
                                    tracing::debug!("[{}] Duplicate device auth request for {}…, ignoring",
                                        &session_id[..12.min(session_id.len())],
                                        &fingerprint[..16.min(fingerprint.len())]);
                                    return Ok(());
                                }

                                // Forward to phone as an Action card with Approve/Deny buttons.
                                // Uses the existing Action mechanism (same as permission prompts).
                                let short_fp = &fingerprint[..16.min(fingerprint.len())];
                                let action_id = format!("device-approve-{}", fingerprint);
                                let prompt = format!(
                                    "New device wants to connect:\n\nFingerprint: {}…\n\nApprove this device?",
                                    short_fp
                                );
                                let action = crate::parser::ParsedMessage::Action {
                                    id: action_id,
                                    prompt,
                                    options: vec![
                                        "Approve".to_string(),
                                        "Deny".to_string(),
                                    ],
                                };
                                if let Err(e) = client.send_message(&action).await {
                                    // Fail-closed: if we can't reach the phone, deny the device
                                    tracing::error!("Failed to send device approval request to phone: {} — denying", e);
                                    let _ = client.send_device_authorize_response(&fingerprint, false).await;
                                } else {
                                    // Track pending approval for timeout enforcement
                                    pending_device_approvals.insert(fingerprint.clone(), Instant::now());
                                }

                                manager.write().await.append_event_line(
                                    session_id, &format!("{} Device auth request: {}…", event_ts(), short_fp));
                                Ok(())
                            }
                        };
                        if let Err(e) = result {
                            tracing::error!("send error: {}", e);
                            break;
                        }
                    }
                    Err(e) => {
                        tracing::warn!("[{}] Relay error: {} — scheduling reconnect", &session_id[..12.min(session_id.len())], e);
                        reconnect_attempt = 0;
                        reconnect_deadline = Some(tokio::time::Instant::now() + Duration::from_secs(1));
                        continue;
                    }
                }
            }

            // Branch: HTTP proxy responses (spawned tasks)
            Some(relay_msg) = proxy_rx.recv() => {
                if let Err(e) = client.send_relay_message(&relay_msg).await {
                    tracing::error!("Failed to send proxy response: {}", e);
                }
            }

            // Branch 3: hook events from Claude Code
            Some(event) = async {
                match hook_rx.as_mut() {
                    Some(rx) => rx.recv().await,
                    None => std::future::pending().await,
                }
            } => {
                // AskUserQuestion in -p mode: intercept PreToolUse, send question
                // card to phone, wait for user's answer, then deny the tool
                // (it can't execute in -p mode) with the answer in the reason.
                if event.hook_event_name == "PreToolUse" {
                    if let Some(ref tool_name) = event.tool_name {
                        if tool_name == "AskUserQuestion" {
                            if let Some(ref input) = event.tool_input {
                                if let Some(questions_val) = input.get("questions") {
                                    if let Ok(questions) = serde_json::from_value::<Vec<crate::parser::QuestionData>>(questions_val.clone()) {
                                        let card = crate::parser::ParsedMessage::AskQuestion {
                                            id: format!("ask-{}", event.request_id),
                                            questions,
                                        };
                                        if let Err(e) = client.send_message(&card).await {
                                            tracing::error!("[{}] Critical send failed (AskQuestion): {}", &session_id[..12.min(session_id.len())], e);
                                            send_failed = true;
                                        }
                                        pending_ask_request_id = Some(event.request_id.clone());
                                        tracing::info!("Sent AskQuestion card, waiting for answer (request_id={})", event.request_id);
                                    }
                                }
                            }
                            // Don't write response yet — wait for user's answer
                            continue;
                        }
                    }
                }

                if event.hook_event_name == "PreToolUse"
                    && event.tool_name.as_ref().map_or(false, |t| session_allow_tools.contains(t.as_str()))
                {
                    // Session-scoped auto-allow: tool was granted "Always" for this session.
                    // Auto-write allow response so the hook unblocks immediately.
                    if let Some(ref dir) = hook_dir {
                        let response = crate::hooks::PreToolUseResponse::allow();
                        if let Err(e) = dir.write_pre_tool_response(&event.request_id, &response) {
                            tracing::error!("Failed to auto-allow session tool: {}", e);
                        } else {
                            let tool = event.tool_name.as_deref().unwrap_or("?");
                            tracing::info!("Session auto-allowed: {} ({})", tool, event.request_id);
                            manager.write().await.append_event_line(
                                session_id, &format!("{} Hook: PreToolUse {} (session auto-allowed)", event_ts(), tool));
                        }
                    }
                    // Don't send to phone — already handled
                } else if let Some(parsed) = crate::parser::ParsedMessage::from_hook_event(&event) {
                    // Store dangerous PreToolUse events for "Always" rule building.
                    // Only events that pass from_hook_event (= produce an Action card) are stored.
                    // Safe tools return None above and are never stored.
                    if event.hook_event_name == "PreToolUse" {
                        if let Some(ref tool_name) = event.tool_name {
                            pending_pretool_events.insert(
                                event.request_id.clone(),
                                (tool_name.clone(), event.tool_input.clone().unwrap_or(serde_json::Value::Null), Instant::now()),
                            );
                            // Prevent unbounded growth: FIFO eviction (oldest first via IndexMap).
                            if pending_pretool_events.len() > 50 {
                                if let Some((key, _)) = pending_pretool_events.shift_remove_index(0) {
                                    tracing::warn!("Evicted oldest pending PreToolUse: {}", key);
                                }
                            }
                        }
                    }
                    tracing::info!("Sending hook event to phone: {:?} id={}", event.hook_event_name, event.request_id);
                    if let Err(e) = client.send_message(&parsed).await {
                        tracing::error!("[{}] Critical send failed (hook event {:?}): {}", &session_id[..12.min(session_id.len())], event.hook_event_name, e);
                        send_failed = true;
                    }
                    // PreToolUse sent to phone = awaiting user permission decision
                    if event.hook_event_name == "PreToolUse" {
                        let json = manager.write().await.update_live_state(session_id, |ls| {
                            ls.claude_status = ClaudeStatus::AwaitingInput;
                            ls.last_activity = "Awaiting permission".to_string();
                        });
                        if let Some(ref j) = json {
                            let _ = client.send_raw_json(j).await;
                        }
                    }
                }

                // Auto-refresh browser when files are edited while tunnel is active.
                if event.hook_event_name == "PostToolUse" && http_proxy.is_some() {
                    if let Some(ref tool_name) = event.tool_name {
                        if tool_name == "Edit" || tool_name == "Write" {
                            tracing::info!("File changed via {}, sending browser refresh", tool_name);
                            let _ = client.send_relay_message(&RelayMessage::HttpTunnelRefresh {}).await;
                        }
                    }
                }

                // HTTP tunnel permission: detect localhost URLs in Bash output
                if event.hook_event_name == "PostToolUse" {
                    if let Some(ref tool_name) = event.tool_name {
                        if tool_name == "Bash" {
                            turn_used_bash = true;
                            let input_text = event.tool_input.as_ref()
                                .and_then(|v| v["command"].as_str())
                                .unwrap_or("");
                            let response_text = event.tool_response.as_ref()
                                .map(|v| v.as_str().map(|s| s.to_string()).unwrap_or_else(|| v.to_string()))
                                .unwrap_or_default();
                            let search = format!("{} {}", input_text, response_text);
                            let log_end = search.char_indices().map(|(i,_)| i).take_while(|&i| i <= 200).last().unwrap_or(0);
                            tracing::info!("PostToolUse Bash search text: {:?}", &search[..log_end]);
                            if let Some(port) = extract_port_from_text(&search) {
                                let current_port = http_proxy.as_ref().map(|p| p.port());
                                if current_port == Some(port) {
                                    tracing::info!("Tunnel already open on port {}, skipping", port);
                                } else if browser_tunnel_always_allow {
                                    if let Some(old) = current_port {
                                        tracing::info!("Switching HTTP tunnel from port {} to {} (always-allow)", old, port);
                                    } else {
                                        tracing::info!("Auto-opening HTTP tunnel to port {} (always-allow)", port);
                                    }
                                    http_proxy = Some(HttpProxy::new(port));
                                    let _ = client.send_relay_message(&RelayMessage::HttpTunnelStatus {
                                        active: true,
                                        port: Some(port),
                                        error: None,
                                    }).await;
                                } else {
                                    tracing::info!("Requesting tunnel permission for port {}", port);
                                    pending_tunnel_port = Some(port);
                                    let action = crate::parser::ParsedMessage::Action {
                                        id: format!("tunnel-{}", port),
                                        prompt: format!("Open browser tunnel to localhost:{}?", port),
                                        options: vec!["Allow".to_string(), "Always".to_string(), "Deny".to_string()],
                                    };
                                    if let Err(e) = client.send_message(&action).await {
                                        tracing::error!("[{}] Critical send failed (tunnel Action): {}", &session_id[..12.min(session_id.len())], e);
                                        send_failed = true;
                                    }
                                }
                            }
                        }
                    }
                }

                // GUI event monitor — log hook events from file-based IPC
                {
                    let tool = event.tool_name.as_deref().unwrap_or("");
                    let line = match event.hook_event_name.as_str() {
                        "PreToolUse" if !tool.is_empty() => format!("{} Hook: PreToolUse {}", event_ts(), tool),
                        "PostToolUse" if !tool.is_empty() => format!("{} Hook: PostToolUse {}", event_ts(), tool),
                        "PostToolUseFailure" if !tool.is_empty() => format!("{} Hook: {} failed", event_ts(), tool),
                        "Stop" => format!("{} Hook: Stop", event_ts()),
                        "SubagentStart" => format!("{} Agent started: {}", event_ts(),
                            event.agent_type.as_deref().unwrap_or("unknown")),
                        "SubagentStop" => format!("{} Agent stopped: {}", event_ts(),
                            event.agent_type.as_deref().unwrap_or("unknown")),
                        "Notification" => format!("{} Notification: {}", event_ts(),
                            event.message.as_deref().unwrap_or("").chars().take(60).collect::<String>()),
                        "SessionStart" => format!("{} Session started ({})", event_ts(),
                            event.source.as_deref().unwrap_or("startup")),
                        "SessionEnd" => format!("{} Session ended ({})", event_ts(),
                            event.reason.as_deref().unwrap_or("unknown")),
                        "UserPromptSubmit" => {
                            let preview: String = event.prompt.as_deref().unwrap_or("").chars().take(60).collect();
                            format!("{} Prompt: \"{}{}\"", event_ts(), preview,
                                if event.prompt.as_deref().map_or(false, |p| p.len() > 60) { "..." } else { "" })
                        }
                        "TeammateIdle" => format!("{} Teammate idle: {}", event_ts(),
                            event.teammate_name.as_deref().unwrap_or("unknown")),
                        "TaskCompleted" => format!("{} Task completed: {}", event_ts(),
                            event.task_subject.as_deref().unwrap_or("unknown")),
                        _ => format!("{} Hook: {}", event_ts(), event.hook_event_name),
                    };
                    manager.write().await.append_event_line(session_id, &line);
                }

                // Update live state for subagent lifecycle events
                if event.hook_event_name == "SubagentStart" || event.hook_event_name == "SubagentStop" {
                    let is_start = event.hook_event_name == "SubagentStart";
                    let json = manager.write().await.update_live_state(session_id, |ls| {
                        if is_start {
                            ls.active_agents = ls.active_agents.saturating_add(1);
                        } else {
                            ls.active_agents = ls.active_agents.saturating_sub(1);
                        }
                    });
                    if let Some(ref j) = json {
                        let _ = client.send_raw_json(j).await;
                    }
                }

                // SessionStart: sync model to phone
                if event.hook_event_name == "SessionStart" {
                    if let Some(ref model) = event.hook_model {
                        let sync = crate::parser::ParsedMessage::ConfigSync {
                            model: Some(model.clone()),
                            permission_mode: None,
                        };
                        if let Err(e) = client.send_message(&sync).await {
                            tracing::error!("[{}] Critical send failed (ConfigSync on SessionStart): {}", &session_id[..12.min(session_id.len())], e);
                            send_failed = true;
                        }
                    }
                }

                // Stop: drain all pending PreToolUse events — Claude's turn is done,
                // so all unanswered permission cards are moot.
                if event.hook_event_name == "Stop" {
                    if !pending_pretool_events.is_empty() {
                        let count = pending_pretool_events.len();
                        for (rid, _) in pending_pretool_events.drain(..) {
                            let timeout_msg = crate::parser::ParsedMessage::ActionTimeout {
                                action_id: format!("ptool-{}", rid),
                            };
                            let _ = client.send_message(&timeout_msg).await;
                        }
                        tracing::info!("[{}] Drained {} stale PreToolUse events on Stop",
                            &session_id[..12.min(session_id.len())], count);
                    }
                }

                // SessionEnd: mark status idle
                if event.hook_event_name == "SessionEnd" {
                    let json = manager.write().await.update_live_state(session_id, |ls| {
                        ls.claude_status = ClaudeStatus::Idle;
                        ls.last_activity = "Session ended".to_string();
                    });
                    if let Some(ref j) = json {
                        let _ = client.send_raw_json(j).await;
                    }
                }

                // UserPromptSubmit: enter thinking state
                if event.hook_event_name == "UserPromptSubmit" {
                    thinking_since = Some(Instant::now());
                    let json = manager.write().await.update_live_state(session_id, |ls| {
                        ls.claude_status = ClaudeStatus::Thinking;
                        ls.thinking_since = Some(Instant::now());
                        ls.last_activity = "Processing prompt".to_string();
                    });
                    if let Some(ref j) = json {
                        let _ = client.send_raw_json(j).await;
                    }
                }

                // Forward permission_mode to phone whenever it changes
                if let Some(ref mode) = event.permission_mode {
                    if mode != &current_permission_mode {
                        tracing::info!("Permission mode changed: {} → {}", current_permission_mode, mode);
                        current_permission_mode = mode.clone();
                    }
                    let sync = crate::parser::ParsedMessage::ConfigSync {
                        model: None,
                        permission_mode: Some(mode.clone()),
                    };
                    if let Err(e) = client.send_message(&sync).await {
                        tracing::error!("Failed to send ConfigSync: {}", e);
                    }
                }
            }

            // Branch 5: commands from GUI
            cmd = cmd_rx.recv() => {
                match cmd {
                    Some(SessionCommand::SendInput(input)) => {
                        let text = input.trim_end_matches('\n');
                        if let Err(e) = stream_session.send_message(text).await {
                            tracing::error!("Failed to send input: {}", e);
                        }
                    }
                    Some(SessionCommand::Terminate) => {
                        tracing::info!("[{}] Terminate: shutting down", &session_id[..12.min(session_id.len())]);
                        break;
                    }
                    Some(SessionCommand::Shutdown) | None => {
                        tracing::info!("[{}] Shutdown: shutting down (bridge exiting)", &session_id[..12.min(session_id.len())]);
                        break;
                    }
                    Some(SessionCommand::Handoff) | Some(SessionCommand::TakeBack) => {
                        // Handled in relay message branch (phone sends these as text commands)
                        tracing::debug!("Ignoring GUI-side Handoff/TakeBack command");
                    }
                }
            }

            // Branch 6: outbox file detected — collect into pending batch
            Some(file_path) = outbox_rx.recv() => {
                // Skip events in the first 500ms — they're from directory setup, not real files
                if outbox_startup_time.elapsed() < Duration::from_millis(500) {
                    tracing::debug!("[{}] Ignoring early outbox event: {:?}",
                        &session_id[..12.min(session_id.len())], file_path);
                    continue;
                }
                outbox_pending.push(file_path);
                // Start or reset the 2-second debounce window
                outbox_debounce = Some(tokio::time::Instant::now() + Duration::from_secs(2));
            }

            // Branch 7: outbox debounce timer — send the collected batch
            _ = async {
                match outbox_debounce {
                    Some(deadline) => tokio::time::sleep_until(deadline).await,
                    None => std::future::pending().await,
                }
            } => {
                outbox_debounce = None;
                let paths: Vec<std::path::PathBuf> = outbox_pending.drain(..).collect();
                if paths.is_empty() {
                    continue;
                }

                if let Some(ref dir) = outbox_dir {
                    match crate::file_transfer::zip::prepare_outbox_batch(&paths, dir) {
                        Ok((individual_files, zip_path)) => {
                            // Send individual files (queue if peer is offline)
                            for file_path in &individual_files {
                                let tx_id = uuid::Uuid::new_v4().to_string();
                                match PreparedFile::from_path(tx_id, file_path) {
                                    Ok(prepared) => {
                                        let offer = file_manager.prepare_send(prepared);
                                        if peer_connected {
                                            if let Err(e) = client.send_message(&offer).await {
                                                tracing::warn!(
                                                    "[{}] Send failed, queuing offer for {}: {}",
                                                    &session_id[..12.min(session_id.len())],
                                                    file_path.display(), e
                                                );
                                                pending_offers.push(offer);
                                            }
                                        } else {
                                            tracing::info!(
                                                "[{}] Peer offline, queuing offer for {}",
                                                &session_id[..12.min(session_id.len())],
                                                file_path.display()
                                            );
                                            pending_offers.push(offer);
                                        }
                                        // Clean up source file (data is in memory via file_manager)
                                        let _ = std::fs::remove_file(file_path);
                                    }
                                    Err(e) => {
                                        tracing::error!("Failed to prepare outbox file: {}", e);
                                    }
                                }
                            }
                            // Send zip bundle if created (queue if peer is offline)
                            if let Some(ref zip) = zip_path {
                                let tx_id = uuid::Uuid::new_v4().to_string();
                                match PreparedFile::from_path(tx_id, zip) {
                                    Ok(prepared) => {
                                        let offer = file_manager.prepare_send(prepared);
                                        if peer_connected {
                                            if let Err(e) = client.send_message(&offer).await {
                                                tracing::warn!(
                                                    "[{}] Send failed, queuing zip offer: {}",
                                                    &session_id[..12.min(session_id.len())], e
                                                );
                                                pending_offers.push(offer);
                                            }
                                        } else {
                                            tracing::info!(
                                                "[{}] Peer offline, queuing zip offer",
                                                &session_id[..12.min(session_id.len())]
                                            );
                                            pending_offers.push(offer);
                                        }
                                    }
                                    Err(e) => {
                                        tracing::error!("Failed to prepare zip file: {}", e);
                                    }
                                }
                                // Clean up temp zip after sending (data in memory via file_manager)
                                let _ = std::fs::remove_file(zip);
                                // Clean up original source files that were zipped
                                for p in &paths {
                                    if p.is_file() {
                                        let _ = std::fs::remove_file(p);
                                    } else if p.is_dir() {
                                        let _ = std::fs::remove_dir_all(p);
                                    }
                                }
                            }
                        }
                        Err(e) => {
                            tracing::error!("Failed to prepare outbox batch: {}", e);
                        }
                    }
                }
            }

            // Branch 8: Text buffer flush (500ms interval, stream-json mode)
            // Accumulates token-by-token TextDelta events into chunks,
            // then runs parse() to detect Code blocks, Diffs, and plain Text.
            _ = text_flush_interval.tick(), if !text_buffer.is_empty() => {
                flush_text_buffer(&mut text_buffer, &mut client).await;
            }

            // Branch 8b: PreToolUse timeout cleanup (30s interval)
            // Evicts entries older than 310s (5min + 10s grace) and sends ActionTimeout to phone.
            _ = pretool_cleanup.tick() => {
                let expired: Vec<String> = pending_pretool_events.iter()
                    .filter(|(_, (_, _, created))| created.elapsed() > Duration::from_secs(310))
                    .map(|(k, _)| k.clone())
                    .collect();
                for rid in expired {
                    pending_pretool_events.shift_remove(&rid);
                    let timeout_msg = crate::parser::ParsedMessage::ActionTimeout {
                        action_id: format!("ptool-{}", rid),
                    };
                    let _ = client.send_message(&timeout_msg).await;
                    manager.write().await.append_event_line(
                        session_id, &format!("{} PreToolUse timed out ({})", event_ts(), rid));
                }
            }

            // Branch 9: Forward transcript watcher messages to phone (during handoff)
            msg = async {
                match transcript_watcher_rx.as_mut() {
                    Some(rx) => rx.recv().await,
                    None => std::future::pending().await,
                }
            } => {
                if let Some(msg) = msg {
                    let observer_msg = serde_json::json!({
                        "type": "HandoffMessage",
                        "sessionId": session_id,
                        "message": {
                            "uuid": msg.uuid,
                            "role": msg.role,
                            "content": msg.content,
                            "toolUses": msg.tool_uses.iter().map(|t| {
                                serde_json::json!({ "name": t.tool_name, "id": t.tool_id })
                            }).collect::<Vec<_>>(),
                            "timestamp": msg.timestamp,
                        }
                    });
                    let _ = client.send_raw_json(&observer_msg).await;
                }
            }

            // Branch 10: Stream-JSON events (structured protocol)
            event = stream_session.recv_event(), if !claude_dead && !handed_off => {
                let Some(event) = event else {
                    // Claude process exited — flush any remaining text
                    flush_text_buffer(&mut text_buffer, &mut client).await;
                    consecutive_respawn_failures += 1;
                    tracing::warn!("Stream-JSON session ended (respawn attempt {}/{})",
                        consecutive_respawn_failures, MAX_RESPAWN_RETRIES);
                    respawning = true;
                    pending_ask_request_id = None; // Clear stale AskUserQuestion state

                    // Check retry limit — stop after MAX_RESPAWN_RETRIES consecutive failures
                    if consecutive_respawn_failures > MAX_RESPAWN_RETRIES {
                        tracing::error!("Max respawn retries ({}) exceeded — stopping auto-restart", MAX_RESPAWN_RETRIES);
                        let msg = crate::parser::ParsedMessage::System {
                            content: format!("Claude Code failed to restart after {} attempts. Send a new message to try again.", MAX_RESPAWN_RETRIES),
                        };
                        let _ = client.send_message(&msg).await;
                        // Update live state: Exited
                        {
                            let json = manager.write().await.update_live_state(session_id, |ls| {
                                ls.claude_status = ClaudeStatus::Exited;
                                ls.last_activity = "Restart failed".to_string();
                            });
                            if let Some(ref j) = json {
                                let _ = client.send_raw_json(j).await;
                            }
                        }
                        // Don't break — stay in the loop so the user can send
                        // a new message which will trigger a fresh spawn.
                        claude_dead = true;
                        respawning = false;
                        continue;
                    }

                    // Backoff: wait before retrying (2s * attempt)
                    let backoff = Duration::from_secs(2 * consecutive_respawn_failures as u64);
                    tracing::info!("Waiting {:?} before respawn attempt", backoff);
                    tokio::time::sleep(backoff).await;

                    // Update live state: Respawning
                    {
                        let json = manager.write().await.update_live_state(session_id, |ls| {
                            ls.claude_status = ClaudeStatus::Respawning;
                            ls.thinking_since = None;
                            ls.last_activity = "Restarting".to_string();
                        });
                        if let Some(ref j) = json {
                            let _ = client.send_raw_json(j).await;
                        }
                    }

                    let msg = crate::parser::ParsedMessage::System {
                        content: "Claude Code exited. Restarting...".to_string(),
                    };
                    let _ = client.send_message(&msg).await;

                    // Attempt respawn with --resume to preserve conversation.
                    // Use claude_session_id (set from Init event or user resume)
                    // instead of stream_session's internal session_id which may be None.
                    if let Err(e) = stream_session.respawn_with_session(
                        claude_session_id.as_deref(), None, None
                    ).await {
                        tracing::error!("Failed to respawn: {}", e);
                        // Update live state: Exited (respawn failed)
                        {
                            let json = manager.write().await.update_live_state(session_id, |ls| {
                                ls.claude_status = ClaudeStatus::Exited;
                                ls.last_activity = "Exited".to_string();
                            });
                            if let Some(ref j) = json {
                                let _ = client.send_raw_json(j).await;
                            }
                        }
                        break;
                    }
                    respawning = false;
                    continue; // Re-enter event loop with new process
                };
                // Helper: append a line to the GUI event monitor
                macro_rules! gui_log {
                    ($fmt:expr $(, $arg:expr)*) => {
                        manager.write().await.append_event_line(
                            session_id, &format!(concat!("{} ", $fmt), event_ts() $(, $arg)*)
                        );
                    };
                }

                match event {
                    StreamEvent::Init { session_id: sid, model, permission_mode,
                                        tools, slash_commands, skills, agents,
                                        mcp_servers, plugins, version, fast_mode,
                                        api_key_source, cwd, .. } => {
                        // Store session metadata
                        stream_session.set_session_id(sid.clone());
                        stream_session.set_model(model.clone());
                        current_model = model.clone();

                        // Successful Init — reset respawn failure counter
                        consecutive_respawn_failures = 0;

                        // Create symlink so hooks find our IPC dirs.
                        // Claude doesn't propagate env vars to hooks, so the hook
                        // binary uses Claude's session_id (from event JSON) to locate
                        // /tmp/termopus-{prefix}/. Our dirs use the bridge session_id.
                        // The symlink bridges the gap.
                        claude_session_id = Some(sid.clone());
                        // Persist for crash recovery (--resume on bridge restart)
                        let _ = storage::save_claude_session_id(session_id, &sid);

                        let claude_prefix = &sid[..8.min(sid.len())];
                        let bridge_prefix = &session_id[..8.min(session_id.len())];
                        if claude_prefix != bridge_prefix {
                            let claude_dir = std::path::PathBuf::from("/tmp")
                                .join(format!("termopus-{}", claude_prefix));
                            let bridge_dir = std::path::PathBuf::from("/tmp")
                                .join(format!("termopus-{}", bridge_prefix));
                            if !claude_dir.exists() {
                                #[cfg(unix)]
                                {
                                    let _ = std::os::unix::fs::symlink(&bridge_dir, &claude_dir);
                                    tracing::info!("Symlinked {} -> {} for hook IPC",
                                        claude_dir.display(), bridge_dir.display());
                                }
                            }
                        }
                        {
                            let mut mgr = manager.write().await;
                            if let Some(session) = mgr.get_session_mut(session_id) {
                                session.claude_authenticated = true;
                            }
                        }
                        // Send config to phone
                        if let Err(e) = client.send_message(&crate::parser::ParsedMessage::ConfigSync {
                            model: Some(model.clone()),
                            permission_mode: Some(permission_mode.clone()),
                        }).await {
                            tracing::error!("[{}] Critical send failed (ConfigSync on init): {}", &session_id[..12.min(session_id.len())], e);
                            send_failed = true;
                        }
                        // Send full capabilities to phone
                        if let Err(e) = client.send_raw_json(&serde_json::json!({
                            "type": "SessionCapabilities",
                            "sessionId": sid,
                            "model": model,
                            "tools": tools,
                            "slashCommands": slash_commands,
                            "skills": skills,
                            "agents": agents,
                            "mcpServers": mcp_servers,
                            "plugins": plugins,
                            "permissionMode": permission_mode,
                            "cwd": cwd,
                            "cliVersion": version,
                            "fastMode": fast_mode,
                            "apiKeySource": api_key_source,
                        })).await {
                            tracing::error!("[{}] Critical send failed (SessionCapabilities): {}", &session_id[..12.min(session_id.len())], e);
                            send_failed = true;
                        }
                        // Sync permission rules to phone
                        let (allow, deny) = crate::hooks::permissions::read_rules();
                        if let Err(e) = client.send_message(&crate::parser::ParsedMessage::PermissionRulesSync { allow, deny }).await {
                            tracing::error!("[{}] Critical send failed (PermissionRulesSync on init): {}", &session_id[..12.min(session_id.len())], e);
                            send_failed = true;
                        }
                        gui_log!("Session initialized ({})", model);
                        // Update live state: session initialized, Claude is idle
                        {
                            let model_c = model.clone();
                            let pm_c = permission_mode.clone();
                            let json = manager.write().await.update_live_state(session_id, |ls| {
                                ls.claude_status = ClaudeStatus::Idle;
                                ls.model = Some(model_c);
                                ls.permission_mode = Some(pm_c);
                                ls.last_activity = "Session initialized".to_string();
                            });
                            if let Some(ref j) = json {
                                let _ = client.send_raw_json(j).await;
                            }
                        }
                    }

                    StreamEvent::ThinkingStart => {
                        text_delta_streaming = false; // reset for next text run
                        thinking_since = Some(Instant::now());
                        // If Claude starts thinking, any pending AskUserQuestion hook
                        // has already resolved (answered or timed out). Clear stale state
                        // so the next user text isn't consumed as a dead answer.
                        pending_ask_request_id = None;
                        let msg = crate::parser::ParsedMessage::Thinking {
                            status: "Thinking...".to_string(),
                        };
                        let _ = client.send_message(&msg).await;
                        gui_log!("Thinking...");
                        // Update live state: Thinking
                        {
                            let json = manager.write().await.update_live_state(session_id, |ls| {
                                ls.claude_status = ClaudeStatus::Thinking;
                                ls.thinking_since = Some(Instant::now());
                                ls.last_activity = "Thinking".to_string();
                            });
                            if let Some(ref j) = json {
                                let _ = client.send_raw_json(j).await;
                            }
                        }
                    }

                    StreamEvent::TextDelta { text } => {
                        // DON'T send per-token — accumulate in buffer.
                        // Buffer is flushed every 500ms by the tick branch,
                        // or on turn boundaries (AssistantMessage, ThinkingStop).
                        text_buffer.push_str(&text);
                        turn_response_text.push_str(&text);
                        // Transition to Responding on first text delta only.
                        // Uses a local bool instead of locking the manager mutex
                        // on every token (hundreds per response).
                        if !text_delta_streaming {
                            text_delta_streaming = true;
                            let json = manager.write().await.update_live_state(session_id, |ls| {
                                ls.claude_status = ClaudeStatus::Responding;
                                ls.last_activity = "Responding".to_string();
                            });
                            if let Some(ref j) = json {
                                let _ = client.send_raw_json(j).await;
                            }
                        }
                    }

                    StreamEvent::ToolUseStart { ref tool_name, .. } => {
                        // Flush any accumulated text before tool starts
                        flush_text_buffer(&mut text_buffer, &mut client).await;
                        // Show tool-running status so the phone doesn't look stuck.
                        // Keep thinking_since active so the ticker updates the elapsed time.
                        if thinking_since.is_none() {
                            thinking_since = Some(Instant::now());
                        }
                        let msg = crate::parser::ParsedMessage::Thinking {
                            status: format!("Running {}...", tool_name),
                        };
                        let _ = client.send_message(&msg).await;
                        // Hooks handle the structured tool info (PreToolUse)
                        gui_log!("Tool: {}", tool_name);
                        // Update live state: ToolRunning
                        {
                            let tn = tool_name.clone();
                            let json = manager.write().await.update_live_state(session_id, |ls| {
                                ls.claude_status = ClaudeStatus::ToolRunning { tool_name: tn };
                                ls.last_activity = "Running tool".to_string();
                            });
                            if let Some(ref j) = json {
                                let _ = client.send_raw_json(j).await;
                            }
                        }
                    }

                    StreamEvent::ToolResult { ref content, is_error, .. } => {
                        // Tool finished — Claude will think about the result
                        thinking_since = Some(Instant::now());
                        let msg = crate::parser::ParsedMessage::Thinking {
                            status: "Thinking...".to_string(),
                        };
                        let _ = client.send_message(&msg).await;
                        if is_error {
                            gui_log!("Tool error ({} chars)", content.len());
                        } else {
                            gui_log!("Tool result ({} chars)", content.len());
                        }
                        // Update live state: back to Thinking (processing tool result)
                        {
                            let json = manager.write().await.update_live_state(session_id, |ls| {
                                ls.claude_status = ClaudeStatus::Thinking;
                                ls.thinking_since = Some(Instant::now());
                                ls.last_activity = "Thinking".to_string();
                            });
                            if let Some(ref j) = json {
                                let _ = client.send_raw_json(j).await;
                            }
                        }
                    }

                    StreamEvent::AssistantMessage { content_text, .. } => {
                        text_delta_streaming = false; // turn complete
                        // Usage tracking handled by MessageDelta (per-message running
                        // count) and Result (final session totals). No accumulation here
                        // to avoid double-counting.

                        // Flush remaining text buffer before sending ClaudeResponse
                        flush_text_buffer(&mut text_buffer, &mut client).await;

                        // Per-turn response: if this assistant message contains text,
                        // send it as ClaudeResponse.
                        if let Some(ref text) = content_text {
                            if !text.trim().is_empty() {
                                let preview: String = text.chars().take(60).collect();
                                let ellipsis = if text.len() > 60 { "..." } else { "" };
                                gui_log!("Response: \"{}{}\"", preview, ellipsis);
                                let msg = crate::parser::ParsedMessage::ClaudeResponse { content: text.clone() };
                                let _ = client.send_message(&msg).await;
                            }
                        }
                        // Update live state: Idle (assistant turn complete)
                        {
                            let json = manager.write().await.update_live_state(session_id, |ls| {
                                ls.claude_status = ClaudeStatus::Idle;
                                ls.thinking_since = None;
                                ls.last_activity = "Response complete".to_string();
                            });
                            if let Some(ref j) = json {
                                let _ = client.send_raw_json(j).await;
                            }
                        }
                    }

                    StreamEvent::ThinkingStop => {
                        flush_text_buffer(&mut text_buffer, &mut client).await;
                        thinking_since = None;
                    }

                    StreamEvent::MessageDelta { input_tokens, output_tokens,
                                                cache_read_input_tokens, cache_creation_input_tokens,
                                                context_management, .. } => {
                        total_input_tokens = input_tokens;
                        total_output_tokens = output_tokens;
                        cache_read_tokens = cache_read_input_tokens;
                        cache_creation_tokens = cache_creation_input_tokens;

                        if let Some(cm) = context_management {
                            if !cm.applied_edits.is_empty() {
                                let msg = crate::parser::ParsedMessage::System {
                                    content: "Context compacted — conversation history was summarized to free space.".to_string(),
                                };
                                let _ = client.send_message(&msg).await;
                                gui_log!("Context compacted");
                            }
                        }
                        // Token counts logged on Result, not per-delta (too noisy)
                    }

                    StreamEvent::HookStarted { ref hook_event, ref hook_name, .. } => {
                        if hook_event == "PreCompact" {
                            let msg = crate::parser::ParsedMessage::System {
                                content: "Compacting conversation...".to_string(),
                            };
                            let _ = client.send_message(&msg).await;
                        }
                        gui_log!("Hook: {}", hook_name);
                    }

                    StreamEvent::HookResponse { ref hook_name, ref outcome, .. } => {
                        gui_log!("Hook done: {} ({})", hook_name, outcome);
                    }

                    StreamEvent::Result { total_cost_usd, is_error, usage, model_usage,
                                          permission_denials: denials, duration_ms,
                                          duration_api_ms, .. } => {
                        text_delta_streaming = false; // turn complete
                        flush_text_buffer(&mut text_buffer, &mut client).await;

                        // Port detection fallback: scan assistant's response text.
                        // Catches cases where port isn't in the Bash command/output
                        // (e.g. `python3 server.py` with port inside the file).
                        // Only activate when NO tunnel is currently open — don't
                        // bounce between ports when one is already active.
                        if !turn_response_text.is_empty() && turn_used_bash {
                            if http_proxy.is_none() {
                                if let Some(port) = extract_port_from_text(&turn_response_text) {
                                    if browser_tunnel_always_allow {
                                        tracing::info!("Auto-opening tunnel to port {} from response text", port);
                                        http_proxy = Some(HttpProxy::new(port));
                                        let _ = client.send_relay_message(&RelayMessage::HttpTunnelStatus {
                                            active: true, port: Some(port), error: None,
                                        }).await;
                                    } else if pending_tunnel_port.is_none() {
                                        tracing::info!("Detected port {} from response text, requesting permission", port);
                                        pending_tunnel_port = Some(port);
                                        let action = crate::parser::ParsedMessage::Action {
                                            id: format!("tunnel-{}", port),
                                            prompt: format!("Open browser tunnel to localhost:{}?", port),
                                            options: vec!["Allow".to_string(), "Always".to_string(), "Deny".to_string()],
                                        };
                                        let _ = client.send_message(&action).await;
                                    }
                                }
                            }
                            turn_response_text.clear();
                            turn_used_bash = false;
                        }

                        // Update context window from model usage
                        for (_, mu) in &model_usage {
                            if mu.context_window > 0 {
                                context_window = mu.context_window;
                            }
                        }

                        // Clear thinking
                        let clear = crate::parser::ParsedMessage::Thinking { status: String::new() };
                        let _ = client.send_message(&clear).await;

                        // Send cost/usage info — use Result's authoritative totals
                        session_cost_usd = total_cost_usd;
                        total_input_tokens = usage.input_tokens;
                        total_output_tokens = usage.output_tokens;
                        cache_read_tokens = usage.cache_read_input_tokens;
                        cache_creation_tokens = usage.cache_creation_input_tokens;
                        sj_permission_denials = denials;
                        // Context remaining = window - ALL tokens (input + cache + output)
                        let total_consumed = total_input_tokens
                            .saturating_add(cache_read_tokens)
                            .saturating_add(cache_creation_tokens)
                            .saturating_add(total_output_tokens);
                        let context_pct = if context_window > 0 {
                            ((context_window.saturating_sub(total_consumed.min(context_window))) as f64
                                / context_window as f64 * 100.0) as u32
                        } else { 0 };
                        let _ = client.send_raw_json(&serde_json::json!({
                            "type": "UsageUpdate",
                            "isError": is_error,
                            "totalCostUsd": session_cost_usd,
                            "outputTokens": total_output_tokens,
                            "inputTokens": total_input_tokens,
                            "cacheReadInputTokens": cache_read_tokens,
                            "cacheCreationInputTokens": cache_creation_tokens,
                            "contextRemainingPct": context_pct,
                            "contextWindow": context_window,
                            "durationMs": duration_ms,
                            "durationApiMs": duration_api_ms,
                            "permissionDenials": sj_permission_denials,
                        })).await;

                        // Format token counts for display
                        let fmt_tokens = |t: u64| -> String {
                            if t >= 1000 { format!("{:.1}k", t as f64 / 1000.0) }
                            else { format!("{}", t) }
                        };
                        gui_log!("Tokens: {} in / {} out / {}% context",
                            fmt_tokens(total_input_tokens.saturating_add(cache_read_tokens).saturating_add(cache_creation_tokens)),
                            fmt_tokens(total_output_tokens),
                            context_pct);
                        let duration_s = duration_ms as f64 / 1000.0;
                        if is_error {
                            gui_log!("Result (error): ${:.2} / {:.1}s", total_cost_usd, duration_s);
                        } else {
                            gui_log!("Result: ${:.2} / {:.1}s", total_cost_usd, duration_s);
                        }
                        // Update live state: Idle (turn complete)
                        {
                            let json = manager.write().await.update_live_state(session_id, |ls| {
                                ls.claude_status = ClaudeStatus::Idle;
                                ls.thinking_since = None;
                                ls.last_activity = "Idle".to_string();
                            });
                            if let Some(ref j) = json {
                                let _ = client.send_raw_json(j).await;
                            }
                        }
                    }

                    StreamEvent::ContentBlockStop { .. } => {
                        // Signals end of a content block. Currently informational —
                        // tool streaming completion is tracked via hooks.
                    }

                    _ => {}
                }
            }

            // Branch 10: Thinking status ticker (1s, only when thinking)
            _ = thinking_ticker.tick(), if thinking_since.is_some() => {
                if let Some(since) = thinking_since {
                    let elapsed = since.elapsed();
                    let secs = elapsed.as_secs();
                    let time_str = if secs >= 60 {
                        format!("{}m {}s", secs / 60, secs % 60)
                    } else {
                        format!("{}s", secs)
                    };
                    let token_str = if total_output_tokens >= 1000 {
                        format!("{:.1}k", total_output_tokens as f64 / 1000.0)
                    } else {
                        format!("{}", total_output_tokens)
                    };
                    let status = format!("Thinking... ({} · ↓ {} tokens)", time_str, token_str);
                    let msg = crate::parser::ParsedMessage::Thinking { status };
                    let _ = client.send_message(&msg).await;
                }
            }
        }

        // ── Device approval timeout check (fail-closed) ──
        // Runs after every select iteration. Expired approvals are denied.
        if !pending_device_approvals.is_empty() {
            let timeout = Duration::from_secs(DEVICE_APPROVAL_TIMEOUT_SECS);
            let expired: Vec<String> = pending_device_approvals.iter()
                .filter(|(_, &ts)| ts.elapsed() > timeout)
                .map(|(fp, _)| fp.clone())
                .collect();
            for fingerprint in expired {
                pending_device_approvals.remove(&fingerprint);
                let short_fp = &fingerprint[..16.min(fingerprint.len())];
                tracing::warn!("[{}] Device approval timed out ({}s) — denying: {}…",
                    &session_id[..12.min(session_id.len())], DEVICE_APPROVAL_TIMEOUT_SECS, short_fp);
                let _ = client.send_device_authorize_response(&fingerprint, false).await;
                let msg = crate::parser::ParsedMessage::System {
                    content: format!("Device approval timed out — denied: {}…", short_fp),
                };
                let _ = client.send_message(&msg).await;
                manager.write().await.append_event_line(
                    session_id, &format!("{} Device approval timeout — denied: {}…", event_ts(), short_fp));
            }
        }

    }

    // Cleanup hook directory for this session
    if let Some(ref dir) = hook_dir {
        dir.cleanup();
    }

    // Remove IPC symlink created for stream-json hook routing
    if let Some(ref csid) = claude_session_id {
        let claude_prefix = &csid[..8.min(csid.len())];
        let bridge_prefix = &session_id[..8.min(session_id.len())];
        if claude_prefix != bridge_prefix {
            let symlink = std::path::PathBuf::from("/tmp").join(format!("termopus-{}", claude_prefix));
            if symlink.symlink_metadata().map(|m| m.is_symlink()).unwrap_or(false) {
                let _ = std::fs::remove_file(&symlink);
            }
        }
    }

    // Kill stream-json session on exit
    let _ = stream_session.kill().await;
    let _ = client.close().await;

    // Clear saved claude_session_id — session ended cleanly, no resume needed.
    // If the bridge crashes mid-session, the file persists and enables recovery.
    storage::clear_claude_session_id(session_id);

    // Note: manager status update (Disconnected) is handled by run_session() caller

    Ok(())
}

/// Flush accumulated text buffer to the phone.
/// In stream-json mode, TextDelta text is already clean (no ANSI codes) and
/// structured events handle tool output separately. Skip the parse() regex
/// pipeline (ANSI strip + code-block + diff detection) — just send as Text.
async fn flush_text_buffer(buffer: &mut String, client: &mut RelayClient) {
    if buffer.is_empty() {
        return;
    }
    let msg = crate::parser::ParsedMessage::Text {
        content: std::mem::take(buffer),
    };
    let _ = client.send_message(&msg).await;
}

/// Calculate how many BTab (Shift+Tab) presses are needed to cycle
/// from the current permission mode to the target mode.
///
/// Claude Code's Shift+Tab cycles: default → acceptEdits → plan → default
/// (With agent teams active, delegate is also in the cycle)
///
/// Returns:
///   > 0: number of BTab presses needed
///   0: already in target mode
///   -1: target mode is not in the cycle (e.g. dontAsk, bypassPermissions)
fn btab_presses_needed(current: &str, target: &str) -> i32 {
    // The Shift+Tab cycle order (from Claude Code docs)
    const CYCLE: &[&str] = &["default", "acceptEdits", "plan"];

    if current == target {
        return 0;
    }

    let current_pos = CYCLE.iter().position(|&m| m == current);
    let target_pos = CYCLE.iter().position(|&m| m == target);

    match (current_pos, target_pos) {
        (Some(from), Some(to)) => {
            // Calculate forward distance in the cycle
            let len = CYCLE.len() as i32;
            ((to as i32 - from as i32 + len) % len)
        }
        _ => -1, // One or both modes not in cycle
    }
}

/// Check if a key/input would exit or suspend Claude Code.
///
/// Blocks: C-d (EOF/exit), C-z (suspend → shell), C-\ (SIGQUIT).
/// Note: C-c is NOT blocked here — it's rate-limited separately to allow
/// canceling operations while preventing rapid kills.
fn is_dangerous_key(key: &str) -> bool {
    matches!(key, "C-d" | "C-z" | "C-\\")
}

/// Check if text contains a command that would exit Claude Code.
///
/// Uses starts_with to catch variants like "/exit now" or "/quit ".
fn is_blocked_text(text: &str) -> bool {
    let trimmed = text.trim().to_lowercase();
    trimmed.starts_with("/exit") || trimmed.starts_with("/quit")
}

/// Encode a filesystem path the same way Claude Code does for project directory names.
///
/// Claude Code replaces both `/` and `_` with `-` in project directory names.
/// e.g. `/Users/foo/My_Project` → `-Users-foo-My-Project`
fn encode_path_for_claude(path: &str) -> String {
    path.replace('/', "-").replace('_', "-")
}

/// Look up the actual filesystem directory for a Claude project.
///
/// Claude Code encodes project paths by replacing `/` and `_` with `-`,
/// making the encoding ambiguous. To resolve this, we walk the path segments
/// and at each level check which real directory, when encoded, matches the
/// expected project dir name prefix.
fn resolve_project_dir(dir_name: &str) -> Option<String> {
    // dir_name is e.g. "-Users-youruser-my-project"
    // Start by listing top-level directories that could match
    // We know the path starts with /, so dir_name starts with -
    // Try to find the real path by walking from root

    // Quick check: direct decode (replace first - with /, rest with /)
    let simple = dir_name.replacen('-', "/", 1).replace('-', "/");
    if std::path::Path::new(&simple).is_dir() {
        return Some(simple);
    }

    // Smart resolution: walk from $HOME directory downward.
    // Most projects are under $HOME, so encode $HOME and match prefix.
    let home = std::env::var("HOME").ok()?;
    let home_encoded = encode_path_for_claude(&home);

    if !dir_name.starts_with(&home_encoded) {
        return None;
    }

    let remaining = &dir_name[home_encoded.len()..];
    if remaining.is_empty() {
        return Some(home);
    }

    // remaining starts with "-" followed by the project subdirectory encoded
    let remaining = remaining.trim_start_matches('-');
    if remaining.is_empty() {
        return Some(home);
    }

    // List directories in $HOME and find one whose encoded name matches
    if let Ok(entries) = std::fs::read_dir(&home) {
        for entry in entries.flatten() {
            if !entry.file_type().map(|ft| ft.is_dir()).unwrap_or(false) {
                continue;
            }
            let name = entry.file_name().to_string_lossy().to_string();
            let name_encoded = encode_path_for_claude(&name);
            if name_encoded == remaining {
                return Some(format!("{}/{}", home, name));
            }
            // Check deeper: remaining might be "subdir-deeper"
            if remaining.starts_with(&name_encoded) {
                let sub_remaining = &remaining[name_encoded.len()..];
                if sub_remaining.starts_with('-') {
                    // Recurse one level deeper
                    let parent = format!("{}/{}", home, name);
                    if let Ok(sub_entries) = std::fs::read_dir(&parent) {
                        let sub_target = sub_remaining.trim_start_matches('-');
                        for sub_entry in sub_entries.flatten() {
                            if !sub_entry.file_type().map(|ft| ft.is_dir()).unwrap_or(false) {
                                continue;
                            }
                            let sub_name = sub_entry.file_name().to_string_lossy().to_string();
                            if encode_path_for_claude(&sub_name) == sub_target {
                                return Some(format!("{}/{}", parent, sub_name));
                            }
                        }
                    }
                }
            }
        }
    }

    None
}

/// Look up which project directory a Claude session belongs to.
///
/// Scans `~/.claude/projects/*/sessions-index.json` for the given session UUID,
/// then resolves the project dir name back to a real filesystem path.
fn find_project_dir_for_session(session_uuid: &str) -> Option<String> {
    let home = std::env::var("HOME").ok()?;
    let projects_dir = std::path::PathBuf::from(&home).join(".claude/projects");
    if !projects_dir.exists() { return None; }

    if let Ok(entries) = std::fs::read_dir(&projects_dir) {
        for entry in entries.flatten() {
            let dir_name = entry.file_name().to_string_lossy().to_string();

            // Quick check: does the .jsonl file exist? (session must be resumable)
            let jsonl_path = entry.path().join(format!("{}.jsonl", session_uuid));
            if !jsonl_path.exists() {
                // Check sessions-index.json only as fallback
                let index_path = entry.path().join("sessions-index.json");
                if !index_path.exists() { continue; }
                if let Ok(content) = std::fs::read_to_string(&index_path) {
                    if !content.contains(session_uuid) { continue; }
                } else { continue; }
                // Session listed in index but .jsonl missing — not resumable
                tracing::warn!("Session {} listed in index but .jsonl missing in {}",
                    &session_uuid[..8.min(session_uuid.len())], dir_name);
                continue;
            }

            // Found the session — resolve the project directory
            if let Some(real_path) = resolve_project_dir(&dir_name) {
                return Some(real_path);
            }

            // Fallback: return $HOME
            tracing::warn!("Could not resolve project dir '{}', falling back to $HOME", dir_name);
            return Some(home);
        }
    }
    None
}

/// Read the sessions-index.json for the current project and return session entries.
///
/// Claude Code stores a sessions index per project at:
///   ~/.claude/projects/<project-hash>/sessions-index.json
/// We find the right project directory by matching the current working directory.
fn read_sessions_index(project_cwd: Option<&str>) -> anyhow::Result<Vec<crate::parser::SessionEntry>> {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let projects_dir = std::path::PathBuf::from(&home).join(".claude/projects");

    if !projects_dir.exists() {
        anyhow::bail!("No Claude projects directory found");
    }

    // Derive the project hash from the CWD (Claude Code uses path with / → -)
    // e.g. /Users/youruser/project/foo → -Users-youruser-project-foo
    let project_hash = project_cwd.map(|cwd| cwd.replace('/', "-"));

    let mut all_sessions: Vec<crate::parser::SessionEntry> = Vec::new();

    if let Ok(entries) = std::fs::read_dir(&projects_dir) {
        for entry in entries.flatten() {
            let dir_name = entry.file_name().to_string_lossy().to_string();

            // If we know the project, only read that project's sessions
            if let Some(ref hash) = project_hash {
                if dir_name != *hash {
                    continue;
                }
            }

            // Derive project name from directory hash:
            // e.g. "-Users-youruser-project-foo" → "foo"
            let project_name = dir_name
                .rfind("-project-")
                .map(|pos| &dir_name[pos + 9..])
                .unwrap_or(&dir_name)
                .to_string();

            let index_path = entry.path().join("sessions-index.json");
            if index_path.exists() {
                if let Ok(content) = std::fs::read_to_string(&index_path) {
                    if let Ok(index) = serde_json::from_str::<serde_json::Value>(&content) {
                        if let Some(entries) = index.get("entries").and_then(|e| e.as_array()) {
                            for e in entries {
                                let session = crate::parser::SessionEntry {
                                    session_id: e.get("sessionId")
                                        .and_then(|v| v.as_str())
                                        .unwrap_or_default()
                                        .to_string(),
                                    summary: e.get("summary")
                                        .and_then(|v| v.as_str())
                                        .unwrap_or("Untitled")
                                        .to_string(),
                                    first_prompt: e.get("firstPrompt")
                                        .and_then(|v| v.as_str())
                                        .unwrap_or_default()
                                        .chars().take(100).collect(),
                                    message_count: e.get("messageCount")
                                        .and_then(|v| v.as_u64())
                                        .unwrap_or(0) as u32,
                                    created: e.get("created")
                                        .and_then(|v| v.as_str())
                                        .unwrap_or_default()
                                        .to_string(),
                                    modified: e.get("modified")
                                        .and_then(|v| v.as_str())
                                        .unwrap_or_default()
                                        .to_string(),
                                    git_branch: e.get("gitBranch")
                                        .and_then(|v| v.as_str())
                                        .filter(|s| !s.is_empty())
                                        .map(|s| s.to_string()),
                                    project: project_name.clone(),
                                };
                                if !session.session_id.is_empty() {
                                    // Only include sessions whose .jsonl file exists (actually resumable)
                                    let jsonl = entry.path().join(format!("{}.jsonl", &session.session_id));
                                    if jsonl.exists() {
                                        all_sessions.push(session);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Sort by modified date descending (most recent first)
    all_sessions.sort_by(|a, b| b.modified.cmp(&a.modified));

    // Return top 100 most recent
    all_sessions.truncate(100);

    if all_sessions.is_empty() {
        anyhow::bail!("No sessions found");
    }

    Ok(all_sessions)
}

/// Read installed plugins from ~/.claude/plugins/installed_plugins.json
/// and check enabled status from ~/.claude/settings.json.
fn read_plugins() -> anyhow::Result<Vec<crate::parser::PluginEntry>> {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let base = std::path::PathBuf::from(&home).join(".claude");

    // Read installed_plugins.json
    let installed_path = base.join("plugins/installed_plugins.json");
    let installed: serde_json::Value = if installed_path.exists() {
        serde_json::from_str(&std::fs::read_to_string(&installed_path)?)?
    } else {
        anyhow::bail!("No installed_plugins.json found");
    };

    // Read settings.json for enabledPlugins
    let settings_path = base.join("settings.json");
    let settings: serde_json::Value = if settings_path.exists() {
        serde_json::from_str(&std::fs::read_to_string(&settings_path).unwrap_or_default())
            .unwrap_or(serde_json::Value::Null)
    } else {
        serde_json::Value::Null
    };
    let enabled_map = settings.get("enabledPlugins").and_then(|v| v.as_object());

    let plugins_obj = installed.get("plugins").and_then(|v| v.as_object());
    let mut entries = Vec::new();

    if let Some(plugins) = plugins_obj {
        for (plugin_id, versions) in plugins {
            let latest = versions.as_array().and_then(|a| a.first());
            let version = latest
                .and_then(|v| v.get("version"))
                .and_then(|v| v.as_str())
                .unwrap_or("unknown")
                .to_string();
            let install_path = latest
                .and_then(|v| v.get("installPath"))
                .and_then(|v| v.as_str())
                .unwrap_or("");

            let enabled = enabled_map
                .and_then(|m| m.get(plugin_id))
                .and_then(|v| v.as_bool())
                .unwrap_or(false);

            // Try to read plugin.json for metadata
            let plugin_json_path = std::path::Path::new(install_path)
                .join(".claude-plugin/plugin.json");
            let (name, description, author) = if plugin_json_path.exists() {
                let meta: serde_json::Value = std::fs::read_to_string(&plugin_json_path)
                    .ok()
                    .and_then(|s| serde_json::from_str(&s).ok())
                    .unwrap_or(serde_json::Value::Null);
                (
                    meta.get("name").and_then(|v| v.as_str()).unwrap_or(plugin_id).to_string(),
                    meta.get("description").and_then(|v| v.as_str()).map(|s| s.to_string()),
                    meta.get("author")
                        .and_then(|v| v.get("name"))
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string()),
                )
            } else {
                // Derive name from plugin_id (e.g. "rust-analyzer-lsp@..." → "rust-analyzer-lsp")
                let name = plugin_id.split('@').next().unwrap_or(plugin_id).to_string();
                (name, None, None)
            };

            // Count skills in this plugin
            let skills_dir = std::path::Path::new(install_path).join("skills");
            let skill_count = if skills_dir.is_dir() {
                std::fs::read_dir(&skills_dir)
                    .map(|entries| entries.filter_map(|e| e.ok()).filter(|e| e.path().is_dir()).count())
                    .unwrap_or(0) as u32
            } else {
                0
            };

            entries.push(crate::parser::PluginEntry {
                id: plugin_id.clone(),
                name,
                description,
                version,
                enabled,
                author,
                skill_count,
            });
        }
    }

    Ok(entries)
}

/// Read skills from global ~/.claude/skills/ and from all installed plugin skill directories.
/// Parses YAML frontmatter from each SKILL.md for name and description.
fn read_skills() -> anyhow::Result<Vec<crate::parser::SkillEntry>> {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let base = std::path::PathBuf::from(&home).join(".claude");
    let mut entries = Vec::new();

    // 1. Global skills from ~/.claude/skills/
    let global_skills_dir = base.join("skills");
    if global_skills_dir.is_dir() {
        if let Ok(dirs) = std::fs::read_dir(&global_skills_dir) {
            for dir in dirs.flatten() {
                if dir.path().is_dir() {
                    if let Some(skill) = parse_skill_md(&dir.path(), "global") {
                        entries.push(skill);
                    }
                }
            }
        }
    }

    // 2. Plugin-bundled skills (from each installed plugin's skills/ dir)
    let installed_path = base.join("plugins/installed_plugins.json");
    if installed_path.exists() {
        if let Ok(content) = std::fs::read_to_string(&installed_path) {
            if let Ok(installed) = serde_json::from_str::<serde_json::Value>(&content) {
                if let Some(plugins) = installed.get("plugins").and_then(|v| v.as_object()) {
                    for (plugin_id, versions) in plugins {
                        let install_path = versions.as_array()
                            .and_then(|a| a.first())
                            .and_then(|v| v.get("installPath"))
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        let skills_dir = std::path::Path::new(install_path).join("skills");
                        if skills_dir.is_dir() {
                            let source = plugin_id.split('@').next().unwrap_or(plugin_id);
                            if let Ok(dirs) = std::fs::read_dir(&skills_dir) {
                                for dir in dirs.flatten() {
                                    if dir.path().is_dir() {
                                        if let Some(skill) = parse_skill_md(&dir.path(), source) {
                                            entries.push(skill);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    entries.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(entries)
}

/// Parse a SKILL.md file's YAML frontmatter for name and description.
fn parse_skill_md(skill_dir: &std::path::Path, source: &str) -> Option<crate::parser::SkillEntry> {
    let skill_md = skill_dir.join("SKILL.md");
    if !skill_md.exists() {
        return None;
    }

    let content = std::fs::read_to_string(&skill_md).ok()?;

    // Parse YAML frontmatter between --- markers
    let mut name = skill_dir.file_name()?.to_string_lossy().to_string();
    let mut description = String::new();

    if content.starts_with("---") {
        if let Some(end) = content[3..].find("---") {
            let frontmatter = &content[3..3 + end];
            for line in frontmatter.lines() {
                let line = line.trim();
                if let Some(val) = line.strip_prefix("name:") {
                    name = val.trim().trim_matches('"').to_string();
                } else if let Some(val) = line.strip_prefix("description:") {
                    description = val.trim().trim_matches('"').to_string();
                }
            }
        }
    }

    Some(crate::parser::SkillEntry {
        name,
        description,
        source: source.to_string(),
    })
}

/// Read rules from ~/.claude/rules/ (global) and optionally project-level.
fn read_rules(project_cwd: Option<&str>) -> anyhow::Result<Vec<crate::parser::RuleEntry>> {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let base = std::path::PathBuf::from(&home).join(".claude");
    let mut entries = Vec::new();

    // 1. Global rules from ~/.claude/rules/
    let rules_dir = base.join("rules");
    if rules_dir.is_dir() {
        if let Ok(files) = std::fs::read_dir(&rules_dir) {
            for file in files.flatten() {
                let path = file.path();
                if path.is_file() && path.extension().map(|e| e == "md").unwrap_or(false) {
                    if let Ok(content) = std::fs::read_to_string(&path) {
                        let filename = path.file_name()
                            .map(|n| n.to_string_lossy().to_string())
                            .unwrap_or_default();
                        entries.push(crate::parser::RuleEntry {
                            filename,
                            content,
                            scope: "global".to_string(),
                        });
                    }
                }
            }
        }
    }

    // 2. Project-level CLAUDE.md (if we know the project CWD)
    if let Some(cwd) = project_cwd {
        let claude_md = std::path::Path::new(cwd).join("CLAUDE.md");
        if claude_md.exists() {
            if let Ok(content) = std::fs::read_to_string(&claude_md) {
                entries.push(crate::parser::RuleEntry {
                    filename: "CLAUDE.md".to_string(),
                    content,
                    scope: "project".to_string(),
                });
            }
        }
    }

    entries.sort_by(|a, b| a.filename.cmp(&b.filename));
    Ok(entries)
}

/// Read CLAUDE.md memory files from global (~/.claude/) and project CWD.
fn read_memory(project_cwd: Option<&str>) -> anyhow::Result<Vec<crate::parser::MemoryEntry>> {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let base = std::path::PathBuf::from(&home).join(".claude");
    let mut entries = Vec::new();

    // 1. Global CLAUDE.md
    let global_md = base.join("CLAUDE.md");
    if global_md.exists() {
        if let Ok(content) = std::fs::read_to_string(&global_md) {
            entries.push(crate::parser::MemoryEntry {
                filename: "CLAUDE.md".to_string(),
                content,
                scope: "global".to_string(),
            });
        }
    }

    // 2. Project-level CLAUDE.md (if we know the project CWD)
    if let Some(cwd) = project_cwd {
        let project_md = std::path::Path::new(cwd).join("CLAUDE.md");
        if project_md.exists() {
            if let Ok(content) = std::fs::read_to_string(&project_md) {
                entries.push(crate::parser::MemoryEntry {
                    filename: "CLAUDE.md".to_string(),
                    content,
                    scope: "project".to_string(),
                });
            }
        }

        // 3. Project-local CLAUDE.local.md
        let local_md = std::path::Path::new(cwd).join("CLAUDE.local.md");
        if local_md.exists() {
            if let Ok(content) = std::fs::read_to_string(&local_md) {
                entries.push(crate::parser::MemoryEntry {
                    filename: "CLAUDE.local.md".to_string(),
                    content,
                    scope: "project".to_string(),
                });
            }
        }
    }

    Ok(entries)
}

#[cfg(test)]
mod tests {
    use super::*;
}

