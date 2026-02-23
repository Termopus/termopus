import Foundation
import DeviceCheck
import CryptoKit

// MARK: - AttestError

enum AttestError: Error, LocalizedError {
    case notSupported
    case keyGenerationFailed(Error)
    case keyNotFound
    case attestationFailed(Error)
    case assertionFailed(Error)
    case invalidChallenge
    case storageFailed

    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "App Attest is not supported on this device."
        case .keyGenerationFailed(let error):
            return "Attest key generation failed: \(error.localizedDescription)"
        case .keyNotFound:
            return "Attest key ID not found. Generate a key first."
        case .attestationFailed(let error):
            return "Attestation failed: \(error.localizedDescription)"
        case .assertionFailed(let error):
            return "Assertion generation failed: \(error.localizedDescription)"
        case .invalidChallenge:
            return "Challenge data is invalid or empty."
        case .storageFailed:
            return "Failed to persist attest key ID."
        }
    }
}

// MARK: - DeviceAttestation

@available(iOS 14.0, *)
final class DeviceAttestation {

    static let shared = DeviceAttestation()

    private let keyIdStorageKey = "com.clauderemote.appAttest.keyId"
    private let service: DCAppAttestService

    private init() {
        service = DCAppAttestService.shared
    }

    // MARK: - Support Check

    /// Returns true if App Attest is supported on this device and OS version.
    var isSupported: Bool {
        return service.isSupported
    }

    // MARK: - Key Generation

    /// Generates a new App Attest key and stores the key ID in UserDefaults.
    /// Overwrites any previously stored key ID.
    func generateKey() async throws -> String {
        guard isSupported else {
            throw AttestError.notSupported
        }

        do {
            let keyId = try await service.generateKey()

            // Persist the key ID
            UserDefaults.standard.set(keyId, forKey: keyIdStorageKey)
            UserDefaults.standard.synchronize()

            guard UserDefaults.standard.string(forKey: keyIdStorageKey) != nil else {
                throw AttestError.storageFailed
            }

            return keyId
        } catch let error as AttestError {
            throw error
        } catch {
            throw AttestError.keyGenerationFailed(error)
        }
    }

    /// Returns the stored key ID, or generates a new one if none exists.
    func getOrCreateKey() async throws -> String {
        if let existingKeyId = UserDefaults.standard.string(forKey: keyIdStorageKey) {
            return existingKeyId
        }
        return try await generateKey()
    }

    /// Returns the stored key ID, or nil.
    func getStoredKeyId() -> String? {
        return UserDefaults.standard.string(forKey: keyIdStorageKey)
    }

    // MARK: - Attestation

    /// Attests the stored key with the given challenge.
    ///
    /// The challenge is SHA-256 hashed before being sent to the attestation service,
    /// as required by the App Attest protocol.
    ///
    /// - Parameter challenge: Raw challenge data from the server.
    /// - Returns: The attestation object (CBOR-encoded).
    func attest(challenge: Data) async throws -> Data {
        guard isSupported else {
            throw AttestError.notSupported
        }

        guard !challenge.isEmpty else {
            throw AttestError.invalidChallenge
        }

        let keyId = try await getOrCreateKey()

        // Hash the challenge with SHA-256
        let challengeHash = Data(SHA256.hash(data: challenge))

        do {
            let attestation = try await service.attestKey(keyId, clientDataHash: challengeHash)
            return attestation
        } catch {
            // If attestation fails, the key may be invalidated -- clear storage
            UserDefaults.standard.removeObject(forKey: keyIdStorageKey)
            throw AttestError.attestationFailed(error)
        }
    }

    // MARK: - Assertion

    /// Generates an assertion for the given challenge using the stored attest key.
    ///
    /// - Parameter challenge: Raw challenge data from the server.
    /// - Returns: The assertion object.
    func generateAssertion(challenge: Data) async throws -> Data {
        guard isSupported else {
            throw AttestError.notSupported
        }

        guard !challenge.isEmpty else {
            throw AttestError.invalidChallenge
        }

        guard let keyId = getStoredKeyId() else {
            throw AttestError.keyNotFound
        }

        // Hash the challenge with SHA-256
        let challengeHash = Data(SHA256.hash(data: challenge))

        do {
            let assertion = try await service.generateAssertion(keyId, clientDataHash: challengeHash)
            return assertion
        } catch {
            throw AttestError.assertionFailed(error)
        }
    }

    // MARK: - Reset

    /// Clears the stored key ID. A new key must be generated after calling this.
    func reset() {
        UserDefaults.standard.removeObject(forKey: keyIdStorageKey)
    }
}
