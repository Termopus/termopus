package com.termopus.app.security

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricPrompt
import androidx.fragment.app.FragmentActivity
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.security.spec.ECGenParameterSpec

class BiometricCryptoService(private val activity: FragmentActivity) {
    companion object {
        private const val KEY_ALIAS = "com.termopus.biometric.signing.key"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    }

    enum class Error {
        KEY_GENERATION_FAILED,
        KEY_NOT_FOUND,
        SIGNING_FAILED,
        BIOMETRIC_FAILED,
    }

    /** Generate EC P-256 key in AndroidKeyStore with biometric requirement. */
    fun initialize() {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE)
        ks.load(null)
        if (ks.containsAlias(KEY_ALIAS)) return

        val specBuilder = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
        )
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            specBuilder.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        }

        // Try StrongBox first, fall back to TEE
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                specBuilder.setIsStrongBoxBacked(true)
            }
            val kpg = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, ANDROID_KEYSTORE)
            kpg.initialize(specBuilder.build())
            kpg.generateKeyPair()
        } catch (_: Exception) {
            // StrongBox not available, try TEE
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                specBuilder.setIsStrongBoxBacked(false)
            }
            val kpg = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, ANDROID_KEYSTORE)
            kpg.initialize(specBuilder.build())
            kpg.generateKeyPair()
        }
    }

    /**
     * Sign a challenge with the biometric-protected key.
     * Delegates to BiometricGate.authenticateWithCrypto() for prompt display.
     */
    fun signChallenge(
        challengeBase64: String,
        reason: String,
        callback: (Result<String>) -> Unit
    ) {
        val challengeData = try {
            Base64.decode(challengeBase64, Base64.NO_WRAP)
        } catch (_: Exception) {
            callback(Result.failure(IllegalArgumentException("Invalid Base64 challenge")))
            return
        }

        val ks = KeyStore.getInstance(ANDROID_KEYSTORE)
        ks.load(null)
        val entry = ks.getEntry(KEY_ALIAS, null) as? KeyStore.PrivateKeyEntry
        if (entry == null) {
            callback(Result.failure(IllegalStateException("Biometric signing key not found")))
            return
        }

        val signature = Signature.getInstance("SHA256withECDSA")
        signature.initSign(entry.privateKey)

        val cryptoObject = BiometricPrompt.CryptoObject(signature)

        BiometricGate.authenticateWithCrypto(activity, reason, cryptoObject) { authResult, error ->
            if (error != null) {
                callback(Result.failure(SecurityException("Biometric auth failed: $error")))
                return@authenticateWithCrypto
            }

            val authedSignature = authResult?.cryptoObject?.signature
            if (authedSignature == null) {
                callback(Result.failure(SecurityException("No signature from biometric auth")))
                return@authenticateWithCrypto
            }

            try {
                authedSignature.update(challengeData)
                val signed = authedSignature.sign()
                val signedBase64 = Base64.encodeToString(signed, Base64.NO_WRAP)
                callback(Result.success(signedBase64))
            } catch (e: Exception) {
                callback(Result.failure(e))
            }
        }
    }

    /** Get public key in X9.63 uncompressed format. */
    fun getPublicKey(): ByteArray {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE)
        ks.load(null)
        val entry = ks.getEntry(KEY_ALIAS, null) as? KeyStore.PrivateKeyEntry
            ?: throw IllegalStateException("Biometric signing key not found")
        return entry.certificate.publicKey.encoded
    }
}
