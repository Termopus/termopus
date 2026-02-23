package com.termopus.app.security

import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity

/**
 * Gate that controls biometric authentication using [androidx.biometric].
 *
 * All operations delegate to [BiometricManager] and [BiometricPrompt] from
 * the AndroidX biometric library, which internally handles Face, Fingerprint,
 * and Iris authentication across OEM implementations.
 *
 * Usage:
 * ```
 * if (BiometricGate.isAvailable(activity)) {
 *     BiometricGate.authenticate(activity, "Unlock session") { success, error ->
 *         if (success) { /* proceed */ }
 *     }
 * }
 * ```
 */
object BiometricGate {

    /**
     * Types of biometric hardware that may be present on the device.
     */
    enum class BiometricType {
        NONE,
        FINGERPRINT,
        FACE,
        IRIS,
        UNKNOWN
    }

    // -------------------------------------------------------------------------
    // Availability checks
    // -------------------------------------------------------------------------

    /**
     * Check whether strong biometric authentication is available and enrolled.
     *
     * @return `true` if [BIOMETRIC_STRONG] hardware is present, the user has
     *         enrolled at least one biometric, and the feature is not disabled.
     */
    fun isAvailable(activity: FragmentActivity): Boolean {
        val biometricManager = BiometricManager.from(activity)
        return biometricManager.canAuthenticate(BIOMETRIC_STRONG) ==
                BiometricManager.BIOMETRIC_SUCCESS
    }

    /**
     * Detailed status of biometric availability.
     *
     * Useful for presenting context-specific error messages in the UI.
     *
     * @return one of the [BiometricManager] `BIOMETRIC_*` result codes
     */
    fun getAvailabilityStatus(activity: FragmentActivity): Int {
        val biometricManager = BiometricManager.from(activity)
        return biometricManager.canAuthenticate(BIOMETRIC_STRONG)
    }

    /**
     * Determine which biometric type is available.
     *
     * Android does not expose a direct API for querying the biometric type in
     * the same way iOS does (`biometryType`). We inspect the package manager
     * feature flags as a best-effort heuristic.
     */
    fun getBiometricType(activity: FragmentActivity): BiometricType {
        if (!isAvailable(activity)) return BiometricType.NONE

        val pm = activity.packageManager
        return when {
            pm.hasSystemFeature("android.hardware.fingerprint") -> BiometricType.FINGERPRINT
            pm.hasSystemFeature("android.hardware.biometrics.face") -> BiometricType.FACE
            pm.hasSystemFeature("android.hardware.biometrics.iris") -> BiometricType.IRIS
            else -> BiometricType.UNKNOWN
        }
    }

    // -------------------------------------------------------------------------
    // Authentication
    // -------------------------------------------------------------------------

    /**
     * Display the system biometric prompt and authenticate the user.
     *
     * @param activity   a [FragmentActivity] (required for [BiometricPrompt])
     * @param reason     the user-visible subtitle explaining why auth is needed
     * @param callback   invoked on the main thread with `(success, errorMessage)`
     */
    fun authenticate(
        activity: FragmentActivity,
        reason: String,
        callback: (success: Boolean, error: String?) -> Unit
    ) {
        val executor = ContextCompat.getMainExecutor(activity)

        val authCallback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                super.onAuthenticationSucceeded(result)
                callback(true, null)
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                super.onAuthenticationError(errorCode, errString)
                callback(false, errString.toString())
            }

            override fun onAuthenticationFailed() {
                super.onAuthenticationFailed()
                // Called on each failed attempt (e.g. wrong finger). The prompt
                // remains visible; the system will eventually trigger
                // onAuthenticationError if the user exhausts attempts or cancels.
            }
        }

        val biometricPrompt = BiometricPrompt(activity, executor, authCallback)

        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Claude Code Remote")
            .setSubtitle(reason)
            .setNegativeButtonText("Cancel")
            .setAllowedAuthenticators(BIOMETRIC_STRONG)
            .setConfirmationRequired(false)
            .build()

        biometricPrompt.authenticate(promptInfo)
    }

    /**
     * Authenticate with a [CryptoObject] so that the KeyStore key can be
     * unlocked by biometric authentication.
     *
     * This is used when a KeyStore key was created with
     * `setUserAuthenticationRequired(true)`.
     *
     * @param activity     a [FragmentActivity]
     * @param reason       subtitle for the prompt
     * @param cryptoObject the cipher/signature to unlock
     * @param callback     invoked with `(authResult, errorMessage)`
     */
    fun authenticateWithCrypto(
        activity: FragmentActivity,
        reason: String,
        cryptoObject: BiometricPrompt.CryptoObject,
        callback: (result: BiometricPrompt.AuthenticationResult?, error: String?) -> Unit
    ) {
        val executor = ContextCompat.getMainExecutor(activity)

        val authCallback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                super.onAuthenticationSucceeded(result)
                callback(result, null)
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                super.onAuthenticationError(errorCode, errString)
                callback(null, errString.toString())
            }

            override fun onAuthenticationFailed() {
                super.onAuthenticationFailed()
                // Prompt stays visible; system handles retry / lockout.
            }
        }

        val biometricPrompt = BiometricPrompt(activity, executor, authCallback)

        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Claude Code Remote")
            .setSubtitle(reason)
            .setNegativeButtonText("Cancel")
            .setAllowedAuthenticators(BIOMETRIC_STRONG)
            .setConfirmationRequired(false)
            .build()

        biometricPrompt.authenticate(promptInfo, cryptoObject)
    }
}
