use serde::{Deserialize, Serialize};

/// Messages exchanged over the relay WebSocket connection.
///
/// Uses serde's tagged enum representation so each JSON message has a
/// `"type"` field identifying the variant.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum RelayMessage {
    /// Pairing message: contains the sender's P-256 public key (base64).
    ///
    /// Sent during the initial handshake so both sides can perform ECDH
    /// and derive a shared encryption key.
    #[serde(rename = "pairing")]
    Pairing {
        /// Base64-encoded P-256 public key (65 bytes X9.63 uncompressed)
        pubkey: String,
    },

    /// An encrypted application-layer message (with auto-newline).
    ///
    /// The `payload` field contains base64-encoded encrypted data.
    /// After decryption, it deserializes to a `ParsedMessage`.
    /// A newline is automatically appended when sent to the terminal.
    #[serde(rename = "message")]
    Message {
        /// The message content (plaintext when not E2E encrypted,
        /// or used as a wrapper for encrypted payloads)
        content: String,
    },

    /// Raw input without automatic newline.
    ///
    /// Use this for sending input exactly as-is to the terminal.
    #[serde(rename = "input")]
    Input {
        /// Raw input to send (no newline appended)
        content: String,
    },

    /// A special key press (Enter, Escape, Arrow keys, etc.)
    ///
    /// The key name is mapped to tmux key syntax.
    #[serde(rename = "key")]
    Key {
        /// Key name: "Enter", "Escape", "Up", "Down", "Left", "Right", "Tab", "C-c", etc.
        key: String,
    },

    /// A response to an action prompt.
    ///
    /// Sent by the phone when the user taps Allow/Deny/Yes/No.
    #[serde(rename = "response")]
    Response {
        /// The ID of the action being responded to
        #[serde(rename = "actionId")]
        action_id: String,
        /// The user's chosen response (e.g., "allow", "deny", "yes", "no")
        response: String,
    },

    /// Notification that a peer has connected to the relay session.
    #[serde(rename = "peer_connected")]
    PeerConnected {
        /// The role of the connected peer ("computer" or "phone")
        role: String,
    },

    /// Notification that a phone has completed device authentication.
    /// Sent by relay after auth_challenge/device_auth succeeds.
    /// Safe to send data to this phone now.
    #[serde(rename = "phone_authenticated")]
    PhoneAuthenticated {
        #[serde(rename = "deviceId")]
        device_id: String,
    },

    /// Relay requests bridge to authorize a device for this session.
    /// Sent when a new device connects that isn't in the session allowlist.
    #[serde(rename = "device_authorize_request")]
    DeviceAuthorizeRequest {
        /// SHA-256 fingerprint of the device's certificate
        fingerprint: String,
        /// When the request was created
        #[serde(skip_serializing_if = "Option::is_none")]
        timestamp: Option<i64>,
    },

    /// Bridge's response authorizing or denying a device.
    #[serde(rename = "device_authorize_response")]
    DeviceAuthorizeResponse {
        /// SHA-256 fingerprint of the device
        fingerprint: String,
        /// Whether the device is authorized for this session
        authorized: bool,
    },

    /// Relay notifies phone that session authorization completed.
    #[serde(rename = "session_authorized")]
    SessionAuthorized {
        success: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },

    /// Notification that a peer has disconnected from the relay session.
    #[serde(rename = "peer_disconnected")]
    PeerDisconnected {
        /// The role of the disconnected peer ("computer" or "phone")
        role: String,
    },

    /// Notification that the peer is offline (not currently connected).
    #[serde(rename = "peer_offline")]
    PeerOffline {
        /// The role of the offline peer ("computer" or "phone")
        role: String,
        /// Whether a push notification was sent
        #[serde(rename = "pushSent")]
        push_sent: Option<bool>,
    },

    /// Pong response to a ping.
    #[serde(rename = "pong")]
    Pong {
        timestamp: Option<i64>,
    },

    /// Status response.
    #[serde(rename = "status_response")]
    StatusResponse {
        #[serde(rename = "peerConnected")]
        peer_connected: bool,
        #[serde(rename = "lastActivity")]
        last_activity: Option<i64>,
    },

    /// FCM token registered confirmation.
    #[serde(rename = "fcm_registered")]
    FcmRegistered {
        timestamp: Option<i64>,
    },

    /// A Claude Code command (slash command like /help, /clear, /model).
    #[serde(rename = "command")]
    Command {
        /// The command to execute (e.g., "help", "clear", "model")
        command: String,
        /// Optional arguments for the command
        args: Option<String>,
    },

    /// Set the Claude Code model.
    #[serde(rename = "set_model")]
    SetModel {
        /// The model to switch to (e.g., "opus", "sonnet", "haiku")
        model: String,
    },

    /// Configuration update for Claude Code.
    #[serde(rename = "config")]
    Config {
        /// The config key to update
        key: String,
        /// The config value
        value: serde_json::Value,
    },

    /// File transfer initiation (metadata + chunking info).
    #[serde(rename = "file_transfer_start")]
    FileTransferStart {
        #[serde(rename = "transferId")]
        transfer_id: String,
        filename: String,
        #[serde(rename = "mimeType")]
        mime_type: String,
        #[serde(rename = "totalSize")]
        total_size: u64,
        #[serde(rename = "totalChunks")]
        total_chunks: u32,
        direction: String,
        checksum: String,
    },

    /// A single chunk of file data (base64-encoded).
    #[serde(rename = "file_chunk")]
    FileChunk {
        #[serde(rename = "transferId")]
        transfer_id: String,
        sequence: u32,
        data: String,
    },

    /// File transfer completed (success or failure).
    #[serde(rename = "file_transfer_complete")]
    FileTransferComplete {
        #[serde(rename = "transferId")]
        transfer_id: String,
        success: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },

    /// Acknowledgement of received chunks (flow control).
    #[serde(rename = "file_transfer_ack")]
    FileTransferAck {
        #[serde(rename = "transferId")]
        transfer_id: String,
        #[serde(rename = "receivedThrough")]
        received_through: u32,
    },

    /// Cancel an in-progress file transfer.
    #[serde(rename = "file_transfer_cancel")]
    FileTransferCancel {
        #[serde(rename = "transferId")]
        transfer_id: String,
        reason: String,
    },

    // --- HTTP Tunnel ---

    /// Phone requests to open an HTTP tunnel to a localhost port.
    #[serde(rename = "http_tunnel_open")]
    HttpTunnelOpen {
        /// The localhost port to proxy to (e.g., 3000, 8080)
        port: u16,
    },

    /// Phone requests to close the HTTP tunnel.
    #[serde(rename = "http_tunnel_close")]
    HttpTunnelClose {},

    /// HTTP tunnel status update (bridge → phone).
    #[serde(rename = "http_tunnel_status")]
    HttpTunnelStatus {
        /// Whether the tunnel is active
        active: bool,
        /// The target port
        #[serde(skip_serializing_if = "Option::is_none")]
        port: Option<u16>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },

    /// Tell the phone to refresh its browser WebView (bridge → phone).
    /// Sent when a file is edited/written while the tunnel is active.
    #[serde(rename = "http_tunnel_refresh")]
    HttpTunnelRefresh {},

    /// An HTTP request from the phone to be proxied to localhost.
    #[serde(rename = "http_request")]
    HttpRequest {
        /// Unique request ID for matching responses
        #[serde(rename = "requestId")]
        request_id: String,
        /// HTTP method (GET, POST, PUT, DELETE, etc.)
        method: String,
        /// Request path (e.g., "/api/data", "/index.html")
        path: String,
        /// HTTP headers as key-value pairs
        #[serde(default)]
        headers: std::collections::HashMap<String, String>,
        /// Base64-encoded request body (None for GET/HEAD)
        #[serde(skip_serializing_if = "Option::is_none")]
        body: Option<String>,
    },

    /// An HTTP response from the bridge back to the phone.
    #[serde(rename = "http_response")]
    HttpResponse {
        /// Matches the requestId from HttpRequest
        #[serde(rename = "requestId")]
        request_id: String,
        /// HTTP status code (200, 404, 500, etc.)
        status: u16,
        /// Response headers as key-value pairs
        #[serde(default)]
        headers: std::collections::HashMap<String, String>,
        /// Base64-encoded response body
        #[serde(default)]
        body: String,
    },
}

