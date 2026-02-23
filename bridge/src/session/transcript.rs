//! JSONL transcript reader for Claude Code's session transcripts.
//!
//! Claude Code persists full conversation transcripts at:
//!   `~/.claude/projects/{hash}/{session_uuid}.jsonl`
//!
//! This module reads the tail of those files for reconnect catchup.

use std::fs;
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::PathBuf;

/// A simplified message extracted from Claude's JSONL transcript.
#[derive(Debug, Clone, serde::Serialize)]
pub struct TranscriptMessage {
    /// Message UUID (if available)
    pub uuid: Option<String>,
    /// "user" or "assistant"
    pub role: String,
    /// Text content
    pub content: String,
    /// Tool uses in this message (for assistant messages)
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub tool_uses: Vec<TranscriptToolUse>,
    /// ISO timestamp
    pub timestamp: String,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct TranscriptToolUse {
    pub tool_name: String,
    pub tool_id: String,
}

/// Find the JSONL transcript file for a Claude session.
///
/// Scans `~/.claude/projects/*/` for `{claude_session_id}.jsonl`.
pub fn find_transcript(claude_session_id: &str) -> Option<PathBuf> {
    let home = dirs::home_dir()?;
    let projects_dir = home.join(".claude").join("projects");
    if !projects_dir.exists() {
        return None;
    }

    // Scan project directories for the transcript file
    let entries = fs::read_dir(&projects_dir).ok()?;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            let transcript = path.join(format!("{}.jsonl", claude_session_id));
            if transcript.exists() {
                return Some(transcript);
            }
        }
    }
    None
}

/// Read the last N messages from a Claude JSONL transcript.
///
/// Uses backward seeking for efficiency — O(N) in messages read,
/// not O(total file size).
pub fn read_transcript_tail(
    claude_session_id: &str,
    max_messages: usize,
) -> Vec<TranscriptMessage> {
    let path = match find_transcript(claude_session_id) {
        Some(p) => p,
        None => {
            tracing::debug!("No transcript found for {}", &claude_session_id[..8.min(claude_session_id.len())]);
            return Vec::new();
        }
    };

    // Read lines from the tail of the file
    let lines = match read_tail_lines(&path, max_messages * 3) {
        Ok(l) => l,
        Err(e) => {
            tracing::warn!("Failed to read transcript: {}", e);
            return Vec::new();
        }
    };

    // Parse JSONL lines into messages
    let mut messages = Vec::new();
    for line in &lines {
        if let Some(msg) = parse_transcript_line(line) {
            messages.push(msg);
        }
    }

    // Keep only the last N messages
    if messages.len() > max_messages {
        messages.drain(..messages.len() - max_messages);
    }

    messages
}

/// Read the last N lines from a file using backward seeking.
fn read_tail_lines(path: &PathBuf, max_lines: usize) -> std::io::Result<Vec<String>> {
    let file = fs::File::open(path)?;
    let file_size = file.metadata()?.len();

    if file_size == 0 {
        return Ok(Vec::new());
    }

    // For small files, just read all lines
    if file_size < 1_000_000 {
        let reader = BufReader::new(file);
        let all_lines: Vec<String> = reader.lines().filter_map(|l| l.ok()).collect();
        let start = all_lines.len().saturating_sub(max_lines);
        return Ok(all_lines[start..].to_vec());
    }

    // For large files, seek backward using raw File (no BufReader overhead)
    use std::io::Read;
    let mut file = file;
    let chunk_size: u64 = 256 * 1024; // 256KB chunks
    let mut offset = file_size;
    let mut chunks: Vec<Vec<u8>> = Vec::new();
    let mut total_newlines = 0;

    loop {
        let seek_to = offset.saturating_sub(chunk_size);
        file.seek(SeekFrom::Start(seek_to))?;

        let mut chunk = vec![0u8; (offset - seek_to) as usize];
        file.read_exact(&mut chunk)?;

        total_newlines += chunk.iter().filter(|&&b| b == b'\n').count();
        chunks.push(chunk);
        offset = seek_to;

        if total_newlines >= max_lines || seek_to == 0 {
            break;
        }
    }

    // Assemble chunks in correct order (they were read back-to-front)
    chunks.reverse();
    let mut tail_bytes = Vec::with_capacity(chunks.iter().map(|c| c.len()).sum());
    for chunk in chunks {
        tail_bytes.extend(chunk);
    }

    let text = String::from_utf8_lossy(&tail_bytes);
    let lines: Vec<String> = text.lines().map(|s| s.to_string()).collect();
    let start = lines.len().saturating_sub(max_lines);
    Ok(lines[start..].to_vec())
}

