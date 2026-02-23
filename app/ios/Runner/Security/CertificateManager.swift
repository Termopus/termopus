import Foundation
import Security
import CommonCrypto

// MARK: - CertificateError

enum CertificateError: Error, LocalizedError {
    case csrGenerationFailed(String)
    case pemParsingFailed
    case certificateStoreFailed(OSStatus)
    case certificateNotFound
    case identityNotFound
    case keychainError(OSStatus)
    case invalidPublicKey

    var errorDescription: String? {
        switch self {
        case .csrGenerationFailed(let detail):
            return "CSR generation failed: \(detail)"
        case .pemParsingFailed:
            return "Failed to parse PEM certificate data."
        case .certificateStoreFailed(let status):
            return "Certificate store failed with status: \(status)"
        case .certificateNotFound:
            return "Client certificate not found in Keychain."
        case .identityNotFound:
            return "Client identity (certificate + key) not found."
        case .keychainError(let status):
            return "Keychain operation failed with status: \(status)"
        case .invalidPublicKey:
            return "The provided public key data is invalid."
        }
    }
}

// MARK: - CertificateManager

final class CertificateManager {

    static let shared = CertificateManager()

    private let certificateLabel = "com.clauderemote.client.cert"
    private let identityLabel = "com.clauderemote.client.identity"

    private init() {}

    // MARK: - CSR Generation

    /// Generates a PKCS#10 Certificate Signing Request (CSR) in PEM format.
    ///
    /// This builds a minimal CSR structure manually since Apple does not provide
    /// a native CSR API. The CSR uses the provided public key and a hardcoded
    /// subject (CN=claude-remote-device, O=ClaudeRemote).
    ///
    /// - Parameter publicKey: The P-256 public key in X9.63 uncompressed format (65 bytes).
    /// - Returns: A PEM-encoded CSR string.
    func generateCSR(publicKey: Data) throws -> String {
        guard publicKey.count == 65, publicKey.first == 0x04 else {
            throw CertificateError.invalidPublicKey
        }

        // Build the CSR DER structure
        let csrDER = try buildCSRData(publicKey: publicKey)

        // Encode as PEM
        let base64 = csrDER.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let pem = "-----BEGIN CERTIFICATE REQUEST-----\n\(base64)\n-----END CERTIFICATE REQUEST-----"

        return pem
    }

    // MARK: - Certificate Storage

    /// Stores a PEM-encoded certificate in the Keychain.
    ///
    /// - Parameter pem: A PEM-encoded X.509 certificate.
    /// - Returns: true on success.
    @discardableResult
    func storeCertificate(_ pem: String) throws -> Bool {
        guard let derData = parsePEM(pem) else {
            throw CertificateError.pemParsingFailed
        }

        guard let certificate = SecCertificateCreateWithData(nil, derData as CFData) else {
            throw CertificateError.pemParsingFailed
        }

        // Remove any existing certificate with the same label
        deleteCertificateFromKeychain()

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: certificateLabel,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CertificateError.certificateStoreFailed(status)
        }

