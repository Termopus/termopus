import LocalAuthentication
import Security

final class BiometricCryptoService {
    static let shared = BiometricCryptoService()

    private let keyTag = "com.termopus.biometric.signing.key"

    enum BiometricCryptoError: Error {
        case keyGenerationFailed(OSStatus)
        case keyNotFound
        case signingFailed(Error)
        case publicKeyExportFailed
        case invalidChallenge
    }

    /// Generate EC P-256 key in Secure Enclave with biometric requirement.
    /// Key invalidates on biometric enrollment change.
    func initialize() throws {
        // Check if key already exists
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

        // Create access control requiring biometric (current set)
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            &error
        ) else {
            throw BiometricCryptoError.keyGenerationFailed(-1)
        }

        // Generate key in Secure Enclave
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrAccessControl as String: accessControl,
            ] as [String: Any],
        ]

        var genError: Unmanaged<CFError>?
        guard SecKeyCreateRandomKey(attributes as CFDictionary, &genError) != nil else {
            let osStatus = genError.map { CFErrorGetCode($0.takeRetainedValue()) } ?? -1
            throw BiometricCryptoError.keyGenerationFailed(OSStatus(osStatus))
        }
    }

    /// Sign a challenge with the biometric-protected key.
    /// Triggers Face ID/Touch ID automatically when key is accessed.
    func signChallenge(_ challengeBase64: String, reason: String,
                       completion: @escaping (Result<String, Error>) -> Void) {
        guard let challengeData = Data(base64Encoded: challengeBase64) else {
            completion(.failure(BiometricCryptoError.invalidChallenge))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                let privateKey = try getPrivateKey(reason: reason)

                var signError: Unmanaged<CFError>?
                guard let signature = SecKeyCreateSignature(
                    privateKey,
                    .ecdsaSignatureMessageX962SHA256,
                    challengeData as CFData,
                    &signError
                ) else {
                    let error = signError?.takeRetainedValue() as Error? ?? BiometricCryptoError.signingFailed(
                        NSError(domain: "BiometricCrypto", code: -1))
                    completion(.failure(error))
                    return
                }

                let signatureBase64 = (signature as Data).base64EncodedString()
                completion(.success(signatureBase64))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Get public key in X9.63 uncompressed format for server verification.
    func getPublicKey() throws -> Data {
        let privateKey = try getPrivateKey(reason: nil)
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw BiometricCryptoError.publicKeyExportFailed
        }

        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            throw BiometricCryptoError.publicKeyExportFailed
        }

        return publicKeyData as Data
    }

    // MARK: - Private

    private func getPrivateKey(reason: String?) throws -> SecKey {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]

        if let reason = reason {
            let context = LAContext()
            context.localizedReason = reason
            query[kSecUseAuthenticationContext as String] = context
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw BiometricCryptoError.keyNotFound
        }

        return item as! SecKey
    }
}
