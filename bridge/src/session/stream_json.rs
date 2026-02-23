//! Stream-JSON session backend for Claude Code.
//!
//! Uses `claude -p --output-format stream-json --input-format stream-json`
//! to get structured JSON events instead of terminal scraping.
//! See `docs/claude-code-cli-schema.md` for the full protocol specification.

use anyhow::{Context, Result};
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::mpsc;

/// A Claude Code session using the official stream-json protocol.
/// Replaces tmux terminal scraping with structured JSON events.
pub struct StreamJsonSession {
    child: Child,
    stdin_tx: mpsc::Sender<String>,
    event_rx: mpsc::Receiver<StreamEvent>,
    session_id: Option<String>,
    model: Option<String>,
    working_dir: String,
    env_vars: Vec<(String, String)>,
    system_prompt_file: Option<String>,
}

/// Parsed stream-json event (one JSON line from stdout).
#[derive(Debug, Clone)]
pub enum StreamEvent {
    Init {
        session_id: String,
        model: String,
        tools: Vec<String>,
        slash_commands: Vec<CommandInfo>,
        skills: Vec<CommandInfo>,
        agents: Vec<CommandInfo>,
        mcp_servers: Vec<ServerInfo>,
        plugins: Vec<PluginInfo>,
        permission_mode: String,
        version: String,
        fast_mode: String,
        api_key_source: String,
        cwd: String,
        output_style: String,
    },
    ThinkingStart,
    TextDelta {
        text: String,
    },
    ToolUseStart {
        tool_name: String,
        tool_id: String,
    },
    ToolInputDelta {
        partial_json: String,
    },
    /// Emitted when Claude Code shows a tool result (user event with tool_result content).
    /// `content` is the tool output text. Real CLI has no stderr field.
    ToolResult {
        tool_id: String,
        content: String,
        is_error: bool,
    },
    /// End of a content block (text or tool_use).
    ContentBlockStop {
        index: u64,
    },
    AssistantMessage {
        content_text: Option<String>,
        content_tool_use: Option<ToolUseInfo>,
        usage: UsageInfo,
    },
    /// Live token count + context compaction detection.
    /// Fires on every message_delta stream event.
    MessageDelta {
        input_tokens: u64,
        output_tokens: u64,
        cache_read_input_tokens: u64,
        cache_creation_input_tokens: u64,
        stop_reason: Option<String>,
        context_management: Option<ContextManagement>,
    },
    ThinkingStop,
    Result {
        text: String,
        subtype: String,
        is_error: bool,
        total_cost_usd: f64,
        num_turns: u32,
        duration_ms: u64,
        duration_api_ms: u64,
        usage: UsageInfo,
        model_usage: std::collections::HashMap<String, ModelUsage>,
        permission_denials: Vec<String>,
    },
    HookStarted {
        hook_id: String,
        hook_event: String,
        hook_name: String,
    },
    HookResponse {
        hook_id: String,
        hook_event: String,
        hook_name: String,
        outcome: String,
        output: Option<String>,
        exit_code: Option<i32>,
    },
}

#[derive(Debug, Clone)]
pub struct ContextManagement {
    pub applied_edits: Vec<serde_json::Value>,
}

#[derive(Debug, Clone)]
pub struct UsageInfo {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_input_tokens: u64,
    pub cache_creation_input_tokens: u64,
}

