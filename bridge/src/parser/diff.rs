use super::{DiffLine, DiffLineType, ParsedMessage};
use regex::Regex;
use std::sync::OnceLock;

/// Regex matching the "diff --git a/... b/..." header line.
fn diff_header_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?m)^diff --git a/(.+?) b/(.+?)$").expect("Failed to compile diff header regex")
    })
}

/// Regex matching the "@@ -old,count +new,count @@" hunk header.
fn hunk_header_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")
            .expect("Failed to compile hunk header regex")
    })
}

/// Regex for "--- a/file" and "+++ b/file" lines.
fn file_marker_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"^(?:---|\+\+\+) (?:a/|b/)?(.+)$").expect("Failed to compile file marker regex")
    })
}

/// Parse git-style unified diff output into structured diff messages.
///
/// Detects `diff --git` headers, hunk headers, and +/- lines.
/// Returns `Some(Vec<ParsedMessage::Diff>)` if diff content is found,
/// `None` otherwise.
pub fn parse_diffs(text: &str) -> Option<Vec<ParsedMessage>> {
    let header_re = diff_header_regex();

    // Quick check: does the text contain any diff headers?
    if !header_re.is_match(text) {
        return None;
    }

    let mut messages = Vec::new();
    let mut current_file: Option<String> = None;
    let mut current_lines: Vec<DiffLine> = Vec::new();
    let mut add_line_num: u32 = 0;
    let mut remove_line_num: u32 = 0;

    let hunk_re = hunk_header_regex();
    let file_re = file_marker_regex();

    for line in text.lines() {
        // Check for a new diff file header
        if let Some(caps) = header_re.captures(line) {
            // Flush any previous diff
            if let Some(file) = current_file.take() {
                if !current_lines.is_empty() {
                    messages.push(ParsedMessage::Diff {
                        file,
                        lines: std::mem::take(&mut current_lines),
                    });
                }
            }

            let filename = caps.get(2).unwrap().as_str().to_string();
            current_file = Some(filename);
            continue;
        }

        // Skip --- a/file and +++ b/file lines
        if file_re.is_match(line) {
            // Optionally update the file name from +++ line
            if line.starts_with("+++ ") {
                if let Some(caps) = file_re.captures(line) {
                    let fname = caps.get(1).unwrap().as_str();
                    if fname != "/dev/null" {
                        current_file = Some(fname.to_string());
                    }
                }
            }
            continue;
        }

        // Check for hunk header
        if let Some(caps) = hunk_re.captures(line) {
            remove_line_num = caps.get(1).unwrap().as_str().parse().unwrap_or(1);
            add_line_num = caps.get(2).unwrap().as_str().parse().unwrap_or(1);

            // Add the hunk header as a context line
            current_lines.push(DiffLine {
                content: line.to_string(),
                line_type: DiffLineType::Context,
                line_number: None,
            });
            continue;
        }

        // Only process diff content lines when inside a diff block
        if current_file.is_some() {
            if let Some(stripped) = line.strip_prefix('+') {
                current_lines.push(DiffLine {
                    content: stripped.to_string(),
                    line_type: DiffLineType::Add,
                    line_number: Some(add_line_num),
                });
                add_line_num += 1;
            } else if let Some(stripped) = line.strip_prefix('-') {
                current_lines.push(DiffLine {
                    content: stripped.to_string(),
                    line_type: DiffLineType::Remove,
                    line_number: Some(remove_line_num),
                });
                remove_line_num += 1;
            } else if let Some(stripped) = line.strip_prefix(' ') {
                current_lines.push(DiffLine {
                    content: stripped.to_string(),
                    line_type: DiffLineType::Context,
                    line_number: Some(add_line_num),
                });
                add_line_num += 1;
                remove_line_num += 1;
            }
            // Lines that don't start with +, -, or space inside a diff are
            // metadata lines (e.g., "index ...", "new file mode ...") -- skip them.
        }
    }

    // Flush the last diff block
    if let Some(file) = current_file {
        if !current_lines.is_empty() {
            messages.push(ParsedMessage::Diff {
                file,
                lines: current_lines,
            });
        }
    }

    if messages.is_empty() {
        None
    } else {
        Some(messages)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_simple_diff() {
        let text = r#"diff --git a/src/main.rs b/src/main.rs
index 1234567..abcdefg 100644
--- a/src/main.rs
+++ b/src/main.rs
@@ -1,3 +1,4 @@
 fn main() {
-    println!("old");
+    println!("new");
+    println!("added");
 }
"#;
        let result = parse_diffs(text);
        assert!(result.is_some());
        let messages = result.unwrap();
        assert_eq!(messages.len(), 1);

        match &messages[0] {
            ParsedMessage::Diff { file, lines } => {
                assert_eq!(file, "src/main.rs");
                // Hunk header + 3 context + 1 remove + 2 add = multiple lines
                let adds = lines
                    .iter()
                    .filter(|l| l.line_type == DiffLineType::Add)
                    .count();
                let removes = lines
                    .iter()
                    .filter(|l| l.line_type == DiffLineType::Remove)
                    .count();
                assert_eq!(adds, 2);
                assert_eq!(removes, 1);
            }
            _ => panic!("Expected Diff message"),
        }
    }

    #[test]
    fn test_parse_multiple_file_diff() {
        let text = r#"diff --git a/foo.rs b/foo.rs
--- a/foo.rs
+++ b/foo.rs
@@ -1,2 +1,2 @@
-old foo
+new foo
diff --git a/bar.rs b/bar.rs
--- a/bar.rs
+++ b/bar.rs
@@ -1,2 +1,2 @@
-old bar
+new bar
"#;
        let result = parse_diffs(text);
        assert!(result.is_some());
        let messages = result.unwrap();
        assert_eq!(messages.len(), 2);
    }

    #[test]
    fn test_no_diff_in_text() {
        let text = "This is regular output with no diff content.";
        let result = parse_diffs(text);
        assert!(result.is_none());
    }

    #[test]
    fn test_diff_line_numbers() {
        let text = r#"diff --git a/test.rs b/test.rs
--- a/test.rs
+++ b/test.rs
@@ -10,3 +10,3 @@
 context line
-removed line
+added line
"#;
        let result = parse_diffs(text);
        assert!(result.is_some());
        let messages = result.unwrap();
        match &messages[0] {
            ParsedMessage::Diff { lines, .. } => {
                // Find the added line and check its line number
                let added = lines.iter().find(|l| l.line_type == DiffLineType::Add);
                assert!(added.is_some());
                assert_eq!(added.unwrap().line_number, Some(11));
            }
            _ => panic!("Expected Diff"),
        }
    }
}
