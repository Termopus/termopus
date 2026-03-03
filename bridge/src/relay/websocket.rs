use anyhow::{Context, Result};
use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpStream;
use tokio_tungstenite::{
    connect_async_with_config, tungstenite::{self, Message, http::Request},
    MaybeTlsStream, WebSocketStream,
};

use crate::crypto::aes::AesGcm;
use crate::crypto::kdf;
use crate::crypto::keypair::SessionKeyPair;
use crate::parser::ParsedMessage;
use crate::relay::messages::RelayMessage;

/// A WebSocket client that connects to the Cloudflare relay server.
///
/// Handles:
/// - Initial connection and pairing handshake
/// - ECDH key derivation for E2E encryption
/// - Encrypting outgoing messages and decrypting incoming messages
/// - Ping/pong keepalive
pub struct RelayClient {
    ws: WebSocketStream<MaybeTlsStream<TcpStream>>,
    relay_url: String,
    session_id: String,
    keypair: Option<SessionKeyPair>,
    crypto: Option<AesGcm>,
    /// Bearer token for relay authentication — must be reused on reconnect
    token: String,
}

/// Represents a message received from the relay after decryption.
#[derive(Debug)]
pub enum ReceivedMessage {
    /// A response to an action prompt (user tapped Allow/Deny/etc.)
    ActionResponse {
        action_id: String,
        response: String,
    },
    /// Free-form text input from the phone (newline auto-appended)
    Text(String),
    /// Raw input from the phone (no auto-newline)
    RawInput(String),
    /// A special key press (Enter, Escape, arrows, etc.)
    Key(String),
    /// The peer (phone) connected (may not be authenticated yet)
    PeerConnected,
    /// The phone completed device authentication — safe to send data
    PhoneAuthenticated,
    /// The peer (phone) disconnected
    PeerDisconnected,
    /// A Claude Code slash command (e.g., /help, /clear)
    Command {
        command: String,
        args: Option<String>,
    },
    /// Set the Claude Code model
    SetModel {
        model: String,
    },
    /// Configuration update
    Config {
        key: String,
        value: serde_json::Value,
    },
    /// Incoming file transfer start from phone
    FileTransferStart {
        transfer_id: String,
        filename: String,
        mime_type: String,
        total_size: u64,
        total_chunks: u32,
        direction: String,
        checksum: String,
    },
    /// Incoming file chunk from phone
    FileChunk {
        transfer_id: String,
        sequence: u32,
        data: String,
    },
    /// File transfer complete notification
    FileTransferComplete {
        transfer_id: String,
        success: bool,
        error: Option<String>,
    },
    /// File transfer ACK (flow control)
    FileTransferAck {
        transfer_id: String,
        received_through: u32,
    },
    /// File transfer cancel
    FileTransferCancel {
        transfer_id: String,
        reason: String,
    },
    /// The relay is asking us to authorize a device for this session
    DeviceAuthorizeRequest {
        fingerprint: String,
    },
    /// Phone requests to open HTTP tunnel
    HttpTunnelOpen { port: u16 },
    /// Phone requests to close HTTP tunnel
    HttpTunnelClose,
    /// Incoming HTTP request from phone to proxy
    HttpRequest {
        request_id: String,
        method: String,
        path: String,
        headers: std::collections::HashMap<String, String>,
        body: Option<String>,
    },
}

