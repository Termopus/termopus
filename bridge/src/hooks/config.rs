use anyhow::Result;
use std::fs;


/// Configures Claude Code hooks to use the termopus-hook binary.
///
/// Writes to ~/.claude/settings.local.json (user-local, not committed to repos).
/// This ensures Claude Code invokes our hook for PreToolUse, PostToolUse,
/// PostToolUseFailure, and Notification events.
///
/// Uses file locking to prevent corruption when multiple bridge instances
/// perform concurrent read-modify-write on the same settings file.
pub fn configure_hooks(hook_binary_path: &str) -> Result<()> {
    let claude_dir = dirs::home_dir()
        .ok_or_else(|| anyhow::anyhow!("Cannot determine home directory"))?
        .join(".claude");

    // Create .claude dir if it doesn't exist
    fs::create_dir_all(&claude_dir)?;

    // Acquire exclusive lock before read-modify-write
    let lock_path = claude_dir.join("settings.local.json.lock");
    let _lock = crate::platform::acquire_file_lock(&lock_path)?;

    let settings_path = claude_dir.join("settings.local.json");

    // Read existing settings or start fresh
    let mut settings: serde_json::Value = if settings_path.exists() {
        let content = fs::read_to_string(&settings_path)?;
        serde_json::from_str(&content).map_err(|e| {
            anyhow::anyhow!("Corrupt settings.local.json: {}. Please fix or remove the file.", e)
        })?
    } else {
        serde_json::json!({})
    };

    // Shell-quote the path to handle spaces (e.g. "Application Support").
    // Claude Code passes hook commands through `sh -c`, so unquoted spaces break.
    let quoted_path = crate::platform::quote_shell_path(hook_binary_path);

    // Build hooks configuration
    let hook_entry = serde_json::json!([
        {
            "matcher": ".*",
            "hooks": [
                {
                    "type": "command",
                    "command": quoted_path,
                    "timeout": 600
                }
            ]
        }
    ]);

    // Set hooks (preserve other settings)
    let hooks = settings
        .as_object_mut()
        .ok_or_else(|| anyhow::anyhow!("Settings is not a JSON object"))?
        .entry("hooks")
        .or_insert(serde_json::json!({}));

    let hooks_obj = hooks
        .as_object_mut()
        .ok_or_else(|| anyhow::anyhow!("hooks is not a JSON object"))?;

    // PreToolUse: fires before every tool execution — shows pending tool info on phone
    hooks_obj.insert("PreToolUse".to_string(), hook_entry.clone());
    // PostToolUse: fires after successful tool execution — shows results on phone
    hooks_obj.insert("PostToolUse".to_string(), hook_entry.clone());
    // PostToolUseFailure: fires after tool execution fails
    hooks_obj.insert("PostToolUseFailure".to_string(), hook_entry.clone());
    // Stop: fires when Claude finishes responding — extract text response from transcript
    hooks_obj.insert("Stop".to_string(), hook_entry.clone());
    // SubagentStart/SubagentStop: background agent lifecycle (non-blocking)
    hooks_obj.insert("SubagentStart".to_string(), hook_entry.clone());
    hooks_obj.insert("SubagentStop".to_string(), hook_entry.clone());
    // Notification: system notifications from Claude Code
    hooks_obj.insert("Notification".to_string(), serde_json::json!([
        {
            "matcher": ".*",
            "hooks": [
                {
                    "type": "command",
                    "command": quoted_path,
                    "timeout": 30
                }
            ]
        }
    ]));
    // SessionStart: fires when Claude session begins or resumes (non-blocking)
    hooks_obj.insert("SessionStart".to_string(), hook_entry.clone());
    // SessionEnd: fires when Claude session terminates (non-blocking)
    hooks_obj.insert("SessionEnd".to_string(), hook_entry.clone());
    // UserPromptSubmit: fires when user submits a prompt (non-blocking)
    hooks_obj.insert("UserPromptSubmit".to_string(), hook_entry.clone());
    // TeammateIdle: agent team member went idle (non-blocking)
    hooks_obj.insert("TeammateIdle".to_string(), hook_entry.clone());
    // TaskCompleted: a task was marked completed (non-blocking)
    hooks_obj.insert("TaskCompleted".to_string(), hook_entry.clone());

    // Write back
    let json_str = serde_json::to_string_pretty(&settings)?;
    fs::write(&settings_path, json_str)?;

    tracing::info!("Configured Claude Code hooks in {}", settings_path.display());
    Ok(())
}