        return true
    }

    // MARK: - Certificate Query

    /// Returns true if a client certificate is stored in the Keychain.
    func hasCertificate() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certificateLabel,
            kSecReturnRef as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieves the stored client certificate.
    func getCertificate() -> SecCertificate? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certificateLabel,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess, let cert = item else {
            return nil
        }

        return (cert as! SecCertificate)
    }

    // MARK: - Client Identity (for mTLS)

    /// Returns a SecIdentity that pairs the client certificate with the corresponding
    /// private key. Used to authenticate via mTLS in URLSession challenges.
    func getClientIdentity() -> SecIdentity? {
        guard let certificate = getCertificate() else {
            return nil
        }

        // Use SecIdentityCreateWithCertificate approach:
        // Look up an identity matching the certificate
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let identity = item {
            // Verify the identity matches our certificate
            var identityCert: SecCertificate?
            if SecIdentityCopyCertificate(identity as! SecIdentity, &identityCert) == errSecSuccess,
               let iCert = identityCert {
                let certData = SecCertificateCopyData(certificate) as Data
                let iCertData = SecCertificateCopyData(iCert) as Data
                if certData == iCertData {
                    return (identity as! SecIdentity)
                }
            }
        }

        // Fallback: try to find identity by iterating all identities
        let allQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var allItems: CFTypeRef?
        let allStatus = SecItemCopyMatching(allQuery as CFDictionary, &allItems)

        guard allStatus == errSecSuccess, let identities = allItems as? [SecIdentity] else {
            return nil
        }

        let targetData = SecCertificateCopyData(certificate) as Data

        for identity in identities {
            var identityCert: SecCertificate?
            if SecIdentityCopyCertificate(identity, &identityCert) == errSecSuccess,
               let iCert = identityCert {
                let iCertData = SecCertificateCopyData(iCert) as Data
                if iCertData == targetData {
                    return identity
                }
            }
        }

        return nil
    }

    // MARK: - Certificate Fingerprint & PEM

    /// Compute the SHA-256 fingerprint of the stored client certificate (DER encoding).
    /// Returns lowercase hex string, or nil if no certificate.
    func getCertificateFingerprint() -> String? {
        guard let cert = getCertificate() else { return nil }
        let derData = SecCertificateCopyData(cert) as Data

        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        derData.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(derData.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Get the PEM-encoded client certificate.
    func getCertificatePEM() -> String? {
        guard let cert = getCertificate() else { return nil }
        let derData = SecCertificateCopyData(cert) as Data
        let base64 = derData.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----"
    }

    // MARK: - Delete Certificate

    /// Removes the stored client certificate from the Keychain.
    @discardableResult
    func deleteCertificate() -> Bool {
        return deleteCertificateFromKeychain()
    }

    // MARK: - Private Helpers

    /// Parses a PEM string, strips headers/footers, and returns the DER data.
    private func parsePEM(_ pem: String) -> Data? {
        var base64 = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE REQUEST-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE REQUEST-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")

        // Remove any remaining whitespace
        base64 = base64.trimmingCharacters(in: .whitespacesAndNewlines)

        return Data(base64Encoded: base64)
    }

    /// Removes certificate from Keychain.
    @discardableResult
    private func deleteCertificateFromKeychain() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certificateLabel,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Minimal CSR DER Builder

    /// Builds a minimal PKCS#10 CSR DER structure.
    /// Subject: CN=claude-remote-device, O=ClaudeRemote
    /// Key: P-256 (ecPublicKey with prime256v1 OID)
    ///
    /// Builds a complete, signed PKCS#10 CSR. The certificationRequestInfo is
    /// signed with the Secure Enclave private key (ecdsaSignatureMessageX962SHA256).
    private func buildCSRData(publicKey: Data) throws -> Data {
        // OIDs
        let oidCommonName: [UInt8] = [0x55, 0x04, 0x03] // 2.5.4.3
        let oidOrganization: [UInt8] = [0x55, 0x04, 0x0A] // 2.5.4.10
        let oidEcPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01] // 1.2.840.10045.2.1
        let oidPrime256v1: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07] // 1.2.840.10045.3.1.7
        let oidEcdsaWithSHA256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02] // 1.2.840.10045.4.3.2

        // Version 0
        let version = wrapASN1(tag: 0x02, content: [0x00])

        // Subject: CN=claude-remote-device, O=ClaudeRemote
        let cnValue = Array("claude-remote-device".utf8)
        let cnString = wrapASN1(tag: 0x0C, content: cnValue)
        let cnOID = wrapASN1(tag: 0x06, content: oidCommonName)
        let cnAttr = wrapASN1(tag: 0x30, content: cnOID + cnString)
        let cnSet = wrapASN1(tag: 0x31, content: cnAttr)

        let orgValue = Array("ClaudeRemote".utf8)
        let orgString = wrapASN1(tag: 0x0C, content: orgValue)
        let orgOID = wrapASN1(tag: 0x06, content: oidOrganization)
        let orgAttr = wrapASN1(tag: 0x30, content: orgOID + orgString)
        let orgSet = wrapASN1(tag: 0x31, content: orgAttr)

        let subject = wrapASN1(tag: 0x30, content: cnSet + orgSet)

        // SubjectPublicKeyInfo
        let algorithmOID = wrapASN1(tag: 0x06, content: oidEcPublicKey)
        let curveOID = wrapASN1(tag: 0x06, content: oidPrime256v1)
        let algorithmIdentifier = wrapASN1(tag: 0x30, content: algorithmOID + curveOID)
        // BIT STRING wrapping the public key
        let pubKeyBitString = wrapASN1BitString(content: Array(publicKey))
        let subjectPublicKeyInfo = wrapASN1(tag: 0x30, content: algorithmIdentifier + pubKeyBitString)

        // Attributes (empty, context-specific tag [0])
        let attributes: [UInt8] = [0xA0, 0x00]

        // CertificationRequestInfo
        let certRequestInfo = wrapASN1(tag: 0x30, content: version + subject + subjectPublicKeyInfo + attributes)

        // Sign the certificationRequestInfo with Secure Enclave private key
        let signature: Data
        do {
            signature = try SecureKeyManager.shared.sign(data: Data(certRequestInfo))
        } catch {
            throw CertificateError.csrGenerationFailed("Failed to sign CSR: \(error.localizedDescription)")
        }

        // Signature algorithm: ecdsaWithSHA256
        let sigAlgOID = wrapASN1(tag: 0x06, content: oidEcdsaWithSHA256)
        let signatureAlgorithm = wrapASN1(tag: 0x30, content: sigAlgOID)

        // Signature value (DER-encoded ECDSA signature from Secure Enclave)
        let signatureValue = wrapASN1BitString(content: Array(signature))

        // CertificationRequest (outer SEQUENCE)
        let csr = wrapASN1(tag: 0x30, content: certRequestInfo + signatureAlgorithm + signatureValue)

        return Data(csr)
    }

    /// Wraps content in an ASN.1 TLV with the given tag.
    private func wrapASN1(tag: UInt8, content: [UInt8]) -> [UInt8] {
        var result: [UInt8] = [tag]
        result.append(contentsOf: encodeASN1Length(content.count))
        result.append(contentsOf: content)
        return result
    }

    /// Wraps content as an ASN.1 BIT STRING (prepends 0x00 unused-bits byte).
    private func wrapASN1BitString(content: [UInt8]) -> [UInt8] {
        let inner: [UInt8] = [0x00] + content // 0 unused bits
        return wrapASN1(tag: 0x03, content: inner)
    }

    /// Encodes an ASN.1 length using DER rules.
    private func encodeASN1Length(_ length: Int) -> [UInt8] {
        if length < 0x80 {
            return [UInt8(length)]
        } else if length <= 0xFF {
            return [0x81, UInt8(length)]
        } else if length <= 0xFFFF {
            return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
        } else {
            // For very large lengths (unlikely in our use case)
            return [0x83, UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
        }
    }
}
