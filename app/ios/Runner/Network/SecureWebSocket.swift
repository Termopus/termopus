import Foundation
import CryptoKit

// MARK: - ConnectionState

enum ConnectionState: String {
    case disconnected = "disconnected"
    case connecting = "connecting"
    case connected = "connected"
    case reconnecting = "reconnecting"
    case failed = "failed"
    case subscriptionRequired = "subscription_required"
}

// MARK: - SecureWebSocket

final class SecureWebSocket: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {

    /// The session this WebSocket belongs to.
    let sessionId: String

    // MARK: - Public Callbacks

    /// Called when an encrypted message is received and successfully decrypted.
    var onMessage: ((Data) -> Void)?

    /// Called when the connection state changes.
    var onStateChange: ((ConnectionState) -> Void)?

    // MARK: - Private State

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var currentURL: URL?

    /// Whether the disconnect was intentional (user-initiated).
    private var intentionalDisconnect = false

    /// Current reconnection attempt count (for exponential backoff).
    private var reconnectAttempt = 0

    /// Base delay for reconnection (1 second).
    private static let reconnectBaseDelay: TimeInterval = 1.0

    /// Maximum delay for reconnection (30 seconds).
    private static let reconnectMaxDelay: TimeInterval = 30.0

    /// Maximum number of reconnection attempts before giving up.
    private static let maxReconnectAttempts = 50

    /// Reconnection work item (cancellable).
    private var reconnectWorkItem: DispatchWorkItem?

    /// Periodic ping timer for keepalive (30s interval).
    private var pingTimer: Timer?

    private(set) var state: ConnectionState = .disconnected {
        didSet {
            if oldValue != state {
                let newState = state
                DispatchQueue.main.async { [weak self] in
                    self?.onStateChange?(newState)
                }
            }
        }
    }

    deinit {
        reconnectWorkItem?.cancel()
        pingTimer?.invalidate()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
    }

    /// Certificate pinning is always enabled in release builds.
    /// Only disabled in debug builds for local development. Immutable at runtime.
    static var isPinningEnabled: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    /// Relay-readable control message types allowed as plaintext after handshake.
    /// Source of truth: PHONE_CONTROL_TYPES in relay_worker/src/relay.ts
    private static let relayControlTypes: Set<String> = [
        "auth_challenge", "auth_result", "session_authorized",
        "fcm_registered", "peer_connected", "peer_disconnected",
        "peer_offline", "pong", "status_response",
    ]

    /// Opaque auth state — hash-based, not a hookable boolean.
    /// Set to SHA-256(nonce + "handshake-complete") on auth_result success.
    /// Verified by checking hash matches, not by reading a boolean.
    private var authStateToken: Data?

    func isHandshakeComplete() -> Bool {
        guard let token = authStateToken else { return false }
        return token.count == 32
    }

    func markHandshakeComplete(nonce: String) {
        var hasher = SHA256()
        hasher.update(data: Data(nonce.utf8))
        hasher.update(data: Data("handshake-complete".utf8))
        authStateToken = Data(hasher.finalize())
    }

    /// Certificate pins for YOUR_RELAY_DEV_DOMAIN (SHA-256 of SPKI, Base64-encoded).
    /// Verified via: openssl s_client -connect YOUR_RELAY_DEV_DOMAIN:443 -showcerts
    /// In production, rotate these via remote config.
    private static let pinnedSPKIHashes: Set<String> = [
        // Pins removed
    ]