impl RelayClient {
    /// WS send with 15s timeout to prevent indefinite hangs on slow networks.
    const WS_WRITE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);
    const WS_READ_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(90);
    /// Interval for sending WebSocket protocol pings.
    /// Must be shorter than WS_READ_TIMEOUT (90s) so pong responses keep
    /// the read loop alive during DO hibernation (CF auto-responds to pings).
    const WS_PING_INTERVAL: std::time::Duration = std::time::Duration::from_secs(60);

    async fn send_ws(&mut self, msg: Message) -> Result<()> {
        tokio::time::timeout(Self::WS_WRITE_TIMEOUT, self.ws.send(msg))
            .await
            .map_err(|_| anyhow::anyhow!("WebSocket send timed out after 15s"))?
            .context("WebSocket send failed")
    }

    /// Connect to the relay WebSocket server.
    ///
    /// The URL is constructed as: `{relay_url}/{session_id}?role=computer`
    /// An Authorization header with a Bearer token is included for authentication.
    pub async fn new(
        relay_url: &str,
        session_id: &str,
        keypair: Option<SessionKeyPair>,
    ) -> Result<Self> {
        let url = format!("{}/{}?role=computer", relay_url, session_id);

        // Generate a session token for authentication
        // Use part of session_id + random bytes for uniqueness
        let token = format!("{}_{}", session_id, hex::encode(&rand::random::<[u8; 16]>()));

        // Build request with Authorization header
        let mut builder = Request::builder()
            .uri(&url)
            .header("Authorization", format!("Bearer {}", token))
            .header("Host", url.split('/').nth(2).unwrap_or("YOUR_RELAY_DOMAIN"))
            .header("User-Agent", "Termopus/1.0")
            .header("Accept", "*/*")
            .header("Connection", "Upgrade")
            .header("Upgrade", "websocket")
            .header("Sec-WebSocket-Version", "13")
            .header("Sec-WebSocket-Key", tungstenite::handshake::client::generate_key());

        // Cloudflare Access service token (bypasses Zero Trust gate)
        if let (Ok(cid), Ok(csec)) = (
            std::env::var("CF_ACCESS_CLIENT_ID"),
            std::env::var("CF_ACCESS_CLIENT_SECRET"),
        ) {
            builder = builder
                .header("CF-Access-Client-Id", cid)
                .header("CF-Access-Client-Secret", csec);
        }

        let request = builder.body(())
            .context("Failed to build WebSocket request")?;

        let result = tokio::time::timeout(
            std::time::Duration::from_secs(15),
            connect_async_with_config(request, None, false),
        )
        .await
        .map_err(|_| anyhow::anyhow!("WebSocket connect timed out after 15s"))?;

        match result {
            Ok((ws, _response)) => {
                tracing::info!("Connected to relay: {}", relay_url);
                Ok(Self {
                    ws,
                    relay_url: relay_url.to_string(),
                    session_id: session_id.to_string(),
                    keypair,
                    crypto: None,
                    token,
                })
            }
            Err(e) => {
                let err_str = e.to_string();
                tracing::error!("Relay connection error: {}", err_str);
                tracing::error!("Relay connection error (debug): {:?}", e);

                // Check for HTTP error status codes (relay rejection)
                if err_str.contains("402") {
                    anyhow::bail!(
                        "Subscription required — please open the Termopus app and subscribe"
                    );
                }
                if err_str.contains("401") || err_str.contains("403") {
                    anyhow::bail!(
                        "Authentication failed — please open the Termopus app on your phone and verify your device is provisioned"
                    );
                }
                Err(e).context(format!("Failed to connect to relay at {}", relay_url))
            }
        }
    }

    /// Get the session ID.
    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    /// Re-establish the WebSocket connection while preserving crypto state.
    ///
    /// After a transient network error the bridge can call this to reconnect
    /// to the same relay session without re-pairing. The existing AES key
    /// (derived during the original ECDH handshake) is kept so encrypted
    /// communication resumes immediately.
    pub async fn reconnect(&mut self) -> Result<()> {
        let url = format!("{}/{}?role=computer", self.relay_url, self.session_id);
        let token = &self.token;

        let mut builder = Request::builder()
            .uri(&url)
            .header("Authorization", format!("Bearer {}", token))
            .header("Host", url.split('/').nth(2).unwrap_or("YOUR_RELAY_DOMAIN"))
            .header("User-Agent", "Termopus/1.0")
            .header("Accept", "*/*")
            .header("Connection", "Upgrade")
            .header("Upgrade", "websocket")
            .header("Sec-WebSocket-Version", "13")
            .header("Sec-WebSocket-Key", tungstenite::handshake::client::generate_key());

        if let (Ok(cid), Ok(csec)) = (
            std::env::var("CF_ACCESS_CLIENT_ID"),
            std::env::var("CF_ACCESS_CLIENT_SECRET"),
        ) {
            builder = builder
                .header("CF-Access-Client-Id", cid)
                .header("CF-Access-Client-Secret", csec);
        }

        let request = builder.body(())
            .context("Failed to build reconnect request")?;

        let result = tokio::time::timeout(
            std::time::Duration::from_secs(15),
            connect_async_with_config(request, None, false),
        )
        .await
        .map_err(|_| anyhow::anyhow!("WebSocket reconnect timed out after 15s"))?;

        match result {
            Ok((ws, _response)) => {
                self.ws = ws;
                tracing::info!("Reconnected to relay: {}", self.relay_url);
                Ok(())
            }
            Err(e) => {
                let err_str = e.to_string();
                if err_str.contains("402") {
                    anyhow::bail!(
                        "Subscription required — please subscribe in the Termopus app"
                    );
                }
                if err_str.contains("401") || err_str.contains("403") {
                    anyhow::bail!(
                        "Authentication failed — please verify your device is provisioned"
                    );
                }
                Err(e).context(format!("Failed to reconnect to relay at {}", self.relay_url))
            }
        }
    }

    /// Wait for the phone to connect and send its public key.
    ///
    /// Blocks until a `Pairing` message is received from the relay containing
    /// the phone's P-256 public key. Returns the raw public key bytes
    /// (65 bytes: 0x04 || x || y in X9.63 uncompressed format).
    pub async fn wait_for_pairing(&mut self) -> Result<Vec<u8>> {
        tracing::info!("Waiting for phone to pair...");
        tokio::time::timeout(
            std::time::Duration::from_secs(5 * 60),
            self.wait_for_pairing_inner(),
        )
        .await
        .map_err(|_| anyhow::anyhow!("Pairing timed out after 5 minutes — no phone connected"))?
    }

    async fn wait_for_pairing_inner(&mut self) -> Result<Vec<u8>> {
        let mut ping_interval = tokio::time::interval(Self::WS_PING_INTERVAL);
        ping_interval.tick().await; // consume the immediate first tick

        loop {
            tracing::debug!("Waiting for next WebSocket message...");
            let msg = tokio::select! {
                result = self.ws.next() => {
                    result
                        .context("WebSocket connection closed while waiting for pairing")?
                        .context("WebSocket error while waiting for pairing")?
                }
                _ = ping_interval.tick() => {
                    self.ws.send(Message::Ping(vec![]))
                        .await
                        .context("Failed to send keepalive ping during pairing")?;
                    continue;
                }
            };

            tracing::debug!("Received WebSocket message: {:?}", msg);

            match msg {
                Message::Text(text) => {
                    tracing::info!("Received text message: {}", &text[..text.len().min(200)]);
                    let relay_msg: RelayMessage = serde_json::from_str(&text)
                        .context("Failed to parse relay message during pairing")?;

                    match relay_msg {
                        RelayMessage::Pairing { pubkey } => {
                            let decoded = base64::engine::general_purpose::STANDARD
                                .decode(&pubkey)
                                .context("Failed to decode peer public key from base64")?;

                            // P-256 uncompressed public keys are 65 bytes (0x04 || x || y)
                            if decoded.len() != 65 && decoded.len() != 33 {
                                anyhow::bail!(
                                    "Invalid P-256 public key length: expected 65 (uncompressed) or 33 (compressed) bytes, got {}",
                                    decoded.len()
                                );
                            }

                            tracing::info!("Received peer public key ({} bytes)", decoded.len());

                            // Now send OUR public key back to the phone
                            if let Some(ref kp) = self.keypair {
                                let our_pairing = RelayMessage::pairing(kp.public_key_base64());
                                let json = serde_json::to_string(&our_pairing)?;
                                self.send_ws(Message::Text(json))
                                    .await
                                    .context("Failed to send our public key")?;
                                tracing::info!("Sent our public key to phone");
                            }

                            return Ok(decoded);
                        }
                        RelayMessage::PeerConnected { role } => {
                            tracing::info!("Peer connected: {}", role);
                        }
                        RelayMessage::DeviceAuthorizeRequest { fingerprint, .. } => {
                            tracing::info!("Device authorization request (during pairing) for: {}", &fingerprint[..16.min(fingerprint.len())]);
                            // Auto-approve during initial pairing — no phone connected yet to
                            // forward approval to. Post-pairing approvals go through the phone (T4).
                            let response = RelayMessage::DeviceAuthorizeResponse {
                                fingerprint: fingerprint.clone(),
                                authorized: true,
                            };
                            let json = serde_json::to_string(&response)?;
                            self.send_ws(Message::Text(json)).await
                                .context("Failed to send device_authorize_response")?;
                            tracing::info!("Auto-approved device authorization (during pairing)");
                        }
                        other => {
                            tracing::debug!("Ignoring non-pairing message: {:?}", other);
                        }
                    }
                }
                Message::Ping(data) => {
                    self.send_ws(Message::Pong(data))
                        .await
                        .context("Failed to send pong")?;
                }
                Message::Close(_) => {
                    anyhow::bail!("WebSocket closed by relay while waiting for pairing");
                }
                _ => {
                    // Ignore binary and other message types during pairing
                }
            }
        }
    }

    /// Derive the shared encryption key from the peer's public key.
    ///
    /// Performs P-256 ECDH key agreement and derives an AES-256 key via HKDF.
    /// After this call, `send_message()` and `receive_message()` will
    /// automatically encrypt/decrypt.
    ///
    /// The peer public key should be in X9.63 format (65 bytes uncompressed
    /// or 33 bytes compressed).
    pub fn derive_shared_secret(&mut self, peer_public: &[u8]) -> Result<()> {
        let keypair = self
            .keypair
            .as_mut()
            .context("No keypair available for key derivation")?;

        // Perform P-256 ECDH (consumes the ephemeral secret inside the keypair)
        let shared_secret = keypair
            .derive_shared_secret(peer_public)
            .map_err(|e| anyhow::anyhow!("ECDH key agreement failed: {}", e))?;

        // Derive AES key via HKDF — both values auto-zeroize when dropped
        let aes_key = kdf::derive_aes_key(&shared_secret)?;
        self.crypto = Some(AesGcm::new(aes_key.as_ref())?);

        tracing::info!("Shared secret derived, E2E encryption active");
        Ok(())
    }

    /// Send a parsed message to the phone.
    ///
    /// The message is serialized to JSON, encrypted with AES-256-GCM,
    /// and sent as a WebSocket binary frame.
    pub async fn send_message(&mut self, msg: &ParsedMessage) -> Result<()> {
        let crypto = self
            .crypto
            .as_ref()
            .context("Cannot send: not paired yet (no encryption key)")?;

        // Serialize to JSON
        let json = serde_json::to_vec(msg).context("Failed to serialize message")?;

        // Encrypt
        let encrypted = crypto
            .encrypt(&json)
            .context("Failed to encrypt message")?;

        // Send as binary WebSocket frame
        self.send_ws(Message::Binary(encrypted))
            .await
            .context("Failed to send encrypted message to relay")?;

        tracing::debug!("Sent encrypted message ({} bytes)", json.len());
        Ok(())
    }

    /// Send a raw JSON value (encrypted) to the phone.
    /// Used for protocol extensions (UsageUpdate, SessionCapabilities, etc.)
    /// that don't have a ParsedMessage variant yet.
    pub async fn send_raw_json(&mut self, value: &serde_json::Value) -> Result<()> {
        let crypto = self
            .crypto
            .as_ref()
            .context("Cannot send: not paired yet (no encryption key)")?;

        let json = serde_json::to_vec(value).context("Failed to serialize JSON")?;
        let encrypted = crypto.encrypt(&json).context("Failed to encrypt message")?;

        self.send_ws(Message::Binary(encrypted))
            .await
            .context("Failed to send encrypted JSON to relay")?;

        tracing::debug!("Sent raw JSON ({} bytes)", json.len());
        Ok(())
    }

    /// Send a raw RelayMessage (encrypted) to the phone.
    /// Used for file transfer protocol messages that don't go through ParsedMessage.
    pub async fn send_relay_message(&mut self, msg: &RelayMessage) -> Result<()> {
        let crypto = self
            .crypto
            .as_ref()
            .context("Cannot send: not paired yet")?;

        let json = serde_json::to_vec(msg)?;
        let encrypted = crypto.encrypt(&json)?;

        self.send_ws(Message::Binary(encrypted))
            .await
            .context("Failed to send relay message")?;

        Ok(())
    }

    /// Receive and decrypt a message from the phone.
    ///
    /// Blocks until a message is received. Handles:
    /// - Binary frames: decrypted and parsed as `RelayMessage`
    /// - Text frames: parsed as unencrypted control messages
    /// - Ping: automatically responds with Pong
    /// - Close: returns an error
    pub async fn receive_message(&mut self) -> Result<ReceivedMessage> {
        let crypto = self
            .crypto
            .as_ref()
            .context("Cannot receive: not paired yet (no encryption key)")?;

        let mut ping_interval = tokio::time::interval(Self::WS_PING_INTERVAL);
        ping_interval.tick().await; // consume the immediate first tick

        loop {
            let msg = tokio::select! {
                result = tokio::time::timeout(Self::WS_READ_TIMEOUT, self.ws.next()) => {
                    result
                        .map_err(|_| anyhow::anyhow!(
                            "WebSocket read timed out after {}s — connection may be dead",
                            Self::WS_READ_TIMEOUT.as_secs()
                        ))?
                        .context("WebSocket connection closed")?
                        .context("WebSocket receive error")?
                }
                _ = ping_interval.tick() => {
                    // Send protocol-level ping to keep connection alive.
                    // During DO hibernation, Cloudflare auto-responds with pong
                    // without waking the DO.
                    self.ws.send(Message::Ping(vec![]))
                        .await
                        .context("Failed to send keepalive ping")?;
                    continue;
                }
            };

            match msg {
                Message::Binary(data) => {
                    // Decrypt the binary payload — gracefully skip on failure.
                    // Stale relay messages, network corruption, or replay attacks
                    // should NOT crash the session.
                    let decrypted = match crypto.decrypt(&data) {
                        Ok(d) => d,
                        Err(e) => {
                            tracing::warn!(
                                "[{}] Decrypt failed ({} bytes), skipping: {}",
                                &self.session_id[..12.min(self.session_id.len())],
                                data.len(),
                                e
                            );
                            continue;
                        }
                    };

                    let relay_msg: RelayMessage = match serde_json::from_slice(&decrypted) {
                        Ok(m) => m,
                        Err(e) => {
                            tracing::warn!(
                                "[{}] Failed to parse decrypted message, skipping: {}",
                                &self.session_id[..12.min(self.session_id.len())],
                                e
                            );
                            continue;
                        }
                    };

                    match relay_msg {
                        RelayMessage::Response {
                            action_id,
                            response,
                        } => {
                            tracing::info!(
                                "Received action response: {} -> {}",
                                action_id,
                                response
                            );
                            return Ok(ReceivedMessage::ActionResponse {
                                action_id,
                                response,
                            });
                        }
                        RelayMessage::Message { content } => {
                            tracing::debug!("Received text message from phone: {}", content);
                            return Ok(ReceivedMessage::Text(content));
                        }
                        RelayMessage::Input { content } => {
                            tracing::debug!("Received raw input from phone: {:?}", content);
                            return Ok(ReceivedMessage::RawInput(content));
                        }
                        RelayMessage::Key { key } => {
                            tracing::debug!("Received key press from phone: {}", key);
                            return Ok(ReceivedMessage::Key(key));
                        }
                        RelayMessage::Command { command, args } => {
                            tracing::info!("Received command from phone: {} {:?}", command, args);
                            return Ok(ReceivedMessage::Command { command, args });
                        }
                        RelayMessage::SetModel { model } => {
                            tracing::info!("Received set_model from phone: {}", model);
                            return Ok(ReceivedMessage::SetModel { model });
                        }
                        RelayMessage::Config { key, value } => {
                            tracing::info!("Received config from phone: {} = {:?}", key, value);
                            return Ok(ReceivedMessage::Config { key, value });
                        }
                        RelayMessage::FileTransferStart {
                            transfer_id, filename, mime_type, total_size,
                            total_chunks, direction, checksum,
                        } => {
                            tracing::info!("Received file transfer start: {}", filename);
                            return Ok(ReceivedMessage::FileTransferStart {
                                transfer_id, filename, mime_type, total_size,
                                total_chunks, direction, checksum,
                            });
                        }
                        RelayMessage::FileChunk { transfer_id, sequence, data } => {
                            return Ok(ReceivedMessage::FileChunk {
                                transfer_id, sequence, data,
                            });
                        }
                        RelayMessage::FileTransferComplete { transfer_id, success, error } => {
                            return Ok(ReceivedMessage::FileTransferComplete {
                                transfer_id, success, error,
                            });
                        }
                        RelayMessage::FileTransferAck { transfer_id, received_through } => {
                            return Ok(ReceivedMessage::FileTransferAck {
                                transfer_id, received_through,
                            });
                        }
                        RelayMessage::FileTransferCancel { transfer_id, reason } => {
                            return Ok(ReceivedMessage::FileTransferCancel {
                                transfer_id, reason,
                            });
                        }
                        RelayMessage::HttpTunnelOpen { port } => {
                            return Ok(ReceivedMessage::HttpTunnelOpen { port });
                        }
                        RelayMessage::HttpTunnelClose { .. } => {
                            return Ok(ReceivedMessage::HttpTunnelClose);
                        }
                        RelayMessage::HttpRequest { request_id, method, path, headers, body } => {
                            return Ok(ReceivedMessage::HttpRequest {
                                request_id, method, path, headers, body,
                            });
                        }
                        RelayMessage::HttpResponse { .. } | RelayMessage::HttpTunnelStatus { .. } => {
                            // These are outbound-only (bridge → phone), ignore if received
                            tracing::warn!("Received unexpected HTTP tunnel response from phone");
                        }
                        other => {
                            tracing::debug!(
                                "Ignoring unexpected encrypted message type: {:?}",
                                other
                            );
                        }
                    }
                }
                Message::Text(text) => {
                    // Unencrypted control messages from the relay
                    match serde_json::from_str::<RelayMessage>(&text) {
                        Ok(relay_msg) => match relay_msg {
                            RelayMessage::PeerConnected { role } => {
                                tracing::info!("Peer connected: {}", role);
                                return Ok(ReceivedMessage::PeerConnected);
                            }
                            RelayMessage::PhoneAuthenticated { device_id } => {
                                tracing::info!("Phone authenticated: {}", &device_id[..16.min(device_id.len())]);
                                return Ok(ReceivedMessage::PhoneAuthenticated);
                            }
                            RelayMessage::PeerDisconnected { role } => {
                                tracing::warn!("Peer disconnected: {}", role);
                                return Ok(ReceivedMessage::PeerDisconnected);
                            }
                            RelayMessage::DeviceAuthorizeRequest { fingerprint, .. } => {
                                tracing::info!("Device authorization request for: {}", &fingerprint[..16.min(fingerprint.len())]);
                                // Return to session loop for phone approval — do NOT auto-approve
                                return Ok(ReceivedMessage::DeviceAuthorizeRequest { fingerprint });
                            }
                            _ => {
                                tracing::debug!("Ignoring unencrypted non-control message");
                            }
                        },
                        Err(e) => {
                            tracing::warn!("Failed to parse relay text message: {}", e);
                        }
                    }
                }
                Message::Ping(data) => {
                    // Inline timeout (can't use send_ws here due to borrow on self.crypto)
                    tokio::time::timeout(Self::WS_WRITE_TIMEOUT, self.ws.send(Message::Pong(data)))
                        .await
                        .map_err(|_| anyhow::anyhow!("Pong send timed out"))?
                        .context("Failed to send pong")?;
                }
                Message::Close(frame) => {
                    let reason = frame
                        .map(|f| format!("code={}, reason={}", f.code, f.reason))
                        .unwrap_or_else(|| "no reason".to_string());
                    anyhow::bail!("WebSocket closed by relay: {}", reason);
                }
                Message::Pong(_) => {
                    // Ignore pong responses
                }
                _ => {}
            }
        }
    }

    /// Replace the encryption context with a new AES-256-GCM key.
    ///
    /// Used after key renegotiation to switch to a freshly derived key.
    pub fn set_crypto(&mut self, crypto: AesGcm) {
        self.crypto = Some(crypto);
    }

    /// Renegotiate the encryption key after a reconnect.
    ///
    /// Generates a fresh ephemeral P-256 keypair, sends our new public key
    /// to the phone (encrypted with the CURRENT key), waits for the phone's
    /// new public key (also encrypted with the current key), and returns
    /// both so the caller can derive the new shared secret.
    ///
    /// The caller must then:
    /// 1. Call `new_keypair.derive_shared_secret(&peer_bytes)`
    /// 2. Feed the result through `kdf::derive_aes_key()`
    /// 3. Call `set_crypto(AesGcm::new(&aes_key)?)`
    pub async fn renegotiate_key(&mut self) -> Result<(SessionKeyPair, Vec<u8>, Vec<Vec<u8>>)> {
        // Generate fresh ephemeral keypair
        let new_keypair = SessionKeyPair::generate();

        // Send our new public key as a "rekey" message, encrypted with current key
        let rekey_msg = serde_json::json!({
            "type": "rekey",
            "pubkey": new_keypair.public_key_base64(),
        });
        let json = serde_json::to_string(&rekey_msg)?;

        // Encrypt with current key and send
        if let Some(ref crypto) = self.crypto {
            let encrypted = crypto.encrypt(json.as_bytes())?;
            self.send_ws(Message::Binary(encrypted))
                .await
                .context("Failed to send rekey message")?;
        } else {
            anyhow::bail!("Cannot renegotiate key — no crypto context");
        }

        tracing::info!("Sent rekey request, waiting for phone response...");

        // Buffer non-rekey messages that arrive during handshake (e.g. queued replays)
        let mut buffered: Vec<Vec<u8>> = Vec::new();

        // Wait for phone's new public key (encrypted with OLD key)
        let peer_public_bytes: Vec<u8> = tokio::time::timeout(
            std::time::Duration::from_secs(15),
            async {
                loop {
                    let msg = self
                        .ws
                        .next()
                        .await
                        .context("WebSocket closed during rekey")?
                        .context("WebSocket error during rekey")?;

                    match msg {
                        Message::Binary(data) => {
                            if let Some(ref crypto) = self.crypto {
                                if let Ok(decrypted) = crypto.decrypt(&data) {
                                    if let Ok(parsed) =
                                        serde_json::from_slice::<serde_json::Value>(&decrypted)
                                    {
                                        if parsed.get("type").and_then(|t| t.as_str())
                                            == Some("rekey")
                                        {
                                            if let Some(pubkey) =
                                                parsed.get("pubkey").and_then(|p| p.as_str())
                                            {
                                                let peer_bytes =
                                                    base64::engine::general_purpose::STANDARD
                                                        .decode(pubkey)
                                                        .context(
                                                            "Failed to decode rekey pubkey",
                                                        )?;
                                                return anyhow::Ok(peer_bytes);
                                            }
                                        }
                                    }
                                    // Not a rekey response — buffer for processing after rekey
                                    buffered.push(decrypted);
                                }
                            }
                        }
                        Message::Text(_) => continue, // Control messages during rekey
                        Message::Ping(data) => {
                            // Respond to pings during rekey to keep connection alive
                            let _ = self.send_ws(Message::Pong(data)).await;
                        }
                        _ => continue,
                    }
                }
            },
        )
        .await
        .context("Rekey timed out after 15s")??;

        if !buffered.is_empty() {
            tracing::info!("Rekey: buffered {} messages during handshake", buffered.len());
        }
        Ok((new_keypair, peer_public_bytes, buffered))
    }

    /// Parse already-decrypted bytes into a ReceivedMessage.
    ///
    /// Used to process messages that were buffered during the rekey handshake.
    pub fn parse_decrypted(&self, data: &[u8]) -> Result<ReceivedMessage> {
        let relay_msg: RelayMessage = serde_json::from_slice(data)
            .context("Failed to parse buffered message")?;

        match relay_msg {
            RelayMessage::Response { action_id, response } => {
                Ok(ReceivedMessage::ActionResponse { action_id, response })
            }
            RelayMessage::Message { content } => Ok(ReceivedMessage::Text(content)),
            RelayMessage::Input { content } => Ok(ReceivedMessage::RawInput(content)),
            RelayMessage::Key { key } => Ok(ReceivedMessage::Key(key)),
            RelayMessage::Command { command, args } => Ok(ReceivedMessage::Command { command, args }),
            RelayMessage::SetModel { model } => Ok(ReceivedMessage::SetModel { model }),
            RelayMessage::Config { key, value } => Ok(ReceivedMessage::Config { key, value }),
            RelayMessage::FileTransferStart { transfer_id, filename, mime_type, total_size, total_chunks, direction, checksum }
                => Ok(ReceivedMessage::FileTransferStart { transfer_id, filename, mime_type, total_size, total_chunks, direction, checksum }),
            RelayMessage::FileChunk { transfer_id, sequence, data }
                => Ok(ReceivedMessage::FileChunk { transfer_id, sequence, data }),
            RelayMessage::FileTransferComplete { transfer_id, success, error }
                => Ok(ReceivedMessage::FileTransferComplete { transfer_id, success, error }),
            RelayMessage::FileTransferAck { transfer_id, received_through }
                => Ok(ReceivedMessage::FileTransferAck { transfer_id, received_through }),
            RelayMessage::FileTransferCancel { transfer_id, reason }
                => Ok(ReceivedMessage::FileTransferCancel { transfer_id, reason }),
            RelayMessage::HttpTunnelOpen { port }
                => Ok(ReceivedMessage::HttpTunnelOpen { port }),
            RelayMessage::HttpTunnelClose { .. }
                => Ok(ReceivedMessage::HttpTunnelClose),
            RelayMessage::HttpRequest { request_id, method, path, headers, body }
                => Ok(ReceivedMessage::HttpRequest { request_id, method, path, headers, body }),
            _ => anyhow::bail!("Unsupported buffered message type"),
        }
    }

    /// Close the WebSocket connection gracefully.
    pub async fn close(&mut self) -> Result<()> {
        match tokio::time::timeout(
            std::time::Duration::from_secs(5),
            self.ws.close(None),
        ).await {
            Ok(result) => result.context("Failed to close WebSocket connection")?,
            Err(_) => tracing::warn!("WebSocket close timed out after 5s, dropping connection"),
        }
        tracing::info!("WebSocket connection closed");
        Ok(())
    }

    /// Send a device authorization response to the relay.
    ///
    /// Called after the phone user approves or denies a new device connection,
    /// or after the approval timeout expires (fail-closed: deny).
    pub async fn send_device_authorize_response(&mut self, fingerprint: &str, authorized: bool) -> Result<()> {
        let response = RelayMessage::DeviceAuthorizeResponse {
            fingerprint: fingerprint.to_string(),
            authorized,
        };
        let json = serde_json::to_string(&response)?;
        self.send_ws(Message::Text(json)).await
            .context("Failed to send device_authorize_response")?;
        tracing::info!("Sent device_authorize_response: fingerprint={}… authorized={}", &fingerprint[..16.min(fingerprint.len())], authorized);
        Ok(())
    }
}

