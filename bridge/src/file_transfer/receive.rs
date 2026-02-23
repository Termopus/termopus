//! Receives chunked file transfers and reassembles them on disk.

use anyhow::{Context, Result};
use base64::Engine;
use sha2::{Sha256, Digest};
use std::collections::BTreeSet;
use std::path::PathBuf;
use std::time::Instant;

use super::protocol::{self, Direction, CHUNK_SIZE, MAX_FILE_SIZE, TRANSFER_TIMEOUT_SECS};

/// State for an in-progress file receive.
pub struct ReceiveState {
    pub transfer_id: String,
    pub filename: String,
    pub mime_type: String,
    pub total_size: u64,
    pub total_chunks: u32,
    pub expected_checksum: String,
    pub received_chunks: BTreeSet<u32>,
    pub data: Vec<Option<Vec<u8>>>,
    pub started_at: Instant,
}

impl ReceiveState {
    /// Create a new receive state from a FileTransferStart message.
    pub fn new(
        transfer_id: String,
        filename: String,
        mime_type: String,
        total_size: u64,
        total_chunks: u32,
        checksum: String,
    ) -> Result<Self> {
        if total_size > MAX_FILE_SIZE {
            anyhow::bail!(
                "File too large: {} bytes (max {} bytes)",
                total_size,
                MAX_FILE_SIZE
            );
        }

        // Validate total_chunks is consistent with total_size to prevent
        // DoS via crafted metadata (small size + huge chunk count).
        let expected_chunks = protocol::total_chunks(total_size);
        if total_chunks != expected_chunks {
            anyhow::bail!(
                "Invalid chunk count: got {} but expected {} for {} bytes",
                total_chunks,
                expected_chunks,
                total_size
            );
        }

        let safe_name = protocol::sanitize_filename(&filename);

        Ok(Self {
            transfer_id,
            filename: safe_name,
            mime_type,
            total_size,
            total_chunks,
            expected_checksum: checksum,
            received_chunks: BTreeSet::new(),
            data: vec![None; total_chunks as usize],
            started_at: Instant::now(),
        })
    }

    /// Process a received chunk. Returns true if all chunks are now received.
    pub fn add_chunk(&mut self, sequence: u32, data_b64: &str) -> Result<bool> {
        if sequence >= self.total_chunks {
            anyhow::bail!(
                "Chunk sequence {} out of range (total: {})",
                sequence,
                self.total_chunks
            );
        }

        let decoded = base64::engine::general_purpose::STANDARD
            .decode(data_b64)
            .context("Failed to decode chunk base64")?;

        if decoded.len() > CHUNK_SIZE {
            anyhow::bail!(
                "Chunk {} too large: {} bytes (max {})",
                sequence,
                decoded.len(),
                CHUNK_SIZE
            );
        }

        self.data[sequence as usize] = Some(decoded);
        self.received_chunks.insert(sequence);

        Ok(self.received_chunks.len() == self.total_chunks as usize)
    }

    /// Get the highest contiguous sequence number received.
    pub fn highest_contiguous(&self) -> u32 {
        let mut highest = 0u32;
        for &seq in &self.received_chunks {
            if seq == highest {
                highest = seq + 1;
            } else {
                break;
            }
        }
        highest.saturating_sub(1)
    }

    /// Check if the transfer has timed out.
    pub fn is_timed_out(&self) -> bool {
        self.started_at.elapsed().as_secs() > TRANSFER_TIMEOUT_SECS
    }

    /// Reassemble all chunks, verify checksum, and save to disk.
    /// Returns the full path where the file was saved.
    pub fn assemble_and_save(&self, session_id: &str) -> Result<PathBuf> {
        let recv_dir = protocol::received_dir(session_id)
            .ok_or_else(|| anyhow::anyhow!("Cannot determine home directory"))?;
        std::fs::create_dir_all(&recv_dir)?;

        // Reassemble
        let mut full_data = Vec::with_capacity(self.total_size as usize);
        for (i, chunk) in self.data.iter().enumerate() {
            let chunk = chunk
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("Missing chunk {}", i))?;
            full_data.extend_from_slice(chunk);
        }

        // Verify checksum
        let mut hasher = Sha256::new();
        hasher.update(&full_data);
        let computed = format!("{:x}", hasher.finalize());

        if computed != self.expected_checksum {
            anyhow::bail!(
                "Checksum mismatch: expected {}, got {}",
                self.expected_checksum,
                computed
            );
        }

        // Save -- avoid overwriting by appending counter if needed
        let mut dest = recv_dir.join(&self.filename);
        if dest.exists() {
            let stem = dest.file_stem().unwrap_or_default().to_string_lossy().to_string();
            let ext = dest.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
            let mut found = false;
            for i in 1..1000 {
                dest = recv_dir.join(format!("{} ({}){}", stem, i, ext));
                if !dest.exists() {
                    found = true;
                    break;
                }
            }
            if !found {
                anyhow::bail!("Cannot find unique filename for '{}' after 999 attempts", self.filename);
            }
        }

        std::fs::write(&dest, &full_data)?;
        tracing::info!("File saved: {} ({} bytes)", dest.display(), full_data.len());

        Ok(dest)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_test_state() -> ReceiveState {
        ReceiveState::new(
            "test-tx".to_string(),
            "test.txt".to_string(),
            "text/plain".to_string(),
            10,      // 10 bytes
            1,       // 1 chunk
            String::new(), // checksum checked separately
        )
        .unwrap()
    }

    #[test]
    fn test_add_chunk_completes() {
        let mut state = make_test_state();
        let data = base64::engine::general_purpose::STANDARD.encode(b"0123456789");
        let complete = state.add_chunk(0, &data).unwrap();
        assert!(complete);
        assert_eq!(state.received_chunks.len(), 1);
    }

    #[test]
    fn test_highest_contiguous() {
        // total_size must be consistent with total_chunks=5
        // 4 * CHUNK_SIZE + 1 = 768_001 bytes → ceil(768_001 / 192_000) = 5 chunks
        let total_size = (CHUNK_SIZE as u64) * 4 + 1;
        let mut state = ReceiveState::new(
            "tx".to_string(), "f.txt".to_string(), "text/plain".to_string(),
            total_size, 5, String::new(),
        ).unwrap();

        let chunk = base64::engine::general_purpose::STANDARD.encode(b"data");
        state.add_chunk(0, &chunk).unwrap();
        state.add_chunk(1, &chunk).unwrap();
        state.add_chunk(3, &chunk).unwrap(); // gap at 2
        assert_eq!(state.highest_contiguous(), 1);

        state.add_chunk(2, &chunk).unwrap(); // fill gap
        assert_eq!(state.highest_contiguous(), 3);
    }

    #[test]
    fn test_rejects_oversized_file() {
        let result = ReceiveState::new(
            "tx".to_string(), "big.bin".to_string(), "application/octet-stream".to_string(),
            MAX_FILE_SIZE + 1, 1000, String::new(),
        );
        assert!(result.is_err());
    }

    #[test]
    fn test_rejects_out_of_range_chunk() {
        let mut state = make_test_state();
        let data = base64::engine::general_purpose::STANDARD.encode(b"data");
        let result = state.add_chunk(5, &data); // only 1 chunk expected
        assert!(result.is_err());
    }
}
