import Foundation
import Security
import CryptoKit
import LocalAuthentication

// MARK: - KeyError

enum KeyError: Error, LocalizedError {
    case secureEnclaveNotAvailable
    case keyGenerationFailed(OSStatus)
    case keyNotFound
    case keyDeletionFailed(OSStatus)
    case publicKeyExportFailed
    case signingFailed(Error)
    case keyExchangeFailed(Error)
    case hkdfDerivationFailed
    case invalidPeerPublicKey
    case biometricAccessControlFailed(Error)

    var errorDescription: String? {
        switch self {
        case .secureEnclaveNotAvailable:
            return "Secure Enclave is not available on this device."
        case .keyGenerationFailed(let status):
            return "Key generation failed with status: \(status)"
        case .keyNotFound:
            return "Key not found in Keychain."
        case .keyDeletionFailed(let status):
            return "Key deletion failed with status: \(status)"
        case .publicKeyExportFailed:
            return "Failed to export public key."
        case .signingFailed(let error):
            return "Signing failed: \(error.localizedDescription)"
        case .keyExchangeFailed(let error):
            return "Key exchange failed: \(error.localizedDescription)"
        case .hkdfDerivationFailed:
            return "HKDF derivation failed."
        case .invalidPeerPublicKey:
            return "Invalid peer public key data."
        case .biometricAccessControlFailed(let error):
            return "Biometric access control setup failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - SecureKeyManager

final class SecureKeyManager {

    static let shared = SecureKeyManager()

    private let keyTag = "com.clauderemote.secure-enclave.p256"
    private let keychainService = "com.clauderemote.keychain"
    private let hkdfSalt = "claude-remote-v1"

    /// Cached SecKey references to avoid Keychain IPC (securityd) on every encrypt/decrypt.
    /// Cleared on key generation/deletion so stale references are never used.
    private var cachedPrivateKey: SecKey?
    private var cachedPublicKey: SecKey?

    private init() {}

    // MARK: - Key Generation

    /// Generates a P-256 key pair inside the Secure Enclave with biometric access control.
    /// Requires biometryCurrentSet -- invalidates if biometric enrollment changes.
    @discardableResult
    func generateKeyPair() throws -> SecKey {
        // Ensure Secure Enclave is available
        guard SecureEnclave.isAvailable else {
            throw KeyError.secureEnclaveNotAvailable
        }

        // Clear cached references — the old key is about to be deleted
        cachedPrivateKey = nil
        cachedPublicKey = nil

        // Delete any existing key pair first
        try? deleteKeyPair()

        // Create access control requiring biometry for private key usage
        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            &accessControlError
        ) else {
            let error = accessControlError?.takeRetainedValue() as Error? ?? KeyError.secureEnclaveNotAvailable
            throw KeyError.biometricAccessControlFailed(error)
        }

        // Private key attributes
        let privateKeyAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecAttrAccessControl as String: accessControl,
        ]

        // Key generation parameters
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: privateKeyAttributes,
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &error) else {
            let cfError = error?.takeRetainedValue()
            let status = cfError.map { CFErrorGetCode($0) } ?? -1
            throw KeyError.keyGenerationFailed(OSStatus(status))
        }

        return privateKey
    }

    // MARK: - Private Key Retrieval

    /// Retrieves the private key from the Keychain / Secure Enclave.
    /// Uses a cached reference when available to avoid Keychain IPC on every call.
    /// Biometric authentication will be triggered by the system on first access.
    func getPrivateKey(context: LAContext? = nil) throws -> SecKey {
        // Return cached key if available and no custom LAContext is provided
        if context == nil, let cached = cachedPrivateKey {
            return cached
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
        ]

        if let context = context {
            query[kSecUseAuthenticationContext as String] = context
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess, let key = item else {
            throw KeyError.keyNotFound
        }

        // Force-cast is safe here because kSecReturnRef guarantees a SecKey
        let privateKey = key as! SecKey

        // Cache for subsequent calls (only when no custom context)
        if context == nil {
            cachedPrivateKey = privateKey
        }

        return privateKey
    }

    // MARK: - Public Key Export

    /// Exports the public key in X9.63 uncompressed external representation (0x04 || x || y).
    /// Caches the public key SecKey reference to avoid repeated Keychain lookups.
    func getPublicKey() throws -> Data {
        let publicKey: SecKey
        if let cached = cachedPublicKey {
            publicKey = cached
        } else {
            let privateKey = try getPrivateKey()
            guard let pk = SecKeyCopyPublicKey(privateKey) else {
                throw KeyError.publicKeyExportFailed
            }
            cachedPublicKey = pk
            publicKey = pk
        }

        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw KeyError.publicKeyExportFailed
        }

        return publicKeyData
    }