impl ReceivedMessage {
    /// Convert this received message to PTY input, if applicable.
    ///
    /// Action responses are mapped through `ParsedMessage::response_to_input`
    /// to convert "allow"/"deny" etc. to the single-character input that
    /// Claude Code expects.
    ///
    /// Keys are converted to normalized key names for stream-json handling.
    pub fn as_key_input(&self) -> Option<String> {
        match self {
            ReceivedMessage::ActionResponse { response, .. } => {
                ParsedMessage::response_to_input(response)
            }
            ReceivedMessage::Text(text) => {
                // For text messages, append newline (like pressing Enter after typing)
                if text.is_empty() {
                    // Empty text = just press Enter
                    Some("\n".to_string())
                } else {
                    Some(format!("{}\n", text))
                }
            }
            ReceivedMessage::RawInput(input) => {
                // Raw input is sent exactly as-is (no newline appended)
                Some(input.clone())
            }
            ReceivedMessage::Key(key) => {
                // Convert phone key names to normalized format
                Some(Self::normalize_key(key))
            }
            ReceivedMessage::Command { command, args } => {
                // Convert command to slash command input
                match args {
                    Some(a) => Some(format!("/{} {}\n", command, a)),
                    None => Some(format!("/{}\n", command)),
                }
            }
            ReceivedMessage::SetModel { model } => {
                // Convert to /model command
                Some(format!("/model {}\n", model))
            }
            ReceivedMessage::Config { key, value } => {
                // Convert to /config command
                Some(format!("/config set {} {}\n", key, value))
            }
            ReceivedMessage::PeerConnected
            | ReceivedMessage::PeerDisconnected
            | ReceivedMessage::DeviceAuthorizeRequest { .. }
            | ReceivedMessage::FileTransferStart { .. }
            | ReceivedMessage::FileChunk { .. }
            | ReceivedMessage::FileTransferComplete { .. }
            | ReceivedMessage::FileTransferAck { .. }
            | ReceivedMessage::FileTransferCancel { .. }
            | ReceivedMessage::HttpTunnelOpen { .. }
            | ReceivedMessage::HttpTunnelClose
            | ReceivedMessage::HttpRequest { .. }
            | ReceivedMessage::PhoneAuthenticated => None,
        }
    }

