/// File transfer protocol constants and types.

/// Maximum raw chunk payload size in bytes.
/// Budget: 256KB CF limit - 28B AES-GCM - ~200B JSON envelope - base64 expansion.
/// Using 128KB for safe margin (base64 → ~171KB, encrypted → ~171KB).
pub const CHUNK_SIZE: usize = 128_000;

/// Number of chunks sent before waiting for ACK.
pub const WINDOW_SIZE: u32 = 5;

/// Send ACK after receiving this many chunks.
pub const ACK_INTERVAL: u32 = 5;

/// Timeout for receiving a chunk/ACK before cancelling.
pub const TRANSFER_TIMEOUT_SECS: u64 = 30;

/// Maximum file size (100 MB).
pub const MAX_FILE_SIZE: u64 = 100 * 1024 * 1024;

/// Base directory for all Termopus session data.
pub const SESSIONS_BASE: &str = ".termopus/sessions";

/// Subdirectory name for received files within a session.
pub const RECEIVED_SUBDIR: &str = "received";

/// Subdirectory name for outbox files within a session.
pub const OUTBOX_SUBDIR: &str = "outbox";

/// Get the session-specific directory: ~/.termopus/sessions/<session_id>/
pub fn session_dir(session_id: &str) -> Option<std::path::PathBuf> {
    // Use first 12 chars of session ID for shorter paths
    let short_id = &session_id[..session_id.len().min(12)];
    dirs::home_dir().map(|h| h.join(SESSIONS_BASE).join(short_id))
}

/// Get the outbox directory for a session.
pub fn outbox_dir(session_id: &str) -> Option<std::path::PathBuf> {
    session_dir(session_id).map(|d| d.join(OUTBOX_SUBDIR))
}

/// Get the received files directory for a session.
pub fn received_dir(session_id: &str) -> Option<std::path::PathBuf> {
    session_dir(session_id).map(|d| d.join(RECEIVED_SUBDIR))
}

/// Transfer direction.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Direction {
    PhoneToComputer,
    ComputerToPhone,
}

impl Direction {
    pub fn as_str(&self) -> &'static str {
        match self {
            Direction::PhoneToComputer => "phone_to_computer",
            Direction::ComputerToPhone => "computer_to_phone",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "phone_to_computer" => Some(Direction::PhoneToComputer),
            "computer_to_phone" => Some(Direction::ComputerToPhone),
            _ => None,
        }
    }
}

/// Calculate total chunks for a file of given size.
pub fn total_chunks(file_size: u64) -> u32 {
    if file_size == 0 {
        return 1;
    }
    ((file_size as f64) / (CHUNK_SIZE as f64)).ceil() as u32
}

/// Sanitize a filename: strip path components, prevent traversal.
pub fn sanitize_filename(name: &str) -> String {
    let name = name.replace(['/', '\\', '\0'], "");
    let name = name.trim_start_matches('.');
    if name.is_empty() {
        "unnamed_file".to_string()
    } else {
        name.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_chunk_count() {
        assert_eq!(total_chunks(0), 1);
        assert_eq!(total_chunks(1), 1);
        assert_eq!(total_chunks(128_000), 1);
        assert_eq!(total_chunks(128_001), 2);
        assert_eq!(total_chunks(100 * 1024 * 1024), 820); // 100 MB
    }

    #[test]
    fn test_sanitize_filename() {
        assert_eq!(sanitize_filename("photo.jpg"), "photo.jpg");
        assert_eq!(sanitize_filename("../../../etc/passwd"), "etcpasswd");
        assert_eq!(sanitize_filename(".hidden"), "hidden");
        assert_eq!(sanitize_filename("path/to/file.txt"), "pathtofile.txt");
        assert_eq!(sanitize_filename(""), "unnamed_file");
    }

    #[test]
    fn test_direction_roundtrip() {
        assert_eq!(
            Direction::from_str(Direction::PhoneToComputer.as_str()),
            Some(Direction::PhoneToComputer)
        );
        assert_eq!(
            Direction::from_str(Direction::ComputerToPhone.as_str()),
            Some(Direction::ComputerToPhone)
        );
        assert_eq!(Direction::from_str("invalid"), None);
    }

    #[test]
    fn test_chunk_size_fits_in_ws_frame() {
        // base64 expansion: ceil(128000 / 3) * 4 = ~170668
        // + ~200 bytes JSON envelope + 28 bytes AES-GCM = ~170896
        // Must be < 262144 (256 KB CF DO limit) — with wide margin
        let base64_size = ((CHUNK_SIZE + 2) / 3) * 4;
        let total_wire = base64_size + 200 + 28;
        assert!(total_wire < 262_144, "chunk too large: {} bytes", total_wire);
    }
}