/// Parse a single JSONL line from Claude's transcript into a message.
pub fn parse_transcript_line(line: &str) -> Option<TranscriptMessage> {
    let obj: serde_json::Value = serde_json::from_str(line).ok()?;

    let msg_type = obj["type"].as_str()?;
    let uuid = obj["uuid"].as_str().map(String::from);
    let timestamp = obj["timestamp"].as_str()
        .unwrap_or("")
        .to_string();

    match msg_type {
        "user" => {
            let message = &obj["message"];
            let content = extract_text_content(message);
            if content.is_empty() {
                return None;
            }
            Some(TranscriptMessage {
                uuid,
                role: "user".to_string(),
                content,
                tool_uses: Vec::new(),
                timestamp,
            })
        }
        "assistant" => {
            let message = &obj["message"];
            let content = extract_text_content(message);
            let tool_uses = extract_tool_uses(message);
            // Skip empty assistant messages (e.g. pure tool_use with no text)
            if content.is_empty() && tool_uses.is_empty() {
                return None;
            }
            Some(TranscriptMessage {
                uuid,
                role: "assistant".to_string(),
                content,
                tool_uses,
                timestamp,
            })
        }
        _ => None,
    }
}

/// Extract text content from a message's content array.
fn extract_text_content(message: &serde_json::Value) -> String {
    let content = match message["content"].as_array() {
        Some(c) => c,
        None => return message["content"].as_str().unwrap_or("").to_string(),
    };

    let mut texts = Vec::new();
    for item in content {
        if item["type"].as_str() == Some("text") {
            if let Some(text) = item["text"].as_str() {
                if !text.is_empty() {
                    texts.push(text.to_string());
                }
            }
        }
    }
    texts.join("\n")
}

/// Extract tool uses from a message's content array.
fn extract_tool_uses(message: &serde_json::Value) -> Vec<TranscriptToolUse> {
    let content = match message["content"].as_array() {
        Some(c) => c,
        None => return Vec::new(),
    };

    content.iter().filter_map(|item| {
        if item["type"].as_str() == Some("tool_use") {
            Some(TranscriptToolUse {
                tool_name: item["name"].as_str().unwrap_or("").to_string(),
                tool_id: item["id"].as_str().unwrap_or("").to_string(),
            })
        } else {
            None
        }
    }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_user_message() {
        let line = r#"{"type":"user","uuid":"abc-123","message":{"role":"user","content":[{"type":"text","text":"hello world"}]},"timestamp":"2026-02-15T10:00:00Z"}"#;
        let msg = parse_transcript_line(line).unwrap();
        assert_eq!(msg.role, "user");
        assert_eq!(msg.content, "hello world");
        assert_eq!(msg.uuid, Some("abc-123".to_string()));
    }

    #[test]
    fn test_parse_assistant_message() {
        let line = r#"{"type":"assistant","uuid":"def-456","message":{"role":"assistant","content":[{"type":"text","text":"I'll help you"},{"type":"tool_use","name":"Read","id":"tool-1","input":{}}]},"timestamp":"2026-02-15T10:01:00Z"}"#;
        let msg = parse_transcript_line(line).unwrap();
        assert_eq!(msg.role, "assistant");
        assert_eq!(msg.content, "I'll help you");
        assert_eq!(msg.tool_uses.len(), 1);
        assert_eq!(msg.tool_uses[0].tool_name, "Read");
    }

    #[test]
    fn test_parse_result_line_skipped() {
        let line = r#"{"type":"result","subtype":"success"}"#;
        assert!(parse_transcript_line(line).is_none());
    }

    #[test]
    fn test_parse_invalid_json() {
        assert!(parse_transcript_line("not json").is_none());
        assert!(parse_transcript_line("{}").is_none());
    }
}
