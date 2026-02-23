import Flutter
import UIKit
import Foundation
import Security
import CommonCrypto

// MARK: - SecurityChannel (FlutterPlugin)

/// Bridges the native iOS security layer to Flutter/Dart via platform channels.
///
/// Method Channel: "app.clauderemote/security"
/// Event Channel:  "app.clauderemote/messages"
public class SecurityChannel: NSObject, FlutterPlugin {

    // MARK: - Properties

    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    /// Per-session WebSocket pool — each session maintains its own connection.
    /// Access ONLY through thread-safe accessors below (never touch _webSockets directly outside wsQueue.sync).
    private let wsQueue = DispatchQueue(label: "com.termopus.webSockets")
    private var _webSockets: [String: SecureWebSocket] = [:]

    /// Maximum concurrent WebSocket connections.
    private let maxConnections = 10

    /// The session ID currently active in the UI. Used for messaging defaults.
    private var activeSessionId: String?

    /// Pairing payloads deferred until after relay auth_challenge completes.
    private var pendingPairingPayloads: [String: String] = [:]

    /// Auth challenge nonces — stored per session for handshake completion marking.
    private var pendingAuthNonces: [String: String] = [:]

    // MARK: - Thread-safe WebSocket Pool Accessors

    private func webSocket(for sessionId: String) -> SecureWebSocket? {
        wsQueue.sync { _webSockets[sessionId] }
    }

    private func setWebSocket(_ ws: SecureWebSocket?, for sessionId: String) {
        wsQueue.sync { _webSockets[sessionId] = ws }
    }

    @discardableResult
    private func removeWebSocket(for sessionId: String) -> SecureWebSocket? {
        wsQueue.sync {
            let ws = _webSockets[sessionId]
            _webSockets[sessionId] = nil
            return ws
        }
    }

    private func allWebSockets() -> [(String, SecureWebSocket)] {
        wsQueue.sync { Array(_webSockets) }
    }

    private var webSocketCount: Int {
        wsQueue.sync { _webSockets.count }
    }

    /// Look up the WebSocket for the currently active session.
    private func activeWebSocket() -> SecureWebSocket? {
        guard let sid = activeSessionId else { return nil }
        return webSocket(for: sid)
    }

    /// Return the active WebSocket only if connected AND relay auth is complete.
    /// Returns nil during the auth window (onOpen -> auth_result), causing
    /// callers to queue messages for replay instead of sending to a relay
    /// that will drop them.
    private func authenticatedWebSocket() -> SecureWebSocket? {
        guard let ws = activeWebSocket(),
              ws.state == .connected,
              ws.isHandshakeComplete() else { return nil }
        return ws
    }

    /// Evict the oldest non-active connection if pool is at capacity.
    private func evictIfNeeded() {
        wsQueue.sync {
            guard _webSockets.count >= maxConnections else { return }
            if let victim = _webSockets.keys.first(where: { $0 != activeSessionId }) {
                NSLog("[SecurityChannel] WebSocket pool full (\(maxConnections)), evicting session \(victim.prefix(12))")
                _webSockets.removeValue(forKey: victim)?.disconnect()
            }
        }
    }

    // MARK: - FlutterPlugin Registration

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = SecurityChannel()

        // Method channel for request/response calls
        let methodChannel = FlutterMethodChannel(
            name: "app.clauderemote/security",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        instance.methodChannel = methodChannel

        // Event channel for streaming messages from WebSocket
        let eventChannel = FlutterEventChannel(
            name: "app.clauderemote/messages",
            binaryMessenger: registrar.messenger()
        )
        eventChannel.setStreamHandler(instance)
        instance.eventChannel = eventChannel

        // Initialize hardware security services (silent, no biometric)
        do {
            try HardwareKeyService.shared.initialize()
        } catch {
            NSLog("[SecurityChannel] Failed to initialize HardwareKeyService: \(error)")
        }
        do {
            try BiometricCryptoService.shared.initialize()
        } catch {
            NSLog("[SecurityChannel] Failed to initialize BiometricCryptoService: \(error)")
        }

        // Start network monitoring
        NetworkMonitor.shared.onStateChange = { [weak instance] state in
            NSLog("[SecurityChannel] Network state changed: reachable=\(state.isReachable) transport=\(state.transport.rawValue)")

            // Emit networkState event to Flutter
            instance?.sendEvent([
                "type": "networkState",
                "isReachable": state.isReachable,
                "transport": state.transport.rawValue,
            ])

            // If network recovered, probe/reconnect active sessions
            if state.isReachable {
                for (sid, ws) in instance?.allWebSockets() ?? [] {
                    if ws.state == .connected {
                        // Network interface changed — old TCP socket is likely bound to
                        // the dead interface. Force reconnect instead of waiting for
                        // ping probe to detect staleness.
                        NSLog("[SecurityChannel][\(sid.prefix(12))] Network changed, forcing reconnect")
                        ws.reconnectNow()
                    } else if ws.state == .reconnecting || ws.state == .disconnected {
                        // Trigger immediate reconnect
                        NSLog("[SecurityChannel][\(sid.prefix(12))] Network recovered, triggering immediate reconnect")
                        ws.reconnectNow()
                    }
                }
            }
        }
        NetworkMonitor.shared.start()
    }

    /// Queue a message for offline replay. Returns true if queued successfully.
    private func queueForReplay(_ envelope: [String: Any], messageType: String, result: @escaping FlutterResult) -> Bool {
        guard let sid = activeSessionId,
              let data = try? JSONSerialization.data(withJSONObject: envelope, options: []) else {
            return false
        }
        MessageQueue.shared.enqueue(sessionId: sid, data: data, messageType: messageType)
        result(true)
        return true
    }

    /// Replay queued messages after relay authentication succeeds.
    /// Uses sequential send with partial-failure safety: only removes messages
    /// that were actually sent, preserving unsent ones for the next reconnect.
    private func replayQueuedMessages(sessionId: String) {
        guard let ws = webSocket(for: sessionId) else { return }
        let queued = MessageQueue.shared.loadForSession(sessionId: sessionId)
        guard !queued.isEmpty else { return }
        NSLog("[SecurityChannel] [\(sessionId.prefix(12))] Replaying \(queued.count) queued messages")

        var sent = 0
        func sendNext() {
            guard sent < queued.count else {
                // All sent — remove and notify
                if sent > 0 {
                    MessageQueue.shared.removeFirst(sessionId: sessionId, count: sent)
                    DispatchQueue.main.async { [weak self] in
                        self?.sendEvent(["type": "queueReplayed", "count": sent, "sessionId": sessionId])
                    }
                }
                return
            }
            let msg = queued[sent]
            ws.send(data: msg.data) { error in
                if let error = error {
                    NSLog("[SecurityChannel] [\(sessionId.prefix(12))] Replay failed at \(sent): \(error)")
                    // Save what we sent so far
                    if sent > 0 {
                        MessageQueue.shared.removeFirst(sessionId: sessionId, count: sent)
                    }
                    return
                }
                sent += 1
                sendNext()
            }
        }
        sendNext()
    }

