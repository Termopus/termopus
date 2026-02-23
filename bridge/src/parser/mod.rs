pub mod ansi;
pub mod code_block;
pub mod diff;

use serde::{Deserialize, Serialize};

use crate::safe_tools::SAFE_TOOLS;

/// Represents a structured message parsed from raw PTY output.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ParsedMessage {
    /// Plain text output from Claude Code
    Text { content: String },

    /// Code block with optional language tag
    Code { language: String, content: String },

    /// Git-style diff output
    Diff {
        file: String,
        lines: Vec<DiffLine>,
    },

    /// Action prompt requiring user response (e.g. [y/n], [allow/deny])
    Action {
        id: String,
        prompt: String,
        options: Vec<String>,
    },

    /// System-level message (connection status, errors, etc.)
    System { content: String },

    /// Tool use event from Claude Code hooks (structured tool invocation data)
    ToolUse {
        id: String,
        tool: String,
        status: String,
        input: serde_json::Value,
        #[serde(skip_serializing_if = "Option::is_none")]
        result: Option<serde_json::Value>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },

    /// Multi-choice question from Claude (AskUserQuestion tool).
    AskQuestion {
        id: String,
        questions: Vec<QuestionData>,
    },

    /// Claude's text response extracted from transcript (via Stop hook).
    ClaudeResponse { content: String },

    /// Claude's thinking/processing status (detected from terminal).
    Thinking { status: String },

    /// Background agent lifecycle event (SubagentStart/SubagentStop).
    SubagentEvent {
        agent_id: String,
        agent_type: String,
        status: String, // "started" | "stopped"
    },

    /// File offer from computer to phone (user must accept/decline).
    FileOffer {
        transfer_id: String,
        filename: String,
        mime_type: String,
        total_size: u64,
    },

    /// File transfer progress update.
    FileProgress {
        transfer_id: String,
        chunks_received: u32,
        total_chunks: u32,
    },

    /// File transfer completed (success or failure).
    FileComplete {
        transfer_id: String,
        filename: String,
        local_path: String,
        success: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },

    /// Config sync from Claude Code (model, permission mode).
    ConfigSync {
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        permission_mode: Option<String>,
    },

    /// List of resumable sessions (read from sessions-index.json).
    SessionList {
        sessions: Vec<SessionEntry>,
    },

    /// List of installed plugins (read from installed_plugins.json + settings.json).
    PluginList {
        plugins: Vec<PluginEntry>,
    },

    /// List of available skills (global + plugin-bundled, read from SKILL.md files).
    SkillList {
        skills: Vec<SkillEntry>,
    },

    /// List of rules files (read from ~/.claude/rules/).
    RulesList {
        rules: Vec<RuleEntry>,
    },

    /// Project memory content (CLAUDE.md files).
    MemoryContent {
        entries: Vec<MemoryEntry>,
    },

    /// Permission rules sync (allow/deny from settings.local.json).
    PermissionRulesSync {
        allow: Vec<String>,
        deny: Vec<String>,
    },

    /// Timeout dismissal for a stale Action card.
    ActionTimeout {
        action_id: String,
    },
}

/// A resumable conversation session (from Claude Code's sessions-index.json).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionEntry {
    pub session_id: String,
    pub summary: String,
    pub first_prompt: String,
    pub message_count: u32,
    pub created: String,
    pub modified: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub git_branch: Option<String>,
    pub project: String,
}

/// An installed Claude Code plugin.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PluginEntry {
    /// Plugin identifier (e.g. "superpowers@claude-plugins-official").
    pub id: String,
    /// Human-readable name (from plugin.json or derived from id).
    pub name: String,
    /// Description (from plugin.json, if available).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Version string.
    pub version: String,
    /// Whether the plugin is enabled in settings.json.
    pub enabled: bool,
    /// Author name (from plugin.json, if available).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    /// Number of skills this plugin provides.
    pub skill_count: u32,
}

/// A Claude Code skill (from global ~/.claude/skills/ or plugin-bundled).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillEntry {
    /// Skill name (from SKILL.md frontmatter).
    pub name: String,
    /// Description (from SKILL.md frontmatter).
    pub description: String,
    /// Where the skill comes from: "global" or plugin name.
    pub source: String,
}

/// A Claude Code rules file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuleEntry {
    /// Filename (e.g. "skills.md").
    pub filename: String,
    /// File content (full markdown text).
    pub content: String,
    /// Where the rule comes from: "global" or "project".
    pub scope: String,
}

/// A project memory entry (from CLAUDE.md files).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemoryEntry {
    pub filename: String,
    pub content: String,
    /// Where the memory comes from: "global" or "project".
    pub scope: String,
}

/// A single line within a diff block.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiffLine {
    /// The text content of the line (without the leading +/- marker)
    pub content: String,
    /// Whether this line is an addition, removal, or context
    #[serde(rename = "type")]
    pub line_type: DiffLineType,
    /// Optional line number (for display purposes)
    pub line_number: Option<u32>,
}

