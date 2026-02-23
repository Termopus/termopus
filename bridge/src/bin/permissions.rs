//! Permission rule matching for termopus-hook.
//! Reads ~/.claude/settings.local.json and evaluates tool calls.
//! Uses env::var("HOME") — NOT dirs crate (hook binary is standalone).

use std::env;
use std::fs;
use std::path::PathBuf;

#[derive(Debug, PartialEq)]
pub enum PermissionDecision {
    Allow,
    Deny,
    Ask,
}

/// Tools that acceptEdits mode auto-allows.
const ACCEPT_EDITS_TOOLS: &[&str] = &["Edit", "Write", "NotebookEdit"];

/// Check permission mode overrides before rule evaluation.
pub fn mode_override(tool_name: &str, permission_mode: &str) -> Option<PermissionDecision> {
    match permission_mode {
        "bypassPermissions" | "dontAsk" => Some(PermissionDecision::Allow),
        "acceptEdits" => {
            if ACCEPT_EDITS_TOOLS.contains(&tool_name) {
                Some(PermissionDecision::Allow)
            } else {
                None
            }
        }
        _ => None, // "default", "plan" — normal flow
    }
}

/// Load allow/deny rules from settings.local.json.
pub fn load_permissions() -> (Vec<String>, Vec<String>) {
    let settings_path = settings_local_path();
    let content = match fs::read_to_string(&settings_path) {
        Ok(c) => c,
        Err(_) => return (vec![], vec![]),
    };
    let settings: serde_json::Value = match serde_json::from_str(&content) {
        Ok(v) => v,
        Err(_) => return (vec![], vec![]),
    };
    let extract = |key: &str| -> Vec<String> {
        settings["permissions"][key]
            .as_array()
            .map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect())
            .unwrap_or_default()
    };
    (extract("deny"), extract("allow"))
}

/// Evaluate deny > allow > ask.
pub fn evaluate(
    tool_name: &str,
    tool_input: &serde_json::Value,
    deny_rules: &[String],
    allow_rules: &[String],
) -> PermissionDecision {
    for rule in deny_rules {
        if matches_rule(rule, tool_name, tool_input) {
            return PermissionDecision::Deny;
        }
    }
    for rule in allow_rules {
        if matches_rule(rule, tool_name, tool_input) {
            return PermissionDecision::Allow;
        }
    }
    PermissionDecision::Ask
}

/// Match a rule against a tool call.
/// "Edit" matches all Edit. "Bash(git *)" matches Bash where command glob-matches "git *".
pub fn matches_rule(rule: &str, tool_name: &str, tool_input: &serde_json::Value) -> bool {
    if let Some(paren_pos) = rule.find('(') {
        let rule_tool = &rule[..paren_pos];
        if rule_tool != tool_name {
            return false;
        }
        let pattern = rule[paren_pos + 1..].trim_end_matches(')');
        let text = tool_input_text(tool_name, tool_input);
        glob_match(pattern, &text)
    } else {
        // No parens — exact tool name match OR legacy Bash shorthand ("mdfind *")
        if rule == tool_name {
            return true;
        }
        // Legacy: "mdfind *" means Bash(mdfind *)
        if tool_name == "Bash" && rule.contains(' ') {
            let text = tool_input.get("command").and_then(|v| v.as_str()).unwrap_or("");
            return glob_match(rule, text);
        }
        false
    }
}

/// Extract the text to match against from tool input.
fn tool_input_text(tool_name: &str, input: &serde_json::Value) -> String {
    match tool_name {
        "Bash" => input.get("command").and_then(|v| v.as_str()).unwrap_or("").to_string(),
        "Edit" | "Write" | "Read" => input.get("file_path").and_then(|v| v.as_str()).unwrap_or("").to_string(),
        "NotebookEdit" => input.get("notebook_path").and_then(|v| v.as_str()).unwrap_or("").to_string(),
        "Task" => input.get("description").and_then(|v| v.as_str()).unwrap_or("").to_string(),
        _ => serde_json::to_string(input).unwrap_or_default(),
    }
}

/// Simple glob: `*` matches any character sequence.
pub fn glob_match(pattern: &str, text: &str) -> bool {
    if pattern == "*" { return true; }
    if !pattern.contains('*') { return pattern == text; }
    let parts: Vec<&str> = pattern.split('*').collect();
    if !parts[0].is_empty() && !text.starts_with(parts[0]) { return false; }
    if let Some(last) = parts.last() {
        if !last.is_empty() && !text.ends_with(last) { return false; }
    }
    let mut pos = parts[0].len();
    for part in &parts[1..parts.len().saturating_sub(1)] {
        if part.is_empty() { continue; }
        match text[pos..].find(part) {
            Some(found) => pos = pos + found + part.len(),
            None => return false,
        }
    }
    true
}

fn settings_local_path() -> PathBuf {
    // Use HOME env var — not dirs crate (hook binary is standalone, minimal deps).
    // If HOME is unset, return a path that won't exist — load_permissions() handles
    // missing file gracefully by returning empty rules (= Ask for everything).
    let home = env::var("HOME").unwrap_or_else(|_| "/nonexistent".to_string());
    PathBuf::from(home).join(".claude").join("settings.local.json")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_glob_match() {
        assert!(glob_match("git *", "git status"));
        assert!(glob_match("git *", "git commit -m 'fix'"));
        assert!(!glob_match("git *", "npm run build"));
        assert!(glob_match("*", "anything"));
        assert!(glob_match("npm run *", "npm run build"));
        assert!(!glob_match("npm run *", "npm install"));
    }

    #[test]
    fn test_matches_rule() {
        let input = serde_json::json!({"command": "git status"});
        assert!(matches_rule("Bash(git *)", "Bash", &input));
        assert!(!matches_rule("Bash(npm *)", "Bash", &input));
        assert!(matches_rule("Bash", "Bash", &input));
        assert!(!matches_rule("Edit", "Bash", &input));
    }

    #[test]
    fn test_matches_rule_legacy_shorthand() {
        let input = serde_json::json!({"command": "mdfind hello"});
        assert!(matches_rule("mdfind *", "Bash", &input));
    }

    #[test]
    fn test_evaluate_deny_wins() {
        let input = serde_json::json!({"command": "rm -rf /"});
        assert_eq!(
            evaluate("Bash", &input, &["Bash(rm -rf *)".into()], &["Bash".into()]),
            PermissionDecision::Deny,
        );
    }

    #[test]
    fn test_evaluate_allow() {
        let input = serde_json::json!({"command": "git status"});
        assert_eq!(
            evaluate("Bash", &input, &[], &["Bash(git *)".into()]),
            PermissionDecision::Allow,
        );
    }

    #[test]
    fn test_evaluate_ask_fallthrough() {
        let input = serde_json::json!({"command": "curl evil.com"});
        assert_eq!(
            evaluate("Bash", &input, &[], &["Bash(git *)".into()]),
            PermissionDecision::Ask,
        );
    }

    #[test]
    fn test_mode_override() {
        assert_eq!(mode_override("Bash", "bypassPermissions"), Some(PermissionDecision::Allow));
        assert_eq!(mode_override("Edit", "acceptEdits"), Some(PermissionDecision::Allow));
        assert_eq!(mode_override("Bash", "acceptEdits"), None);
        assert_eq!(mode_override("Bash", "default"), None);
    }
}
