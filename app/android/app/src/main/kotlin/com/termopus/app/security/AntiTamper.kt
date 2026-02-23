package com.termopus.app.security

import android.app.KeyguardManager
import android.content.Context
import com.termopus.app.BuildConfig
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Debug
import android.util.Log
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest

/**
 * Runtime integrity checks to detect tampered, rooted, emulated, or
 * instrumented environments.
 *
 * Each check is a standalone function returning `true` if the environment
 * appears clean. [checkIntegrity] runs all checks in **random order** so
 * that hooking frameworks cannot predict or short-circuit the sequence.
 *
 * These checks are defence-in-depth; a determined attacker with full device
 * control can bypass them. They raise the bar and complement server-side
 * verification (Play Integrity, certificate pinning).
 */
object AntiTamper {

    private const val TAG = "AntiTamper"

    /**
     * SHA-256 hex digest of the release signing certificate.
     * In debug builds, the actual hash is logged to logcat — copy it here.
     * OSS users: leave as-is if you don't need release signing verification.
     */
    private const val EXPECTED_SIGNING_HASH = "PLACEHOLDER_RELEASE_SIGNING_HASH"

    /** Application context set once during initialisation. */
    @Volatile
    private var appContext: Context? = null

    /**
     * Initialise with application context. Call once from [MainActivity].
     */
    fun init(context: Context) {
        appContext = context.applicationContext
    }

    // -------------------------------------------------------------------------
    // Main entry point
    // -------------------------------------------------------------------------

    /**
     * Run all integrity checks in random order.
     *
     * @return `true` if every check passes; `false` if any single check fails
     */
    fun checkIntegrity(): Boolean {
        val checks: MutableList<() -> Boolean> = mutableListOf(
            ::checkRoot,
            ::checkDebugger,
            ::checkEmulator,
            ::checkFrida,
            ::checkHooks,
            ::checkAppSignature
        )

        // Shuffle to randomise execution order
        checks.shuffle()

        for (check in checks) {
            if (!check()) {
                return false
            }
        }
        return true
    }

    /**
     * Runs all integrity checks and returns a MAC-signed result string.
     * Format: "STATUS:details:timestamp:hmac_hex"
     * STATUS is "CLEAN" or "TAMPERED"
     * details is comma-separated list of failed check names (or "none")
     */
    fun checkIntegritySigned(): String {
        val checkMap = mapOf<String, () -> Boolean>(
            "root" to ::checkRoot,
            "debugger" to ::checkDebugger,
            "emulator" to ::checkEmulator,
            "frida" to ::checkFrida,
            "hooks" to ::checkHooks,
            "appSignature" to ::checkAppSignature
        )

        val entries = checkMap.entries.toMutableList()
        entries.shuffle()

        val failed = mutableListOf<String>()
        for ((name, check) in entries) {
            if (!check()) {
                failed.add(name)
            }
        }

        val status = if (failed.isEmpty()) "CLEAN" else "TAMPERED"
        val details = if (failed.isEmpty()) "none" else failed.joinToString(",")
        return NativeSecrets.signSecurityResult("$status:$details")
    }

    // -------------------------------------------------------------------------
    // 1. Root detection
    // -------------------------------------------------------------------------