/// Classification of a diff line.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum DiffLineType {
    Add,
    Remove,
    Context,
}

/// A single question with options from AskUserQuestion.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QuestionData {
    pub question: String,
    #[serde(default)]
    pub header: String,
    pub options: Vec<QuestionOption>,
    #[serde(default)]
    pub multi_select: bool,
}

/// An option within an AskUserQuestion.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QuestionOption {
    pub label: String,
    #[serde(default)]
    pub description: String,
}

/// Parse raw output bytes into structured messages.
///
/// This function strips ANSI escape codes, then attempts to detect:
/// 1. Markdown code blocks
/// 2. Git-style diffs
/// 3. Fallback to plain text
pub fn parse(raw: &[u8]) -> Vec<ParsedMessage> {
    let mut messages = Vec::new();

    // Strip ANSI escape codes for semantic parsing
    let text = ansi::strip_ansi_codes(raw);

    if text.trim().is_empty() {
        return messages;
    }

    // Check for markdown code blocks
    if let Some(code_messages) = code_block::parse_code_blocks(&text) {
        messages.extend(code_messages);
        return messages;
    }

    // Check for git diff output
    if let Some(diff_messages) = diff::parse_diffs(&text) {
        messages.extend(diff_messages);
        return messages;
    }

    // Default: plain text
    messages.push(ParsedMessage::Text {
        content: text.to_string(),
    });

    messages
}

impl ParsedMessage {
    /// Returns true if this message is an action that requires user response.
    pub fn needs_response(&self) -> bool {
        matches!(self, ParsedMessage::Action { .. })
    }

    /// Convert a user's response string to the appropriate PTY input.
    ///
    /// Maps common response words to the single-character inputs that
    /// Claude Code expects:
    ///   - "Yes" / "Allow" / "y" -> "y\n"
    ///   - "No" / "Deny" / "n"  -> "n\n"
    ///   - "Always" / "a"       -> "a\n"
    pub fn response_to_input(option: &str) -> Option<String> {
        match option.to_lowercase().as_str() {
            "allow" | "yes" | "y" => Some("y\n".to_string()),
            "deny" | "no" | "n" => Some("n\n".to_string()),
            "always" | "a" => Some("a\n".to_string()),
            other => Some(format!("{}\n", other)),
        }
    }