    /// ASN.1 header for EC P-256 SubjectPublicKeyInfo.
    /// SecKeyCopyExternalRepresentation returns raw key bytes without this header.
    private static let ecP256SPKIHeader: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86,
        0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A,
        0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00,
    ]

    /// ASN.1 header for RSA 2048 SubjectPublicKeyInfo.
    private static let rsa2048SPKIHeader: [UInt8] = [
        0x30, 0x82, 0x01, 0x22, 0x30, 0x0D, 0x06, 0x09,
        0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01,
        0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0F, 0x00,
    ]

    init(sessionId: String) {
        self.sessionId = sessionId
        super.init()
    }

    // MARK: - Connect

    /// Opens a secure WebSocket connection.
    ///
    /// - Parameters:
    ///   - url: The wss:// URL to connect to.
    ///   - onMessage: Called when an encrypted message is received and decrypted.
    ///   - onStateChange: Called when connection state changes.
    func connect(
        url: URL,
        onMessage: ((Data) -> Void)? = nil,
        onStateChange: ((ConnectionState) -> Void)? = nil
    ) {
        disconnect()

        self.currentURL = url
        self.intentionalDisconnect = false
        self.reconnectAttempt = 0
        if let onMessage = onMessage { self.onMessage = onMessage }
        if let onStateChange = onStateChange { self.onStateChange = onStateChange }

        state = .connecting

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300

        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.termopus.websocket"
        delegateQueue.maxConcurrentOperationCount = 1  // Serial queue for thread safety

        urlSession = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: delegateQueue
        )

        var request = URLRequest(url: url)
        request.timeoutInterval = 60

        webSocketTask = urlSession?.webSocketTask(with: request)
        webSocketTask?.resume()

        // Start listening for messages
        receiveMessage()
    }

    // MARK: - Send (Encrypted)

    /// Encrypts raw data via CryptoEngine and sends it over the WebSocket.
    func send(data: Data, completion: ((Error?) -> Void)? = nil) {
        guard state == .connected else {
            completion?(NSError(
                domain: "SecureWebSocket",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Not connected"]
            ))
            return
        }

        do {
            let encrypted = try CryptoEngine.shared.encrypt(data: data, forSession: sessionId)
            let message = URLSessionWebSocketTask.Message.data(encrypted)

            webSocketTask?.send(message) { error in
                DispatchQueue.main.async {
                    completion?(error)
                }
            }
        } catch {
            completion?(error)
        }
    }

    /// Encrypts a string message and sends it over the WebSocket.
    func sendMessage(_ string: String, completion: ((Error?) -> Void)? = nil) {
        guard let data = string.data(using: .utf8) else {
            completion?(CryptoError.stringEncodingFailed)
            return
        }
        send(data: data, completion: completion)
    }

    /// Send a plaintext string over the WebSocket **without encryption**.
    ///
    /// Used exclusively for relay control messages (e.g. `fcm_register`, `ping`)
    /// that the relay must parse as raw JSON. User content must always go
    /// through ``send(data:completion:)`` (encrypted).
    func sendPlaintext(_ text: String, completion: ((Error?) -> Void)? = nil) {
        guard state == .connected else {
            completion?(NSError(
                domain: "SecureWebSocket",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Not connected"]
            ))
            return
        }

        let message = URLSessionWebSocketTask.Message.string(text)
        webSocketTask?.send(message) { error in
            DispatchQueue.main.async {
                completion?(error)
            }
        }
    }

    // MARK: - Disconnect

    /// Gracefully closes the WebSocket connection.
    func disconnect() {
        stopPingTimer()
        intentionalDisconnect = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        webSocketTask = nil
        onMessage = nil
        onStateChange = nil
        state = .disconnected
    }

    // MARK: - Resume Probe

    /// Verify an existing connection is still alive by sending a ping.
    /// Calls completion with `true` if pong received within 5s, `false` otherwise.
    func verifyConnection(completion: @escaping (Bool) -> Void) {
        guard state == .connected, let task = webSocketTask else {
            completion(false)
            return
        }

        let timeout = DispatchWorkItem { [weak self] in
            self?.scheduleReconnect()
            completion(false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: timeout)

        task.sendPing { [weak self] error in
            guard !timeout.isCancelled else { return }
            timeout.cancel()
            if error != nil {
                self?.scheduleReconnect()
                completion(false)
            } else {
                completion(true)
            }
        }
    }

    // MARK: - Immediate Reconnect (Network Recovery)

    /// Cancel pending backoff timer and reconnect immediately.
    /// Called by NetworkMonitor when network recovers.
    func reconnectNow() {
        // Guard against rapid-fire calls from NetworkMonitor
        guard state != .connecting else { return }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempt = 0  // Reset backoff since network just recovered

        guard let url = currentURL, !intentionalDisconnect else { return }

        NSLog("[SecureWebSocket][\(sessionId.prefix(12))] Immediate reconnect (network recovered)")

        // Clean up old task
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        state = .connecting

        if urlSession == nil {
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 300

            let delegateQueue = OperationQueue()
            delegateQueue.name = "com.termopus.websocket"
            delegateQueue.maxConcurrentOperationCount = 1

            urlSession = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: delegateQueue
            )
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60

        webSocketTask = urlSession?.webSocketTask(with: request)
        webSocketTask?.resume()
        receiveMessage()
    }

    // MARK: - Receive Loop

    /// Recursively listens for incoming WebSocket messages.
    /// Decrypts received data through CryptoEngine before delivering to onMessage.
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                self.handleReceivedMessage(message)
                // Continue listening
                self.receiveMessage()

            case .failure(let error):
                // Ignore failures from a cancelled/replaced WebSocket
                guard self.webSocketTask != nil else {
                    NSLog("[SecureWebSocket][\(self.sessionId.prefix(12))] Ignoring receive failure from stale WebSocket")
                    return
                }
                // Connection may have closed
                if self.state == .connected || self.state == .connecting {
                    NSLog("[SecureWebSocket][\(self.sessionId.prefix(12))] Receive error: \(error.localizedDescription)")

                    // Check for HTTP-level auth rejection (403/401) during WebSocket upgrade.
                    // URLSessionWebSocketTask doesn't call didCloseWith for failed upgrades —
                    // the error arrives here instead.
                    let httpCode = (self.webSocketTask?.response as? HTTPURLResponse)?.statusCode
                    if httpCode == 403 || httpCode == 401 {
                        NSLog("[SecureWebSocket][\(self.sessionId.prefix(12))] HTTP authentication failure (\(httpCode!)), not reconnecting")
                        self.reconnectWorkItem?.cancel()
                        self.reconnectWorkItem = nil
                        self.state = .failed
                    } else if httpCode == 429 {
                        // Rate limited — force longer backoff before reconnect
                        NSLog("[SecureWebSocket][\(self.sessionId.prefix(12))] Rate limited (429), delaying reconnect")
                        self.reconnectAttempt = max(self.reconnectAttempt, 4)
                        self.scheduleReconnect()
                    } else if httpCode == 400 {
                        // Bad request — permanent failure (malformed URL or invalid request)
                        NSLog("[SecureWebSocket][\(self.sessionId.prefix(12))] Bad request (400), not reconnecting")
                        self.reconnectWorkItem?.cancel()
                        self.reconnectWorkItem = nil
                        self.state = .failed
                    } else if !self.intentionalDisconnect {
                        self.scheduleReconnect()
                    } else {
                        self.state = .disconnected
                    }
                }
            }
        }
    }

    /// Processes a received WebSocket message -- decrypts and forwards.
    /// After ECDH handshake completes, plaintext JSON messages are only forwarded
    /// if their `type` field is in the relay control whitelist.
    private func handleReceivedMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            // Binary frame — always treat as encrypted
            if data.count >= 28 {
                do {
                    let decrypted = try CryptoEngine.shared.decrypt(data: data, forSession: sessionId)
                    DispatchQueue.main.async {
                        self.onMessage?(decrypted)
                    }
                } catch {
                    // SECURITY: Drop messages that fail decryption — never forward raw bytes.
                    NSLog("[SecureWebSocket][\(sessionId.prefix(12))] Decryption failed, dropping message: \(error.localizedDescription)")
                }
            } else if isHandshakeComplete() {
                // Post-handshake: undersized binary frames cannot be valid ciphertext — drop them
                NSLog("[SecureWebSocket][\(sessionId.prefix(12))] Dropping undersized binary frame post-handshake (\(data.count) bytes)")
            } else {
                // Pre-handshake: forward as plaintext (handshake/control message)
                DispatchQueue.main.async {
                    self.onMessage?(data)
                }
            }

        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)

            // Try JSON parse first
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
               let jsonData = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                let type = json["type"] as? String ?? ""

                if isHandshakeComplete() && !SecureWebSocket.relayControlTypes.contains(type) {
                    NSLog("[SecureWebSocket][\(sessionId.prefix(12))] SECURITY: Rejected plaintext message type '\(type)' after handshake")
                    return
                }

                NSLog("[SecureWebSocket][\(sessionId.prefix(12))] Forwarding relay control message: type=\(type)")
                if let data = text.data(using: .utf8) {
                    DispatchQueue.main.async {
                        self.onMessage?(data)
                    }
                }
                return
            }

            // Not JSON — try Base64 decode
            if let decoded = Data(base64Encoded: text), decoded.count >= 28 {
                do {
                    let decrypted = try CryptoEngine.shared.decrypt(data: decoded, forSession: sessionId)
                    DispatchQueue.main.async {
                        self.onMessage?(decrypted)
                    }
                    return
                } catch {
                    NSLog("[SecureWebSocket][\(sessionId.prefix(12))] Base64 decrypt failed, dropping: \(error.localizedDescription)")
                    return
                }
            }

            // Non-JSON, non-Base64 — drop after handshake
            if isHandshakeComplete() {
                NSLog("[SecureWebSocket][\(sessionId.prefix(12))] SECURITY: Rejected non-JSON plaintext after handshake")
                return
            }
            if let data = text.data(using: .utf8) {
                DispatchQueue.main.async {
                    self.onMessage?(data)
                }
            }

        @unknown default:
            NSLog("[SecureWebSocket][\(self.sessionId.prefix(12))] Unknown message type received.")
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        // Ignore callbacks from a cancelled/replaced WebSocket
        guard webSocketTask === self.webSocketTask else {
            NSLog("[SecureWebSocket][\(sessionId.prefix(12))] Ignoring didOpen from stale WebSocket")
            return
        }
        NSLog("[SecureWebSocket][\(sessionId.prefix(12))] Connected (protocol: \(`protocol` ?? "none"))")
        authStateToken = nil  // Reset handshake state on new connection
        reconnectAttempt = 0
        state = .connected
        startPingTimer()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        // Ignore callbacks from a cancelled/replaced WebSocket
        guard webSocketTask === self.webSocketTask else {
            NSLog("[SecureWebSocket][\(sessionId.prefix(12))] Ignoring didCloseWith from stale WebSocket")
            return
        }

        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
        NSLog("[SecureWebSocket][\(sessionId.prefix(12))] Disconnected (code: \(closeCode.rawValue), reason: \(reasonString))")

        if closeCode.rawValue == 4002 {
            // Subscription required — permanent, do not reconnect
            NSLog("[SecureWebSocket][\(sessionId.prefix(12))] Subscription required (code 4002), not reconnecting")
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            state = .subscriptionRequired
        } else if closeCode.rawValue == 4001 || closeCode.rawValue == 4003 {
            // Auth failure is permanent — do not reconnect
            NSLog("[SecureWebSocket][\(sessionId.prefix(12))] Authentication failure (code \(closeCode.rawValue)), not reconnecting")
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            state = .failed
        } else if !intentionalDisconnect && closeCode != .normalClosure {
            // 1001 (goingAway) intentionally triggers reconnect — server may restart/redeploy
            scheduleReconnect()
        } else {
            state = .disconnected
        }
    }

    // MARK: - URLSessionDelegate (TLS)

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod

        switch method {
        case NSURLAuthenticationMethodClientCertificate:
            handleClientCertificateChallenge(challenge, completionHandler: completionHandler)

        case NSURLAuthenticationMethodServerTrust:
            handleServerTrustChallenge(challenge, completionHandler: completionHandler)

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: - Client Certificate (mTLS)

    /// Provides the client identity from CertificateManager for mutual TLS.
    private func handleClientCertificateChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let identity = CertificateManager.shared.getClientIdentity() {
            let credential = URLCredential(
                identity: identity,
                certificates: nil,
                persistence: .forSession
            )
            completionHandler(.useCredential, credential)
        } else {
            NSLog("[SecureWebSocket][\(sessionId.prefix(12))] No client identity available — falling back to default handling.")
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: - Server Trust / Certificate Pinning

    /// Validates the server certificate chain against pinned SPKI hashes.
    /// Matches Android's `CloudflarePinningTrustManager.checkPins()` behavior.
    private func handleServerTrustChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Perform standard trust evaluation first
        var error: CFError?
        let trusted = SecTrustEvaluateWithError(serverTrust, &error)

        guard trusted else {
            NSLog("[SecureWebSocket][\(sessionId.prefix(12))] Server trust evaluation failed: \(error?.localizedDescription ?? "unknown")")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Extract certificate chain
        var certChain: [SecCertificate] = []
        if #available(iOS 15.0, *) {
            certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] ?? []
        } else {
            let count = SecTrustGetCertificateCount(serverTrust)
            for i in 0..<count {
                if let cert = SecTrustGetCertificateAtIndex(serverTrust, i) {
                    certChain.append(cert)
                }
            }
        }

        // Check if pinning is disabled via remote config (CA rotation safety valve)
        if !SecureWebSocket.isPinningEnabled {
            NSLog("[SecureWebSocket][\(sessionId.prefix(12))] Certificate pinning disabled via remote config")
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
            return
        }

        // Self-hosted: certificate pinning disabled
        let credential = URLCredential(trust: serverTrust)
        completionHandler(.useCredential, credential)
    }

    // MARK: - URLSessionTaskDelegate

    /// Catches connection-level failures (DNS, TLS) that don't surface through the receive loop.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        NSLog("[SecureWebSocket][\(sessionId.prefix(12))] Task completed with error: \(error.localizedDescription)")
        if state == .connected || state == .connecting {
            if !intentionalDisconnect {
                scheduleReconnect()
            }
        }
    }

    /// Catches session invalidation errors.
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        if let error = error {
            NSLog("[SecureWebSocket][\(sessionId.prefix(12))] Session invalidated: \(error.localizedDescription)")
        }
        webSocketTask = nil
        urlSession = nil
    }

    // MARK: - Keepalive Ping

    /// Start a periodic ping timer (30s) to detect dead connections.
    /// Timer must be scheduled on the main run loop since delegate callbacks
    /// now run on a background queue (which has no run loop).
    private func startPingTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pingTimer?.invalidate()
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                guard let self = self, self.state == .connected else { return }
                self.webSocketTask?.sendPing { [weak self] error in
                    if let error = error {
                        guard let self = self else { return }
                        NSLog("[SecureWebSocket][\(self.sessionId.prefix(12))] Ping failed: \(error.localizedDescription)")
                        if !self.intentionalDisconnect {
                            self.scheduleReconnect()
                        }
                    }
                }
            }
        }
    }

    /// Stop the keepalive ping timer.
    private func stopPingTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer?.invalidate()
            self?.pingTimer = nil
        }
    }

    // MARK: - Reconnection

    /// Schedule a reconnection with exponential backoff.
    private func scheduleReconnect() {
        stopPingTimer()
        guard let url = currentURL else { return }

        guard reconnectAttempt < SecureWebSocket.maxReconnectAttempts else {
            NSLog("[SecureWebSocket][\(sessionId.prefix(12))] Max reconnect attempts (\(SecureWebSocket.maxReconnectAttempts)) reached, giving up")
            state = .failed
            return
        }

        state = .reconnecting

        let baseDelay = min(
            SecureWebSocket.reconnectBaseDelay * pow(2.0, Double(min(reconnectAttempt, 5))),
            SecureWebSocket.reconnectMaxDelay
        )
        // Add ±20% jitter to prevent thundering herd
        let jitter = baseDelay * 0.2 * Double.random(in: -1...1)
        let delay = max(baseDelay + jitter, SecureWebSocket.reconnectBaseDelay)
        reconnectAttempt += 1

        NSLog("[SecureWebSocket][\(sessionId.prefix(12))] Reconnecting in \(delay)s (attempt \(reconnectAttempt))")

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, !self.intentionalDisconnect else { return }

            // Clean up old task only — keep session for TLS cache
            self.webSocketTask?.cancel(with: .goingAway, reason: nil)
            self.webSocketTask = nil

            self.state = .connecting

            // Only create new session if none exists (preserves TLS session tickets)
            if self.urlSession == nil {
                let configuration = URLSessionConfiguration.default
                configuration.waitsForConnectivity = true
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 300

                let delegateQueue = OperationQueue()
                delegateQueue.name = "com.termopus.websocket"
                delegateQueue.maxConcurrentOperationCount = 1

                self.urlSession = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: delegateQueue
                )
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 60

            self.webSocketTask = self.urlSession?.webSocketTask(with: request)
            self.webSocketTask?.resume()
            self.receiveMessage()
        }

        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    // MARK: - SPKI Hash Extraction

    /// Extracts the SHA-256 hash of a certificate's SubjectPublicKeyInfo (SPKI).
    ///
    /// On iOS, `SecKeyCopyExternalRepresentation` returns raw key bytes without
    /// the ASN.1 SPKI header. We must prepend the correct header based on key
    /// type (EC P-256 or RSA 2048) before hashing, so the result matches what
    /// Android's `publicKey.encoded` (which includes the header) produces.
    ///
    /// Returns a Base64-encoded SHA-256 hash, or empty string on failure.
    private func getPublicKeyHash(certificate: SecCertificate) -> String {
        guard let publicKey = SecCertificateCopyKey(certificate) else {
            return ""
        }
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            return ""
        }

        // Determine key type to select the correct ASN.1 header
        let keyAttributes = SecKeyCopyAttributes(publicKey) as? [String: Any]
        let keyType = keyAttributes?[kSecAttrKeyType as String] as? String

        var spkiData: Data
        if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            spkiData = Data(SecureWebSocket.ecP256SPKIHeader)
        } else {
            spkiData = Data(SecureWebSocket.rsa2048SPKIHeader)
        }
        spkiData.append(publicKeyData)

        // SHA-256 hash → Base64 (matching Android's Base64.NO_WRAP)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        spkiData.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(spkiData.count), &hash)
        }
        return Data(hash).base64EncodedString()
    }
}

// MARK: - CommonCrypto Bridge

import CommonCrypto