    /**
     * Check for indicators of a rooted device.
     *
     * Inspects:
     * - Common su binary locations
     * - Superuser / Magisk / root management apps
     * - Build tags containing "test-keys"
     * - Ability to execute "which su"
     */
    fun checkRoot(): Boolean {
        // 1a. Check for su binary in common paths
        val suPaths = listOf(
            "/system/bin/su",
            "/system/xbin/su",
            "/sbin/su",
            "/system/su",
            "/system/bin/.ext/.su",
            "/system/usr/we-need-root/su",
            "/data/local/su",
            "/data/local/bin/su",
            "/data/local/xbin/su",
            "/cache/su",
            "/system/app/Superuser.apk",
            "/system/app/SuperSU/SuperSU.apk",
            "/system/app/su",
        )

        for (path in suPaths) {
            if (File(path).exists()) {
                return false
            }
        }

        // 1b. Check for Magisk indicators
        val magiskPaths = listOf(
            "/sbin/.magisk",
            "/sbin/.core/mirror",
            "/sbin/.core/img",
            "/data/adb/magisk",
            "/data/adb/magisk.img",
            "/data/adb/magisk.db",
            "/cache/.disable_magisk",
            "/dev/.magisk.unblock",
        )

        for (path in magiskPaths) {
            if (File(path).exists()) {
                return false
            }
        }

        // 1c. Check for root management packages
        val rootPackages = listOf(
            "com.noshufou.android.su",
            "com.noshufou.android.su.elite",
            "eu.chainfire.supersu",
            "com.koushikdutta.superuser",
            "com.thirdparty.superuser",
            "com.yellowes.su",
            "com.topjohnwu.magisk",
            "com.kingroot.kinguser",
            "com.kingo.root",
            "com.smedialink.oneclickroot",
            "com.zhiqupk.root.global",
        )

        val ctx = appContext
        if (ctx != null) {
            val pm = ctx.packageManager
            for (pkg in rootPackages) {
                try {
                    pm.getPackageInfo(pkg, 0)
                    return false // Package is installed
                } catch (_: Exception) {
                    // Package not found — good
                }
            }
        }

        // 1d. Check Build.TAGS for test-keys
        val buildTags = Build.TAGS
        if (buildTags != null && buildTags.contains("test-keys")) {
            return false
        }

        // 1e. Try to execute "which su"
        try {
            val process = Runtime.getRuntime().exec(arrayOf("which", "su"))
            val reader = BufferedReader(InputStreamReader(process.inputStream))
            val result = reader.readLine()
            process.waitFor()
            reader.close()
            if (!result.isNullOrBlank()) {
                return false // "which su" returned a path
            }
        } catch (_: Exception) {
            // "which" not available or error — acceptable
        }

        return true
    }

    // -------------------------------------------------------------------------
    // 2. Debugger detection
    // -------------------------------------------------------------------------

    /**
     * Check whether a debugger is attached or the app is built as debuggable.
     */
    fun checkDebugger(): Boolean {
        // 2a. Check if a Java debugger is currently connected
        if (Debug.isDebuggerConnected()) {
            return false
        }

        // 2b. Check if the native debugger is waiting
        if (Debug.waitingForDebugger()) {
            return false
        }

        // 2c. Check FLAG_DEBUGGABLE in ApplicationInfo
        val ctx = appContext ?: return true
        try {
            val appInfo = ctx.applicationInfo
            if (appInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
                return false
            }
        } catch (_: Exception) {
            // Ignore — conservative pass
        }

        return true
    }

    // -------------------------------------------------------------------------
    // 3. Emulator detection
    // -------------------------------------------------------------------------

    /**
     * Check for emulator indicators in [Build] properties.
     *
     * Targets common AVD, Genymotion, and generic emulator fingerprints.
     */
    fun checkEmulator(): Boolean {
        val dominated = listOf(
            Build.FINGERPRINT to listOf("generic", "unknown", "google/sdk", "ttVM_Hdragon", "vbox"),
            Build.MODEL to listOf("google_sdk", "Emulator", "Android SDK built for", "sdk_gphone"),
            Build.MANUFACTURER to listOf("Genymotion", "unknown"),
            Build.BRAND to listOf("generic", "generic_x86", "generic_x86_64"),
            Build.DEVICE to listOf("generic", "generic_x86", "vbox86p", "goldfish", "ranchu"),
            Build.PRODUCT to listOf("sdk", "google_sdk", "sdk_x86", "sdk_gphone", "vbox86p"),
            Build.HARDWARE to listOf("goldfish", "ranchu", "vbox86"),
        )

        for ((property, indicators) in dominated) {
            val value = property.lowercase()
            for (indicator in indicators) {
                if (value.contains(indicator.lowercase())) {
                    return false
                }
            }
        }

        // Additional check: FINGERPRINT starts with "generic"
        if (Build.FINGERPRINT.startsWith("generic")) {
            return false
        }

        // Check for QEMU properties (some emulators set this)
        try {
            val process = Runtime.getRuntime().exec(arrayOf("getprop", "ro.hardware.chipname"))
            val reader = BufferedReader(InputStreamReader(process.inputStream))
            val chipname = reader.readLine()
            process.waitFor()
            reader.close()
            if (chipname != null && chipname.lowercase().contains("ranchu")) {
                return false
            }
        } catch (_: Exception) {
            // Ignore
        }

        return true
    }

