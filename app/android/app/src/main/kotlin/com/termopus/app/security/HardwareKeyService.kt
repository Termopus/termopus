package com.termopus.app.security

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Silent at-rest encryption using hardware-backed AES-256-GCM.
 * NO biometric prompt required — keys are accessible whenever the device is unlocked.
 * Used for encrypting stored tokens, cached session data, and preference values.
 */
class HardwareKeyService {
    companion object {
        private const val KEY_ALIAS = "com.termopus.hardware.encryption.key"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_LENGTH = 128
        private const val GCM_IV_LENGTH = 12
    }

    /** Generate AES-256 key in AndroidKeyStore. StrongBox if available, TEE fallback. */
    fun initialize() {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE)
        ks.load(null)
        if (ks.containsAlias(KEY_ALIAS)) return

        val specBuilder = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            // No user authentication required — silent encryption
            .setUserAuthenticationRequired(false)

        // Try StrongBox, fall back to TEE
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                specBuilder.setIsStrongBoxBacked(true)
            }
            val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
            kg.init(specBuilder.build())
            kg.generateKey()
        } catch (_: Exception) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                specBuilder.setIsStrongBoxBacked(false)
            }
            val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
            kg.init(specBuilder.build())
            kg.generateKey()
        }
    }

    /** Encrypt data. Returns IV (12 bytes) + ciphertext + GCM tag. */
    fun encrypt(data: ByteArray): ByteArray {
        val key = getKey()
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val iv = cipher.iv
        val encrypted = cipher.doFinal(data)
        // Prepend IV to ciphertext
        return iv + encrypted
    }

    /** Decrypt data. Expects IV (12 bytes) + ciphertext + GCM tag. */
    fun decrypt(encryptedData: ByteArray): ByteArray {
        require(encryptedData.size > GCM_IV_LENGTH) { "Data too short" }
        val iv = encryptedData.copyOfRange(0, GCM_IV_LENGTH)
        val ciphertext = encryptedData.copyOfRange(GCM_IV_LENGTH, encryptedData.size)

        val key = getKey()
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_LENGTH, iv))
        return cipher.doFinal(ciphertext)
    }

    private fun getKey(): SecretKey {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE)
        ks.load(null)
        val entry = ks.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry
            ?: throw IllegalStateException("Hardware encryption key not found")
        return entry.secretKey
    }
}
