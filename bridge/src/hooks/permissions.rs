//! Permission rule writing for the bridge.
//! Generates rules from tool calls and writes to settings.local.json.

use anyhow::Result;
use std::fs;
use std::path::PathBuf;

/// Build a permission rule string from a tool invocation.
/// Uses command-family grouping for Bash (e.g. "git status" → "Bash(git *)").
/// Other tools get blanket rules: "Edit", "Write", "Task", etc.
pub fn build_rule_for_tool(tool_name: &str, tool_input: &serde_json::Value) -> String {
    match tool_name {
        "Bash" => {
            let command = tool_input.get("command")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            if command.is_empty() {
                return "Bash".to_string();
            }
            // Use first word + * as pattern: "git status" -> "Bash(git *)"
            // Groups by command family (git, npm, cargo, ls, find, etc.)
            let first_word = command.split_whitespace().next().unwrap_or(command);
            if first_word == command {
                // Single-word command: exact match
                format!("Bash({})", command)
            } else {
                format!("Bash({} *)", first_word)
            }
        }
        // Non-Bash tools: blanket allow the tool class
        "Edit" | "Write" | "NotebookEdit" | "Task" => tool_name.to_string(),
        _ => tool_name.to_string(),
    }
}

/// Add a permission rule to settings.local.json permissions.allow.
/// Idempotent — won't add duplicates. Uses atomic write (tmp + rename).
pub fn add_allow_rule(rule: &str) -> Result<()> {
    let settings_path = settings_local_path()?;
    let content = fs::read_to_string(&settings_path).unwrap_or_else(|_| "{}".to_string());
    let mut settings: serde_json::Value = serde_json::from_str(&content)?;

    let perms = settings.as_object_mut().unwrap()
        .entry("permissions")
        .or_insert(serde_json::json!({"allow": [], "deny": []}));
    let allow = perms.as_object_mut().unwrap()
        .entry("allow")
        .or_insert(serde_json::json!([]));
    let arr = allow.as_array_mut()
        .ok_or_else(|| anyhow::anyhow!("permissions.allow is not an array"))?;

    let rule_val = serde_json::Value::String(rule.to_string());
    if !arr.contains(&rule_val) {
        arr.push(rule_val);
    }

    let tmp = settings_path.with_extension("tmp");
    fs::write(&tmp, serde_json::to_string_pretty(&settings)?)?;
    fs::rename(&tmp, &settings_path)?;
    tracing::info!("Added permission rule: {}", rule);
    Ok(())
}

/// Remove a permission rule from settings.local.json.
/// `list` is "allow" or "deny".
pub fn remove_rule(rule: &str, list: &str) -> Result<()> {
    if list != "allow" && list != "deny" {
        anyhow::bail!("Invalid permission list '{}': must be 'allow' or 'deny'", list);
    }
    let settings_path = settings_local_path()?;
    if !settings_path.exists() { return Ok(()); }

    let content = fs::read_to_string(&settings_path)?;
    let mut settings: serde_json::Value = serde_json::from_str(&content)?;

    if let Some(arr) = settings.pointer_mut(&format!("/permissions/{}", list))
        .and_then(|v| v.as_array_mut())
    {
        arr.retain(|v| v.as_str() != Some(rule));
    }

    let tmp = settings_path.with_extension("tmp");
    fs::write(&tmp, serde_json::to_string_pretty(&settings)?)?;
    fs::rename(&tmp, &settings_path)?;
    tracing::info!("Removed permission rule '{}' from {}", rule, list);
    Ok(())
}

/// Read current allow/deny rules from settings.local.json.
pub fn read_rules() -> (Vec<String>, Vec<String>) {
    let settings_path = match settings_local_path() {
        Ok(p) => p,
        Err(_) => return (vec![], vec![]),
    };
    let content = match fs::read_to_string(&settings_path) {
        Ok(c) => c,
        Err(_) => return (vec![], vec![]),
    };
    let settings: serde_json::Value = match serde_json::from_str(&content) {
        Ok(v) => v,
        Err(_) => return (vec![], vec![]),
    };
    let extract = |key: &str| -> Vec<String> {
        settings["permissions"][key].as_array()
            .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
            .unwrap_or_default()
    };
    (extract("allow"), extract("deny"))
}

fn settings_local_path() -> Result<PathBuf> {
    Ok(dirs::home_dir()
        .ok_or_else(|| anyhow::anyhow!("Cannot determine home directory"))?
        .join(".claude")
        .join("settings.local.json"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_rule_bash_multi_word() {
        let input = serde_json::json!({"command": "git status"});
        assert_eq!(build_rule_for_tool("Bash", &input), "Bash(git *)");
    }

    #[test]
    fn test_build_rule_bash_single_word() {
        let input = serde_json::json!({"command": "ls"});
        assert_eq!(build_rule_for_tool("Bash", &input), "Bash(ls)");
    }

    #[test]
    fn test_build_rule_bash_empty() {
        let input = serde_json::json!({});
        assert_eq!(build_rule_for_tool("Bash", &input), "Bash");
    }

    #[test]
    fn test_build_rule_file_tools() {
        let input = serde_json::json!({"file_path": "/tmp/foo.rs"});
        assert_eq!(build_rule_for_tool("Edit", &input), "Edit");
        assert_eq!(build_rule_for_tool("Write", &input), "Write");
    }

    #[test]
    fn test_build_rule_unknown_tool() {
        let input = serde_json::json!({"query": "hello"});
        assert_eq!(build_rule_for_tool("mcp__search", &input), "mcp__search");
    }
}
