import Foundation
import UIKit
import MachO
import Darwin
import LocalAuthentication
import Network

// MARK: - TamperCheck

/// Describes which tamper check failed.
enum TamperCheck: String, Codable {
    case jailbreak
    case debugger
    case codeSignature
    case dyldInjection
    case suspiciousFiles
}

// MARK: - TamperResult

struct TamperResult {
    let passed: Bool
    let failedChecks: [TamperCheck]

    var dictionary: [String: Any] {
        return [
            "passed": passed,
            "failedChecks": failedChecks.map { $0.rawValue },
        ]
    }
}

// MARK: - AntiTamper

final class AntiTamper {

    static let shared = AntiTamper()

    private init() {}

    // MARK: - Main Integrity Check

    /// Runs all integrity checks in random order and returns a combined result.
    func checkIntegrity() -> TamperResult {
        typealias Check = () -> TamperCheck?

        var checks: [Check] = [
            { self.checkJailbreak() ? nil : .jailbreak },
            { self.checkDebugger() ? nil : .debugger },
            { self.checkCodeSignature() ? nil : .codeSignature },
            { self.checkDyldInjection() ? nil : .dyldInjection },
            { self.checkSuspiciousFiles() ? nil : .suspiciousFiles },
            { self.checkBundleIntegrity() ? nil : .codeSignature },
        ]

        // Run checks in random order to make bypassing harder
        checks.shuffle()

        var failedChecks: [TamperCheck] = []
        for check in checks {
            if let failed = check() {
                failedChecks.append(failed)
            }
        }

        return TamperResult(
            passed: failedChecks.isEmpty,
            failedChecks: failedChecks
        )
    }

    /// Runs all integrity checks and returns a MAC-signed result string.
    /// Format: "STATUS:details:timestamp:hmac_hex"
    /// Preserves per-check failure granularity from TamperResult.
    func checkIntegritySigned() -> String {
        let result = checkIntegrity()
        let status = result.passed ? "CLEAN" : "TAMPERED"
        let details = result.failedChecks.isEmpty
            ? "none"
            : result.failedChecks.map { $0.rawValue }.joined(separator: ",")
        return NativeSecretsWrapper.signSecurityResult("\(status):\(details)")
    }

    // MARK: - Jailbreak Detection

    /// Returns true if the device appears to NOT be jailbroken.
    func checkJailbreak() -> Bool {
        // 1. Check for suspicious paths
        let suspiciousPaths = [
            "/Applications/Cydia.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/bin/bash",
            "/usr/sbin/sshd",
            "/usr/bin/ssh",
            "/etc/apt",
            "/usr/bin/apt",
            "/Applications/Sileo.app",
            "/var/jb",
            "/var/lib/apt",
            "/var/lib/cydia",
            "/var/cache/apt",
            "/var/log/syslog",
            "/bin/sh",
            "/usr/libexec/sftp-server",
            "/private/var/lib/apt",
            "/private/var/stash",
            "/private/var/tmp/cydia.log",
            "/private/var/mobile/Library/SBSettings/Themes",
        ]

        for path in suspiciousPaths {
            if FileManager.default.fileExists(atPath: path) {
                return false
            }
        }

        // 2. Try to write a file outside the app sandbox
        let testPath = "/private/jailbreak_test_\(UUID().uuidString)"
        do {
            try "test".write(toFile: testPath, atomically: true, encoding: .utf8)
            // If we can write outside sandbox, the device is jailbroken
            try? FileManager.default.removeItem(atPath: testPath)
            return false
        } catch {
            // Expected -- writing outside sandbox should fail on a clean device
        }

        // 3. Check if Cydia URL scheme is registered
        if let url = URL(string: "cydia://package/com.example.package") {
            if UIApplication.shared.canOpenURL(url) {
                return false
            }
        }

        // 4. Check for symbolic links in system directories
        let symlinks = [
            "/Applications",
            "/var/stash/Library/Ringtones",
            "/var/stash/Library/Wallpaper",
            "/var/stash/usr/include",
            "/var/stash/usr/libexec",
            "/var/stash/usr/share",
            "/Library/Ringtones",
            "/Library/Wallpaper",
        ]

        for path in symlinks {
            var s = stat()
            if lstat(path, &s) == 0 {
                if (s.st_mode & S_IFLNK) == S_IFLNK {
                    return false
                }
            }
        }

        return true
    }

    // MARK: - Debugger Detection

    /// Returns true if no debugger is attached.
    func checkDebugger() -> Bool {
        // Use sysctl to check for P_TRACED flag
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]

        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else {
            // If sysctl fails, assume potentially tampered
            return false
        }