impl RelayMessage {
    /// Create a pairing message with the given base64-encoded public key.
    pub fn pairing(pubkey: String) -> Self {
        Self::Pairing { pubkey }
    }

    /// Create a text message.
    pub fn message(content: String) -> Self {
        Self::Message { content }
    }

    /// Create a response message for an action.
    pub fn response(action_id: String, response: String) -> Self {
        Self::Response {
            action_id,
            response,
        }
    }

    /// Create a peer-connected notification.
    pub fn peer_connected(role: &str) -> Self {
        Self::PeerConnected {
            role: role.to_string(),
        }
    }

    /// Create a peer-disconnected notification.
    pub fn peer_disconnected(role: &str) -> Self {
        Self::PeerDisconnected {
            role: role.to_string(),
        }
    }

    /// Check if this is a control message (not application data).
    pub fn is_control(&self) -> bool {
        matches!(
            self,
            Self::PeerConnected { .. }
                | Self::PeerDisconnected { .. }
                | Self::DeviceAuthorizeRequest { .. }
                | Self::DeviceAuthorizeResponse { .. }
                | Self::SessionAuthorized { .. }
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;

    #[test]
    fn test_serialize_pairing() {
        let msg = RelayMessage::pairing("dGVzdA==".to_string());
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"pairing\""));
        assert!(json.contains("\"pubkey\":\"dGVzdA==\""));
    }

