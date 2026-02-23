import Foundation
import LocalAuthentication

// MARK: - BiometricType

enum BiometricType: String {
    case faceID = "faceID"
    case touchID = "touchID"
    case opticID = "opticID"
    case none = "none"
}

// MARK: - BiometricGate

final class BiometricGate {

    static let shared = BiometricGate()

    private init() {}

    // MARK: - Availability

    /// Returns true if biometric authentication is available on this device.
    func isAvailable() -> Bool {
        let context = LAContext()
        // Hide the "Enter Password" fallback button
        context.localizedFallbackTitle = ""
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Returns the type of biometric hardware present.
    func biometricType() -> BiometricType {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }

        switch context.biometryType {
        case .faceID:
            return .faceID
        case .touchID:
            return .touchID
        case .opticID:
            return .opticID
        @unknown default:
            return .none
        }
    }

    // MARK: - Authentication (Callback)

    /// Authenticates the user with biometrics.
    ///
    /// - Parameters:
    ///   - reason: A localized string explaining why biometric authentication is needed.
    ///   - completion: Called on the main thread with (success, errorMessage?).
    func authenticate(reason: String, completion: @escaping (Bool, String?) -> Void) {
        let context = LAContext()
        // Hide the "Enter Password" fallback so only biometrics are presented
        context.localizedFallbackTitle = ""

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            DispatchQueue.main.async {
                completion(false, "Biometric authentication is not available.")
            }
            return
        }

        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        ) { success, error in
            DispatchQueue.main.async {
                if success {
                    completion(true, nil)
                } else {
                    let message = self.mapError(error)
                    completion(false, message)
                }
            }
        }
    }

    // MARK: - Authentication (Async)

    /// Async/await version of biometric authentication.
    @available(iOS 13.0, *)
    func authenticate(reason: String) async -> (success: Bool, error: String?) {
        await withCheckedContinuation { continuation in
            authenticate(reason: reason) { success, errorMessage in
                continuation.resume(returning: (success, errorMessage))
            }
        }
    }

    // MARK: - Create Authenticated LAContext

    /// Creates an LAContext that has been successfully authenticated via biometrics.
    /// Useful for passing to Keychain queries that require biometric gating.
    func authenticatedContext(reason: String, completion: @escaping (LAContext?, String?) -> Void) {
        let context = LAContext()
        context.localizedFallbackTitle = ""

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            DispatchQueue.main.async {
                completion(nil, "Biometric authentication is not available.")
            }
            return
        }

        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        ) { success, error in
            DispatchQueue.main.async {
                if success {
                    completion(context, nil)
                } else {
                    completion(nil, self.mapError(error))
                }
            }
        }
    }

    // MARK: - Error Mapping

    private func mapError(_ error: Error?) -> String {
        guard let laError = error as? LAError else {
            return error?.localizedDescription ?? "Unknown biometric error."
        }

        switch laError.code {
        case .authenticationFailed:
            return "Biometric authentication failed."
        case .userCancel:
            return "Authentication was cancelled by the user."
        case .userFallback:
            return "User chose password fallback."
        case .biometryNotAvailable:
            return "Biometric authentication is not available."
        case .biometryNotEnrolled:
            return "No biometric data is enrolled on this device."
        case .biometryLockout:
            return "Biometric authentication is locked out due to too many failed attempts."
        case .systemCancel:
            return "Authentication was cancelled by the system."
        case .passcodeNotSet:
            return "Device passcode is not set."
        case .appCancel:
            return "Authentication was cancelled by the application."
        case .invalidContext:
            return "The authentication context is invalid."
        @unknown default:
            return laError.localizedDescription
        }
    }
}