    // MARK: - Device ID (SHA-256 of SPKI)

    /// Derives a stable device identifier from SHA-256(SPKI) of the Secure Enclave public key.
    ///
    /// The X9.63 uncompressed point (65 bytes) is wrapped in a SubjectPublicKeyInfo
    /// DER structure for P-256, then SHA-256 hashed. The result is a 64-character
    /// lowercase hex string that is identical to the Android derivation for the same key.
    func getDeviceId() throws -> String {
        let rawPublicKey = try getPublicKey() // X9.63: 0x04 || x || y (65 bytes)

        // SPKI DER prefix for P-256 (ecPublicKey OID + prime256v1 OID + BIT STRING header)
        let spkiPrefix: [UInt8] = [
            0x30, 0x59,                                     // SEQUENCE (89 bytes)
            0x30, 0x13,                                     // SEQUENCE (19 bytes) — AlgorithmIdentifier
            0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d,     //   OID 1.2.840.10045.2.1 (ecPublicKey)
            0x02, 0x01,
            0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d,     //   OID 1.2.840.10045.3.1.7 (prime256v1)
            0x03, 0x01, 0x07,
            0x03, 0x42, 0x00                                // BIT STRING (66 bytes, 0 unused bits)
        ]

        var spkiData = Data(spkiPrefix)
        spkiData.append(rawPublicKey)                       // 26 + 65 = 91 bytes total

        let hash = SHA256.hash(data: spkiData)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Key Deletion

    /// Removes the key pair from the Keychain and clears cached references.
    func deleteKeyPair() throws {
        // Clear cached references first — the key is about to be deleted
        cachedPrivateKey = nil
        cachedPublicKey = nil

        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyError.keyDeletionFailed(status)
        }
    }

    // MARK: - ECDH Key Exchange + HKDF

    /// Derives a shared secret using ECDH with the local private key and a remote peer
    /// public key, then runs HKDF-SHA256 with salt "claude-remote-v1".
    ///
    /// - Parameter peerPublicKeyData: The peer's P-256 public key in X9.63 format.
    /// - Returns: 32-byte derived symmetric key material.
    func deriveSharedSecret(peerPublicKeyData: Data) throws -> Data {
        let privateKey = try getPrivateKey()

        // Import peer public key
        let peerKeyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256,
        ]

        var error: Unmanaged<CFError>?
        guard let peerPublicKey = SecKeyCreateWithData(
            peerPublicKeyData as CFData,
            peerKeyAttributes as CFDictionary,
            &error
        ) else {
            throw KeyError.invalidPeerPublicKey
        }

        // Perform ECDH key exchange via Security framework
        let algorithm = SecKeyAlgorithm.ecdhKeyExchangeStandard
        guard SecKeyIsAlgorithmSupported(privateKey, .keyExchange, algorithm) else {
            throw KeyError.keyExchangeFailed(
                NSError(domain: "SecureKeyManager", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Algorithm not supported"])
            )
        }

        let exchangeParams: [String: Any] = [
            SecKeyKeyExchangeParameter.requestedSize.rawValue as String: 32,
            SecKeyKeyExchangeParameter.sharedInfo.rawValue as String: Data(),
        ]

        var exchangeError: Unmanaged<CFError>?
        guard var rawSharedSecret = SecKeyCopyKeyExchangeResult(
            privateKey,
            algorithm,
            peerPublicKey,
            exchangeParams as CFDictionary,
            &exchangeError
        ) as Data? else {
            let cfError = exchangeError?.takeRetainedValue() as Error?
                ?? NSError(domain: "SecureKeyManager", code: -2, userInfo: nil)
            throw KeyError.keyExchangeFailed(cfError)
        }
        defer { rawSharedSecret.resetBytes(in: 0..<rawSharedSecret.count) }

        // Run HKDF-SHA256 over the raw shared secret
        let saltData = Data(hkdfSalt.utf8)
        let info = Data("claude-remote-session".utf8)
        let derivedKey = deriveHKDF(
            inputKeyMaterial: rawSharedSecret,
            salt: saltData,
            info: info,
            outputByteCount: 32
        )

        guard let key = derivedKey else {
            throw KeyError.hkdfDerivationFailed
        }

        return key
    }

    // MARK: - Ephemeral ECDH (per-session forward secrecy)