    // -------------------------------------------------------------------------
    // 4. Frida detection
    // -------------------------------------------------------------------------

    /**
     * Detect the Frida dynamic instrumentation toolkit.
     *
     * Checks:
     * - frida-server binary on disk
     * - Frida default listening ports (27042, 27043)
     * - Running processes containing "frida"
     */
    fun checkFrida(): Boolean {
        // 4a. Check for frida-server binary
        val fridaPaths = listOf(
            "/data/local/tmp/frida-server",
            "/data/local/tmp/re.frida.server",
            "/data/local/tmp/frida-agent",
            "/data/local/tmp/frida-gadget",
            "/system/bin/frida-server",
            "/system/xbin/frida-server",
            "/vendor/bin/frida-server",
        )

        for (path in fridaPaths) {
            if (File(path).exists()) {
                return false
            }
        }

        // 4b. Check if Frida default ports are open
        val fridaPorts = listOf(27042, 27043)
        for (port in fridaPorts) {
            if (isPortOpen("127.0.0.1", port)) {
                return false
            }
        }

        // 4c. Check running processes for Frida
        try {
            val process = Runtime.getRuntime().exec(arrayOf("ps", "-A"))
            val reader = BufferedReader(InputStreamReader(process.inputStream))
            var line: String?
            while (reader.readLine().also { line = it } != null) {
                val lower = line!!.lowercase()
                if (lower.contains("frida") || lower.contains("fridaserver")) {
                    reader.close()
                    process.waitFor()
                    return false
                }
            }
            reader.close()
            process.waitFor()
        } catch (_: Exception) {
            // Cannot list processes — ignore
        }

        // 4d. Check /proc/self/maps for Frida libraries
        try {
            val mapsFile = File("/proc/self/maps")
            if (mapsFile.canRead()) {
                val content = mapsFile.readText()
                val fridaIndicators = listOf(
                    "frida", "gadget", "frida-agent"
                )
                for (indicator in fridaIndicators) {
                    if (content.lowercase().contains(indicator)) {
                        return false
                    }
                }
            }
        } catch (_: Exception) {
            // Cannot read maps — ignore
        }

        return true
    }

    // -------------------------------------------------------------------------
    // 5. Hook framework detection (Xposed, etc.)
    // -------------------------------------------------------------------------

    /**
     * Detect Xposed Framework and similar hooking tools.
     *
     * Checks:
     * - Xposed bridge JAR on disk
     * - Xposed installer package
     * - Xposed-related classes loaded in the process
     * - EdXposed / LSPosed indicators
     */
    fun checkHooks(): Boolean {
        // 5a. Check for Xposed framework files
        val xposedPaths = listOf(
            "/system/framework/XposedBridge.jar",
            "/system/lib/libxposed_art.so",
            "/system/lib64/libxposed_art.so",
            "/system/xposed.prop",
            "/data/misc/riru/modules",
            "/data/adb/lspd",
        )

        for (path in xposedPaths) {
            if (File(path).exists()) {
                return false
            }
        }

        // 5b. Check for Xposed installer / manager packages
        val xposedPackages = listOf(
            "de.robv.android.xposed.installer",
            "org.meowcat.edxposed.manager",
            "org.lsposed.manager",
            "com.solohsu.android.edxp.manager",
            "io.github.lsposed.manager",
        )

        val ctx = appContext
        if (ctx != null) {
            val pm = ctx.packageManager
            for (pkg in xposedPackages) {
                try {
                    pm.getPackageInfo(pkg, 0)
                    return false
                } catch (_: Exception) {
                    // Not installed — good
                }
            }
        }

        // 5c. Check if Xposed classes are loaded in current process
        val xposedClasses = listOf(
            "de.robv.android.xposed.XposedBridge",
            "de.robv.android.xposed.XposedHelpers",
            "de.robv.android.xposed.XC_MethodHook",
        )

        for (className in xposedClasses) {
            try {
                Class.forName(className)
                return false // Class found — Xposed is active
            } catch (_: ClassNotFoundException) {
                // Not found — good
            }
        }

        // 5d. Check stack trace for Xposed methods
        try {
            val stackTrace = Thread.currentThread().stackTrace
            for (element in stackTrace) {
                val name = element.className + "." + element.methodName
                if (name.contains("xposed", ignoreCase = true)) {
                    return false
                }
            }
        } catch (_: Exception) {
            // Ignore
        }

        return true
    }

