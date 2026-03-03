//! Termopus Hook Script
//!
//! This binary is invoked by Claude Code's hook system.
//! It reads a JSON event from stdin, writes it to the events directory,
//! and for PreToolUse (the only blocking hook), waits for a response
//! file from the bridge.
//!
//! PreToolUse is the permission gate — it can block tools via
//! `permissionDecision: "deny"`.
//!
//! Communication is file-based — no sockets, no listening, outbound-only.

#[path = "permissions.rs"]
mod permissions;

use std::env;
use std::fs;
use std::io::Read;
use std::process;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[path = "../safe_tools.rs"]
mod safe_tools;
use safe_tools::SAFE_TOOLS;

fn main() {
    // Debug trace — gated behind env var for observability without noise
    if env::var("TERMOPUS_HOOK_DEBUG").is_ok() {
        use std::io::Write as _;
        if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(std::env::temp_dir().join("termopus-hook-trace.log")) {
            let ts = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();
            let _ = writeln!(f, "{} invoked pid={} env_session={:?}",
                ts, process::id(), env::var("TERMOPUS_SESSION_ID").ok());
        }
    }

    // Read JSON from stdin (Claude Code pipes hook event data here)
    let mut input = String::new();
    if let Err(e) = std::io::stdin().read_to_string(&mut input) {
        eprintln!("termopus-hook: failed to read stdin: {}", e);
        process::exit(1);
    }

    const MAX_EVENT_SIZE: usize = 1024 * 1024; // 1MB limit
    if input.len() > MAX_EVENT_SIZE {
        eprintln!("termopus-hook: event too large ({} bytes, max {})", input.len(), MAX_EVENT_SIZE);
        process::exit(1);
    }

    // Parse to get hook_event_name and session_id
    let event: serde_json::Value = match serde_json::from_str(&input) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("termopus-hook: invalid JSON: {}", e);
            process::exit(1);
        }
    };

    // Use TERMOPUS_SESSION_ID (set by the bridge in the tmux environment)
    // so we route to the bridge's directory, not Claude Code's internal session.
    // Fall back to Claude Code's session_id if the env var is missing.
    let session_id_owned: String = env::var("TERMOPUS_SESSION_ID")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| event["session_id"].as_str().filter(|s| !s.is_empty()).map(|s| s.to_string()))
        .unwrap_or_else(|| {
            eprintln!("termopus-hook: no TERMOPUS_SESSION_ID and no session_id in event");
            process::exit(1);
        });
    let session_id: &str = &session_id_owned;

    let hook_event = match event["hook_event_name"].as_str() {
        Some(s) if !s.is_empty() => s,
        _ => {
            eprintln!("termopus-hook: missing or empty hook_event_name");
            process::exit(1);
        }
    };

    // Determine the base directory.
    // Uses /tmp/ (not env::temp_dir()) because on macOS $TMPDIR varies per
    // process (/var/folders/.../T/) causing path mismatches between the bridge
    // (which creates the dirs) and this hook binary (spawned by Claude Code).
    // /tmp/ is a stable, well-known path on all Unix systems.
    let session_prefix: String = session_id.chars().take(8).collect();
    #[cfg(unix)]
    let ipc_base = std::path::Path::new("/tmp");
    #[cfg(windows)]
    let ipc_base_buf = std::env::temp_dir().join("Termopus");
    #[cfg(windows)]
    let ipc_base = ipc_base_buf.as_path();
    let primary_dir = ipc_base.join(format!("termopus-{}", &session_prefix));

    // No fallback scan — if the primary IPC directory doesn't exist, the bridge
    // isn't running for this session. For PreToolUse, output explicit "allow" so
    // Claude Code doesn't stall (fixes acceptEdits mode in non-Termopus sessions).
    // For all other hooks, silent exit is correct.
    if !primary_dir.join("events").exists() {
        if hook_event == "PreToolUse" {
            print!(r#"{{"hookSpecificOutput":{{"hookEventName":"PreToolUse","permissionDecision":"allow"}}}}"#);
        }
        process::exit(0);
    }
    let base_dir = primary_dir;
    let events_dir = base_dir.join("events");
    let responses_dir = base_dir.join("responses");

    // Generate unique request ID
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let request_id = format!("{:x}", rand_id());
    let filename = format!("{}-{}-{}.json", timestamp, hook_event, request_id);

    // PreToolUse: check permissions BEFORE writing event file.
    // Auto-decided tools exit immediately without writing an event file,
    // so the bridge never sees them and no phantom Action card is sent to phone.
    if hook_event == "PreToolUse" {
        let tool_name = event["tool_name"].as_str().unwrap_or("");
        let tool_input = &event["tool_input"];
        let permission_mode = event["permission_mode"].as_str().unwrap_or("default");

        // 1. Safe tools — auto-allow without event file
        if SAFE_TOOLS.contains(&tool_name) {
            print!(r#"{{"hookSpecificOutput":{{"hookEventName":"PreToolUse","permissionDecision":"allow"}}}}"#);
            process::exit(0);
        }

        // 2. Permission mode overrides (acceptEdits auto-allows Edit/Write, etc.)
        if let Some(decision) = permissions::mode_override(tool_name, permission_mode) {
            if decision == permissions::PermissionDecision::Allow {
                print!(r#"{{"hookSpecificOutput":{{"hookEventName":"PreToolUse","permissionDecision":"allow"}}}}"#);
                process::exit(0);
            }
        }

        // 3. settings.local.json rules: deny > allow > ask
        let (deny_rules, allow_rules) = permissions::load_permissions();
        match permissions::evaluate(tool_name, tool_input, &deny_rules, &allow_rules) {
            permissions::PermissionDecision::Deny => {
                print!(r#"{{"hookSpecificOutput":{{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Denied by permission rule"}}}}"#);
                process::exit(0);
            }
            permissions::PermissionDecision::Allow => {
                print!(r#"{{"hookSpecificOutput":{{"hookEventName":"PreToolUse","permissionDecision":"allow"}}}}"#);
                process::exit(0);
            }
            permissions::PermissionDecision::Ask => {
                // Needs phone input — fall through to write event + wait
            }
        }
    }

    // Write event to events directory using atomic write (tmp + rename).
    // For PreToolUse: only reached when phone input is needed (auto-decided tools exit above).
    // For all other hooks: always written so the bridge can process them.
    let event_path = events_dir.join(&filename);
    let tmp_path = event_path.with_extension("tmp");
    if let Err(e) = fs::write(&tmp_path, &input) {
        eprintln!("termopus-hook: failed to write event: {}", e);
        let _ = fs::remove_file(&tmp_path);
        process::exit(1);
    }
    if let Err(e) = fs::rename(&tmp_path, &event_path) {
        eprintln!("termopus-hook: failed to rename event file: {}", e);
        let _ = fs::remove_file(&tmp_path);
        process::exit(1);
    }

    // PreToolUse: wait for phone user's decision.
    if hook_event == "PreToolUse" {
        let response_path = responses_dir.join(format!("{}.json", request_id));
        let timeout = Duration::from_secs(300); // 5 minute timeout
        let start = Instant::now();

        loop {
            match fs::read_to_string(&response_path) {
                Ok(response) => {
                    let _ = fs::remove_file(&response_path);
                    // Output response JSON to stdout for Claude Code
                    print!("{}", response);
                    process::exit(0);
                }
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                    // File not ready yet, continue polling
                }
                Err(e) => {
                    eprintln!("termopus-hook: failed to read response: {}", e);
                    let _ = fs::remove_file(&response_path);
                }
            }

            if start.elapsed() > timeout {
                eprintln!("termopus-hook: timeout waiting for PreToolUse response");
                // On timeout, deny to be safe
                print!(r#"{{"hookSpecificOutput":{{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Phone user did not respond (timeout)"}}}}"#);
                process::exit(0);
            }

            thread::sleep(Duration::from_millis(10));
        }
    }

    // For non-blocking hooks (PostToolUse, Notification, Stop, etc.), exit immediately
    process::exit(0);
}

fn rand_id() -> u64 {
    use rand::Rng;
    rand::thread_rng().gen()
}