#[derive(Debug, Clone)]
pub struct ModelUsage {
    pub context_window: u64,
    pub max_output_tokens: u64,
    pub cost_usd: f64,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ToolUseInfo {
    pub id: String,
    pub name: String,
    pub input: serde_json::Value,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct CommandInfo {
    pub name: String,
    pub description: String,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ServerInfo {
    pub name: String,
    pub status: String,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct PluginInfo {
    pub name: String,
    pub path: String,
}

impl StreamJsonSession {
    /// Spawn a new Claude Code session with stream-json protocol.
    ///
    /// `system_prompt_file` path to a file whose contents are appended to
    /// the system prompt via `--append-system-prompt-file` (session-scoped,
    /// survives compaction). Pass `None` for no extra rules.
    pub async fn spawn(
        working_dir: &str,
        resume_session_id: Option<&str>,
        env_vars: Vec<(String, String)>,
        system_prompt_file: Option<&str>,
    ) -> Result<Self> {
        let mut cmd = Command::new("claude");
        cmd.args([
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-mode", "default",
        ]);

        // Expand sandbox to user's home directory so Claude can access
        // Desktop, Documents, etc. without --dangerously-skip-permissions.
        // Hooks still control tool permissions (PreToolUse gate).
        if let Ok(home) = std::env::var("HOME") {
            cmd.args(["--add-dir", &home]);
        }

        if let Some(path) = system_prompt_file {
            cmd.args(["--append-system-prompt-file", path]);
        }

        if let Some(sid) = resume_session_id {
            cmd.args(["--resume", sid]);
        }

        cmd.current_dir(working_dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit()) // inherit to avoid deadlock if buffer fills
            .env_remove("CLAUDECODE"); // allow spawning inside a Claude Code session

        for (k, v) in &env_vars {
            cmd.env(k, v);
        }

        let mut child = cmd.spawn()
            .context("Failed to spawn claude -p (is 'claude' installed?)")?;

        let (stdin_tx, event_rx) = setup_channels(&mut child)?;

        Ok(Self {
            child,
            stdin_tx,
            event_rx,
            session_id: None,
            model: None,
            working_dir: working_dir.to_string(),
            env_vars,
            system_prompt_file: system_prompt_file.map(|s| s.to_string()),
        })
    }

    /// Send a user message to Claude.
    ///
    /// Uses the `--input-format stream-json` wire format:
    /// `{"type":"user","message":{"role":"user","content":[{"type":"text","text":"..."}]}}`
    pub async fn send_message(&self, content: &str) -> Result<()> {
        let msg = serde_json::json!({
            "type": "user",
            "message": {
                "role": "user",
                "content": [{
                    "type": "text",
                    "text": content,
                }]
            }
        });
        self.stdin_tx.send(msg.to_string()).await
            .context("Failed to send to stdin")
    }

    /// Receive the next parsed event.
    pub async fn recv_event(&mut self) -> Option<StreamEvent> {
        self.event_rx.recv().await
    }

    /// Kill the child process.
    pub async fn kill(&mut self) -> Result<()> {
        self.child.kill().await.context("Failed to kill claude process")
    }

    /// Send SIGINT to the Claude process (equivalent to Ctrl+C).
    /// This interrupts the current operation without killing the session.
    pub fn interrupt(&self) -> Result<()> {
        let pid = self.child.id()
            .context("Cannot interrupt: child process already exited")?;
        // SAFETY: Sending SIGINT to a known child process.
        let ret = unsafe { libc::kill(pid as i32, libc::SIGINT) };
        if ret != 0 {
            anyhow::bail!("kill(SIGINT) failed: {}", std::io::Error::last_os_error());
        }
        Ok(())
    }

    /// Update stored session_id (called when Init event arrives).
    pub fn set_session_id(&mut self, sid: String) {
        self.session_id = Some(sid);
    }

    /// Update stored model (called when Init event arrives).
    pub fn set_model(&mut self, model: String) {
        self.model = Some(model);
    }

    /// Get the stored session_id.
    pub fn session_id(&self) -> Option<&str> {
        self.session_id.as_deref()
    }

    /// Get the stored model name.
    pub fn model(&self) -> Option<&str> {
        self.model.as_deref()
    }

    /// Update working directory (used when resuming a session from a different project).
    pub fn set_working_dir(&mut self, dir: String) {
        self.working_dir = dir;
    }

    /// Get the current working directory.
    pub fn working_dir(&self) -> &str {
        &self.working_dir
    }

    /// Respawn the Claude process with new flags, preserving the session.
    /// Used for model/permission switching mid-session.
    ///
    /// Flow: kill current -> respawn with --resume <session_id> + new flags
    /// The conversation is preserved via Claude Code's session persistence.
    pub async fn respawn(
        &mut self,
        model: Option<&str>,
        permission_mode: Option<&str>,
    ) -> Result<()> {
        self.respawn_with_session(None, model, permission_mode).await
    }

    /// Respawn with an explicit session ID to resume.
    /// If `resume_id` is None, uses the current session_id.
    pub async fn respawn_with_session(
        &mut self,
        resume_id: Option<&str>,
        model: Option<&str>,
        permission_mode: Option<&str>,
    ) -> Result<()> {
        let session_id = match resume_id {
            Some(sid) => sid.to_string(),
            None => self.session_id.clone()
                .context("No session_id — can't respawn without resume target")?,
        };

        // Kill current process
        self.kill().await?;

        // Build new command
        let mut cmd = Command::new("claude");
        cmd.args([
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--resume", &session_id,
        ]);

        if let Some(ref path) = self.system_prompt_file {
            cmd.args(["--append-system-prompt-file", path]);
        }

        if let Some(m) = model {
            cmd.args(["--model", m]);
        }
        if let Some(pm) = permission_mode {
            cmd.args(["--permission-mode", pm]);
        }

        // Expand sandbox to home directory (same as spawn)
        if let Ok(home) = std::env::var("HOME") {
            cmd.args(["--add-dir", &home]);
        }

        cmd.current_dir(&self.working_dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit()) // inherit to avoid deadlock if buffer fills
            .env_remove("CLAUDECODE"); // allow spawning inside a Claude Code session

        for (k, v) in &self.env_vars {
            cmd.env(k, v);
        }

        let mut child = cmd.spawn()
            .context("Failed to respawn claude -p")?;

        let (stdin_tx, event_rx) = setup_channels(&mut child)?;

        self.child = child;
        self.stdin_tx = stdin_tx;
        self.event_rx = event_rx;

        Ok(())
    }

    /// Spawn a fresh Claude session (no --resume), replacing the current process.
    /// Used by the "Start Fresh" / clear command to start a brand-new conversation.
    pub async fn spawn_fresh(
        &mut self,
        permission_mode: Option<&str>,
    ) -> Result<()> {
        // Kill current process
        self.kill().await?;

        // Build new command — same base args as spawn() but NO --resume
        let mut cmd = Command::new("claude");
        cmd.args([
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]);

        if let Some(pm) = permission_mode {
            cmd.args(["--permission-mode", pm]);
        } else {
            cmd.args(["--permission-mode", "default"]);
        }

        // Expand sandbox to user's home directory
        if let Ok(home) = std::env::var("HOME") {
            cmd.args(["--add-dir", &home]);
        }

        if let Some(ref path) = self.system_prompt_file {
            cmd.args(["--append-system-prompt-file", path]);
        }

        cmd.current_dir(&self.working_dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .env_remove("CLAUDECODE");

        for (k, v) in &self.env_vars {
            cmd.env(k, v);
        }

        let mut child = cmd.spawn()
            .context("Failed to spawn fresh claude -p")?;

        let (stdin_tx, event_rx) = setup_channels(&mut child)?;

        self.child = child;
        self.stdin_tx = stdin_tx;
        self.event_rx = event_rx;
        self.session_id = None; // Fresh session — no resume target

        Ok(())
    }
}

/// Wire up stdin/stdout channels for a spawned Claude process.
/// Extracts stdout and stdin from the child, creates mpsc channels,
/// and spawns async reader/writer tasks.
fn setup_channels(child: &mut Child) -> Result<(mpsc::Sender<String>, mpsc::Receiver<StreamEvent>)> {
    let stdout = child.stdout.take()
        .context("Failed to capture stdout")?;
    let stdin = child.stdin.take()
        .context("Failed to capture stdin")?;

    let (event_tx, event_rx) = mpsc::channel::<StreamEvent>(256);
    let (stdin_tx, mut stdin_rx) = mpsc::channel::<String>(64);

    // Stdout reader task — parse JSON lines into StreamEvents
    tokio::spawn(async move {
        let reader = BufReader::new(stdout);
        let mut lines = reader.lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if let Some(event) = parse_stream_line(&line) {
                if event_tx.send(event).await.is_err() {
                    break;
                }
            }
        }
    });

    // Stdin writer task — send JSON messages to Claude
    tokio::spawn(async move {
        let mut writer = stdin;
        while let Some(msg) = stdin_rx.recv().await {
            let line = format!("{}\n", msg);
            if writer.write_all(line.as_bytes()).await.is_err() {
                break;
            }
            let _ = writer.flush().await;
        }
    });

    Ok((stdin_tx, event_rx))
}

/// Parse one JSON line from stream-json stdout into a StreamEvent.
fn parse_stream_line(line: &str) -> Option<StreamEvent> {
    let obj: serde_json::Value = serde_json::from_str(line).ok()?;
    let event_type = obj["type"].as_str()?;

    match event_type {
        "system" => {
            let subtype = obj["subtype"].as_str()?;
            match subtype {
                "init" => {
                    // CLI emits string arrays: ["commit", "review", ...]
                    let parse_command_list = |key: &str| -> Vec<CommandInfo> {
                        obj[key].as_array()
                            .map(|a| a.iter().filter_map(|v| {
                                // Handle both string arrays and object arrays
                                if let Some(s) = v.as_str() {
                                    Some(CommandInfo { name: s.to_string(), description: String::new() })
                                } else {
                                    Some(CommandInfo {
                                        name: v["name"].as_str()?.to_string(),
                                        description: v["description"].as_str().unwrap_or("").to_string(),
                                    })
                                }
                            }).collect())
                            .unwrap_or_default()
                    };

                    Some(StreamEvent::Init {
                        session_id: obj["session_id"].as_str()?.to_string(),
                        model: obj["model"].as_str().unwrap_or("unknown").to_string(),
                        tools: obj["tools"].as_array()
                            .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
                            .unwrap_or_default(),
                        slash_commands: parse_command_list("slash_commands"),
                        skills: parse_command_list("skills"),
                        agents: parse_command_list("agents"),
                        mcp_servers: obj["mcp_servers"].as_array()
                            .map(|a| a.iter().filter_map(|v| {
                                Some(ServerInfo {
                                    name: v["name"].as_str()?.to_string(),
                                    status: v["status"].as_str().unwrap_or("unknown").to_string(),
                                })
                            }).collect())
                            .unwrap_or_default(),
                        plugins: obj["plugins"].as_array()
                            .map(|a| a.iter().filter_map(|v| {
                                Some(PluginInfo {
                                    name: v["name"].as_str()?.to_string(),
                                    path: v["path"].as_str().unwrap_or("").to_string(),
                                })
                            }).collect())
                            .unwrap_or_default(),
                        permission_mode: obj["permissionMode"].as_str().unwrap_or("default").to_string(),
                        version: obj["claude_code_version"].as_str().unwrap_or("?").to_string(),
                        fast_mode: obj["fast_mode_state"].as_str().unwrap_or("off").to_string(),
                        api_key_source: obj["apiKeySource"].as_str().unwrap_or("none").to_string(),
                        cwd: obj["cwd"].as_str().unwrap_or("").to_string(),
                        output_style: obj["output_style"].as_str().unwrap_or("default").to_string(),
                    })
                }
                "hook_started" => Some(StreamEvent::HookStarted {
                    hook_id: obj["hook_id"].as_str().unwrap_or("").to_string(),
                    hook_event: obj["hook_event"].as_str().unwrap_or("").to_string(),
                    hook_name: obj["hook_name"].as_str().unwrap_or("").to_string(),
                }),
                "hook_response" => Some(StreamEvent::HookResponse {
                    hook_id: obj["hook_id"].as_str().unwrap_or("").to_string(),
                    hook_event: obj["hook_event"].as_str().unwrap_or("").to_string(),
                    hook_name: obj["hook_name"].as_str().unwrap_or("").to_string(),
                    outcome: obj["outcome"].as_str().unwrap_or("").to_string(),
                    output: obj["output"].as_str().map(String::from),
                    exit_code: obj["exit_code"].as_i64().map(|v| v as i32),
                }),
                _ => None,
            }
        }
        "stream_event" => {
            let ev = &obj["event"];
            let ev_type = ev["type"].as_str()?;
            match ev_type {
                "message_start" => Some(StreamEvent::ThinkingStart),
                "content_block_start" => {
                    let block = &ev["content_block"];
                    match block["type"].as_str()? {
                        "tool_use" => Some(StreamEvent::ToolUseStart {
                            tool_name: block["name"].as_str().unwrap_or("").to_string(),
                            tool_id: block["id"].as_str().unwrap_or("").to_string(),
                        }),
                        "text" => Some(StreamEvent::TextDelta {
                            text: block["text"].as_str().unwrap_or("").to_string(),
                        }),
                        _ => None,
                    }
                }
                "content_block_delta" => {
                    let delta = &ev["delta"];
                    match delta["type"].as_str()? {
                        "text_delta" => Some(StreamEvent::TextDelta {
                            text: delta["text"].as_str().unwrap_or("").to_string(),
                        }),
                        "input_json_delta" => Some(StreamEvent::ToolInputDelta {
                            partial_json: delta["partial_json"].as_str().unwrap_or("").to_string(),
                        }),
                        _ => None,
                    }
                }
                "content_block_stop" => Some(StreamEvent::ContentBlockStop {
                    index: ev["index"].as_u64().unwrap_or(0),
                }),
                "message_delta" => {
                    let usage = &ev["usage"];
                    let delta = &ev["delta"];
                    let cm = ev["context_management"].as_object().and_then(|cm| {
                        let edits = cm.get("applied_edits")?.as_array()?;
                        if edits.is_empty() { return None; }
                        Some(ContextManagement {
                            applied_edits: edits.clone(),
                        })
                    });
                    Some(StreamEvent::MessageDelta {
                        input_tokens: usage["input_tokens"].as_u64().unwrap_or(0),
                        output_tokens: usage["output_tokens"].as_u64().unwrap_or(0),
                        cache_read_input_tokens: usage["cache_read_input_tokens"].as_u64().unwrap_or(0),
                        cache_creation_input_tokens: usage["cache_creation_input_tokens"].as_u64().unwrap_or(0),
                        stop_reason: delta["stop_reason"].as_str().map(String::from),
                        context_management: cm,
                    })
                }
                "message_stop" => Some(StreamEvent::ThinkingStop),
                _ => None,
            }
        }
        "assistant" => {
            let msg = &obj["message"];
            let content = msg["content"].as_array()?;
            // Collect ALL text blocks (concatenated) and ALL tool_use blocks.
            // Parallel tool calls produce multiple tool_use blocks in one message.
            let mut texts = Vec::new();
            let mut tools = Vec::new();
            for item in content {
                match item["type"].as_str()? {
                    "text" => {
                        if let Some(s) = item["text"].as_str() {
                            texts.push(s.to_string());
                        }
                    }
                    "tool_use" => tools.push(ToolUseInfo {
                        id: item["id"].as_str().unwrap_or("").to_string(),
                        name: item["name"].as_str().unwrap_or("").to_string(),
                        input: item["input"].clone(),
                    }),
                    _ => {}
                }
            }
            let text = if texts.is_empty() { None } else { Some(texts.join("\n")) };
            let tool = tools.into_iter().last(); // TODO: emit per-tool events for parallel calls
            let usage = &msg["usage"];
            Some(StreamEvent::AssistantMessage {
                content_text: text,
                content_tool_use: tool,
                usage: UsageInfo {
                    input_tokens: usage["input_tokens"].as_u64().unwrap_or(0),
                    output_tokens: usage["output_tokens"].as_u64().unwrap_or(0),
                    cache_read_input_tokens: usage["cache_read_input_tokens"].as_u64().unwrap_or(0),
                    cache_creation_input_tokens: usage["cache_creation_input_tokens"].as_u64().unwrap_or(0),
                },
            })
        }
        "user" => {
            let content = obj["message"]["content"].as_array()?;
            for item in content {
                if item["type"].as_str() == Some("tool_result") {
                    return Some(StreamEvent::ToolResult {
                        tool_id: item["tool_use_id"].as_str().unwrap_or("").to_string(),
                        content: item["content"].as_str().unwrap_or("").to_string(),
                        is_error: item["is_error"].as_bool().unwrap_or(false),
                    });
                }
            }
            None
        }
        "result" => {
            let usage = &obj["usage"];
            let mu = &obj["modelUsage"];
            let mut model_usage = std::collections::HashMap::new();
            if let Some(map) = mu.as_object() {
                for (model, data) in map {
                    model_usage.insert(model.clone(), ModelUsage {
                        context_window: data["contextWindow"].as_u64().unwrap_or(0),
                        max_output_tokens: data["maxOutputTokens"].as_u64().unwrap_or(0),
                        cost_usd: data["costUSD"].as_f64().unwrap_or(0.0),
                    });
                }
            }
            Some(StreamEvent::Result {
                text: obj["result"].as_str().unwrap_or("").to_string(),
                subtype: obj["subtype"].as_str().unwrap_or("success").to_string(),
                is_error: obj["is_error"].as_bool().unwrap_or(false),
                total_cost_usd: obj["total_cost_usd"].as_f64().unwrap_or(0.0),
                num_turns: obj["num_turns"].as_u64().unwrap_or(0) as u32,
                duration_ms: obj["duration_ms"].as_u64().unwrap_or(0),
                duration_api_ms: obj["duration_api_ms"].as_u64().unwrap_or(0),
                usage: UsageInfo {
                    input_tokens: usage["input_tokens"].as_u64().unwrap_or(0),
                    output_tokens: usage["output_tokens"].as_u64().unwrap_or(0),
                    cache_read_input_tokens: usage["cache_read_input_tokens"].as_u64().unwrap_or(0),
                    cache_creation_input_tokens: usage["cache_creation_input_tokens"].as_u64().unwrap_or(0),
                },
                model_usage,
                permission_denials: obj["permission_denials"].as_array()
                    .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
                    .unwrap_or_default(),
            })
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_init_event_string_arrays() {
        // Real CLI format: slash_commands/skills/agents are string arrays, plugins have path, output_style present
        let line = r#"{"type":"system","subtype":"init","session_id":"abc123","model":"claude-sonnet-4-5","tools":["Read","Write"],"slash_commands":["commit","review"],"skills":["frontend-design"],"agents":["Bash","Explore"],"mcp_servers":[],"plugins":[{"name":"superpowers","path":"/home/.claude/plugins/superpowers"}],"permissionMode":"default","claude_code_version":"2.1.39","fast_mode_state":"off","apiKeySource":"env","cwd":"/home/user","output_style":"default"}"#;
        let event = parse_stream_line(line).unwrap();
        match event {
            StreamEvent::Init { session_id, model, tools, slash_commands, skills, agents, plugins, permission_mode, output_style, .. } => {
                assert_eq!(session_id, "abc123");
                assert_eq!(model, "claude-sonnet-4-5");
                assert_eq!(tools, vec!["Read", "Write"]);
                assert_eq!(slash_commands.len(), 2);
                assert_eq!(slash_commands[0].name, "commit");
                assert_eq!(slash_commands[1].name, "review");
                assert_eq!(skills.len(), 1);
                assert_eq!(skills[0].name, "frontend-design");
                assert_eq!(agents.len(), 2);
                assert_eq!(agents[0].name, "Bash");
                assert_eq!(plugins.len(), 1);
                assert_eq!(plugins[0].name, "superpowers");
                assert_eq!(plugins[0].path, "/home/.claude/plugins/superpowers");
                assert_eq!(permission_mode, "default");
                assert_eq!(output_style, "default");
            }
            _ => panic!("Expected Init event"),
        }
    }

    #[test]
    fn test_parse_init_event_object_arrays() {
        // Backwards compat: if CLI ever sends object arrays, still works
        let line = r#"{"type":"system","subtype":"init","session_id":"abc123","model":"claude-sonnet-4-5","tools":["Read"],"slash_commands":[{"name":"/help","description":"Get help"}],"skills":[],"agents":[],"mcp_servers":[],"plugins":[],"permissionMode":"default","claude_code_version":"2.1.39","fast_mode_state":"off","apiKeySource":"env","cwd":"/home/user"}"#;
        let event = parse_stream_line(line).unwrap();
        match event {
            StreamEvent::Init { slash_commands, .. } => {
                assert_eq!(slash_commands.len(), 1);
                assert_eq!(slash_commands[0].name, "/help");
                assert_eq!(slash_commands[0].description, "Get help");
            }
            _ => panic!("Expected Init event"),
        }
    }

    #[test]
    fn test_parse_text_delta() {
        let line = r#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}}"#;
        let event = parse_stream_line(line).unwrap();
        match event {
            StreamEvent::TextDelta { text } => assert_eq!(text, "Hello"),
            _ => panic!("Expected TextDelta"),
        }
    }

    #[test]
    fn test_parse_message_delta() {
        let line = r#"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":31584,"output_tokens":150}}}"#;
        let event = parse_stream_line(line).unwrap();
        match event {
            StreamEvent::MessageDelta { input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, stop_reason, context_management } => {
                assert_eq!(input_tokens, 3);
                assert_eq!(output_tokens, 150);
                assert_eq!(cache_read_input_tokens, 31584);
                assert_eq!(cache_creation_input_tokens, 0);
                assert_eq!(stop_reason.as_deref(), Some("end_turn"));
                assert!(context_management.is_none());
            }
            _ => panic!("Expected MessageDelta"),
        }
    }

    #[test]
    fn test_parse_result_event() {
        let line = r#"{"type":"result","subtype":"success","is_error":false,"result":"Done","total_cost_usd":0.05,"num_turns":3,"duration_ms":5000,"duration_api_ms":4000,"usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"modelUsage":{"claude-sonnet-4-5":{"contextWindow":200000,"maxOutputTokens":16384,"costUSD":0.05}},"permission_denials":[]}"#;
        let event = parse_stream_line(line).unwrap();
        match event {
            StreamEvent::Result { total_cost_usd, num_turns, is_error, subtype, model_usage, .. } => {
                assert!((total_cost_usd - 0.05).abs() < f64::EPSILON);
                assert_eq!(num_turns, 3);
                assert!(!is_error);
                assert_eq!(subtype, "success");
                assert!(model_usage.contains_key("claude-sonnet-4-5"));
                assert_eq!(model_usage["claude-sonnet-4-5"].context_window, 200_000);
            }
            _ => panic!("Expected Result event"),
        }
    }

    #[test]
    fn test_parse_content_block_stop() {
        let line = r#"{"type":"stream_event","event":{"type":"content_block_stop","index":2}}"#;
        let event = parse_stream_line(line).unwrap();
        match event {
            StreamEvent::ContentBlockStop { index } => assert_eq!(index, 2),
            _ => panic!("Expected ContentBlockStop"),
        }
    }

    #[test]
    fn test_parse_hook_events() {
        let started = r#"{"type":"system","subtype":"hook_started","hook_id":"abc-123","hook_event":"PreToolUse","hook_name":"PreToolUse:test"}"#;
        let event = parse_stream_line(started).unwrap();
        match event {
            StreamEvent::HookStarted { hook_id, hook_event, hook_name } => {
                assert_eq!(hook_id, "abc-123");
                assert_eq!(hook_event, "PreToolUse");
                assert_eq!(hook_name, "PreToolUse:test");
            }
            _ => panic!("Expected HookStarted"),
        }

        let response = r#"{"type":"system","subtype":"hook_response","hook_id":"abc-123","hook_event":"PreToolUse","hook_name":"PreToolUse:test","outcome":"success","output":"ok","exit_code":0}"#;
        let event = parse_stream_line(response).unwrap();
        match event {
            StreamEvent::HookResponse { hook_id, hook_event, hook_name, outcome, output, exit_code } => {
                assert_eq!(hook_id, "abc-123");
                assert_eq!(hook_event, "PreToolUse");
                assert_eq!(hook_name, "PreToolUse:test");
                assert_eq!(outcome, "success");
                assert_eq!(output.as_deref(), Some("ok"));
                assert_eq!(exit_code, Some(0));
            }
            _ => panic!("Expected HookResponse"),
        }
    }

    #[test]
    fn test_parse_thinking_start_stop() {
        let start = r#"{"type":"stream_event","event":{"type":"message_start","message":{}}}"#;
        let stop = r#"{"type":"stream_event","event":{"type":"message_stop"}}"#;
        assert!(matches!(parse_stream_line(start), Some(StreamEvent::ThinkingStart)));
        assert!(matches!(parse_stream_line(stop), Some(StreamEvent::ThinkingStop)));
    }

    #[test]
    fn test_parse_invalid_json() {
        assert!(parse_stream_line("not json").is_none());
        assert!(parse_stream_line("{}").is_none());
        assert!(parse_stream_line(r#"{"type":"unknown"}"#).is_none());
    }
}