        let isBeingTraced = (info.kp_proc.p_flag & P_TRACED) != 0
        return !isBeingTraced
    }

    // MARK: - Code Signature Verification

    /// Returns true if the app's code signature appears valid.
    /// SecStaticCode APIs are macOS-only; on iOS we verify the
    /// embedded provisioning profile exists as a proxy check.
    func checkCodeSignature() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        // Verify embedded.mobileprovision exists (stripped in re-signed/cracked builds)
        guard let _ = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") else {
            return false
        }
        // Verify the main executable exists at the expected path
        guard let executablePath = Bundle.main.executablePath,
              FileManager.default.fileExists(atPath: executablePath) else {
            return false
        }
        return true
        #endif
    }

    // MARK: - DYLD Injection Detection

    /// Returns true if no suspicious dynamic libraries are injected.
    func checkDyldInjection() -> Bool {
        let suspiciousLibraries = [
            "FridaGadget",
            "frida",
            "cynject",
            "libcycript",
            "MobileSubstrate",
            "SSLKillSwitch",
            "SSLKillSwitch2",
            "TrustMe",
            "SubstrateLoader",
            "SubstrateInserter",
            "SubstrateBootstrap",
            "AFlexLoader",
            "libReveal",
            "RevealServer",
        ]

        let imageCount = _dyld_image_count()

        for i in 0..<imageCount {
            guard let imageName = _dyld_get_image_name(i) else {
                continue
            }
            let name = String(cString: imageName)

            for suspicious in suspiciousLibraries {
                if name.localizedCaseInsensitiveContains(suspicious) {
                    return false
                }
            }
        }

        // Also check DYLD_INSERT_LIBRARIES environment variable
        if let insertLibs = ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"],
           !insertLibs.isEmpty {
            return false
        }

        return true
    }

    // MARK: - Suspicious Files & Ports

    /// Returns true if no suspicious instrumentation files or open ports are found.
    func checkSuspiciousFiles() -> Bool {
        // Check for Frida server binaries
        let fridaPaths = [
            "/usr/sbin/frida-server",
            "/usr/bin/frida-server",
            "/usr/local/bin/frida-server",
            "/usr/lib/frida/frida-agent.dylib",
            "/tmp/frida-server",
        ]

        for path in fridaPaths {
            if FileManager.default.fileExists(atPath: path) {
                return false
            }
        }

        // Check if common instrumentation ports are open
        let suspiciousPorts: [UInt16] = [27042, 27043] // Frida default ports

        for port in suspiciousPorts {
            if isPortOpen(port: port) {
                return false
            }
        }

        return true
    }

    // MARK: - Bundle Integrity Verification

    /// Returns true if the app bundle appears legitimate.
    func checkBundleIntegrity() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        let bundlePath = Bundle.main.bundlePath
        let validPaths = [
            "/var/containers/Bundle/Application",
            "/private/var/containers/Bundle/Application"
        ]
        guard validPaths.contains(where: { bundlePath.hasPrefix($0) }) else {
            return false
        }
        guard Bundle.main.bundleIdentifier == "com.termopus.app" else {
            return false
        }
        return true
        #endif
    }

    // MARK: - Screen Lock Detection

    /// Returns true if the device has a screen lock (passcode, biometric).
    /// This is an informational check, not a hard fail.
    func hasScreenLock() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    // MARK: - VPN Detection

    /// Returns true if a VPN interface is active.
    /// This is informational (users may have legitimate VPNs).
    func isVpnActive() -> Bool {
        let monitor = NWPathMonitor()
        let semaphore = DispatchSemaphore(value: 0)
        var usesVPN = false

        monitor.pathUpdateHandler = { path in
            usesVPN = path.availableInterfaces.contains { iface in
                let name = iface.name
                return name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
            }
            semaphore.signal()
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        _ = semaphore.wait(timeout: .now() + 1.0)
        monitor.cancel()

        return usesVPN
    }

    // MARK: - Port Check Helper

    /// Attempts a TCP connection to localhost on the given port to see if it is open.
    private func isPortOpen(port: UInt16) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }

        defer { close(sock) }

        // Set a very short timeout to avoid blocking
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000) // 100ms
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }

    /// Terminate the process immediately via native __builtin_trap().
    /// Compiles to an illegal instruction (brk #1 on ARM64) which cannot
    /// be hooked or intercepted by Frida/dynamic instrumentation.
    func secureExit() -> Never {
        NativeSecretsWrapper.secureExit()
    }
}