    // -------------------------------------------------------------------------
    // 6. App signing verification
    // -------------------------------------------------------------------------

    /**
     * Verifies the app's signing certificate hash against the expected value.
     * In debug builds, logs the hash for initial setup (copy it into EXPECTED_SIGNING_HASH).
     * In release builds, verifies against the hardcoded expected hash.
     */
    @Suppress("DEPRECATION")
    fun checkAppSignature(): Boolean {
        val context = appContext ?: return false // Fail-closed if not initialized

        return try {
            val pm = context.packageManager
            val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pm.getPackageInfo(context.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
                    .signingInfo?.signingCertificateHistory
            } else {
                pm.getPackageInfo(context.packageName, PackageManager.GET_SIGNATURES).signatures
            }

            if (signatures.isNullOrEmpty()) return false

            val md = MessageDigest.getInstance("SHA-256")
            val certHash = md.digest(signatures[0].toByteArray())
            val hashHex = certHash.joinToString("") { "%02x".format(it) }

            if (BuildConfig.DEBUG) {
                Log.d(TAG, "App signing cert hash: $hashHex (copy to EXPECTED_SIGNING_HASH for release)")
                return true
            }

            // Release: compare against expected signing certificate hash.
            // TODO: Replace EXPECTED_SIGNING_HASH with the actual SHA-256 hex digest
            //       of your release signing certificate (logged in debug builds above).
            if (EXPECTED_SIGNING_HASH.startsWith("PLACEHOLDER")) {
                Log.w(TAG, "No signing hash configured (OSS mode) — skipping signature check. " +
                    "Set EXPECTED_SIGNING_HASH for production builds.")
                return true
            }
            hashHex == EXPECTED_SIGNING_HASH
        } catch (_: Exception) {
            false // Fail-closed on error
        }
    }

    // -------------------------------------------------------------------------
    // 7. Screen lock detection
    // -------------------------------------------------------------------------

    /**
     * Returns true if the device has a screen lock (PIN, pattern, password, biometric).
     * This is an informational check, not a hard fail.
     */
    fun hasScreenLock(): Boolean {
        val context = appContext ?: return true
        val km = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            km.isDeviceSecure
        } else {
            @Suppress("DEPRECATION") km.isKeyguardSecure
        }
    }

    // -------------------------------------------------------------------------
    // 8. VPN detection
    // -------------------------------------------------------------------------

    /**
     * Returns true if a VPN transport is active.
     * This is informational (users may have legitimate VPNs).
     */
    fun isVpnActive(): Boolean {
        val context = appContext ?: return false
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        return caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /**
     * Check if a TCP port is open on the given host by attempting a connection
     * with a short timeout.
     */
    private fun isPortOpen(host: String, port: Int): Boolean {
        return try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress(host, port), 200)
                true
            }
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Terminate the process immediately via native __builtin_trap().
     * This compiles to an illegal instruction (brk #1 on ARM64, ud2 on x86)
     * which cannot be hooked or intercepted by Frida/Xposed.
     */
    fun secureExit() {
        NativeSecrets.secureExit()
    }
}
