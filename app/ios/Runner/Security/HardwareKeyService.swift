import Security

final class HardwareKeyService {
    static let shared = HardwareKeyService()

    private let keyTag = "com.termopus.hardware.encryption.key"

    enum HardwareKeyError: Error {
        case keyGenerationFailed(OSStatus)
        case keyNotFound
        case encryptionFailed(Error)
        case decryptionFailed(Error)
    }

    /// Generate or retrieve EC P-256 key in Secure Enclave (NO biometric required).
    /// Used for silent at-rest encryption of tokens and cached data.
    func initialize() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            return // Key already exists
        }

        // No biometric access control — silent encryption
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ] as [String: Any],
        ]

        var error: Unmanaged<CFError>?
        guard SecKeyCreateRandomKey(attributes as CFDictionary, &error) != nil else {
            let osStatus = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? -1
            throw HardwareKeyError.keyGenerationFailed(OSStatus(osStatus))
        }
    }

    /// Encrypt data using ECIES with the hardware-backed key.
    func encrypt(_ data: Data) throws -> Data {
        let publicKey = try getPublicKey()

        let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM
        guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, algorithm) else {
            throw HardwareKeyError.encryptionFailed(
                NSError(domain: "HardwareKey", code: -1, userInfo: [NSLocalizedDescriptionKey: "Algorithm not supported"]))
        }

        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(publicKey, algorithm, data as CFData, &error) else {
            throw HardwareKeyError.encryptionFailed(
                error?.takeRetainedValue() as Error? ?? NSError(domain: "HardwareKey", code: -2))
        }

        return encrypted as Data
    }

    /// Decrypt data using ECIES with the hardware-backed key.
    func decrypt(_ encryptedData: Data) throws -> Data {
        let privateKey = try getPrivateKey()

        let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM
        guard SecKeyIsAlgorithmSupported(privateKey, .decrypt, algorithm) else {
            throw HardwareKeyError.decryptionFailed(
                NSError(domain: "HardwareKey", code: -1, userInfo: [NSLocalizedDescriptionKey: "Algorithm not supported"]))
        }

        var error: Unmanaged<CFError>?
        guard let decrypted = SecKeyCreateDecryptedData(privateKey, algorithm, encryptedData as CFData, &error) else {
            throw HardwareKeyError.decryptionFailed(
                error?.takeRetainedValue() as Error? ?? NSError(domain: "HardwareKey", code: -2))
        }

        return decrypted as Data
    }

    // MARK: - Private

    private func getPrivateKey() throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw HardwareKeyError.keyNotFound
        }
        return item as! SecKey
    }

    private func getPublicKey() throws -> SecKey {
        let privateKey = try getPrivateKey()
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw HardwareKeyError.keyNotFound
        }
        return publicKey
    }
}