    /// Convert a key name from the phone to a normalized key string.
    ///
    /// Maps phone key names (e.g. "enter", "ctrl+c") to canonical
    /// names (e.g. "Enter", "C-c") for consistent handling.
    fn normalize_key(key: &str) -> String {
        match key.to_lowercase().as_str() {
            // Basic keys
            "enter" | "return" => "Enter".to_string(),
            "escape" | "esc" => "Escape".to_string(),
            "tab" => "Tab".to_string(),
            "space" => "Space".to_string(),
            "backspace" | "delete" => "BSpace".to_string(),

            // Arrow keys
            "up" | "arrowup" => "Up".to_string(),
            "down" | "arrowdown" => "Down".to_string(),
            "left" | "arrowleft" => "Left".to_string(),
            "right" | "arrowright" => "Right".to_string(),

            // Control keys
            "c-c" | "ctrl-c" | "ctrl+c" => "C-c".to_string(),
            "c-d" | "ctrl-d" | "ctrl+d" => "C-d".to_string(),
            "c-z" | "ctrl-z" | "ctrl+z" => "C-z".to_string(),
            "c-l" | "ctrl-l" | "ctrl+l" => "C-l".to_string(),

            // Function keys
            "f1" => "F1".to_string(),
            "f2" => "F2".to_string(),
            "f3" => "F3".to_string(),
            "f4" => "F4".to_string(),
            "f5" => "F5".to_string(),
            "f6" => "F6".to_string(),
            "f7" => "F7".to_string(),
            "f8" => "F8".to_string(),
            "f9" => "F9".to_string(),
            "f10" => "F10".to_string(),
            "f11" => "F11".to_string(),
            "f12" => "F12".to_string(),

            // Navigation
            "home" => "Home".to_string(),
            "end" => "End".to_string(),
            "pageup" | "pgup" => "PPage".to_string(),
            "pagedown" | "pgdn" => "NPage".to_string(),
            "insert" => "IC".to_string(),

            // If key is a single character, send it directly
            _ if key.len() == 1 => key.to_string(),

            // Unknown key - send as-is
            _ => key.to_string(),
        }
    }
}