/// Find the termopus-hook binary path.
/// Looks next to the main termopus binary first, then in PATH.
pub fn find_hook_binary() -> Result<String> {
    // Check next to current executable
    if let Ok(exe_path) = std::env::current_exe() {
        if let Some(parent) = exe_path.parent() {
            let hook_name = if cfg!(windows) { "termopus-hook.exe" } else { "termopus-hook" };
            let hook_path = parent.join(hook_name);
            if hook_path.exists() {
                return Ok(hook_path.to_string_lossy().to_string());
            }
        }
    }

    // Check in PATH using platform-specific tool (which/where.exe)
    if let Some(path) = crate::platform::find_in_path("termopus-hook") {
        return Ok(path);
    }

    Err(anyhow::anyhow!("termopus-hook binary not found"))
}

// ---------------------------------------------------------------------------
// Termopus rules (injected per-session via --append-system-prompt)
// ---------------------------------------------------------------------------

/// Build the Termopus system prompt rules.
///
/// Returns the rules text to be passed via `--append-system-prompt` when
/// spawning Claude Code. This keeps rules scoped to Termopus sessions only —
/// non-Termopus Claude sessions never see them.
///
/// Uses `$TERMOPUS_OUTBOX` / `$TERMOPUS_RECEIVED` env var references so each
/// session resolves its own per-session directories at runtime.
pub fn build_termopus_rules() -> String {
    r#"## Termopus (mobile remote control)

The user is controlling this session from their phone via Termopus.

### Sending files to the user's phone
- Copy files to the outbox directory: `$TERMOPUS_OUTBOX`
  Example: `cp report.pdf "$TERMOPUS_OUTBOX/"`
- The exact path is in the `TERMOPUS_OUTBOX` environment variable.
- Do NOT say you cannot send files. Use the outbox directory.

### Receiving files from the user's phone
- Files sent by the user from their phone are saved to: `$TERMOPUS_RECEIVED`
- The exact path is in the `TERMOPUS_RECEIVED` environment variable.
- When a file arrives, you will be told its path automatically.

### Browser preview (localhost tunnel)
- The user is on their phone — they CANNOT see your local screen or Chrome browser.
- Do NOT use Chrome DevTools, MCP browser tools, or open browsers locally. The user won't see them.
- Instead, just start a dev server and clearly state the port number.
- After starting the server, tell the user: "Tap the Browser button in Termopus to preview the page."
- The phone has a built-in browser tunnel that auto-detects the port and lets the user preview.
- If you create an HTML file, start a quick server: `python3 -m http.server <PORT>`
- Always use a specific port number (not 0 or random) so the tunnel can connect.
- After the server starts, tell the user: "Tap the Browser button in Termopus to preview the page.""#
        .to_string()
}


/// Remove termopus hooks from Claude Code settings.
pub fn remove_hooks() -> Result<()> {
    let claude_dir = dirs::home_dir()
        .ok_or_else(|| anyhow::anyhow!("Cannot determine home directory"))?
        .join(".claude");
    let settings_path = claude_dir.join("settings.local.json");

    if !settings_path.exists() {
        return Ok(());
    }

    // Acquire exclusive lock before read-modify-write
    let lock_path = claude_dir.join("settings.local.json.lock");
    let _lock = crate::platform::acquire_file_lock(&lock_path)?;

    let content = fs::read_to_string(&settings_path)?;
    let mut settings: serde_json::Value = serde_json::from_str(&content)?;

    if let Some(hooks) = settings.get_mut("hooks").and_then(|h| h.as_object_mut()) {
        hooks.remove("PreToolUse");
        hooks.remove("PostToolUse");
        hooks.remove("PostToolUseFailure");
        hooks.remove("PermissionRequest"); // legacy
        hooks.remove("Stop");
        hooks.remove("SubagentStart");
        hooks.remove("SubagentStop");
        hooks.remove("Notification");
        hooks.remove("SessionStart");
        hooks.remove("SessionEnd");
        hooks.remove("UserPromptSubmit");
        hooks.remove("TeammateIdle");
        hooks.remove("TaskCompleted");
    }

    let json_str = serde_json::to_string_pretty(&settings)?;
    fs::write(&settings_path, json_str)?;

    tracing::info!("Removed Claude Code hooks");
    Ok(())
}
