pub mod config;
pub mod permissions;
pub mod watcher;

use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

/// Base directory for hook file communication.
/// Structure:
///   {ipc_base}/termopus-{session_id}/events/    <- hooks write, bridge reads
///   {ipc_base}/termopus-{session_id}/responses/ <- bridge writes, hooks read
/// ipc_base: /tmp on Unix, %TEMP%\Termopus on Windows (see platform module)
pub struct HookDirectory {
    pub base: PathBuf,
    pub events_dir: PathBuf,
    pub responses_dir: PathBuf,
}

impl HookDirectory {
    /// Well-known base directory for IPC (platform-specific).
    /// Unix: /tmp (not env::temp_dir(), because macOS $TMPDIR varies per process).
    /// Windows: %TEMP%\Termopus (temp_dir() is consistent on Windows).
    fn ipc_base(session_prefix: &str) -> PathBuf {
        crate::platform::ipc_base().join(format!("termopus-{}", session_prefix))
    }

    pub fn new(session_id: &str) -> Result<Self> {
        let prefix = &session_id[..8.min(session_id.len())];
        let base = Self::ipc_base(prefix);
        let events_dir = base.join("events");
        let responses_dir = base.join("responses");

        // Create directories with restricted permissions
        crate::platform::secure_create_dir(&events_dir)?;
        crate::platform::secure_create_dir(&responses_dir)?;

        Ok(Self {
            base,
            events_dir,
            responses_dir,
        })
    }

    /// Write a response file for a PreToolUse hook.
    pub fn write_pre_tool_response(&self, request_id: &str, response: &PreToolUseResponse) -> Result<()> {
        let path = self.responses_dir.join(format!("{}.json", request_id));
        let json = serde_json::to_string(response)?;
        fs::write(&path, json)?;
        tracing::info!("Wrote PreToolUse response: {}", path.display());
        Ok(())
    }

    /// Clean up the entire directory on shutdown.
    pub fn cleanup(&self) {
        let _ = fs::remove_dir_all(&self.base);
        tracing::info!("Cleaned up hook directory: {}", self.base.display());
    }
}

impl Drop for HookDirectory {
    fn drop(&mut self) {
        self.cleanup();
    }
}

/// A hook event read from the events directory.
#[derive(Debug, Deserialize)]
pub struct HookEvent {
    #[serde(default)]
    pub session_id: String,
    pub hook_event_name: String,
    #[serde(default)]
    pub tool_name: Option<String>,
    #[serde(default)]
    pub tool_input: Option<serde_json::Value>,
    #[serde(default)]
    pub tool_response: Option<serde_json::Value>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub notification_type: Option<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    /// Path to conversation transcript JSONL (available in Stop and other events).
    #[serde(default)]
    pub transcript_path: Option<String>,
    /// Subagent unique ID (SubagentStart/SubagentStop events).
    #[serde(default)]
    pub agent_id: Option<String>,
    /// Subagent type, e.g. "Explore", "Bash", "Plan" (SubagentStart/SubagentStop events).
    #[serde(default)]
    pub agent_type: Option<String>,
    /// Path to subagent's transcript (SubagentStop only).
    #[serde(default)]
    pub agent_transcript_path: Option<String>,
    /// Current permission mode (available in all hook events).
    #[serde(default)]
    pub permission_mode: Option<String>,
    /// SessionStart: "startup" | "resume" | "clear" | "compact"
    #[serde(default)]
    pub source: Option<String>,
    /// UserPromptSubmit: user's prompt text
    #[serde(default)]
    pub prompt: Option<String>,
    /// SessionStart: model ID (renamed to avoid field conflicts)
    #[serde(default, rename = "model")]
    pub hook_model: Option<String>,
    /// SessionEnd: "clear" | "logout" | "prompt_input_exit" | ...
    #[serde(default)]
    pub reason: Option<String>,
    /// PreCompact: "manual" | "auto"
    #[serde(default)]
    pub trigger: Option<String>,
    /// TeammateIdle: the teammate's name
    #[serde(default)]
    pub teammate_name: Option<String>,
    /// TeammateIdle, TaskCompleted: team name
    #[serde(default)]
    pub team_name: Option<String>,
    /// TaskCompleted: task ID
    #[serde(default)]
    pub task_id: Option<String>,
    /// TaskCompleted: task subject line
    #[serde(default)]
    pub task_subject: Option<String>,
    /// Stop, SubagentStop: last assistant message text (v2.1.41+)
    #[serde(default)]
    pub last_assistant_message: Option<String>,
    /// Stop, SubagentStop: whether stop hook is active
    #[serde(default)]
    pub stop_hook_active: Option<bool>,
    /// Unique ID for this event (extracted from filename)
    #[serde(skip)]
    pub request_id: String,
}

/// Response for PreToolUse hooks.
#[derive(Debug, Serialize)]
pub struct PreToolUseResponse {
    #[serde(rename = "hookSpecificOutput")]
    pub hook_specific_output: PreToolUseOutput,
}

#[derive(Debug, Serialize)]
pub struct PreToolUseOutput {
    #[serde(rename = "hookEventName")]
    pub hook_event_name: String,
    #[serde(rename = "permissionDecision")]
    pub permission_decision: String,
    #[serde(rename = "permissionDecisionReason", skip_serializing_if = "Option::is_none")]
    pub permission_decision_reason: Option<String>,
}

impl PreToolUseResponse {
    pub fn allow() -> Self {
        Self {
            hook_specific_output: PreToolUseOutput {
                hook_event_name: "PreToolUse".to_string(),
                permission_decision: "allow".to_string(),
                permission_decision_reason: None,
            },
        }
    }

    pub fn deny(reason: &str) -> Self {
        Self {
            hook_specific_output: PreToolUseOutput {
                hook_event_name: "PreToolUse".to_string(),
                permission_decision: "deny".to_string(),
                permission_decision_reason: Some(reason.to_string()),
            },
        }
    }
}
