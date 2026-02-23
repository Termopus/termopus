//! Reads a local file and produces base64 chunks for sending.

use anyhow::{Context, Result};
use base64::Engine;
use sha2::{Sha256, Digest};
use std::path::Path;

use super::protocol::{self, CHUNK_SIZE, MAX_FILE_SIZE};

/// Prepared file ready to be sent chunk-by-chunk.
pub struct PreparedFile {
    pub transfer_id: String,
    pub filename: String,
    pub mime_type: String,
    pub total_size: u64,
    pub total_chunks: u32,
    pub checksum: String,
    chunks: Vec<String>, // base64-encoded chunks
    pub next_to_send: u32,
    pub acked_through: u32,
}

impl PreparedFile {
    /// Read a file from disk and prepare it for chunked transfer.
    pub fn from_path(transfer_id: String, path: &Path) -> Result<Self> {
        let data = std::fs::read(path).context("Failed to read file")?;

        if data.len() as u64 > MAX_FILE_SIZE {
            anyhow::bail!(
                "File too large: {} bytes (max {} bytes)",
                data.len(),
                MAX_FILE_SIZE
            );
        }

        let filename = path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| "unnamed_file".to_string());

        let filename = protocol::sanitize_filename(&filename);

        let mime_type = mime_from_extension(&filename);

        // Compute SHA-256 checksum
        let mut hasher = Sha256::new();
        hasher.update(&data);
        let checksum = format!("{:x}", hasher.finalize());

        // Split into base64 chunks
        let total_chunks = protocol::total_chunks(data.len() as u64);
        let mut chunks = Vec::with_capacity(total_chunks as usize);

        for chunk_data in data.chunks(CHUNK_SIZE) {
            let encoded = base64::engine::general_purpose::STANDARD.encode(chunk_data);
            chunks.push(encoded);
        }

        // Handle empty file edge case
        if chunks.is_empty() {
            chunks.push(base64::engine::general_purpose::STANDARD.encode(b""));
        }

        Ok(Self {
            transfer_id,
            filename,
            mime_type,
            total_size: data.len() as u64,
            total_chunks: chunks.len() as u32,
            checksum,
            chunks,
            next_to_send: 0,
            acked_through: 0,
        })
    }

    /// Get the next chunk to send (base64-encoded), if within window.
    pub fn next_chunk(&mut self, window_size: u32) -> Option<(u32, &str)> {
        if self.next_to_send >= self.total_chunks {
            return None;
        }
        if self.next_to_send >= self.acked_through.saturating_add(window_size) {
            return None; // Window full, wait for ACK
        }
        let seq = self.next_to_send;
        self.next_to_send += 1;
        Some((seq, &self.chunks[seq as usize]))
    }

    /// Update acked position (allows sending more chunks).
    pub fn handle_ack(&mut self, received_through: u32) {
        if received_through >= self.acked_through {
            self.acked_through = received_through + 1;
        }
    }

    /// Check if all chunks have been sent and acked.
    pub fn is_complete(&self) -> bool {
        self.next_to_send >= self.total_chunks
            && self.acked_through >= self.total_chunks
    }

    /// Check if all chunks have been sent (but not necessarily acked).
    pub fn all_sent(&self) -> bool {
        self.next_to_send >= self.total_chunks
    }
}

/// Simple MIME type detection from file extension.
fn mime_from_extension(filename: &str) -> String {
    let ext = filename
        .rsplit('.')
        .next()
        .unwrap_or("")
        .to_lowercase();

    match ext.as_str() {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "pdf" => "application/pdf",
        "txt" => "text/plain",
        "md" => "text/markdown",
        "json" => "application/json",
        "xml" => "application/xml",
        "html" | "htm" => "text/html",
        "css" => "text/css",
        "js" => "application/javascript",
        "ts" => "application/typescript",
        "rs" => "text/x-rust",
        "py" => "text/x-python",
        "dart" => "text/x-dart",
        "zip" => "application/zip",
        "tar" => "application/x-tar",
        "gz" => "application/gzip",
        "mp4" => "video/mp4",
        "mp3" => "audio/mpeg",
        _ => "application/octet-stream",
    }
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn test_prepare_file() {
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("test.txt");
        std::fs::write(&file_path, "Hello, world!").unwrap();

        let prepared = PreparedFile::from_path("tx-1".to_string(), &file_path).unwrap();
        assert_eq!(prepared.filename, "test.txt");
        assert_eq!(prepared.mime_type, "text/plain");
        assert_eq!(prepared.total_size, 13);
        assert_eq!(prepared.total_chunks, 1);
        assert!(!prepared.checksum.is_empty());
    }

    #[test]
    fn test_chunking_multi_chunk() {
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("big.bin");
        let mut f = std::fs::File::create(&file_path).unwrap();
        // Write 500KB (will need 4 chunks at 128KB each)
        let data = vec![0xABu8; 500_000];
        f.write_all(&data).unwrap();

        let prepared = PreparedFile::from_path("tx-2".to_string(), &file_path).unwrap();
        assert_eq!(prepared.total_chunks, 4); // ceil(500000/128000)
        assert_eq!(prepared.total_size, 500_000);
    }

    #[test]
    fn test_window_flow_control() {
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("data.bin");
        std::fs::write(&file_path, vec![0u8; 128_000 * 10]).unwrap(); // 10 chunks

        let mut prepared = PreparedFile::from_path("tx-3".to_string(), &file_path).unwrap();
        assert_eq!(prepared.total_chunks, 10);

        // Can send first 5 (window=5)
        for i in 0..5 {
            let (seq, _) = prepared.next_chunk(5).unwrap();
            assert_eq!(seq, i);
        }
        // Window full
        assert!(prepared.next_chunk(5).is_none());

        // ACK first 5
        prepared.handle_ack(4);
        // Now can send next 5
        for i in 5..10 {
            let (seq, _) = prepared.next_chunk(5).unwrap();
            assert_eq!(seq, i);
        }
        assert!(prepared.next_chunk(5).is_none());
        assert!(prepared.all_sent());

        prepared.handle_ack(9);
        assert!(prepared.is_complete());
    }

    #[test]
    fn test_rejects_oversized_file() {
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("huge.bin");
        // Create a file larger than MAX_FILE_SIZE by writing sparse
        let f = std::fs::File::create(&file_path).unwrap();
        f.set_len(MAX_FILE_SIZE + 1).unwrap();

        let result = PreparedFile::from_path("tx-4".to_string(), &file_path);
        assert!(result.is_err());
    }

    #[test]
    fn test_mime_detection() {
        assert_eq!(mime_from_extension("photo.jpg"), "image/jpeg");
        assert_eq!(mime_from_extension("doc.pdf"), "application/pdf");
        assert_eq!(mime_from_extension("code.rs"), "text/x-rust");
        assert_eq!(mime_from_extension("unknown.xyz"), "application/octet-stream");
    }
}