    #[test]
    fn test_deserialize_pairing() {
        let json = r#"{"type":"pairing","pubkey":"dGVzdA=="}"#;
        let msg: RelayMessage = serde_json::from_str(json).unwrap();
        match msg {
            RelayMessage::Pairing { pubkey } => {
                assert_eq!(pubkey, "dGVzdA==");
            }
            _ => panic!("Expected Pairing variant"),
        }
    }

    #[test]
    fn test_serialize_response() {
        let msg = RelayMessage::response("yn-abc123".to_string(), "allow".to_string());
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"response\""));
        assert!(json.contains("\"actionId\":\"yn-abc123\""));
        assert!(json.contains("\"response\":\"allow\""));
    }

    #[test]
    fn test_deserialize_peer_connected() {
        let json = r#"{"type":"peer_connected","role":"phone"}"#;
        let msg: RelayMessage = serde_json::from_str(json).unwrap();
        match msg {
            RelayMessage::PeerConnected { role } => {
                assert_eq!(role, "phone");
            }
            _ => panic!("Expected PeerConnected variant"),
        }
    }

    #[test]
    fn test_is_control() {
        let control = RelayMessage::peer_connected("phone");
        assert!(control.is_control());

        let data = RelayMessage::message("hello".to_string());
        assert!(!data.is_control());
    }

    #[test]
    fn test_serialize_file_transfer_start() {
        let msg = RelayMessage::FileTransferStart {
            transfer_id: "abc-123".to_string(),
            filename: "photo.jpg".to_string(),
            mime_type: "image/jpeg".to_string(),
            total_size: 4_200_000,
            total_chunks: 22,
            direction: "phone_to_computer".to_string(),
            checksum: "deadbeef".to_string(),
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"file_transfer_start\""));
        assert!(json.contains("\"filename\":\"photo.jpg\""));
        let deserialized: RelayMessage = serde_json::from_str(&json).unwrap();
        let json2 = serde_json::to_string(&deserialized).unwrap();
        assert_eq!(json, json2);
    }

    #[test]
    fn test_serialize_file_chunk() {
        let msg = RelayMessage::FileChunk {
            transfer_id: "abc-123".to_string(),
            sequence: 5,
            data: "base64encodeddata==".to_string(),
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"file_chunk\""));
        assert!(json.contains("\"sequence\":5"));
        let rt: RelayMessage = serde_json::from_str(&json).unwrap();
        let json2 = serde_json::to_string(&rt).unwrap();
        assert_eq!(json, json2);
    }

    #[test]
    fn test_serialize_file_transfer_ack() {
        let msg = RelayMessage::FileTransferAck {
            transfer_id: "abc-123".to_string(),
            received_through: 9,
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"file_transfer_ack\""));
        let rt: RelayMessage = serde_json::from_str(&json).unwrap();
        let json2 = serde_json::to_string(&rt).unwrap();
        assert_eq!(json, json2);
    }

    #[test]
    fn test_serialize_file_transfer_complete() {
        let msg = RelayMessage::FileTransferComplete {
            transfer_id: "abc-123".to_string(),
            success: true,
            error: None,
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"file_transfer_complete\""));
        assert!(json.contains("\"success\":true"));
    }

    #[test]
    fn test_serialize_file_transfer_cancel() {
        let msg = RelayMessage::FileTransferCancel {
            transfer_id: "abc-123".to_string(),
            reason: "user cancelled".to_string(),
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"file_transfer_cancel\""));
    }

    #[test]
    fn test_serialize_device_authorize_request() {
        let json = r#"{"type":"device_authorize_request","fingerprint":"abc123","timestamp":1234567890}"#;
        let msg: RelayMessage = serde_json::from_str(json).unwrap();
        match msg {
            RelayMessage::DeviceAuthorizeRequest { fingerprint, timestamp } => {
                assert_eq!(fingerprint, "abc123");
                assert_eq!(timestamp, Some(1234567890));
            }
            _ => panic!("Expected DeviceAuthorizeRequest"),
        }
    }

    #[test]
    fn test_serialize_device_authorize_response() {
        let msg = RelayMessage::DeviceAuthorizeResponse {
            fingerprint: "abc123".to_string(),
            authorized: true,
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"device_authorize_response\""));
        assert!(json.contains("\"authorized\":true"));
    }

    #[test]
    fn test_roundtrip_all_variants() {
        let variants = vec![
            RelayMessage::pairing("key123".to_string()),
            RelayMessage::message("hello world".to_string()),
            RelayMessage::response("id-1".to_string(), "yes".to_string()),
            RelayMessage::peer_connected("computer"),
            RelayMessage::peer_disconnected("phone"),
        ];

        for msg in variants {
            let json = serde_json::to_string(&msg).unwrap();
            let deserialized: RelayMessage = serde_json::from_str(&json).unwrap();
            let json2 = serde_json::to_string(&deserialized).unwrap();
            assert_eq!(json, json2);
        }
    }

    // ===== P1+P2 Security Hardening: Cross-Component Format Tests =====

    #[test]
    fn test_device_authorize_request_serialization_matches_relay() {
        // Verify Rust serialization produces EXACT JSON that relay.ts sends
        let msg = RelayMessage::DeviceAuthorizeRequest {
            fingerprint: "a1b2c3d4e5f6".to_string(),
            timestamp: Some(1708300000000),
        };
        let json = serde_json::to_string(&msg).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

        // relay.ts sends: { type: "device_authorize_request", fingerprint: "...", timestamp: ... }
        assert_eq!(parsed["type"], "device_authorize_request");
        assert_eq!(parsed["fingerprint"], "a1b2c3d4e5f6");
        assert_eq!(parsed["timestamp"], 1708300000000i64);
    }

    #[test]
    fn test_device_authorize_request_without_timestamp() {
        // relay may send without timestamp — verify Rust handles it
        let json = r#"{"type":"device_authorize_request","fingerprint":"abc123"}"#;
        let msg: RelayMessage = serde_json::from_str(json).unwrap();
        match msg {
            RelayMessage::DeviceAuthorizeRequest { fingerprint, timestamp } => {
                assert_eq!(fingerprint, "abc123");
                assert!(timestamp.is_none());
            }
            _ => panic!("Expected DeviceAuthorizeRequest"),
        }
    }

    #[test]
    fn test_device_authorize_request_with_extra_fields() {
        // relay may include extra fields (e.g., deviceId) — verify Rust ignores them
        let json = r#"{"type":"device_authorize_request","fingerprint":"abc123","timestamp":123,"deviceId":"xyz","extraField":"ignored"}"#;
        let msg: RelayMessage = serde_json::from_str(json).unwrap();
        match msg {
            RelayMessage::DeviceAuthorizeRequest { fingerprint, timestamp } => {
                assert_eq!(fingerprint, "abc123");
                assert_eq!(timestamp, Some(123));
            }
            _ => panic!("Expected DeviceAuthorizeRequest"),
        }
    }

    #[test]
    fn test_device_authorize_response_serialization_matches_relay() {
        // Verify Rust output matches what relay.ts parses:
        // relay checks: parsed.fingerprint and parsed.authorized
        let msg_approve = RelayMessage::DeviceAuthorizeResponse {
            fingerprint: "a1b2c3d4e5f6".to_string(),
            authorized: true,
        };
        let json = serde_json::to_string(&msg_approve).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["type"], "device_authorize_response");
        assert_eq!(parsed["fingerprint"], "a1b2c3d4e5f6");
        assert_eq!(parsed["authorized"], true);

        // Also test deny
        let msg_deny = RelayMessage::DeviceAuthorizeResponse {
            fingerprint: "a1b2c3d4e5f6".to_string(),
            authorized: false,
        };
        let json_deny = serde_json::to_string(&msg_deny).unwrap();
        let parsed_deny: serde_json::Value = serde_json::from_str(&json_deny).unwrap();
        assert_eq!(parsed_deny["authorized"], false);
    }

    #[test]
    fn test_device_authorize_response_deserialization() {
        // Verify Rust can parse the format it sends (round-trip)
        let json = r#"{"type":"device_authorize_response","fingerprint":"test-fp","authorized":false}"#;
        let msg: RelayMessage = serde_json::from_str(json).unwrap();
        match msg {
            RelayMessage::DeviceAuthorizeResponse { fingerprint, authorized } => {
                assert_eq!(fingerprint, "test-fp");
                assert!(!authorized);
            }
            _ => panic!("Expected DeviceAuthorizeResponse"),
        }
    }

    #[test]
    fn test_device_authorize_roundtrip() {
        // Full round-trip: serialize then deserialize
        let original = RelayMessage::DeviceAuthorizeResponse {
            fingerprint: "sha256-fp-here".to_string(),
            authorized: true,
        };
        let json = serde_json::to_string(&original).unwrap();
        let deserialized: RelayMessage = serde_json::from_str(&json).unwrap();
        let json2 = serde_json::to_string(&deserialized).unwrap();
        assert_eq!(json, json2);
    }

    #[test]
    fn test_rekey_message_format_matches_phones() {
        // Bridge sends rekey as ad-hoc JSON: {"type":"rekey","pubkey":"base64..."}
        // Android parses: messageType == "rekey", then getString("pubkey")
        // iOS parses: type == "rekey", then string for "pubkey"
        // Verify the exact format
        let rekey_msg = serde_json::json!({
            "type": "rekey",
            "pubkey": "dGVzdHB1YmtleQ==",
        });
        let json = serde_json::to_string(&rekey_msg).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed["type"].as_str().unwrap(), "rekey");
        assert_eq!(parsed["pubkey"].as_str().unwrap(), "dGVzdHB1YmtleQ==");
        // Verify no extra fields
        assert_eq!(parsed.as_object().unwrap().len(), 2);
    }

    #[test]
    fn test_rekey_response_parsing() {
        // Phone sends back: {"type":"rekey","pubkey":"base64..."}
        // Bridge parses with serde_json::Value, checking .get("type") == "rekey"
        // and .get("pubkey").as_str()
        let phone_response = r#"{"type":"rekey","pubkey":"cGhvbmVwdWJrZXk="}"#;
        let parsed: serde_json::Value = serde_json::from_str(phone_response).unwrap();

        assert_eq!(
            parsed.get("type").and_then(|t| t.as_str()),
            Some("rekey")
        );
        let pubkey = parsed.get("pubkey").and_then(|p| p.as_str()).unwrap();
        assert_eq!(pubkey, "cGhvbmVwdWJrZXk=");

        // Verify base64 decodes successfully
        let decoded = base64::engine::general_purpose::STANDARD.decode(pubkey).unwrap();
        assert_eq!(decoded, b"phonepubkey");
    }

    #[test]
    fn test_rekey_response_with_extra_fields() {
        // Phone might include extra fields — bridge should still parse correctly
        let phone_response = r#"{"type":"rekey","pubkey":"dGVzdA==","timestamp":12345}"#;
        let parsed: serde_json::Value = serde_json::from_str(phone_response).unwrap();

        assert_eq!(
            parsed.get("type").and_then(|t| t.as_str()),
            Some("rekey")
        );
        assert!(parsed.get("pubkey").and_then(|p| p.as_str()).is_some());
    }

    #[test]
    fn test_session_authorized_format() {
        // relay sends: { type: "session_authorized", success: true/false }
        let json_success = r#"{"type":"session_authorized","success":true}"#;
        let msg: RelayMessage = serde_json::from_str(json_success).unwrap();
        match msg {
            RelayMessage::SessionAuthorized { success, .. } => {
                assert!(success);
            }
            _ => panic!("Expected SessionAuthorized"),
        }

        let json_fail = r#"{"type":"session_authorized","success":false,"reason":"Bridge denied authorization"}"#;
        let msg_fail: RelayMessage = serde_json::from_str(json_fail).unwrap();
        match msg_fail {
            RelayMessage::SessionAuthorized { success, .. } => {
                assert!(!success);
            }
            _ => panic!("Expected SessionAuthorized"),
        }
    }

    #[test]
    fn test_phone_authenticated_format() {
        // relay sends: { type: "phone_authenticated", deviceId: "fingerprint" }
        let json = r#"{"type":"phone_authenticated","deviceId":"sha256-fingerprint"}"#;
        let msg: RelayMessage = serde_json::from_str(json).unwrap();
        match msg {
            RelayMessage::PhoneAuthenticated { device_id } => {
                assert_eq!(device_id, "sha256-fingerprint");
            }
            _ => panic!("Expected PhoneAuthenticated"),
        }
    }

    #[test]
    fn test_peer_disconnected_with_revocation_reason() {
        // relay sends on cert revocation:
        // { type: "peer_disconnected", role: "phone", deviceId: "fp", reason: "certificate_revoked", phoneCount: 0, timestamp: ... }
        let json = r#"{"type":"peer_disconnected","role":"phone","deviceId":"abc","reason":"certificate_revoked","phoneCount":0,"timestamp":1234567}"#;
        let msg: RelayMessage = serde_json::from_str(json).unwrap();
        match msg {
            RelayMessage::PeerDisconnected { role, .. } => {
                assert_eq!(role, "phone");
            }
            _ => panic!("Expected PeerDisconnected"),
        }
    }

    #[test]
    fn test_unknown_message_type_does_not_panic() {
        // If relay adds a new message type in the future, Rust must NOT panic.
        // It should return a deserialization error that the caller can handle gracefully.
        let unknown = r#"{"type":"future_new_type","data":"something"}"#;
        let result = serde_json::from_str::<RelayMessage>(unknown);
        // Should be Err, not panic
        assert!(result.is_err(), "Unknown message type should return Err, not Ok");
    }

    #[test]
    fn test_malformed_json_does_not_panic() {
        // Malformed JSON must not crash the bridge
        let cases = vec![
            r#"{}"#,                          // no type field
            r#"{"type":null}"#,               // null type
            r#"{"type":123}"#,                // numeric type
            r#"{"type":""}"#,                 // empty type
            r#"not json at all"#,             // not JSON
            r#"{"type":"device_authorize_request"}"#,  // missing required field
        ];
        for case in cases {
            let result = serde_json::from_str::<RelayMessage>(case);
            // Each should be Err, never panic
            assert!(result.is_err(), "Should fail gracefully for: {}", case);
        }
    }

    #[test]
    fn test_rekey_invalid_base64_detected() {
        // If phone sends invalid base64 in rekey pubkey, bridge must catch it
        let bad_rekey = r#"{"type":"rekey","pubkey":"not-valid-base64!!!"}"#;
        let parsed: serde_json::Value = serde_json::from_str(bad_rekey).unwrap();
        let pubkey = parsed.get("pubkey").and_then(|p| p.as_str()).unwrap();
        let result = base64::engine::general_purpose::STANDARD.decode(pubkey);
        assert!(result.is_err(), "Invalid base64 must be detected");
    }

    #[test]
    fn test_device_authorize_request_is_control() {
        let msg = RelayMessage::DeviceAuthorizeRequest {
            fingerprint: "abc123".to_string(),
            timestamp: None,
        };
        assert!(msg.is_control());
    }

    #[test]
    fn test_device_authorize_response_is_control() {
        let msg = RelayMessage::DeviceAuthorizeResponse {
            fingerprint: "abc123".to_string(),
            authorized: true,
        };
        assert!(msg.is_control());
    }

    #[test]
    fn test_session_authorized_is_control() {
        let msg = RelayMessage::SessionAuthorized {
            success: true,
            reason: None,
        };
        assert!(msg.is_control());
    }

    #[test]
    fn test_device_authorize_response_deny_format() {
        let msg = RelayMessage::DeviceAuthorizeResponse {
            fingerprint: "fp-deny-test".to_string(),
            authorized: false,
        };
        let json = serde_json::to_string(&msg).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["type"], "device_authorize_response");
        assert_eq!(parsed["fingerprint"], "fp-deny-test");
        assert_eq!(parsed["authorized"], false);

        // Deserialize back and verify
        let rt: RelayMessage = serde_json::from_str(&json).unwrap();
        match rt {
            RelayMessage::DeviceAuthorizeResponse { fingerprint, authorized } => {
                assert_eq!(fingerprint, "fp-deny-test");
                assert!(!authorized);
            }
            _ => panic!("Expected DeviceAuthorizeResponse"),
        }
    }

    #[test]
    fn test_device_authorize_request_empty_fingerprint() {
        let msg = RelayMessage::DeviceAuthorizeRequest {
            fingerprint: "".to_string(),
            timestamp: Some(0),
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"fingerprint\":\"\""));

        let rt: RelayMessage = serde_json::from_str(&json).unwrap();
        match rt {
            RelayMessage::DeviceAuthorizeRequest { fingerprint, timestamp } => {
                assert_eq!(fingerprint, "");
                assert_eq!(timestamp, Some(0));
            }
            _ => panic!("Expected DeviceAuthorizeRequest"),
        }
    }
}
