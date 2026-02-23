import Foundation

enum NativeSecretsWrapper {
    static func signSecurityResult(_ status: String) -> String {
        guard let cStr = NativeSecrets_signSecurityResult(status) else { return "" }
        let result = String(cString: cStr)
        NativeSecrets_freeResult(cStr)
        return result
    }

    /// Validates signed result in native code.
    /// Calls __builtin_trap() if tampered — does NOT return on failure.
    static func enforceSecurityResult(_ signedResult: String) {
        NativeSecrets_enforceSecurityResult(signedResult)
    }

    static func verifyCertificatePin(_ spkiHash: String) -> String {
        guard let cStr = NativeSecrets_verifyCertificatePin(spkiHash) else { return "" }
        let result = String(cString: cStr)
        NativeSecrets_freeResult(cStr)
        return result
    }

    static func getEndpoint(_ key: String) -> String {
        guard let cStr = NativeSecrets_getEndpoint(key) else { return "" }
        let result = String(cString: cStr)
        NativeSecrets_freeResult(cStr)
        return result
    }

    static func secureExit() -> Never {
        NativeSecrets_secureExit()
        // Unreachable — secureExit calls __builtin_trap()
        fatalError("secureExit should have crashed")
    }
}