    /// Generates an ephemeral P-256 key pair in memory (NOT Secure Enclave).
    /// Returns (privateKey, publicKeyX963) tuple.
    /// The private key is NOT persisted — discard after ECDH.
    func generateEphemeralKeyPair() throws -> (SecKey, Data) {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let cfError = error?.takeRetainedValue() {
                throw KeyError.keyGenerationFailed(OSStatus(CFErrorGetCode(cfError)))
            }
            throw KeyError.keyGenerationFailed(-1)
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw KeyError.publicKeyExportFailed
        }

        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw KeyError.publicKeyExportFailed
        }

        return (privateKey, publicKeyData)
    }

    /// Performs ECDH using an ephemeral private key with a peer public key.
    /// Returns 32-byte derived AES key via HKDF.
    func deriveSharedSecretEphemeral(ephemeralPrivateKey: SecKey, peerPublicKeyData: Data) throws -> Data {
        let peerKeyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256,
        ]

        var error: Unmanaged<CFError>?
        guard let peerPublicKey = SecKeyCreateWithData(
            peerPublicKeyData as CFData,
            peerKeyAttributes as CFDictionary,
            &error
        ) else {
            throw KeyError.invalidPeerPublicKey
        }

        let algorithm = SecKeyAlgorithm.ecdhKeyExchangeStandard
        let exchangeParams: [String: Any] = [
            SecKeyKeyExchangeParameter.requestedSize.rawValue as String: 32,
            SecKeyKeyExchangeParameter.sharedInfo.rawValue as String: Data(),
        ]

        var exchangeError: Unmanaged<CFError>?
        guard var rawSharedSecret = SecKeyCopyKeyExchangeResult(
            ephemeralPrivateKey,
            algorithm,
            peerPublicKey,
            exchangeParams as CFDictionary,
            &exchangeError
        ) as Data? else {
            let cfError = exchangeError?.takeRetainedValue() as Error?
                ?? NSError(domain: "SecureKeyManager", code: -2, userInfo: nil)
            throw KeyError.keyExchangeFailed(cfError)
        }
        defer { rawSharedSecret.resetBytes(in: 0..<rawSharedSecret.count) }

        let saltData = Data(hkdfSalt.utf8)
        let info = Data("claude-remote-session".utf8)
        guard let derivedKey = deriveHKDF(
            inputKeyMaterial: rawSharedSecret,
            salt: saltData,
            info: info,
            outputByteCount: 32
        ) else {
            throw KeyError.hkdfDerivationFailed
        }

        return derivedKey
    }

    // MARK: - Signing

    /// Signs data using ecdsaSignatureMessageX962SHA256 with the Secure Enclave private key.
    func sign(data: Data) throws -> Data {
        let privateKey = try getPrivateKey()

        let algorithm = SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256

        guard SecKeyIsAlgorithmSupported(privateKey, .sign, algorithm) else {
            throw KeyError.signingFailed(
                NSError(domain: "SecureKeyManager", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Algorithm not supported for signing"])
            )
        }

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            algorithm,
            data as CFData,
            &error
        ) as Data? else {
            let cfError = error?.takeRetainedValue() as Error?
                ?? NSError(domain: "SecureKeyManager", code: -3, userInfo: nil)
            throw KeyError.signingFailed(cfError)
        }

        return signature
    }

    // MARK: - Session AES Key Persistence

    private let sessionKeyService = "com.termopus.session-keys"

    /// Persist the derived AES session key in Keychain for reconnect after app kill.
    func persistSessionKey(_ key: Data, forSession sessionId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sessionKeyService,
            kSecAttrAccount as String: sessionId,
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = key
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            print("[SecureKeyManager] Failed to persist session key: OSStatus \(status)")
        }
    }

    /// Load a persisted AES session key from Keychain.
    func loadSessionKey(forSession sessionId: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sessionKeyService,
            kSecAttrAccount as String: sessionId,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Delete a persisted session key.
    func deleteSessionKey(forSession sessionId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sessionKeyService,
            kSecAttrAccount as String: sessionId,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - HKDF-SHA256 (CryptoKit)

    /// Pure CryptoKit HKDF-SHA256 derivation.
    private func deriveHKDF(
        inputKeyMaterial: Data,
        salt: Data,
        info: Data,
        outputByteCount: Int
    ) -> Data? {
        if #available(iOS 14.0, *) {
            let ikm = SymmetricKey(data: inputKeyMaterial)
            let derivedKey = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: ikm,
                salt: salt,
                info: info,
                outputByteCount: outputByteCount
            )
            return derivedKey.withUnsafeBytes { Data($0) }
        } else {
            // HKDF not available on iOS <14 — fail closed (pairing requires iOS 14+)
            return nil
        }
    }
}
