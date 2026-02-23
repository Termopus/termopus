import Foundation
import CryptoKit

// MARK: - CryptoError

enum CryptoError: Error, LocalizedError {
    case keyNotSet
    case encryptionFailed(Error)
    case decryptionFailed(Error)
    case invalidCiphertext
    case invalidNonceLength
    case stringEncodingFailed
    case invalidKeyLength

    var errorDescription: String? {
        switch self {
        case .keyNotSet:
            return "Symmetric key has not been set. Call setSharedSecret() first."
        case .encryptionFailed(let error):
            return "Encryption failed: \(error.localizedDescription)"
        case .decryptionFailed(let error):
            return "Decryption failed: \(error.localizedDescription)"
        case .invalidCiphertext:
            return "Ciphertext data is malformed or too short."
        case .invalidNonceLength:
            return "Nonce must be exactly 12 bytes."
        case .stringEncodingFailed:
            return "Failed to encode/decode string as UTF-8."
        case .invalidKeyLength:
            return "AES-256 key must be exactly 32 bytes."
        }
    }
}

// MARK: - CryptoEngine

/// Session-keyed AES-256-GCM encryption engine.
///
/// Each session gets its own symmetric key stored in a dictionary.
/// Encrypt/decrypt always use the **active** session's key.
/// Keys survive session switches — they're only removed on explicit
/// `clearKey(forSession:)` or `clearAllKeys()`.
final class CryptoEngine {

    static let shared = CryptoEngine()

    /// AES-GCM nonce size (12 bytes)
    private static let nonceSize = 12
    /// AES-GCM tag size (16 bytes)
    private static let tagSize = 16

    /// Per-session symmetric keys derived from ECDH + HKDF.
    private var sessionKeys: [String: SymmetricKey] = [:]

    /// The currently active session whose key is used for encrypt/decrypt.
    private(set) var activeSessionId: String?

    /// Thread-safety lock for key access.
    private let lock = NSLock()

    private init() {}

    // MARK: - Key Management

    /// Store a shared secret for a specific session and make it active.
    func setSharedSecret(_ keyData: Data, forSession sessionId: String) throws {
        guard keyData.count == 32 else {
            throw CryptoError.invalidKeyLength
        }
        lock.lock()
        defer { lock.unlock() }
        sessionKeys[sessionId] = SymmetricKey(data: keyData)
        activeSessionId = sessionId
    }

    /// Switch the active session (key must already be stored).
    @discardableResult
    func setActiveSession(_ sessionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard sessionKeys[sessionId] != nil else { return false }
        activeSessionId = sessionId
        return true
    }

    /// Remove the key for a specific session.
    func clearKey(forSession sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        sessionKeys.removeValue(forKey: sessionId)
        if activeSessionId == sessionId {
            activeSessionId = nil
        }
    }

    /// Remove ALL session keys.
    func clearAllKeys() {
        lock.lock()
        defer { lock.unlock() }
        sessionKeys.removeAll()
        activeSessionId = nil
    }

