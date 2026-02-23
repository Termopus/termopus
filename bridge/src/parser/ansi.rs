use regex::Regex;
use std::sync::OnceLock;

/// Compiled regex that matches ANSI escape sequences.
///
/// Covers:
/// - CSI sequences: ESC [ ... final_byte
/// - OSC sequences: ESC ] ... ST
/// - Simple two-byte sequences: ESC + single char
/// - Raw control characters (except newline, carriage return, tab)
fn ansi_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        // Match common ANSI escape sequences:
        // 1. CSI (Control Sequence Introducer): \x1b\[ followed by params and a final byte
        // 2. OSC (Operating System Command): \x1b\] ... terminated by BEL or ST
        // 3. Two-byte escape sequences: \x1b followed by a single character
        // 4. Other C0/C1 control codes (except \n \r \t)
        Regex::new(concat!(
            r"\x1b\[[0-9;?]*[A-Za-z]",     // CSI sequences
            r"|\x1b\][^\x07]*(?:\x07|\x1b\\)", // OSC sequences
            r"|\x1b[^\[\]()A-Za-z0-9]",    // Two-byte escape sequences (non-bracket/paren)
            r"|\x1b\([A-Za-z]",            // Character set selection
            r"|[\x00-\x08\x0b\x0c\x0e-\x1a\x1c-\x1f]", // Control chars (keep \n \r \t)
        ))
        .expect("Failed to compile ANSI regex")
    })
}

/// Strip all ANSI escape sequences and non-printable control characters from raw bytes.
///
/// Preserves newlines (`\n`), carriage returns (`\r`), and tabs (`\t`).
/// Returns a clean UTF-8 string suitable for semantic parsing.
pub fn strip_ansi_codes(raw: &[u8]) -> String {
    // Convert raw bytes to a string, replacing invalid UTF-8 with replacement char
    let text = String::from_utf8_lossy(raw);

    // Remove all ANSI escape sequences
    let cleaned = ansi_regex().replace_all(&text, "");

    // Normalize carriage returns: replace \r\n with \n, then standalone \r with \n
    let normalized = cleaned.replace("\r\n", "\n").replace('\r', "\n");

    normalized
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_strip_color_codes() {
        let input = b"\x1b[32mGreen text\x1b[0m";
        let result = strip_ansi_codes(input);
        assert_eq!(result, "Green text");
    }

    #[test]
    fn test_strip_bold() {
        let input = b"\x1b[1mBold\x1b[0m normal";
        let result = strip_ansi_codes(input);
        assert_eq!(result, "Bold normal");
    }

    #[test]
    fn test_preserve_newlines() {
        let input = b"line1\nline2\nline3";
        let result = strip_ansi_codes(input);
        assert_eq!(result, "line1\nline2\nline3");
    }

    #[test]
    fn test_strip_cursor_movement() {
        let input = b"\x1b[2J\x1b[HHello";
        let result = strip_ansi_codes(input);
        assert_eq!(result, "Hello");
    }

    #[test]
    fn test_plain_text_unchanged() {
        let input = b"Hello, world!";
        let result = strip_ansi_codes(input);
        assert_eq!(result, "Hello, world!");
    }

    #[test]
    fn test_carriage_return_normalization() {
        let input = b"line1\r\nline2\rline3";
        let result = strip_ansi_codes(input);
        assert_eq!(result, "line1\nline2\nline3");
    }
}
