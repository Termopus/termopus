use super::ParsedMessage;
use regex::Regex;
use std::sync::OnceLock;

/// Regex for matching markdown-style fenced code blocks.
///
/// Captures:
///   1. Optional language identifier after the opening ```
///   2. The content between the fences
fn code_block_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?ms)```(\w*)\s*\n(.*?)```").expect("Failed to compile code block regex")
    })
}

/// Parse markdown-style code blocks from text.
///
/// Detects patterns like:
/// ```rust
/// fn main() { }
/// ```
///
/// Returns `Some(Vec<ParsedMessage::Code>)` if any code blocks are found,
/// `None` otherwise. Non-code-block text surrounding the blocks is also
/// emitted as `ParsedMessage::Text`.
pub fn parse_code_blocks(text: &str) -> Option<Vec<ParsedMessage>> {
    let re = code_block_regex();

    if !re.is_match(text) {
        return None;
    }

    let mut messages = Vec::new();
    let mut last_end = 0;

    for caps in re.captures_iter(text) {
        let full_match = caps.get(0).unwrap();

        // Emit any text before this code block
        let before = &text[last_end..full_match.start()];
        let before_trimmed = before.trim();
        if !before_trimmed.is_empty() {
            messages.push(ParsedMessage::Text {
                content: before_trimmed.to_string(),
            });
        }

        // Extract language and content
        let language = caps
            .get(1)
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
        let content = caps
            .get(2)
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();

        // Trim trailing whitespace from the content but preserve indentation
        let content = content.trim_end().to_string();

        messages.push(ParsedMessage::Code {
            language: if language.is_empty() {
                "text".to_string()
            } else {
                language
            },
            content,
        });

        last_end = full_match.end();
    }

    // Emit any trailing text after the last code block
    let after = &text[last_end..];
    let after_trimmed = after.trim();
    if !after_trimmed.is_empty() {
        messages.push(ParsedMessage::Text {
            content: after_trimmed.to_string(),
        });
    }

    if messages.is_empty() {
        None
    } else {
        Some(messages)
    }
}

/// Detect if a string looks like inline code (single backtick).
pub fn contains_inline_code(text: &str) -> bool {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r"`[^`]+`").expect("Failed to compile inline code regex"));
    re.is_match(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_single_code_block() {
        let text = "Here is some code:\n```rust\nfn main() {\n    println!(\"hello\");\n}\n```\nEnd.";
        let result = parse_code_blocks(text);
        assert!(result.is_some());
        let messages = result.unwrap();

        // Should have: Text("Here is some code:"), Code(...), Text("End.")
        assert_eq!(messages.len(), 3);

        match &messages[1] {
            ParsedMessage::Code { language, content } => {
                assert_eq!(language, "rust");
                assert!(content.contains("fn main()"));
            }
            _ => panic!("Expected Code message"),
        }
    }

    #[test]
    fn test_parse_code_block_no_language() {
        let text = "```\nsome code here\n```";
        let result = parse_code_blocks(text);
        assert!(result.is_some());
        let messages = result.unwrap();
        assert_eq!(messages.len(), 1);

        match &messages[0] {
            ParsedMessage::Code { language, content } => {
                assert_eq!(language, "text");
                assert_eq!(content, "some code here");
            }
            _ => panic!("Expected Code message"),
        }
    }

    #[test]
    fn test_multiple_code_blocks() {
        let text = "```python\nprint('hi')\n```\nSome text\n```js\nconsole.log('hi')\n```";
        let result = parse_code_blocks(text);
        assert!(result.is_some());
        let messages = result.unwrap();

        // Code, Text, Code
        let code_count = messages
            .iter()
            .filter(|m| matches!(m, ParsedMessage::Code { .. }))
            .count();
        assert_eq!(code_count, 2);
    }

    #[test]
    fn test_no_code_blocks() {
        let text = "This is just regular text without any code blocks.";
        let result = parse_code_blocks(text);
        assert!(result.is_none());
    }

    #[test]
    fn test_inline_code_detection() {
        assert!(contains_inline_code("Use `cargo build` to compile"));
        assert!(!contains_inline_code("No inline code here"));
    }
}