    /// Returns true if the active session has a key set.
    var hasKey: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let sid = activeSessionId else { return false }
        return sessionKeys[sid] != nil
    }

    /// Returns true if a specific session has a key stored.
    func hasKey(forSession sessionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessionKeys[sessionId] != nil
    }

    // MARK: - Backward-compat shims (remove after SecurityChannel updated)

    /// Legacy: sets key for the current active session (or "_default").
    func setSharedSecret(_ keyData: Data) throws {
        let sid = activeSessionId ?? "_default"
        try setSharedSecret(keyData, forSession: sid)
    }

    /// Legacy: clears the active session's key (or all if none active).
    func clearKey() {
        if let sid = activeSessionId {
            clearKey(forSession: sid)
        } else {
            clearAllKeys()
        }
    }

    // MARK: - Raw Encrypt / Decrypt

    /// Encrypts plaintext data using AES-256-GCM.
    ///
    /// Output format: `nonce (12 bytes) || ciphertext || tag (16 bytes)`
    ///
    /// - Parameter data: The plaintext data to encrypt.
    /// - Returns: Combined nonce + ciphertext + tag.
    func encrypt(data: Data) throws -> Data {
        let key = try requireKey()

        do {
            let nonce = AES.GCM.Nonce()
            let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)

            // Build combined representation: nonce || ciphertext || tag
            var combined = Data()
            combined.append(contentsOf: nonce)
            combined.append(sealedBox.ciphertext)
            combined.append(sealedBox.tag)

            return combined
        } catch {
            throw CryptoError.encryptionFailed(error)
        }
    }

    /// Decrypts data produced by `encrypt(data:)`.
    ///
    /// Expected input format: `nonce (12 bytes) || ciphertext || tag (16 bytes)`
    ///
    /// - Parameter data: The combined nonce + ciphertext + tag.
    /// - Returns: The original plaintext data.
    func decrypt(data: Data) throws -> Data {
        let key = try requireKey()

        // Minimum: nonce (12) + tag (16) = 28 bytes. Empty plaintext is valid.
        let minimumLength = CryptoEngine.nonceSize + CryptoEngine.tagSize
        guard data.count >= minimumLength else {
            throw CryptoError.invalidCiphertext
        }

        // Parse components
        let nonceData = data.prefix(CryptoEngine.nonceSize)
        let tagStart = data.count - CryptoEngine.tagSize
        let ciphertextData = data[CryptoEngine.nonceSize..<tagStart]
        let tagData = data[tagStart...]

        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: ciphertextData,
                tag: tagData
            )
            let plaintext = try AES.GCM.open(sealedBox, using: key)
            return plaintext
        } catch let error as CryptoError {
            throw error
        } catch {
            throw CryptoError.decryptionFailed(error)
        }
    }

    // MARK: - Session-Explicit Encrypt / Decrypt

    /// Encrypts plaintext using the key for a specific session (NOT the active session).
    ///
    /// Thread-safe: resolves the key under lock. This avoids race conditions
    /// when multiple WebSockets encrypt/decrypt concurrently.
    func encrypt(data: Data, forSession sessionId: String) throws -> Data {
        lock.lock()
        guard let key = sessionKeys[sessionId] else {
            lock.unlock()
            throw CryptoError.keyNotSet
        }
        lock.unlock()

        do {
            let nonce = AES.GCM.Nonce()
            let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)

            var combined = Data()
            combined.append(contentsOf: nonce)
            combined.append(sealedBox.ciphertext)
            combined.append(sealedBox.tag)
            return combined
        } catch {
            throw CryptoError.encryptionFailed(error)
        }
    }

    /// Decrypts data using the key for a specific session (NOT the active session).
    ///
    /// Thread-safe: resolves the key under lock.
    func decrypt(data: Data, forSession sessionId: String) throws -> Data {
        lock.lock()
        guard let key = sessionKeys[sessionId] else {
            lock.unlock()
            throw CryptoError.keyNotSet
        }
        lock.unlock()

        let minimumLength = CryptoEngine.nonceSize + CryptoEngine.tagSize
        guard data.count >= minimumLength else {
            throw CryptoError.invalidCiphertext
        }

        let nonceData = data.prefix(CryptoEngine.nonceSize)
        let tagStart = data.count - CryptoEngine.tagSize
        let ciphertextData = data[CryptoEngine.nonceSize..<tagStart]
        let tagData = data[tagStart...]

        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: ciphertextData,
                tag: tagData
            )
            return try AES.GCM.open(sealedBox, using: key)
        } catch let error as CryptoError {
            throw error
        } catch {
            throw CryptoError.decryptionFailed(error)
        }
    }

    // MARK: - String Helpers

    /// Encrypts a UTF-8 string and returns the sealed ciphertext as Base64.
    func encryptMessage(_ message: String) throws -> String {
        guard let plaintext = message.data(using: .utf8) else {
            throw CryptoError.stringEncodingFailed
        }
        let encrypted = try encrypt(data: plaintext)
        return encrypted.base64EncodedString()
    }

    /// Decrypts a Base64-encoded ciphertext back to a UTF-8 string.
    func decryptMessage(_ base64Ciphertext: String) throws -> String {
        guard let data = Data(base64Encoded: base64Ciphertext) else {
            throw CryptoError.invalidCiphertext
        }
        let plaintext = try decrypt(data: data)
        guard let message = String(data: plaintext, encoding: .utf8) else {
            throw CryptoError.stringEncodingFailed
        }
        return message
    }

    // MARK: - Private

    private func requireKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        guard let sid = activeSessionId, let key = sessionKeys[sid] else {
            throw CryptoError.keyNotSet
        }
        return key
    }
}
