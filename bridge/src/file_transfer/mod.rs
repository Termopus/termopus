pub mod protocol;
pub mod receive;
pub mod send;
pub mod zip;

use anyhow::Result;
use std::collections::HashMap;

use crate::parser::ParsedMessage;
use crate::relay::messages::RelayMessage;
use crate::relay::websocket::RelayClient;

use self::protocol::{Direction, WINDOW_SIZE, ACK_INTERVAL};
use self::receive::ReceiveState;
use self::send::PreparedFile;

/// Manages all active file transfers (both sending and receiving).
pub struct FileTransferManager {
    /// Session ID for per-session directories.
    session_id: String,
    /// Active receives (phone -> computer).
    receives: HashMap<String, ReceiveState>,
    /// Active sends (computer -> phone).
    sends: HashMap<String, PreparedFile>,
}

impl FileTransferManager {
    pub fn new(session_id: &str) -> Self {
        Self {
            session_id: session_id.to_string(),
            receives: HashMap::new(),
            sends: HashMap::new(),
        }
    }

    /// Handle an incoming FileTransferStart from the phone.
    pub async fn handle_start(
        &mut self,
        transfer_id: String,
        filename: String,
        mime_type: String,
        total_size: u64,
        total_chunks: u32,
        checksum: String,
        direction: &str,
        client: &mut RelayClient,
    ) -> Result<()> {
        match Direction::from_str(direction) {
            Some(Direction::PhoneToComputer) => {
                tracing::info!(
                    "Receiving file: {} ({} bytes, {} chunks)",
                    filename, total_size, total_chunks
                );

                let state = ReceiveState::new(
                    transfer_id.clone(),
                    filename.clone(),
                    mime_type.clone(),
                    total_size,
                    total_chunks,
                    checksum,
                )?;
                self.receives.insert(transfer_id.clone(), state);

                // Notify phone we're ready to receive
                let msg = ParsedMessage::System {
                    content: format!("Receiving file: {} ({} bytes)", filename, total_size),
                };
                client.send_message(&msg).await?;
            }
            _ => {
                tracing::warn!("Unexpected file transfer direction: {}", direction);
            }
        }
        Ok(())
    }

    /// Handle an incoming FileChunk.
    /// Returns Some(path) when the transfer is complete and saved to disk.
    pub async fn handle_chunk(
        &mut self,
        transfer_id: &str,
        sequence: u32,
        data: &str,
        client: &mut RelayClient,
    ) -> Result<Option<String>> {
        let state = self.receives.get_mut(transfer_id)
            .ok_or_else(|| anyhow::anyhow!("Unknown transfer: {}", transfer_id))?;

        let complete = state.add_chunk(sequence, data)?;

        // Send ACK periodically
        if sequence % ACK_INTERVAL == (ACK_INTERVAL - 1) || complete {
            let highest = state.highest_contiguous();
            let ack = RelayMessage::FileTransferAck {
                transfer_id: transfer_id.to_string(),
                received_through: highest,
            };
            tracing::debug!("Sending ACK through={}", highest);
            client.send_relay_message(&ack).await?;
        }

        // Send progress to phone
        let progress = ParsedMessage::FileProgress {
            transfer_id: transfer_id.to_string(),
            chunks_received: state.received_chunks.len() as u32,
            total_chunks: state.total_chunks,
        };
        client.send_message(&progress).await?;

        if complete {
            match state.assemble_and_save(&self.session_id) {
                Ok(path) => {
                    let filename = state.filename.clone();
                    let path_str = path.to_string_lossy().to_string();

                    // Notify phone
                    let done = ParsedMessage::FileComplete {
                        transfer_id: transfer_id.to_string(),
                        filename: filename.clone(),
                        local_path: path_str.clone(),
                        success: true,
                        error: None,
                    };
                    client.send_message(&done).await?;

                    self.receives.remove(transfer_id);

                    tracing::info!("File transfer complete: {}", path_str);
                    return Ok(Some(path_str));
                }
                Err(e) => {
                    let done = ParsedMessage::FileComplete {
                        transfer_id: transfer_id.to_string(),
                        filename: state.filename.clone(),
                        local_path: String::new(),
                        success: false,
                        error: Some(e.to_string()),
                    };
                    client.send_message(&done).await?;
                    self.receives.remove(transfer_id);
                }
            }
        }
        Ok(None)
    }

    /// Start sending a file to the phone.
    /// Returns a FileOffer ParsedMessage to send to the phone.
    pub fn prepare_send(&mut self, prepared: PreparedFile) -> ParsedMessage {
        let offer = ParsedMessage::FileOffer {
            transfer_id: prepared.transfer_id.clone(),
            filename: prepared.filename.clone(),
            mime_type: prepared.mime_type.clone(),
            total_size: prepared.total_size,
        };
        self.sends.insert(prepared.transfer_id.clone(), prepared);
        offer
    }

    /// Handle an ACK from the phone for an outgoing transfer.
    /// Returns chunks to send next.
    ///
    /// For computer→phone transfers, sends ALL remaining chunks at once
    /// (no flow control) since the phone doesn't send subsequent ACKs.
    pub fn handle_send_ack(
        &mut self,
        transfer_id: &str,
        received_through: u32,
    ) -> Vec<RelayMessage> {
        let mut messages = Vec::new();

        if let Some(prepared) = self.sends.get_mut(transfer_id) {
            prepared.handle_ack(received_through);

            // Send ALL remaining chunks at once (unlimited window).
            // The phone collects them and assembles on its side.
            while let Some((seq, data)) = prepared.next_chunk(u32::MAX) {
                messages.push(RelayMessage::FileChunk {
                    transfer_id: transfer_id.to_string(),
                    sequence: seq,
                    data: data.to_string(),
                });
            }

            // All chunks sent — notify phone that transfer is complete
            if prepared.all_sent() {
                messages.push(RelayMessage::FileTransferComplete {
                    transfer_id: transfer_id.to_string(),
                    success: true,
                    error: None,
                });
                self.sends.remove(transfer_id);
            }
        }

        messages
    }

    /// Cancel a transfer (either direction).
    pub fn cancel(&mut self, transfer_id: &str) {
        self.receives.remove(transfer_id);
        self.sends.remove(transfer_id);
    }

    /// Clean up timed-out transfers.
    pub fn cleanup_stale(&mut self) {
        self.receives.retain(|_, state| !state.is_timed_out());
    }
}