    /// Convert a hook event into a ParsedMessage.
    pub fn from_hook_event(event: &crate::hooks::HookEvent) -> Option<Self> {
        match event.hook_event_name.as_str() {
            "PostToolUse" => {
                let tool = event.tool_name.clone().unwrap_or_default();
                Some(ParsedMessage::ToolUse {
                    id: format!("hook-{}", event.request_id),
                    tool,
                    status: "success".to_string(),
                    input: event.tool_input.clone().unwrap_or(serde_json::Value::Null),
                    result: event.tool_response.clone(),
                    error: None,
                })
            }
            "PostToolUseFailure" => {
                let tool = event.tool_name.clone().unwrap_or_default();
                Some(ParsedMessage::ToolUse {
                    id: format!("hook-{}", event.request_id),
                    tool,
                    status: "error".to_string(),
                    input: event.tool_input.clone().unwrap_or(serde_json::Value::Null),
                    result: None,
                    error: event.error.clone(),
                })
            }
            "PreToolUse" => {
                let tool = event.tool_name.clone().unwrap_or_default();
                let input = event.tool_input.clone().unwrap_or(serde_json::Value::Null);

                // Skip PreToolUse for internal task management tools — they're noise.
                // PostToolUse has the result data we actually want to display.
                if matches!(tool.as_str(),
                    "TaskCreate" | "TaskUpdate" | "TaskList" | "TaskGet"
                    | "TodoWrite" | "TodoRead"
                ) {
                    return None;
                }

                // Special case: AskUserQuestion renders as interactive multi-choice card
                if tool == "AskUserQuestion" {
                    if let Some(questions_val) = input.get("questions") {
                        if let Ok(questions) = serde_json::from_value::<Vec<QuestionData>>(questions_val.clone()) {
                            return Some(ParsedMessage::AskQuestion {
                                id: format!("ask-{}", event.request_id),
                                questions,
                            });
                        }
                    }
                }

                if SAFE_TOOLS.contains(&tool.as_str()) {
                    return Some(ParsedMessage::ToolUse {
                        id: format!("hook-{}", event.request_id),
                        tool,
                        status: "pending".to_string(),
                        input,
                        result: None,
                        error: None,
                    });
                }

                // Dangerous tool — show approve/deny Action card on phone.
                // The hook binary is blocking, waiting for our response file.
                // Use "ptool-" prefix so ActionResponse handler writes PreToolUseResponse.
                let prompt = match tool.as_str() {
                    "Edit" => {
                        let file = input.get("file_path")
                            .and_then(|v| v.as_str())
                            .unwrap_or("unknown file");
                        format!("Edit {}", file)
                    }
                    "Write" => {
                        let file = input.get("file_path")
                            .and_then(|v| v.as_str())
                            .unwrap_or("unknown file");
                        format!("Create {}", file)
                    }
                    "Bash" => {
                        let cmd = input.get("command")
                            .and_then(|v| v.as_str())
                            .unwrap_or("command");
                        let short_cmd: String = if cmd.len() > 80 {
                            format!("{}...", &cmd.chars().take(77).collect::<String>())
                        } else {
                            cmd.to_string()
                        };
                        format!("Run: {}", short_cmd)
                    }
                    "NotebookEdit" => {
                        let nb = input.get("notebook_path")
                            .and_then(|v| v.as_str())
                            .unwrap_or("notebook");
                        format!("Edit notebook {}", nb)
                    }
                    "Task" => {
                        let desc = input.get("description")
                            .and_then(|v| v.as_str())
                            .unwrap_or("subagent");
                        format!("Launch: {}", desc)
                    }
                    _ => format!("{} tool", tool),
                };

                Some(ParsedMessage::Action {
                    id: format!("ptool-{}", event.request_id),
                    prompt,
                    options: vec!["Allow".to_string(), "Always".to_string(), "Deny".to_string()],
                })
            }
            "Notification" => {
                let msg = event.message.clone().unwrap_or_default();
                Some(ParsedMessage::System { content: msg })
            }
            "SubagentStart" => Some(ParsedMessage::SubagentEvent {
                agent_id: event.agent_id.clone().unwrap_or_default(),
                agent_type: event.agent_type.clone().unwrap_or_else(|| "Agent".to_string()),
                status: "started".to_string(),
            }),
            "SubagentStop" => Some(ParsedMessage::SubagentEvent {
                agent_id: event.agent_id.clone().unwrap_or_default(),
                agent_type: event.agent_type.clone().unwrap_or_else(|| "Agent".to_string()),
                status: "stopped".to_string(),
            }),
            "SessionStart" => {
                let source = event.source.as_deref().unwrap_or("startup");
                Some(ParsedMessage::System {
                    content: format!("Session started ({})", source),
                })
            }
            "SessionEnd" => {
                let reason = event.reason.as_deref().unwrap_or("unknown");
                Some(ParsedMessage::System {
                    content: format!("Session ended ({})", reason),
                })
            }
            "UserPromptSubmit" => {
                Some(ParsedMessage::Thinking {
                    status: "Processing prompt...".to_string(),
                })
            }
            "TeammateIdle" => {
                let name = event.teammate_name.as_deref().unwrap_or("unknown");
                Some(ParsedMessage::System {
                    content: format!("Teammate '{}' went idle", name),
                })
            }
            "TaskCompleted" => {
                let subject = event.task_subject.as_deref().unwrap_or("unknown task");
                Some(ParsedMessage::System {
                    content: format!("Task completed: {}", subject),
                })
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_plain_text() {
        let raw = b"Hello, world!";
        let messages = parse(raw);
        assert_eq!(messages.len(), 1);
        match &messages[0] {
            ParsedMessage::Text { content } => {
                assert_eq!(content, "Hello, world!");
            }
            _ => panic!("Expected Text message"),
        }
    }

    #[test]
    fn test_parse_empty() {
        let raw = b"   \n  \n  ";
        let messages = parse(raw);
        assert!(messages.is_empty());
    }

    #[test]
    fn test_response_to_input() {
        assert_eq!(ParsedMessage::response_to_input("yes"), Some("y\n".into()));
        assert_eq!(ParsedMessage::response_to_input("Allow"), Some("y\n".into()));
        assert_eq!(ParsedMessage::response_to_input("deny"), Some("n\n".into()));
        assert_eq!(ParsedMessage::response_to_input("No"), Some("n\n".into()));
        assert_eq!(
            ParsedMessage::response_to_input("custom"),
            Some("custom\n".into())
        );
    }

    #[test]
    fn test_file_offer_serialization() {
        let msg = ParsedMessage::FileOffer {
            transfer_id: "tx-1".to_string(),
            filename: "report.pdf".to_string(),
            mime_type: "application/pdf".to_string(),
            total_size: 5_000_000,
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"FileOffer\""));
        assert!(json.contains("\"filename\":\"report.pdf\""));
    }

    #[test]
    fn test_file_progress_serialization() {
        let msg = ParsedMessage::FileProgress {
            transfer_id: "tx-1".to_string(),
            chunks_received: 10,
            total_chunks: 22,
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"FileProgress\""));
        assert!(json.contains("\"chunks_received\":10"));
    }

    #[test]
    fn test_file_complete_serialization() {
        let msg = ParsedMessage::FileComplete {
            transfer_id: "tx-1".to_string(),
            filename: "report.pdf".to_string(),
            local_path: "/home/user/.termopus/received/report.pdf".to_string(),
            success: true,
            error: None,
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"FileComplete\""));
        assert!(json.contains("\"success\":true"));
    }
}