    /// Handles a decrypted message from a per-session WebSocket and forwards it to Flutter.
    /// The sessionId comes from the WebSocket instance — always correct regardless of
    /// which session is currently active in the UI.
    private func handleMessage(_ data: Data, fromSession sessionId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let sid = sessionId
            NSLog("[\(sid.prefix(12))] handleMessage: \(data.count) bytes")

            // Intercept auth_challenge / auth_result before forwarding to Flutter
            if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let type = json["type"] as? String {

                if type == "auth_challenge", let nonce = json["nonce"] as? String {
                    NSLog("[SecurityChannel][\(sid.prefix(12))] Received auth_challenge")
                    self.pendingAuthNonces[sid] = nonce  // Store for markHandshakeComplete
                    if let ws = self.webSocket(for: sid) {
                        self.handleAuthChallenge(sessionId: sid, nonce: nonce, ws: ws)
                    }
                    return // Don't forward to Flutter
                }

                if type == "rekey", let bridgePubkeyB64 = json["pubkey"] as? String {
                    NSLog("[SecurityChannel][\(sid.prefix(12))] Received rekey request — renegotiating session key")
                    self.handleRekey(sessionId: sid, bridgePubkeyBase64: bridgePubkeyB64)
                    return // Don't forward to Flutter
                }

                if type == "auth_result" {
                    let success = json["success"] as? Bool ?? false
                    let sessionAuthorized = json["sessionAuthorized"] as? Bool ?? false
                    NSLog("[SecurityChannel][\(sid.prefix(12))] Device auth result: success=\(success) sessionAuthorized=\(sessionAuthorized)")
                    if success {
                        // Mark handshake complete — enables plaintext type whitelist enforcement
                        if let nonce = self.pendingAuthNonces.removeValue(forKey: sid),
                           let ws = self.webSocket(for: sid) {
                            ws.markHandshakeComplete(nonce: nonce)
                            NSLog("[SecurityChannel][\(sid.prefix(12))] Handshake marked complete (plaintext whitelist active)")
                        }

                        if sessionAuthorized {
                            // Already authorized (in allowlist) — send pairing + replay now
                            self.sendDeferredPairingPayload(sessionId: sid)
                            self.replayQueuedMessages(sessionId: sid)
                        } else {
                            // Not yet authorized — wait for session_authorized before sending
                            // pairing payload and replaying queued messages (relay drops
                            // non-control messages from phones where sessionAuthorized=false)
                            NSLog("[SecurityChannel][\(sid.prefix(12))] Waiting for session_authorized before sending pairing payload")
                        }

                        // FCM registration is a relay control message — not gated, send now
                        if let fcmWs = self.webSocket(for: sid) {
                            self.sendPendingFcmToken(via: fcmWs)
                        }
                    } else {
                        let reason = json["reason"] as? String ?? "unknown"
                        self.pendingPairingPayloads.removeValue(forKey: sid)
                        self.eventSink?([
                            "type": "auth_error",
                            "sessionId": sid,
                            "reason": reason,
                        ])
                    }
                    return // Don't forward to Flutter
                }

                if type == "session_authorized" {
                    let success = json["success"] as? Bool ?? false
                    NSLog("[SecurityChannel][\(sid.prefix(12))] Session authorized: success=\(success)")
                    if success {
                        self.sendDeferredPairingPayload(sessionId: sid)
                        self.replayQueuedMessages(sessionId: sid)
                    } else {
                        let reason = json["reason"] as? String ?? "unknown"
                        NSLog("[SecurityChannel][\(sid.prefix(12))] Session authorization denied: \(reason)")
                        self.pendingPairingPayloads.removeValue(forKey: sid)
                        self.eventSink?([
                            "type": "auth_error",
                            "sessionId": sid,
                            "reason": "Authorization denied: \(reason)",
                        ])
                    }
                    return // Don't forward to Flutter
                }

                // Normal JSON message — forward to Flutter
                self.eventSink?([
                    "type": "message",
                    "payload": json,
                    "sessionId": sid,
                ])
            } else if let text = String(data: data, encoding: .utf8) {
                self.eventSink?([
                    "type": "message",
                    "payload": ["text": text],
                    "sessionId": sid,
                ])
            } else {
                self.eventSink?([
                    "type": "message",
                    "payload": ["data": data.base64EncodedString()],
                    "sessionId": sid,
                ])
            }
        }
    }

    /// Thread-safe event sink dispatch.
    private func sendEvent(_ event: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(event)
        }
    }

    // MARK: - Key Renegotiation

    /// Handle a rekey request from the bridge for per-connection forward secrecy.
    ///
    /// Flow:
    /// 1. Receive bridge's new ephemeral public key (already decrypted with OLD key)
    /// 2. Generate our own ephemeral P-256 key pair
    /// 3. Send our new public key back (encrypted with OLD key — CryptoEngine still has it)
    /// 4. Derive new shared secret via ephemeral ECDH
    /// 5. Update CryptoEngine with the new key (all subsequent messages use new key)
    /// 6. Persist the new key for reconnect after app kill
    ///
    /// IMPORTANT: Step 3 (send response) MUST happen before step 5 (key switch),
    /// because the response is encrypted with the OLD key.
    private func handleRekey(sessionId: String, bridgePubkeyBase64: String) {
        // Thread-safe lookup via serial queue
        guard let ws = self.webSocket(for: sessionId), ws.state == .connected else {
            NSLog("[SecurityChannel][\(sessionId.prefix(12))] Rekey: WebSocket not connected, aborting")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                // 1. Decode bridge's new public key
                guard let bridgePubkeyData = Data(base64Encoded: bridgePubkeyBase64) else {
                    NSLog("[SecurityChannel][\(sessionId.prefix(12))] Rekey: invalid base64 pubkey")
                    return
                }
                NSLog("[SecurityChannel][\(sessionId.prefix(12))] Rekey: bridge pubkey \(bridgePubkeyData.count) bytes")

                // 2. Generate our own ephemeral P-256 key pair
                let (ephemeralPrivateKey, ephemeralPublicKeyData) = try SecureKeyManager.shared.generateEphemeralKeyPair()
                NSLog("[SecurityChannel][\(sessionId.prefix(12))] Rekey: generated ephemeral keypair (\(ephemeralPublicKeyData.count) bytes pubkey)")

                let rekeyResponse: [String: Any] = [
                    "type": "rekey",
                    "pubkey": ephemeralPublicKeyData.base64EncodedString(),
                ]
                guard let responseData = try? JSONSerialization.data(withJSONObject: rekeyResponse, options: []) else {
                    NSLog("[SecurityChannel][\(sessionId.prefix(12))] Rekey: failed to serialize response")
                    return
                }

                // Send encrypted with OLD key (CryptoEngine still uses the old key)
                // Use a 5s timeout to prevent hanging forever if disconnect() races with rekey.
                let semaphore = DispatchSemaphore(value: 0)
                var sendError: Error?
                ws.send(data: responseData) { error in
                    sendError = error
                    semaphore.signal()
                }
                let waitResult = semaphore.wait(timeout: .now() + 5.0)

                if waitResult == .timedOut {
                    NSLog("[SecurityChannel][\(sessionId.prefix(12))] Rekey: send timed out (connection likely lost), proceeding with key switch")
                } else if let error = sendError {
                    NSLog("[SecurityChannel][\(sessionId.prefix(12))] Rekey: failed to send response: \(error)")
                    return
                }
                NSLog("[SecurityChannel][\(sessionId.prefix(12))] Rekey: sent response with our ephemeral pubkey")

                // 4. Derive new shared secret via ephemeral ECDH + HKDF
                let newSharedSecret = try SecureKeyManager.shared.deriveSharedSecretEphemeral(
                    ephemeralPrivateKey: ephemeralPrivateKey,
                    peerPublicKeyData: bridgePubkeyData
                )
                NSLog("[SecurityChannel][\(sessionId.prefix(12))] Rekey: derived new shared secret (\(newSharedSecret.count) bytes)")

                // 5. Update CryptoEngine with the new key
                try CryptoEngine.shared.setSharedSecret(newSharedSecret, forSession: sessionId)
                NSLog("[SecurityChannel][\(sessionId.prefix(12))] Session key renegotiated successfully")

                // 6. Persist the new key for reconnect after app kill
                SecureKeyManager.shared.persistSessionKey(newSharedSecret, forSession: sessionId)
                NSLog("[SecurityChannel][\(sessionId.prefix(12))] Rekeyed session key persisted")

            } catch {
                NSLog("[SecurityChannel][\(sessionId.prefix(12))] Rekey failed — keeping old key: \(error)")
            }
        }
    }

    // MARK: - Device Auth Challenge

    /// Responds to an `auth_challenge` from the relay by signing the nonce with
    /// the Secure Enclave private key and sending back a `device_auth` message.
    private func handleAuthChallenge(sessionId: String, nonce: String, ws: SecureWebSocket) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let fingerprint = CertificateManager.shared.getCertificateFingerprint(),
                      let certPEM = CertificateManager.shared.getCertificatePEM() else {
                    NSLog("[SecurityChannel][\(sessionId.prefix(12))] Cannot respond to auth_challenge: no certificate")
                    return
                }

                // Sign the nonce with Secure Enclave private key
                let nonceData = Data(nonce.utf8)
                let signature = try SecureKeyManager.shared.sign(data: nonceData)
                let signatureB64 = signature.base64EncodedString()

                // Build device_auth response
                let authResponse: [String: Any] = [
                    "type": "device_auth",
                    "fingerprint": fingerprint,
                    "signature": signatureB64,
                    "certificate": certPEM,
                ]

                let jsonData = try JSONSerialization.data(withJSONObject: authResponse)
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

                ws.sendPlaintext(jsonString) { error in
                    if let error = error {
                        NSLog("[SecurityChannel][\(sessionId.prefix(12))] Failed to send device_auth: \(error)")
                    } else {
                        NSLog("[SecurityChannel][\(sessionId.prefix(12))] Sent device_auth (fingerprint=\(fingerprint.prefix(16))...)")
                    }
                }
            } catch {
                NSLog("[SecurityChannel][\(sessionId.prefix(12))] Auth challenge error: \(error)")
            }
        }
    }

    // MARK: - Method Call Handling

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]

        switch call.method {

        // ========================
        // Biometric
        // ========================

        case "biometric.isAvailable":
            handleBiometricIsAvailable(result: result)

        case "biometric.type":
            handleBiometricType(result: result)

        case "biometric.authenticate":
            handleBiometricAuthenticate(args: args, result: result)

        case "biometric.authenticateSecure":
            handleBiometricAuthenticateSecure(args: args, result: result)

        // ========================
        // Device Integrity
        // ========================

        case "device.checkIntegrity":
            handleDeviceCheckIntegrity(result: result)

        case "device.attest":
            handleDeviceAttest(args: args, result: result)

        case "device.assertion":
            handleDeviceAssertion(args: args, result: result)

        // ========================
        // Certificates
        // ========================

        case "cert.generateCSR":
            handleCertGenerateCSR(args: args, result: result)

        case "cert.store":
            handleCertStore(args: args, result: result)

        case "cert.exists":
            handleCertExists(result: result)

        case "cert.getPEM":
            handleCertGetPEM(result: result)

        case "cert.delete":
            handleCertDelete(result: result)

        // ========================
        // Key Management
        // ========================

        case "keys.generate":
            handleKeysGenerate(result: result)

        case "keys.getPublicKey":
            handleKeysGetPublicKey(result: result)

        case "keys.delete":
            handleKeysDelete(result: result)

        case "keys.sign":
            handleKeysSign(args: args, result: result)

        // ========================
        // Session / WebSocket
        // ========================

        case "session.pair":
            handleSessionPair(args: args, result: result)

        case "session.connect":
            handleSessionConnect(args: args, result: result)

        case "session.disconnect":
            handleSessionDisconnect(args: args, result: result)

        case "session.state":
            handleSessionState(result: result)

        case "session.clearData":
            handleSessionClearData(args: args, result: result)

        case "session.delete":
            handleSessionDelete(args: args, result: result)

        case "session.keepalive":
            guard let sid = args?["sessionId"] as? String,
                  let ws = webSocket(for: sid) else { result(false); return }
            ws.sendPlaintext("{\"type\":\"keepalive\"}") { err in result(err == nil) }

        // ========================
        // Messaging
        // ========================

        case "message.send":
            handleMessageSend(args: args, result: result)

        case "message.sendKey":
            handleMessageSendKey(args: args, result: result)

        case "message.sendInput":
            handleMessageSendInput(args: args, result: result)

        case "message.respond":
            handleMessageRespond(args: args, result: result)

        case "message.command":
            handleMessageCommand(args: args, result: result)

        case "message.setModel":
            handleMessageSetModel(args: args, result: result)

        case "message.config":
            handleMessageConfig(args: args, result: result)

        // ========================
        // HTTP Tunnel
        // ========================

        case "httpTunnel.open":
            handleHttpTunnelOpen(args: args, result: result)

        case "httpTunnel.close":
            handleHttpTunnelClose(args: args, result: result)

        case "httpTunnel.request":
            handleHttpRequest(args: args, result: result)

        // ========================
        // File Transfer
        // ========================

        case "file.send":
            guard let filePath = args?["filePath"] as? String,
                  let fileName = args?["fileName"] as? String,
                  let mimeType = args?["mimeType"] as? String else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "filePath, fileName, and mimeType are required",
                    details: nil
                ))
                return
            }

            guard authenticatedWebSocket() != nil else {
                result(FlutterError(
                    code: "NOT_CONNECTED",
                    message: "WebSocket is not connected",
                    details: nil
                ))
                return
            }

            sendFile(path: filePath, name: fileName, mime: mimeType) { success in
                if success {
                    result(true)
                } else {
                    result(FlutterError(
                        code: "FILE_SEND_FAILED",
                        message: "File transfer failed",
                        details: nil
                    ))
                }
            }

        case "file.accept":
            guard let transferId = args?["transferId"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "transferId is required", details: nil))
                return
            }
            acceptFileTransfer(id: transferId, result: result)

        case "file.cancel":
            guard let transferId = args?["transferId"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "transferId is required", details: nil))
                return
            }
            cancelFileTransfer(id: transferId, result: result)

        // ========================
        // FCM
        // ========================

        // ========================
        // Security
        // ========================

        case "security.getDeviceId":
            do {
                let deviceId = try SecureKeyManager.shared.getDeviceId()
                result(deviceId)
            } catch {
                result(FlutterError(code: "DEVICE_ID_FAILED", message: error.localizedDescription, details: nil))
            }

        case "security.getEndpoint":
            handleSecurityGetEndpoint(args: args, result: result)

        case "security.enforceResult":
            handleSecurityEnforceResult(args: args, result: result)

        case "biometric.signChallenge":
            handleBiometricSignChallenge(args: args, result: result)

        case "biometric.getPublicKey":
            handleBiometricGetPublicKey(result: result)

        case "hardware.encrypt":
            handleHardwareEncrypt(args: args, result: result)

        case "hardware.decrypt":
            handleHardwareDecrypt(args: args, result: result)

        case "fcm.register":
            handleFCMRegister(args: args, result: result)

        // ========================
        // Bridge Controls
        // ========================

        case "bridge.command":
            handleBridgeCommand(args: args, result: result)

        case "bridge.status":
            handleBridgeStatus(result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Biometric Handlers

    private func handleBiometricIsAvailable(result: @escaping FlutterResult) {
        let available = BiometricGate.shared.isAvailable()
        result(available)
    }

    private func handleBiometricType(result: @escaping FlutterResult) {
        result(BiometricGate.shared.biometricType().rawValue)
    }

    private func handleBiometricAuthenticate(args: [String: Any]?, result: @escaping FlutterResult) {
        let reason = args?["reason"] as? String ?? "Authenticate to continue"

        BiometricGate.shared.authenticate(reason: reason) { success, error in
            result(success)
        }
    }

    /// Secure biometric authentication with HMAC proof.
    ///
    /// Flow:
    /// 1. Generate 32-byte random nonce
    /// 2. BiometricCryptoService.signChallenge(nonce) with LAContext
    ///    → Real biometric → Secure Enclave signs → valid ECDSA
    ///    → Fake biometric → key locked → sign() throws → secureExit()
    /// 3. Verify ECDSA signature with the biometric public key
    /// 4. If valid: NativeSecretsWrapper.signSecurityResult("BIOMETRIC_OK") → HMAC string
    /// 5. If invalid: NativeSecretsWrapper.secureExit() → __builtin_trap()
    ///
    /// Returns {"signedResult": hmacString} — never a boolean.
    private func handleBiometricAuthenticateSecure(args: [String: Any]?, result: @escaping FlutterResult) {
        let reason = args?["reason"] as? String ?? "Authenticate to continue"

        // 1. Generate 32-byte random nonce
        var nonceBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        guard status == errSecSuccess else {
            result(FlutterError(code: "NONCE_FAILED", message: "Failed to generate nonce", details: nil))
            return
        }
        let nonceData = Data(nonceBytes)
        let nonceB64 = nonceData.base64EncodedString()

        // 2. Sign with biometric-protected key (triggers Face ID / Touch ID)
        BiometricCryptoService.shared.signChallenge(nonceB64, reason: reason) { signResult in
            DispatchQueue.main.async {
                switch signResult {
                case .success(let signatureB64):
                    do {
                        // 3. Verify ECDSA signature
                        guard let signatureData = Data(base64Encoded: signatureB64) else {
                            NativeSecretsWrapper.secureExit()
                            return
                        }

                        let publicKeyData = try BiometricCryptoService.shared.getPublicKey()

                        // Reconstruct the public key from X9.63 representation
                        let attributes: [String: Any] = [
                            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                            kSecAttrKeySizeInBits as String: 256,
                        ]

                        var error: Unmanaged<CFError>?
                        guard let publicKey = SecKeyCreateWithData(publicKeyData as CFData, attributes as CFDictionary, &error) else {
                            NSLog("[SecurityChannel] Failed to create public key: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
                            NativeSecretsWrapper.secureExit()
                            return
                        }

                        // Verify: SHA256 + ECDSA over raw nonce bytes
                        let verified = SecKeyVerifySignature(
                            publicKey,
                            .ecdsaSignatureMessageX962SHA256,
                            nonceData as CFData,
                            signatureData as CFData,
                            &error
                        )

                        if verified {
                            // 4. Valid: return HMAC-signed proof
                            let hmac = NativeSecretsWrapper.signSecurityResult("BIOMETRIC_OK")
                            result(["signedResult": hmac])
                        } else {
                            // 5. Invalid signature: tampered — crash
                            NativeSecretsWrapper.secureExit()
                        }
                    } catch {
                        // Verification infrastructure failure — crash (defensive)
                        NSLog("[SecurityChannel] Biometric verification failed: \(error)")
                        NativeSecretsWrapper.secureExit()
                    }

                case .failure(let error):
                    // User cancelled or biometric not recognized
                    result(FlutterError(code: "BIOMETRIC_FAILED", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    // MARK: - Device Integrity Handlers

    private func handleDeviceCheckIntegrity(result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            let signedResult = AntiTamper.shared.checkIntegritySigned()
            DispatchQueue.main.async {
                // Return MAC-signed string to Dart — NOT a boolean
                result(signedResult)
            }
        }
    }

    private func handleDeviceAttest(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let challengeBase64 = args?["challenge"] as? String,
              let challengeData = Data(base64Encoded: challengeBase64) else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing or invalid 'challenge' (Base64 string required).",
                details: nil
            ))
            return
        }

        // Self-hosted: attestation disabled
        result("")
    }

    private func handleDeviceAssertion(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let challengeBase64 = args?["challenge"] as? String,
              let challengeData = Data(base64Encoded: challengeBase64) else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing or invalid 'challenge' (Base64 string required).",
                details: nil
            ))
            return
        }

        // Self-hosted: assertion disabled
        result(["assertion": ""])
    }

    // MARK: - Certificate Handlers

    private func handleCertGenerateCSR(args: [String: Any]?, result: @escaping FlutterResult) {
        do {
            let challenge = args?["challenge"] as? String

            // If a public key is provided, use it; otherwise derive from SecureKeyManager
            let publicKeyData: Data
            if let pkBase64 = args?["publicKey"] as? String, let pkData = Data(base64Encoded: pkBase64) {
                publicKeyData = pkData
            } else {
                // Generate fresh key pair in Secure Enclave (idempotent — deletes existing first)
                try SecureKeyManager.shared.generateKeyPair()
                publicKeyData = try SecureKeyManager.shared.getPublicKey()
            }

            let pem = try CertificateManager.shared.generateCSR(publicKey: publicKeyData)

            if challenge != nil {
                // Match Android's Map response format when challenge is provided.
                // iOS doesn't support Key Attestation cert chains (uses App Attest instead),
                // so keyAttestationChain is omitted — Dart handles this gracefully.
                let responseMap: [String: Any] = ["csr": pem]
                result(responseMap)
            } else {
                // Backward compatibility: return just the CSR string
                result(pem)
            }
        } catch {
            result(FlutterError(
                code: "CSR_FAILED",
                message: error.localizedDescription,
                details: nil
            ))
        }
    }

    private func handleCertStore(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let certificate = args?["certificate"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing 'certificate' string argument.",
                details: nil
            ))
            return
        }

        do {
            let stored = try CertificateManager.shared.storeCertificate(certificate)
            result(stored)
        } catch {
            result(FlutterError(
                code: "CERT_STORE_FAILED",
                message: error.localizedDescription,
                details: nil
            ))
        }
    }

    private func handleCertExists(result: @escaping FlutterResult) {
        result(CertificateManager.shared.hasCertificate())
    }

    private func handleCertGetPEM(result: @escaping FlutterResult) {
        let pem = CertificateManager.shared.getCertificatePEM()
        result(pem)
    }

    private func handleCertDelete(result: @escaping FlutterResult) {
        let deleted = CertificateManager.shared.deleteCertificate()
        result(["deleted": deleted])
    }

    // MARK: - Key Management Handlers

    private func handleKeysGenerate(result: @escaping FlutterResult) {
        do {
            try SecureKeyManager.shared.generateKeyPair()
            let publicKey = try SecureKeyManager.shared.getPublicKey()
            result([
                "publicKey": publicKey.base64EncodedString(),
            ])
        } catch {
            result(FlutterError(
                code: "KEY_GEN_FAILED",
                message: error.localizedDescription,
                details: nil
            ))
        }
    }

    private func handleKeysGetPublicKey(result: @escaping FlutterResult) {
        do {
            let publicKey = try SecureKeyManager.shared.getPublicKey()
            result([
                "publicKey": publicKey.base64EncodedString(),
            ])
        } catch {
            result(FlutterError(
                code: "KEY_NOT_FOUND",
                message: error.localizedDescription,
                details: nil
            ))
        }
    }

    private func handleKeysDelete(result: @escaping FlutterResult) {
        do {
            try SecureKeyManager.shared.deleteKeyPair()
            result(["deleted": true])
        } catch {
            result(FlutterError(
                code: "KEY_DELETE_FAILED",
                message: error.localizedDescription,
                details: nil
            ))
        }
    }

    private func handleKeysSign(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let dataBase64 = args?["data"] as? String,
              let data = Data(base64Encoded: dataBase64) else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing or invalid 'data' (Base64 string required).",
                details: nil
            ))
            return
        }

        do {
            let signature = try SecureKeyManager.shared.sign(data: data)
            result([
                "signature": signature.base64EncodedString(),
            ])
        } catch {
            result(FlutterError(
                code: "SIGN_FAILED",
                message: error.localizedDescription,
                details: nil
            ))
        }
    }

    // MARK: - Session Handlers

    /// Validate device integrity before allowing session operations.
    ///
    /// Runs AntiTamper.checkIntegritySigned() and validates via
    /// NativeSecretsWrapper.enforceSecurityResult(). If the device is tampered,
    /// the native C layer crashes the app via __builtin_trap().
    ///
    /// Returns true if integrity check passes, false if it fails (and sets error on result).
    private func validateIntegrityGate(result: @escaping FlutterResult) -> Bool {
        // Self-hosted: integrity checks disabled
        return true
    }

    /// Build the relay WebSocket URL with session ID and role.
    private func buildRelayUrl(relay: String, sessionId: String) -> URL? {
        var base = relay.trimmingCharacters(in: .whitespaces).lowercased()
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        if base.hasPrefix("https://") {
            base = base.replacingOccurrences(of: "https://", with: "wss://")
        } else if base.hasPrefix("http://") {
            base = base.replacingOccurrences(of: "http://", with: "ws://")
        } else if !base.hasPrefix("wss://") && !base.hasPrefix("ws://") {
            base = "wss://\(base)"
        }


        return URL(string: "\(base)/\(sessionId)?role=phone")
    }

    private func handleSessionPair(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let peerKeyBase64 = args?["peerPublicKey"] as? String,
              let peerKeyData = Data(base64Encoded: peerKeyBase64) else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing or invalid 'peerPublicKey' (Base64 string required).",
                details: nil
            ))
            return
        }

        guard let relay = args?["relay"] as? String,
              let sessionId = args?["sessionId"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing or invalid 'relay' and/or 'sessionId'.",
                details: nil
            ))
            return
        }

        guard let url = buildRelayUrl(relay: relay, sessionId: sessionId) else {
            result(FlutterError(
                code: "SECURITY_ERROR",
                message: "Non-TLS relay URL rejected",
                details: nil
            ))
            return
        }

        // Security gate: validate biometric proof if provided
        if let biometricProof = args?["biometricProof"] as? String, !biometricProof.isEmpty {
            NativeSecretsWrapper.enforceSecurityResult(biometricProof)
        }

        // Security gate: validate device integrity
        guard validateIntegrityGate(result: result) else { return }

        do {
            // 1. Track active session
            self.activeSessionId = sessionId

            // 1b. Ensure we have a permanent key pair for device_auth signing
            if (try? SecureKeyManager.shared.getPrivateKey()) == nil {
                try SecureKeyManager.shared.generateKeyPair()
            }

            // 2. Generate ephemeral P-256 key pair (in-memory, not Secure Enclave)
            let (ephemeralPrivateKey, ephemeralPublicKeyData) = try SecureKeyManager.shared.generateEphemeralKeyPair()

            // 3. Derive shared secret via ephemeral ECDH + HKDF (forward secrecy)
            let sharedSecret = try SecureKeyManager.shared.deriveSharedSecretEphemeral(
                ephemeralPrivateKey: ephemeralPrivateKey,
                peerPublicKeyData: peerKeyData
            )

            // 4. Set the shared secret in CryptoEngine (session-keyed)
            try CryptoEngine.shared.setSharedSecret(sharedSecret, forSession: sessionId)

            // 5. Persist derived AES key for reconnect after app kill
            SecureKeyManager.shared.persistSessionKey(sharedSecret, forSession: sessionId)

            // 6. Prepare pairing message with EPHEMERAL public key (not permanent)
            let pairingMessage: [String: Any] = [
                "type": "pairing",
                "pubkey": ephemeralPublicKeyData.base64EncodedString(),
            ]
            let pairingJson: String? = {
                guard let data = try? JSONSerialization.data(withJSONObject: pairingMessage, options: []) else { return nil }
                return String(data: data, encoding: .utf8)
            }()

            // 7. Create per-session WebSocket (disconnect any existing one for this session)
            if let ws = removeWebSocket(for: sessionId) { ws.disconnect() }
            evictIfNeeded()
            let ws = SecureWebSocket(sessionId: sessionId)
            ws.connect(
                url: url,
                onMessage: { [weak self] data in
                    self?.handleMessage(data, fromSession: sessionId)
                },
                onStateChange: { [weak self] state in
                    if state == .connected, let json = pairingJson {
                        // Defer pairing message until after relay auth_challenge completes.
                        // The relay gates non-control messages from unauthenticated phones,
                        // so sending now would be dropped. Store it and send on auth_result success.
                        self?.pendingPairingPayloads[sessionId] = json
                        NSLog("[\(sessionId.prefix(12))] Connected, pairing payload stored (waiting for auth)")
                    }

                    // Emit per-session connectionState event to Flutter
                    self?.sendEvent([
                        "type": "connectionState",
                        "state": state.rawValue,
                        "sessionId": sessionId,
                    ])

                    // FCM token send deferred until after auth succeeds
                }
            )
            setWebSocket(ws, for: sessionId)

            result(true)
        } catch {
            result(FlutterError(
                code: "PAIRING_FAILED",
                message: error.localizedDescription,
                details: nil
            ))
        }
    }

    private func handleSessionConnect(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let sessionId = args?["sessionId"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing 'sessionId' string.",
                details: nil
            ))
            return
        }

        // Security gate: validate device integrity before reconnect
        guard validateIntegrityGate(result: result) else { return }

        self.activeSessionId = sessionId

        // Restore shared secret if lost (e.g. app was killed by OS)
        if !CryptoEngine.shared.hasKey(forSession: sessionId) {
            if let aesKey = SecureKeyManager.shared.loadSessionKey(forSession: sessionId) {
                do {
                    try CryptoEngine.shared.setSharedSecret(aesKey, forSession: sessionId)
                    NSLog("[SecurityChannel] Session key restored from Keychain for \(sessionId)")
                } catch {
                    SecureKeyManager.shared.deleteSessionKey(forSession: sessionId)
                    result(FlutterError(
                        code: "NO_SESSION",
                        message: "Failed to restore session key: \(error.localizedDescription)",
                        details: nil
                    ))
                    return
                }
            } else {
                result(FlutterError(
                    code: "NO_SESSION",
                    message: "No shared secret available — re-pairing required",
                    details: nil
                ))
                return
            }
        } else {
            // Key exists — just switch to it
            _ = CryptoEngine.shared.setActiveSession(sessionId)
        }

        let nativeRelay = NativeSecretsWrapper.getEndpoint("relay")
        let relay = args?["relay"] as? String ?? (nativeRelay.isEmpty ? "wss://YOUR_RELAY_DEV_DOMAIN" : nativeRelay)
        guard let url = buildRelayUrl(relay: relay, sessionId: sessionId) else {
            result(FlutterError(
                code: "SECURITY_ERROR",
                message: "Non-TLS relay URL rejected",
                details: nil
            ))
            return
        }

        // If already connected to THIS session, verify the connection is still alive
        if let existing = webSocket(for: sessionId), existing.state == .connected {
            _ = CryptoEngine.shared.setActiveSession(sessionId)
            existing.verifyConnection { isAlive in
                if isAlive {
                    result(true)
                } else {
                    // Connection was stale — verifyConnection triggers reconnect internally
                    result(false)
                }
            }
            return
        }

        // Create per-session WebSocket (disconnect any stale one for this session)
        if let ws = removeWebSocket(for: sessionId) { ws.disconnect() }
        evictIfNeeded()
        let ws = SecureWebSocket(sessionId: sessionId)
        ws.connect(
            url: url,
            onMessage: { [weak self] data in
                self?.handleMessage(data, fromSession: sessionId)
            },
            onStateChange: { [weak self] state in
                self?.sendEvent([
                    "type": "connectionState",
                    "state": state.rawValue,
                    "sessionId": sessionId,
                ])

                // FCM token send deferred until after auth succeeds
            }
        )
        setWebSocket(ws, for: sessionId)

        result(true)
    }

    private func handleSessionDisconnect(args: [String: Any]?, result: @escaping FlutterResult) {
        let sid = args?["sessionId"] as? String ?? activeSessionId
        if let sid = sid {
            if let ws = removeWebSocket(for: sid) { ws.disconnect() }
        }
        // DON'T clear the crypto key — it's cached for reconnect.
        // Keys are only removed via session.clearData.
        result(nil)
    }

    private func handleSessionState(result: @escaping FlutterResult) {
        let state = activeWebSocket()?.state ?? .disconnected
        result(state.rawValue)
    }

    private func handleSessionClearData(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let sessionId = args?["sessionId"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing 'sessionId' string.",
                details: nil
            ))
            return
        }
        if let ws = removeWebSocket(for: sessionId) { ws.disconnect() }
        CryptoEngine.shared.clearKey(forSession: sessionId)
        SecureKeyManager.shared.deleteSessionKey(forSession: sessionId)
        result(true)
    }

    /// Notify the bridge to delete a session (kill Claude process + clean storage).
    /// Uses the session-specific WebSocket, not the active one.
    private func handleSessionDelete(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let sessionId = args?["sessionId"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing 'sessionId' string.",
                details: nil
            ))
            return
        }

        guard let ws = webSocket(for: sessionId),
              ws.state == .connected,
              ws.isHandshakeComplete() else {
            // Bridge offline or not authenticated — phone cleans up locally, bridge cleans on restart
            result(true)
            return
        }

        let envelope: [String: Any] = [
            "type": "command",
            "command": "delete_session",
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: []) else {
            result(false)
            return
        }

        ws.send(data: data) { [weak self] error in
            if let error = error {
                NSLog("Failed to send delete_session: \(error)")
            }
            // Disconnect and remove from pool after sending
            if let ws = self?.removeWebSocket(for: sessionId) { ws.disconnect() }
            result(true)
        }
    }

    // MARK: - Message Handlers

    private func handleMessageSend(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let content = args?["content"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing 'content' argument.",
                details: nil
            ))
            return
        }

        let envelope: [String: Any] = [
            "type": "message",
            "content": content,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]

        guard let ws = authenticatedWebSocket() else {
            if queueForReplay(envelope, messageType: "message", result: result) { return }
            result(FlutterError(code: "NOT_CONNECTED", message: "WebSocket is not connected", details: nil))
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: []) else {
            result(FlutterError(code: "ENCODING_ERROR", message: "Failed to serialize message.", details: nil))
            return
        }

        ws.send(data: data) { error in
            if let error = error {
                result(FlutterError(
                    code: "SEND_FAILED",
                    message: error.localizedDescription,
                    details: nil
                ))
            } else {
                result(true)
            }
        }
    }

    private func handleMessageSendKey(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let key = args?["key"] as? String, !key.isEmpty else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing 'key' argument.",
                details: nil
            ))
            return
        }

        let envelope: [String: Any] = [
            "type": "key",
            "key": key,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]

        guard let ws = authenticatedWebSocket() else {
            if queueForReplay(envelope, messageType: "key", result: result) { return }
            result(FlutterError(code: "NOT_CONNECTED", message: "WebSocket is not connected", details: nil))
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: []) else {
            result(FlutterError(code: "ENCODING_ERROR", message: "Failed to serialize key event.", details: nil))
            return
        }

        ws.send(data: data) { error in
            if let error = error {
                result(FlutterError(code: "SEND_FAILED", message: error.localizedDescription, details: nil))
            } else {
                result(true)
            }
        }
    }

    private func handleMessageSendInput(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let content = args?["content"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing 'content' argument.",
                details: nil
            ))
            return
        }

        let envelope: [String: Any] = [
            "type": "input",
            "content": content,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]

        guard let ws = authenticatedWebSocket() else {
            if queueForReplay(envelope, messageType: "input", result: result) { return }
            result(FlutterError(code: "NOT_CONNECTED", message: "WebSocket is not connected", details: nil))
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: []) else {
            result(FlutterError(code: "ENCODING_ERROR", message: "Failed to serialize input.", details: nil))
            return
        }

        ws.send(data: data) { error in
            if let error = error {
                result(FlutterError(code: "SEND_FAILED", message: error.localizedDescription, details: nil))
            } else {
                result(true)
            }
        }
    }

    private func handleMessageRespond(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let actionId = args?["actionId"] as? String,
              let response = args?["response"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing 'actionId' and/or 'response' arguments.",
                details: nil
            ))
            return
        }

        let envelope: [String: Any] = [
            "type": "response",
            "actionId": actionId,
            "response": response,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]

        guard let ws = authenticatedWebSocket() else {
            if queueForReplay(envelope, messageType: "response", result: result) { return }
            result(FlutterError(code: "NOT_CONNECTED", message: "WebSocket is not connected", details: nil))
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: []) else {
            result(FlutterError(code: "ENCODING_ERROR", message: "Failed to serialize response.", details: nil))
            return
        }

        ws.send(data: data) { error in
            if let error = error {
                result(FlutterError(
                    code: "SEND_FAILED",
                    message: error.localizedDescription,
                    details: nil
                ))
            } else {
                result(true)
            }
        }
    }

    // MARK: - Bridge Control Handlers

    private func handleBridgeCommand(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let command = args?["command"] as? String, !command.isEmpty else {
            result(FlutterError(code: "INVALID_ARGS", message: "command is required", details: nil))
            return
        }

        guard let ws = authenticatedWebSocket() else {
            result(FlutterError(
                code: "NOT_CONNECTED",
                message: "WebSocket is not connected",
                details: nil
            ))
            return
        }

        let envelope: [String: Any] = [
            "type": "bridge_command",
            "command": command,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: []) else {
            result(FlutterError(code: "ENCODING_ERROR", message: "Failed to serialize command.", details: nil))
            return
        }

        ws.send(data: data) { error in
            if let error = error {
                result(FlutterError(code: "SEND_FAILED", message: error.localizedDescription, details: nil))
            } else {
                result("Command sent: \(command)")
            }
        }
    }

    private func handleBridgeStatus(result: @escaping FlutterResult) {
        guard let sessionId = activeSessionId else {
            result(["status": "no_session"])
            return
        }

        let ws = activeWebSocket()
        let state = ws?.state.rawValue ?? "disconnected"
        result([
            "status": state,
            "sessionId": sessionId,
        ])
    }

    // MARK: - Command Handlers

    private func handleMessageCommand(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let command = args?["command"] as? String, !command.isEmpty else {
            result(FlutterError(code: "INVALID_ARGS", message: "command is required", details: nil))
            return
        }

        guard let ws = authenticatedWebSocket() else {
            result(FlutterError(
                code: "NOT_CONNECTED",
                message: "WebSocket is not connected",
                details: nil
            ))
            return
        }

        var envelope: [String: Any] = [
            "type": "command",
            "command": command,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]
        if let cmdArgs = args?["args"] as? String {
            envelope["args"] = cmdArgs
        }

        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: []) else {
            result(FlutterError(code: "ENCODING_ERROR", message: "Failed to serialize command.", details: nil))
            return
        }

        ws.send(data: data) { error in
            if let error = error {
                result(FlutterError(code: "SEND_FAILED", message: error.localizedDescription, details: nil))
            } else {
                result(true)
            }
        }
    }

    private func handleHttpTunnelOpen(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let ws = authenticatedWebSocket() else {
            result(FlutterError(code: "NOT_CONNECTED", message: "WebSocket is not connected", details: nil))
            return
        }
        let envelope: [String: Any] = [
            "type": "http_tunnel_open",
            "port": args?["port"] as? Int ?? 3000,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else {
            result(FlutterError(code: "SERIALIZE_FAILED", message: nil, details: nil))
            return
        }
        ws.send(data: data) { error in
            result(error == nil ? true : FlutterError(code: "SEND_FAILED", message: error?.localizedDescription, details: nil))
        }
    }

    private func handleHttpTunnelClose(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let ws = authenticatedWebSocket() else {
            result(FlutterError(code: "NOT_CONNECTED", message: "WebSocket is not connected", details: nil))
            return
        }
        let envelope: [String: Any] = ["type": "http_tunnel_close"]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else {
            result(FlutterError(code: "SERIALIZE_FAILED", message: nil, details: nil))
            return
        }
        ws.send(data: data) { error in
            result(error == nil ? true : FlutterError(code: "SEND_FAILED", message: error?.localizedDescription, details: nil))
        }
    }

    private func handleHttpRequest(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let ws = authenticatedWebSocket() else {
            result(FlutterError(code: "NOT_CONNECTED", message: "WebSocket is not connected", details: nil))
            return
        }
        var envelope: [String: Any] = [
            "type": "http_request",
            "requestId": args?["requestId"] as? String ?? "",
            "method": args?["method"] as? String ?? "GET",
            "path": args?["path"] as? String ?? "/",
        ]
        if let headers = args?["headers"] as? [String: String] {
            envelope["headers"] = headers
        }
        if let body = args?["body"] as? String {
            envelope["body"] = body
        }
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else {
            result(FlutterError(code: "SERIALIZE_FAILED", message: nil, details: nil))
            return
        }
        ws.send(data: data) { error in
            result(error == nil ? true : FlutterError(code: "SEND_FAILED", message: error?.localizedDescription, details: nil))
        }
    }

    private func handleMessageSetModel(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let model = args?["model"] as? String, !model.isEmpty else {
            result(FlutterError(code: "INVALID_ARGS", message: "model is required", details: nil))
            return
        }

        guard let ws = authenticatedWebSocket() else {
            result(FlutterError(code: "NOT_CONNECTED", message: "WebSocket is not connected", details: nil))
            return
        }

        let envelope: [String: Any] = [
            "type": "set_model",
            "model": model,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: []) else {
            result(FlutterError(code: "ENCODING_ERROR", message: "Failed to serialize model.", details: nil))
            return
        }

        ws.send(data: data) { error in
            if let error = error {
                result(FlutterError(code: "SEND_FAILED", message: error.localizedDescription, details: nil))
            } else {
                result(true)
            }
        }
    }

    private func handleMessageConfig(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let key = args?["key"] as? String, !key.isEmpty else {
            result(FlutterError(code: "INVALID_ARGS", message: "key is required", details: nil))
            return
        }

        guard let ws = authenticatedWebSocket() else {
            result(FlutterError(code: "NOT_CONNECTED", message: "WebSocket is not connected", details: nil))
            return
        }

        var envelope: [String: Any] = [
            "type": "config",
            "key": key,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]
        if let value = args?["value"] {
            envelope["value"] = value
        }

        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: []) else {
            result(FlutterError(code: "ENCODING_ERROR", message: "Failed to serialize config.", details: nil))
            return
        }

        ws.send(data: data) { error in
            if let error = error {
                result(FlutterError(code: "SEND_FAILED", message: error.localizedDescription, details: nil))
            } else {
                result(true)
            }
        }
    }

    // MARK: - File Transfer Handlers

    /// Sends a dictionary as an encrypted JSON message over the WebSocket.
    private func sendEncrypted(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            NSLog("[SecurityChannel] Failed to serialize file transfer message")
            return
        }
        guard let ws = authenticatedWebSocket() else {
            NSLog("[SecurityChannel] Cannot send encrypted message — WebSocket not connected or not authenticated")
            return
        }
        ws.send(data: data) { error in
            if let error = error {
                NSLog("[SecurityChannel] Failed to send encrypted file message: \(error.localizedDescription)")
            }
        }
    }

    /// Reads a file, computes SHA-256, chunks into 192KB pieces, and streams
    /// encrypted chunks over WebSocket (fire-and-forget, no ACK wait).
    private func sendFile(path: String, name: String, mime: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url) else {
                NSLog("[SecurityChannel] sendFile: failed to read file at \(path)")
                DispatchQueue.main.async { completion(false) }
                return
            }

            let maxSize: Int = 100 * 1024 * 1024
            guard data.count <= maxSize else {
                NSLog("[SecurityChannel] sendFile: file too large (\(data.count) bytes, max \(maxSize))")
                DispatchQueue.main.async { completion(false) }
                return
            }

            // Compute SHA-256 checksum
            let checksum = SecurityChannel.sha256Hex(data: data)
            let chunkSize = 128_000  // must match bridge CHUNK_SIZE
            let totalChunks = max(1, Int(ceil(Double(data.count) / Double(chunkSize))))
            let transferId = UUID().uuidString

            // Send FileTransferStart
            let startMsg: [String: Any] = [
                "type": "file_transfer_start",
                "transferId": transferId,
                "filename": name,
                "mimeType": mime,
                "totalSize": data.count,
                "totalChunks": totalChunks,
                "direction": "phone_to_computer",
                "checksum": checksum,
            ]
            self.sendEncrypted(startMsg)

            // Stream chunks (fire-and-forget, no ACK wait)
            for i in 0..<totalChunks {
                let start = i * chunkSize
                let end = min(start + chunkSize, data.count)
                let chunk = data[start..<end]
                let b64 = chunk.base64EncodedString()

                let chunkMsg: [String: Any] = [
                    "type": "file_chunk",
                    "transferId": transferId,
                    "sequence": i,
                    "data": b64,
                ]
                self.sendEncrypted(chunkMsg)
            }

            // Send FileTransferComplete
            let completeMsg: [String: Any] = [
                "type": "file_transfer_complete",
                "transferId": transferId,
                "success": true,
            ]
            self.sendEncrypted(completeMsg)

            DispatchQueue.main.async {
                completion(true)
            }
        }
    }

    /// Accept an incoming file transfer from the computer.
    /// Sends a file_transfer_ack message to signal readiness to receive.
    private func acceptFileTransfer(id transferId: String, result: @escaping FlutterResult) {
        guard authenticatedWebSocket() != nil else {
            result(FlutterError(code: "NOT_CONNECTED", message: "WebSocket is not connected", details: nil))
            return
        }
        let ackMsg: [String: Any] = [
            "type": "file_transfer_ack",
            "transferId": transferId,
            "receivedThrough": 0,
        ]
        sendEncrypted(ackMsg)
        result(true)
    }

    /// Cancel/decline a file transfer (either direction).
    /// Sends a file_transfer_cancel message to notify the peer.
    private func cancelFileTransfer(id transferId: String, result: @escaping FlutterResult) {
        guard authenticatedWebSocket() != nil else {
            result(FlutterError(code: "NOT_CONNECTED", message: "WebSocket is not connected", details: nil))
            return
        }
        let cancelMsg: [String: Any] = [
            "type": "file_transfer_cancel",
            "transferId": transferId,
            "reason": "User cancelled",
        ]
        sendEncrypted(cancelMsg)
        result(true)
    }

    /// Computes SHA-256 hex digest of data.
    private static func sha256Hex(data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - FCM Token Keychain Helpers

    private static let fcmKeychainService = "com.termopus.fcm-token"
    private static let fcmKeychainAccount = "pending"

    @discardableResult
    private func persistFcmToken(_ token: String) -> Bool {
        guard let tokenData = token.data(using: .utf8) else {
            NSLog("[SecurityChannel] Failed to encode FCM token as UTF-8")
            return false
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SecurityChannel.fcmKeychainService,
            kSecAttrAccount as String: SecurityChannel.fcmKeychainAccount,
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = tokenData
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("[SecurityChannel] Failed to persist FCM token to Keychain: \(status)")
            return false
        }
        return true
    }

    private func loadFcmToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SecurityChannel.fcmKeychainService,
            kSecAttrAccount as String: SecurityChannel.fcmKeychainAccount,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteFcmToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SecurityChannel.fcmKeychainService,
            kSecAttrAccount as String: SecurityChannel.fcmKeychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - FCM Handler

    /// Pending token key in UserDefaults (legacy, migrated to Keychain).
    private static let pendingFcmTokenKey = "com.clauderemote.fcm.pendingToken"

    private func handleFCMRegister(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let token = args?["token"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing 'token' string argument.",
                details: nil
            ))
            return
        }

        // Always persist so we can re-send on next connect
        persistFcmToken(token)

        // Send to ALL connected sessions so each relay knows this device's FCM token
        for (sid, ws) in allWebSockets() {
            if ws.state == .connected {
                sendFcmToken(token, via: ws)
                NSLog("[SecurityChannel] FCM token sent to session \(sid.prefix(12))")
            }
        }

        // Always return true — the token was accepted and persisted.
        // If no WebSocket is connected, it will be sent on next connect via sendPendingFcmToken.
        result(true)
    }

    /// Send an FCM token as a **plaintext** control message (not encrypted).
    ///
    /// The relay parses control messages as raw JSON — they must not be
    /// encrypted. Clears the persisted pending token on success.
    private func sendFcmToken(_ token: String, via ws: SecureWebSocket, completion: ((Bool) -> Void)? = nil) {
        let registration: [String: Any] = [
            "type": "fcm_register",
            "token": token,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: registration, options: []),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            completion?(false)
            return
        }

        ws.sendPlaintext(jsonString) { error in
            if error == nil {
                self.deleteFcmToken()
                completion?(true)
            } else {
                NSLog("[SecurityChannel] Failed to send FCM token: \(error!.localizedDescription)")
                completion?(false)
            }
        }
    }

    /// Send the deferred pairing payload for a session.
    /// Called when sessionAuthorized becomes true (either immediately from auth_result
    /// or later from session_authorized after bridge approval).
    private func sendDeferredPairingPayload(sessionId sid: String) {
        if let payload = self.pendingPairingPayloads.removeValue(forKey: sid) {
            if let ws = self.webSocket(for: sid) {
                ws.sendPlaintext(payload) { error in
                    if let error = error {
                        NSLog("[\(sid.prefix(12))] Failed to send deferred pairing message: \(error.localizedDescription)")
                    } else {
                        NSLog("[\(sid.prefix(12))] Sent deferred pairing message")
                    }
                }
            } else {
                NSLog("[\(sid.prefix(12))] Cannot send pairing - no WebSocket in pool")
            }
        } else {
            NSLog("[\(sid.prefix(12))] No pending pairing payload to send")
        }
    }

    /// Re-send any pending FCM token stored while the WebSocket was disconnected.
    private func sendPendingFcmToken(via ws: SecureWebSocket) {
        // One-time migration: move token from UserDefaults to Keychain
        if let legacyToken = UserDefaults.standard.string(forKey: SecurityChannel.pendingFcmTokenKey),
           !legacyToken.isEmpty {
            if persistFcmToken(legacyToken) {
                UserDefaults.standard.removeObject(forKey: SecurityChannel.pendingFcmTokenKey)
            }
        }

        guard let token = loadFcmToken(),
              !token.isEmpty else {
            return
        }
        NSLog("[SecurityChannel] Sending pending FCM token")
        sendFcmToken(token, via: ws)
    }

    // MARK: - Security Handlers

    private func handleSecurityGetEndpoint(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let key = args?["key"] as? String else {
            result(FlutterError(code: "MISSING_KEY", message: "key required", details: nil))
            return
        }
        let endpoint = NativeSecretsWrapper.getEndpoint(key)
        if endpoint.isEmpty {
            result(FlutterError(code: "UNKNOWN_KEY", message: "No endpoint for key: \(key)", details: nil))
        } else {
            result(endpoint)
        }
    }

    private func handleSecurityEnforceResult(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let signedResult = args?["signedResult"] as? String, !signedResult.isEmpty else {
            result(FlutterError(code: "INVALID_ARGS", message: "signedResult is required", details: nil))
            return
        }
        // Crashes the app via __builtin_trap() if the signed result is invalid
        NativeSecretsWrapper.enforceSecurityResult(signedResult)
        result(true)
    }

    // MARK: - Biometric Crypto Handlers

    private func handleBiometricSignChallenge(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let challenge = args?["challenge"] as? String, !challenge.isEmpty else {
            result(FlutterError(code: "INVALID_ARGS", message: "challenge (Base64) is required", details: nil))
            return
        }
        let reason = args?["reason"] as? String ?? "Sign security challenge"

        BiometricCryptoService.shared.signChallenge(challenge, reason: reason) { signResult in
            DispatchQueue.main.async {
                switch signResult {
                case .success(let signature):
                    result(["signature": signature])
                case .failure(let error):
                    result(FlutterError(code: "SIGN_FAILED", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func handleBiometricGetPublicKey(result: @escaping FlutterResult) {
        do {
            let publicKey = try BiometricCryptoService.shared.getPublicKey()
            result(["publicKey": publicKey.base64EncodedString()])
        } catch {
            result(FlutterError(code: "KEY_NOT_FOUND", message: error.localizedDescription, details: nil))
        }
    }

    // MARK: - Hardware Encryption Handlers

    private func handleHardwareEncrypt(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let dataB64 = args?["data"] as? String,
              let plaintext = Data(base64Encoded: dataB64) else {
            result(FlutterError(code: "INVALID_ARGS", message: "data (Base64) is required", details: nil))
            return
        }

        do {
            let encrypted = try HardwareKeyService.shared.encrypt(plaintext)
            result(["data": encrypted.base64EncodedString()])
        } catch {
            result(FlutterError(code: "ENCRYPT_FAILED", message: error.localizedDescription, details: nil))
        }
    }

    private func handleHardwareDecrypt(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let dataB64 = args?["data"] as? String,
              let ciphertext = Data(base64Encoded: dataB64) else {
            result(FlutterError(code: "INVALID_ARGS", message: "data (Base64) is required", details: nil))
            return
        }

        do {
            let decrypted = try HardwareKeyService.shared.decrypt(ciphertext)
            result(["data": decrypted.base64EncodedString()])
        } catch {
            result(FlutterError(code: "DECRYPT_FAILED", message: error.localizedDescription, details: nil))
        }
    }
}

// MARK: - FlutterStreamHandler

extension SecurityChannel: FlutterStreamHandler {

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
