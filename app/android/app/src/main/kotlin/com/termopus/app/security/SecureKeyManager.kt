package com.termopus.app.security

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.util.Base64
import android.util.Log
import android.security.keystore.KeyProperties
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.PublicKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Manages EC P-256 key pairs backed by Android KeyStore with StrongBox.
 *
 * The private key never leaves the hardware security module. All ECDH key
 * agreement and signing operations are performed inside the secure hardware.
 *
 * After ECDH, the raw shared secret is expanded with HKDF-SHA256 using
 * the application salt "claude-remote-v1" to produce a 32-byte AES key
 * suitable for [CryptoEngine].
 */
object SecureKeyManager {

    private const val TAG = "SecureKeyManager"
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val KEY_ALIAS = "app.clauderemote.session.key"
    private const val HKDF_SALT = "claude-remote-v1"
    private const val HKDF_OUTPUT_LENGTH = 32 // 256 bits for AES-256

    private val keyStore: KeyStore by lazy {
        KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
    }

    // -------------------------------------------------------------------------
    // Key pair generation
    // -------------------------------------------------------------------------

    /**
     * Generate an EC P-256 key pair inside StrongBox (or TEE as fallback).
     *
     * The key requires user authentication via [BiometricPrompt] before each
     * use because [setUserAuthenticationRequired] is enabled.
     *
     * @param attestationChallenge If non-null, enables Android Key Attestation.
     *   The challenge is embedded in the attestation certificate extension,
     *   binding the generated key to a server-issued challenge. The resulting
     *   certificate chain (leaf → intermediate → Google root CA) can be
     *   retrieved via [getAttestationCertChain].
     * @return the generated [KeyPair]
     * @throws KeyException if generation fails
     */
    @Throws(KeyException::class)
    fun generateKeyPair(attestationChallenge: ByteArray? = null): KeyPair {
        // Remove any previous key
        deleteKeyPair()

        try {
            val paramSpecBuilder = KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_AGREE_KEY or KeyProperties.PURPOSE_SIGN
            ).apply {
                setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                setDigests(KeyProperties.DIGEST_SHA256)

                // Require user authentication — key usable for 30s after biometric/PIN.
                // Uses validity-duration approach (not CryptoObject) to support KeyAgreement (ECDH).
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    // Android 11+: specify auth types explicitly
                    setUserAuthenticationRequired(true)
                    setUserAuthenticationParameters(
                        30,  // 30-second validity window
                        KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL
                    )
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    // Android 7-10: use legacy duration API
                    setUserAuthenticationRequired(true)
                    @Suppress("DEPRECATION")
                    setUserAuthenticationValidityDurationSeconds(30)
                }
                // Android <7: no biometric requirement (key is still hardware-backed)

                // Attestation challenge for Key Attestation cert chain
                if (attestationChallenge != null) {
                    setAttestationChallenge(attestationChallenge)
                }

                // Attempt StrongBox (hardware-backed secure element)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    setIsStrongBoxBacked(true)
                }
            }

            val keyPairGenerator = KeyPairGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_EC,
                ANDROID_KEYSTORE
            )

            return try {
                keyPairGenerator.initialize(paramSpecBuilder.build())
                keyPairGenerator.generateKeyPair()
            } catch (e: Exception) {
                // StrongBox may not be available on all devices – fall back to TEE.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    paramSpecBuilder.setIsStrongBoxBacked(false)
                    keyPairGenerator.initialize(paramSpecBuilder.build())
                    keyPairGenerator.generateKeyPair()
                } else {
                    throw e
                }
            }
        } catch (e: Exception) {
            throw KeyException("Failed to generate key pair", e)
        }
    }

    // -------------------------------------------------------------------------
    // Key Attestation
    // -------------------------------------------------------------------------

    /**
     * Returns the Key Attestation certificate chain as Base64-encoded DER certs.
     *
     * The chain is: [leaf cert with pubkey] -> [intermediate] -> [Google root CA].
     * The leaf certificate contains the Key Attestation extension
     * (OID 1.3.6.1.4.1.11129.2.1.17) with the attestation challenge,
     * security level, and other properties.
     *
     * Returns null if key attestation is not available (e.g. the key was
     * generated without an attestation challenge, or the device does not
     * support hardware attestation).
     */
    fun getAttestationCertChain(): List<String>? {
        return try {
            val chain = keyStore.getCertificateChain(KEY_ALIAS) ?: return null
            if (chain.size < 2) return null
            chain.map { Base64.encodeToString(it.encoded, Base64.NO_WRAP) }
        } catch (e: Exception) {
            Log.w(TAG, "Key attestation cert chain not available", e)
            null
        }
    }

    // -------------------------------------------------------------------------
    // Key retrieval
    // -------------------------------------------------------------------------

    /**
     * Retrieve the private key from Android KeyStore.
     *
     * Note: the actual private key material never leaves the secure hardware.
     * The returned [PrivateKey] is an opaque handle.
     */
    fun getPrivateKey(): PrivateKey? {
        return try {
            keyStore.getKey(KEY_ALIAS, null) as? PrivateKey
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Retrieve the public key from Android KeyStore.
     *
     * The public key bytes are safe to export and share with peers.
     */
    fun getPublicKey(): PublicKey? {
        return try {
            keyStore.getCertificate(KEY_ALIAS)?.publicKey
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Return the public key as a raw X9.63 uncompressed point (65 bytes: 0x04 || x || y).
     *
     * This format matches iOS `SecKeyCopyExternalRepresentation` and the Rust bridge,
     * ensuring cross-platform compatibility for ECDH key exchange.
     *
     * Internally strips the X.509 SPKI DER wrapper to extract the raw EC point.
     */
    fun getPublicKeyBytes(): ByteArray? {
        val publicKey = getPublicKey()
        if (publicKey == null) {
            Log.e(TAG, "getPublicKeyBytes: getPublicKey() returned null")
            return null
        }
        val rawPoint = extractRawECPoint(publicKey.encoded)
        if (rawPoint == null) {
            Log.e(TAG, "getPublicKeyBytes: extractRawECPoint() returned null for ${publicKey.encoded.size} byte key")
        } else {
            Log.d(TAG, "getPublicKeyBytes: success, ${rawPoint.size} bytes")
        }
        return rawPoint
    }

    /**
     * Return the X.509 SPKI DER-encoded bytes of the public key, or null if unavailable.
     *
     * Use [getPublicKeyBytes] for cross-platform compatible format.
     */
    fun getPublicKeyDerBytes(): ByteArray? {
        return getPublicKey()?.encoded
    }

    /**
     * Derive a stable device identifier from SHA-256(SPKI) of the hardware-backed public key.
     *
     * On Android, [getPublicKey]?.encoded already returns the X.509 SubjectPublicKeyInfo
     * DER encoding, so we hash it directly. The result is a 64-character lowercase hex
     * string that is identical to the iOS derivation for the same key material.
     *
     * @return 64-char hex string, or null if the key is unavailable.
     */
    fun getDeviceId(): String? {
        val spkiBytes = getPublicKeyDerBytes() ?: return null
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        val hash = digest.digest(spkiBytes)
        return hash.joinToString("") { "%02x".format(it) }
    }

    /**
     * Extract the raw EC point from an X.509 SubjectPublicKeyInfo DER encoding.
     *
     * SPKI for EC keys has the structure:
     *   SEQUENCE {
     *     SEQUENCE { OID(ecPublicKey), OID(curve) }
     *     BIT STRING { 0x00 (unused bits), 0x04 || x || y }
     *   }
     *
     * We extract the BIT STRING content (skipping the unused-bits byte) to get
     * the raw uncompressed point (65 bytes for P-256).
     */
    private fun extractRawECPoint(spkiDer: ByteArray): ByteArray? {
        try {
            // Find the BIT STRING tag (0x03) which contains the public key point.
            // In a P-256 SPKI, the BIT STRING is the last TLV in the outer SEQUENCE.
            // Walk the ASN.1 structure to find it.
            var offset = 0

            // Outer SEQUENCE
            if (spkiDer[offset].toInt() != 0x30) return null
            offset++
            offset += skipASN1Length(spkiDer, offset)

            // Inner SEQUENCE (AlgorithmIdentifier) — skip it
            if (spkiDer[offset].toInt() != 0x30) return null
            offset++
            val innerLen = readASN1Length(spkiDer, offset)
            offset += lengthOfLengthField(spkiDer, offset) + innerLen

            // BIT STRING containing the public key
            if (spkiDer[offset].toInt() != 0x03) return null
            offset++
            val bitStringLen = readASN1Length(spkiDer, offset)
            offset += lengthOfLengthField(spkiDer, offset)

            // Skip the unused-bits byte (should be 0x00)
            if (spkiDer[offset].toInt() != 0x00) return null
            offset++

            // The remaining bytes are the raw EC point
            val pointLen = bitStringLen - 1
            return spkiDer.copyOfRange(offset, offset + pointLen)
        } catch (_: Exception) {
            return null
        }
    }

    /**
     * Build an X.509 SPKI DER encoding from a raw X9.63 uncompressed EC point.
     *
     * This wraps the raw point (0x04 || x || y) in the SPKI structure
     * so it can be imported via [KeyFactory] with [X509EncodedKeySpec].
     */
    private fun wrapRawECPointInSPKI(rawPoint: ByteArray): ByteArray {
        // OID for ecPublicKey: 1.2.840.10045.2.1
        val ecPublicKeyOid = byteArrayOf(
            0x06, 0x07,
            0x2A, 0x86.toByte(), 0x48, 0xCE.toByte(), 0x3D, 0x02, 0x01
        )
        // OID for prime256v1 (P-256): 1.2.840.10045.3.1.7
        val prime256v1Oid = byteArrayOf(
            0x06, 0x08,
            0x2A, 0x86.toByte(), 0x48, 0xCE.toByte(), 0x3D, 0x03, 0x01, 0x07
        )

        // AlgorithmIdentifier SEQUENCE
        val algIdContent = ecPublicKeyOid + prime256v1Oid
        val algId = byteArrayOf(0x30, algIdContent.size.toByte()) + algIdContent

        // BIT STRING: unused-bits byte (0x00) + raw point
        val bitStringContent = byteArrayOf(0x00) + rawPoint
        val bitString = byteArrayOf(0x03, bitStringContent.size.toByte()) + bitStringContent

        // Outer SEQUENCE
        val outerContent = algId + bitString
        return byteArrayOf(0x30, outerContent.size.toByte()) + outerContent
    }

    private fun readASN1Length(data: ByteArray, offset: Int): Int {
        val firstByte = data[offset].toInt() and 0xFF
        return if (firstByte < 0x80) {
            firstByte
        } else {
            val numBytes = firstByte and 0x7F
            var length = 0
            for (i in 1..numBytes) {
                length = (length shl 8) or (data[offset + i].toInt() and 0xFF)
            }
            length
        }
    }

    private fun lengthOfLengthField(data: ByteArray, offset: Int): Int {
        val firstByte = data[offset].toInt() and 0xFF
        return if (firstByte < 0x80) 1 else 1 + (firstByte and 0x7F)
    }

    private fun skipASN1Length(data: ByteArray, offset: Int): Int {
        return lengthOfLengthField(data, offset)
    }

    // -------------------------------------------------------------------------
    // ECDH key agreement + HKDF derivation
    // -------------------------------------------------------------------------

    /**
     * Perform ECDH key agreement with the peer's public key, then derive a
     * 32-byte AES key via HKDF-SHA256.
     *
     * @param peerPublicKeyBytes Peer's EC public key. Accepts either:
     *   - Raw X9.63 uncompressed format (65 bytes: 0x04 || x || y)
     *   - X.509 SPKI DER encoding (~91 bytes)
     * @return 32-byte derived symmetric key
     * @throws KeyException if agreement or derivation fails
     */
    @Throws(KeyException::class)
    fun deriveSharedSecret(peerPublicKeyBytes: ByteArray): ByteArray {
        val privateKey = getPrivateKey()
            ?: throw KeyException("No private key in KeyStore")

        try {
            // Determine if the input is raw X9.63 or X.509 SPKI DER.
            // Raw X9.63 uncompressed P-256 keys are exactly 65 bytes starting with 0x04.
            // SPKI DER keys start with 0x30 (SEQUENCE tag).
            val spkiBytes = if (peerPublicKeyBytes.size == 65 && peerPublicKeyBytes[0] == 0x04.toByte()) {
                wrapRawECPointInSPKI(peerPublicKeyBytes)
            } else {
                peerPublicKeyBytes
            }

            // Re-construct peer public key from X.509 SPKI encoding
            val keyFactory = KeyFactory.getInstance("EC")
            val peerPublicKey = keyFactory.generatePublic(
                X509EncodedKeySpec(spkiBytes)
            )

            // ECDH key agreement (performed inside secure hardware)
            val keyAgreement = KeyAgreement.getInstance("ECDH", ANDROID_KEYSTORE)
            keyAgreement.init(privateKey)
            keyAgreement.doPhase(peerPublicKey, true)
            val rawSharedSecret = keyAgreement.generateSecret()

            // Expand with HKDF-SHA256, then zeroize the raw shared secret
            try {
                return hkdfSha256(
                    ikm = rawSharedSecret,
                    salt = HKDF_SALT.toByteArray(Charsets.UTF_8),
                    info = "claude-remote-session".toByteArray(Charsets.UTF_8),
                    outputLength = HKDF_OUTPUT_LENGTH
                )
            } finally {
                rawSharedSecret.fill(0)
            }
        } catch (e: android.security.keystore.UserNotAuthenticatedException) {
            throw KeyException("USER_NOT_AUTHENTICATED", e)
        } catch (e: Exception) {
            throw KeyException("ECDH key agreement failed", e)
        }
    }

    // -------------------------------------------------------------------------
    // Ephemeral ECDH (per-session forward secrecy)
    // -------------------------------------------------------------------------

    /**
     * Generates an ephemeral P-256 key pair in memory (NOT in Android KeyStore).
     * Returns Pair(privateKey, publicKeyX963Bytes).
     *
     * The ephemeral private key is used once for ECDH and then discarded.
     * Only the derived AES key is persisted. This provides forward secrecy:
     * compromising the permanent KeyStore key does not reveal past session keys.
     */
    fun generateEphemeralKeyPair(): Pair<java.security.PrivateKey, ByteArray> {
        val kpg = KeyPairGenerator.getInstance("EC")
        kpg.initialize(ECGenParameterSpec("secp256r1"))
        val kp = kpg.generateKeyPair()

        val rawPoint = extractRawECPoint(kp.public.encoded)
            ?: throw KeyException("Failed to extract raw EC point from ephemeral key")

        return Pair(kp.private, rawPoint)
    }

    /**
     * Performs ECDH using an ephemeral private key with a peer public key.
     * Returns 32-byte derived AES key via HKDF.
     *
     * IMPORTANT: Uses standard JCE ECDH (NOT Android KeyStore provider).
     * Ephemeral keys are plain in-memory keys, not hardware-backed.
     *
     * @param ephemeralPrivateKey The ephemeral private key (in-memory, NOT KeyStore)
     * @param peerPublicKeyBytes Peer's EC public key. Accepts either:
     *   - Raw X9.63 uncompressed format (65 bytes: 0x04 || x || y)
     *   - X.509 SPKI DER encoding (~91 bytes)
     * @return 32-byte derived symmetric key
     * @throws KeyException if agreement or derivation fails
     */
    @Throws(KeyException::class)
    fun deriveSharedSecretEphemeral(
        ephemeralPrivateKey: java.security.PrivateKey,
        peerPublicKeyBytes: ByteArray,
    ): ByteArray {
        try {
            // Determine if input is raw X9.63 or SPKI
            val spkiBytes = if (peerPublicKeyBytes.size == 65 && peerPublicKeyBytes[0] == 0x04.toByte()) {
                wrapRawECPointInSPKI(peerPublicKeyBytes)
            } else {
                peerPublicKeyBytes
            }

            val keyFactory = KeyFactory.getInstance("EC")
            val peerPublicKey = keyFactory.generatePublic(X509EncodedKeySpec(spkiBytes))

            // Use standard JCE ECDH (NOT Android KeyStore provider — ephemeral key is in memory)
            val ka = KeyAgreement.getInstance("ECDH")
            ka.init(ephemeralPrivateKey)
            ka.doPhase(peerPublicKey, true)
            val rawSecret = ka.generateSecret()

            // Expand with HKDF-SHA256, then zeroize the raw shared secret
            try {
                return hkdfSha256(
                    ikm = rawSecret,
                    salt = HKDF_SALT.toByteArray(Charsets.UTF_8),
                    info = "claude-remote-session".toByteArray(Charsets.UTF_8),
                    outputLength = HKDF_OUTPUT_LENGTH
                )
            } finally {
                rawSecret.fill(0)
            }
        } catch (e: android.security.keystore.UserNotAuthenticatedException) {
            throw KeyException("USER_NOT_AUTHENTICATED", e)
        } catch (e: Exception) {
            throw KeyException("Ephemeral ECDH key agreement failed", e)
        }
    }

    // -------------------------------------------------------------------------
    // Session AES key persistence (for reconnect after app kill)
    // -------------------------------------------------------------------------

    private const val ENCRYPTED_PREFS_NAME = "termopus_session_keys"
    private const val KEY_SESSION_AES_PREFIX = "session_aes_"

    /**
     * Get or create EncryptedSharedPreferences for session key storage.
     *
     * Uses AndroidX Security EncryptedSharedPreferences backed by a
     * MasterKey in AES256-GCM mode. Keys are encrypted with AES256-SIV
     * and values with AES256-GCM.
     */
    private fun getEncryptedPrefs(context: android.content.Context): android.content.SharedPreferences {
        val masterKey = androidx.security.crypto.MasterKey.Builder(context)
            .setKeyScheme(androidx.security.crypto.MasterKey.KeyScheme.AES256_GCM)
            .build()
        return androidx.security.crypto.EncryptedSharedPreferences.create(
            context,
            ENCRYPTED_PREFS_NAME,
            masterKey,
            androidx.security.crypto.EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            androidx.security.crypto.EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    /**
     * Persist the derived AES session key in EncryptedSharedPreferences.
     *
     * This allows reconnecting to an existing session after the app is killed
     * without requiring a full re-pairing (ephemeral ECDH exchange).
     */
    fun persistSessionKey(context: android.content.Context, sessionId: String, key: ByteArray) {
        val prefs = getEncryptedPrefs(context)
        prefs.edit().putString(
            KEY_SESSION_AES_PREFIX + sessionId,
            android.util.Base64.encodeToString(key, android.util.Base64.NO_WRAP)
        ).apply()
    }

    /**
     * Load a persisted AES session key.
     *
     * @return The 32-byte AES key, or null if no key is persisted for this session.
     */
    fun loadSessionKey(context: android.content.Context, sessionId: String): ByteArray? {
        return try {
            val prefs = getEncryptedPrefs(context)
            val b64 = prefs.getString(KEY_SESSION_AES_PREFIX + sessionId, null) ?: return null
            android.util.Base64.decode(b64, android.util.Base64.NO_WRAP)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load session key for $sessionId", e)
            null
        }
    }

    /**
     * Delete a persisted session key.
     *
     * Called during session cleanup (session.clearData, session.delete).
     */
    fun deleteSessionKey(context: android.content.Context, sessionId: String) {
        try {
            val prefs = getEncryptedPrefs(context)
            prefs.edit().remove(KEY_SESSION_AES_PREFIX + sessionId).apply()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to delete session key for $sessionId", e)
        }
    }

    // -------------------------------------------------------------------------
    // Signing
    // -------------------------------------------------------------------------

    /**
     * Sign [data] with ECDSA-SHA256 using the KeyStore private key.
     *
     * @return DER-encoded ECDSA signature
     * @throws KeyException if no key is available or signing fails
     */
    @Throws(KeyException::class)
    fun sign(data: ByteArray): ByteArray {
        val privateKey = getPrivateKey()
            ?: throw KeyException("No private key in KeyStore")

        return try {
            val signature = Signature.getInstance("SHA256withECDSA")
            signature.initSign(privateKey)
            signature.update(data)
            signature.sign()
        } catch (e: android.security.keystore.UserNotAuthenticatedException) {
            throw KeyException("USER_NOT_AUTHENTICATED", e)
        } catch (e: Exception) {
            throw KeyException("Signing failed", e)
        }
    }

    // -------------------------------------------------------------------------
    // Deletion
    // -------------------------------------------------------------------------

    /**
     * Delete the key pair from Android KeyStore.
     */
    fun deleteKeyPair() {
        try {
            if (keyStore.containsAlias(KEY_ALIAS)) {
                keyStore.deleteEntry(KEY_ALIAS)
            }
        } catch (_: Exception) {
            // Best-effort deletion
        }
    }

    /**
     * Check whether a key pair exists in the KeyStore.
     */
    fun hasKeyPair(): Boolean {
        return try {
            keyStore.containsAlias(KEY_ALIAS)
        } catch (_: Exception) {
            false
        }
    }

    // -------------------------------------------------------------------------
    // HKDF-SHA256 (RFC 5869)
    // -------------------------------------------------------------------------

    /**
     * HKDF-SHA256 implementation (Extract-then-Expand).
     *
     * We implement this manually because Android's [javax.crypto.SecretKeyFactory]
     * does not expose HKDF on all API levels.
     */
    private fun hkdfSha256(
        ikm: ByteArray,
        salt: ByteArray,
        info: ByteArray,
        outputLength: Int
    ): ByteArray {
        // Step 1: Extract — PRK = HMAC-SHA256(salt, IKM)
        val prk = hmacSha256(
            key = if (salt.isEmpty()) ByteArray(32) else salt,
            data = ikm
        )

        var previousT = ByteArray(0)
        try {
            // Step 2: Expand — T(1) || T(2) || ... where T(i) = HMAC-SHA256(PRK, T(i-1) || info || i)
            val hashLength = 32 // SHA-256 output
            val n = (outputLength + hashLength - 1) / hashLength
            require(n <= 255) { "HKDF output too long" }

            val okm = ByteArray(outputLength)
            var offset = 0

            for (i in 1..n) {
                val hmacInput = previousT + info + byteArrayOf(i.toByte())
                val oldT = previousT
                previousT = hmacSha256(key = prk, data = hmacInput)
                oldT.fill(0) // Zeroize previous HMAC output
                val copyLength = minOf(hashLength, outputLength - offset)
                System.arraycopy(previousT, 0, okm, offset, copyLength)
                offset += copyLength
            }

            return okm
        } finally {
            previousT.fill(0) // Zeroize final HMAC output
            prk.fill(0)
        }
    }

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    // -------------------------------------------------------------------------
    // Exception
    // -------------------------------------------------------------------------

    class KeyException : Exception {
        constructor(message: String) : super(message)
        constructor(message: String, cause: Throwable) : super(message, cause)
    }
}
