package com.termopus.app.security

import java.security.SecureRandom
import java.util.concurrent.locks.ReentrantLock
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.concurrent.withLock

/**
 * Symmetric encryption engine using AES-256-GCM.
 *
 * Wire format (matches the iOS [CryptoEngine] exactly):
 * ```
 *   [IV: 12 bytes] [Ciphertext: N bytes] [GCM Tag: 16 bytes]
 * ```
 *
 * The GCM tag is appended automatically by [Cipher] when using
 * `AES/GCM/NoPadding`; the tag length is configured to 128 bits.
 *
 * Thread-safety: a [ReentrantLock] protects all compound operations
 * on [sessionKeys] and [activeSessionId]. Each encrypt/decrypt call
 * obtains a [ThreadLocal]-cached [Cipher] instance after resolving
 * the key under the lock, so concurrent calls from different threads
 * are safe (each thread reuses its own Cipher, avoiding JCA provider
 * lookup overhead on every call).
 */
object CryptoEngine {

    private const val AES_GCM_TRANSFORMATION = "AES/GCM/NoPadding"
    private const val AES_KEY_ALGORITHM = "AES"
    private const val IV_LENGTH_BYTES = 12
    private const val GCM_TAG_LENGTH_BITS = 128
    private const val GCM_TAG_LENGTH_BYTES = GCM_TAG_LENGTH_BITS / 8 // 16
    private const val MINIMUM_CIPHERTEXT_LENGTH = IV_LENGTH_BYTES + GCM_TAG_LENGTH_BYTES // 28

    private val secureRandom = SecureRandom()

    /**
     * ThreadLocal cache for [Cipher] instances to avoid repeated
     * [Cipher.getInstance] lookups (JCA provider resolution overhead).
     *
     * ThreadLocal is the correct choice here because [Cipher] is not
     * thread-safe, and OkHttp callbacks may arrive on different threads.
     * Each thread gets its own instance, reused across encrypt/decrypt calls.
     */
    private val cipherCache = ThreadLocal<Cipher>()

    private fun getCipher(): Cipher {
        return cipherCache.get() ?: Cipher.getInstance(AES_GCM_TRANSFORMATION).also {
            cipherCache.set(it)
        }
    }

    /** Lock protecting all compound operations on [sessionKeys] + [activeSessionId]. */
    private val lock = ReentrantLock()

    /** Per-session symmetric keys derived from ECDH + HKDF. */
    private val sessionKeys = HashMap<String, SecretKey>()

    /** The currently active session whose key is used for encrypt/decrypt. */
    var activeSessionId: String? = null
        private set

    // -------------------------------------------------------------------------
    // Key management
    // -------------------------------------------------------------------------

    /**
     * Set the shared secret for a specific session.
     *
     * @param sessionId  identifier for the session
     * @param keyBytes   32-byte AES-256 key
     * @throws CryptoException if the key length is invalid
     */
    @Throws(CryptoException::class)
    fun setSharedSecret(sessionId: String, keyBytes: ByteArray) {
        if (keyBytes.size != 32) {
            throw CryptoException("AES-256 key must be exactly 32 bytes, got ${keyBytes.size}")
        }
        lock.withLock {
            sessionKeys[sessionId] = SecretKeySpec(keyBytes, AES_KEY_ALGORITHM)
            activeSessionId = sessionId
        }
    }

    /**
     * Set the shared secret for the active (or default) session.
     *
     * @param keyBytes 32-byte AES-256 key
     * @throws CryptoException if the key length is invalid
     */
    @Deprecated(
        message = "Use setSharedSecret(sessionId, keyBytes) for session isolation",
        replaceWith = ReplaceWith("setSharedSecret(sessionId, keyBytes)")
    )
    @Throws(CryptoException::class)
    fun setSharedSecret(keyBytes: ByteArray) {
        val sid = activeSessionId ?: "_default"
        setSharedSecret(sid, keyBytes)
    }

    /**
     * Switch the active session. The session must already have a key stored.
     *
     * @return `true` if the session exists and was activated, `false` otherwise
     */
    fun setActiveSession(sessionId: String): Boolean = lock.withLock {
        if (!sessionKeys.containsKey(sessionId)) return@withLock false
        activeSessionId = sessionId
        true
    }

    /**
     * Remove the key for a specific session.
     *
     * If the cleared session is the active session, [activeSessionId] is set
     * to `null`.
     */
    fun clearKey(sessionId: String) = lock.withLock {
        sessionKeys.remove(sessionId)
        if (activeSessionId == sessionId) {
            activeSessionId = null
        }
    }

    /**
     * Securely clear all session keys.
     *
     * After calling this, all encrypt/decrypt operations will fail until
     * a new shared secret is set.
     */
    fun clearAllKeys() = lock.withLock {
        sessionKeys.clear()
        activeSessionId = null
    }

    /**
     * Securely clear the active session's key.
     *
     * After calling this, all encrypt/decrypt operations will fail until
     * a new shared secret is set.
     */
    @Deprecated(
        message = "Use clearKey(sessionId) or clearAllKeys() for session isolation",
        replaceWith = ReplaceWith("clearAllKeys()")
    )
    fun clearKey() = lock.withLock {
        val sid = activeSessionId
        if (sid != null) {
            sessionKeys.remove(sid)
            activeSessionId = null
        } else {
            sessionKeys.clear()
            activeSessionId = null
        }
    }

    /**
     * Check whether a specific session has a key stored.
     */
    fun hasKey(sessionId: String): Boolean = lock.withLock {
        sessionKeys.containsKey(sessionId)
    }

    /**
     * Check whether the active session has a shared secret set.
     */
    fun hasKey(): Boolean = lock.withLock {
        val sid = activeSessionId ?: return@withLock false
        sessionKeys.containsKey(sid)
    }

    // -------------------------------------------------------------------------
    // Raw byte encryption / decryption
    // -------------------------------------------------------------------------

    /**
     * Encrypt [plaintext] using AES-256-GCM with the active session's key.
     *
     * @return `iv (12 bytes) || ciphertext || tag (16 bytes)`
     * @throws CryptoException if no key is set or encryption fails
     */
    @Throws(CryptoException::class)
    fun encrypt(plaintext: ByteArray): ByteArray {
        val key = activeKey()

        return try {
            // Generate a cryptographically random 12-byte IV
            val iv = ByteArray(IV_LENGTH_BYTES)
            secureRandom.nextBytes(iv)

            val cipher = getCipher()
            val spec = GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv)
            cipher.init(Cipher.ENCRYPT_MODE, key, spec)

            // Cipher.doFinal appends the GCM authentication tag to the ciphertext
            val ciphertextWithTag = cipher.doFinal(plaintext)

            // Prepend the IV: [IV (12)] [ciphertext + tag]
            val result = ByteArray(IV_LENGTH_BYTES + ciphertextWithTag.size)
            System.arraycopy(iv, 0, result, 0, IV_LENGTH_BYTES)
            System.arraycopy(ciphertextWithTag, 0, result, IV_LENGTH_BYTES, ciphertextWithTag.size)
            result
        } catch (e: CryptoException) {
            throw e
        } catch (e: Exception) {
            throw CryptoException("Encryption failed", e)
        }
    }

    /**
     * Decrypt [ciphertext] produced by [encrypt] using the active session's key.
     *
     * @param ciphertext `iv (12 bytes) || ciphertext || tag (16 bytes)`
     * @return the original plaintext bytes
     * @throws CryptoException if decryption or authentication fails
     */
    @Throws(CryptoException::class)
    fun decrypt(ciphertext: ByteArray): ByteArray {
        val key = activeKey()

        if (ciphertext.size < MINIMUM_CIPHERTEXT_LENGTH) {
            throw CryptoException(
                "Ciphertext too short: ${ciphertext.size} bytes " +
                "(minimum $MINIMUM_CIPHERTEXT_LENGTH)"
            )
        }

        return try {
            // Split: [IV (12)] [ciphertext + tag]
            val iv = ciphertext.copyOfRange(0, IV_LENGTH_BYTES)
            val encryptedWithTag = ciphertext.copyOfRange(IV_LENGTH_BYTES, ciphertext.size)

            val cipher = getCipher()
            val spec = GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv)
            cipher.init(Cipher.DECRYPT_MODE, key, spec)

            cipher.doFinal(encryptedWithTag)
        } catch (e: CryptoException) {
            throw e
        } catch (e: javax.crypto.AEADBadTagException) {
            throw CryptoException("GCM authentication failed — data may be tampered", e)
        } catch (e: Exception) {
            throw CryptoException("Decryption failed", e)
        }
    }

    // -------------------------------------------------------------------------
    // Session-explicit encryption / decryption
    // -------------------------------------------------------------------------

    /**
     * Encrypt [plaintext] using the key for [sessionId] (NOT the active session).
     *
     * Thread-safe: resolves the key under lock, then creates a fresh Cipher.
     * This avoids race conditions when multiple WebSockets decrypt concurrently.
     */
    @Throws(CryptoException::class)
    fun encrypt(sessionId: String, plaintext: ByteArray): ByteArray {
        val key = lock.withLock {
            sessionKeys[sessionId]
                ?: throw CryptoException("No encryption key for session '$sessionId'")
        }

        return try {
            val iv = ByteArray(IV_LENGTH_BYTES)
            secureRandom.nextBytes(iv)

            val cipher = getCipher()
            val spec = GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv)
            cipher.init(Cipher.ENCRYPT_MODE, key, spec)

            val ciphertextWithTag = cipher.doFinal(plaintext)

            val result = ByteArray(IV_LENGTH_BYTES + ciphertextWithTag.size)
            System.arraycopy(iv, 0, result, 0, IV_LENGTH_BYTES)
            System.arraycopy(ciphertextWithTag, 0, result, IV_LENGTH_BYTES, ciphertextWithTag.size)
            result
        } catch (e: CryptoException) {
            throw e
        } catch (e: Exception) {
            throw CryptoException("Encryption failed for session '$sessionId'", e)
        }
    }

    /**
     * Decrypt [ciphertext] using the key for [sessionId] (NOT the active session).
     *
     * Thread-safe: resolves the key under lock, then creates a fresh Cipher.
     * This avoids race conditions when multiple WebSockets decrypt concurrently.
     */
    @Throws(CryptoException::class)
    fun decrypt(sessionId: String, ciphertext: ByteArray): ByteArray {
        val key = lock.withLock {
            sessionKeys[sessionId]
                ?: throw CryptoException("No encryption key for session '$sessionId'")
        }

        if (ciphertext.size < MINIMUM_CIPHERTEXT_LENGTH) {
            throw CryptoException(
                "Ciphertext too short: ${ciphertext.size} bytes " +
                "(minimum $MINIMUM_CIPHERTEXT_LENGTH)"
            )
        }

        return try {
            val iv = ciphertext.copyOfRange(0, IV_LENGTH_BYTES)
            val encryptedWithTag = ciphertext.copyOfRange(IV_LENGTH_BYTES, ciphertext.size)

            val cipher = getCipher()
            val spec = GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv)
            cipher.init(Cipher.DECRYPT_MODE, key, spec)

            cipher.doFinal(encryptedWithTag)
        } catch (e: CryptoException) {
            throw e
        } catch (e: javax.crypto.AEADBadTagException) {
            throw CryptoException("GCM auth failed for session '$sessionId'", e)
        } catch (e: Exception) {
            throw CryptoException("Decryption failed for session '$sessionId'", e)
        }
    }

    // -------------------------------------------------------------------------
    // String convenience helpers
    // -------------------------------------------------------------------------

    /**
     * Encrypt a UTF-8 string message.
     *
     * @return the encrypted bytes (IV + ciphertext + tag)
     */
    @Throws(CryptoException::class)
    fun encryptMessage(message: String): ByteArray {
        return encrypt(message.toByteArray(Charsets.UTF_8))
    }

    /**
     * Decrypt bytes back to a UTF-8 string message.
     *
     * @return the decrypted message string
     */
    @Throws(CryptoException::class)
    fun decryptMessage(ciphertext: ByteArray): String {
        val plaintext = decrypt(ciphertext)
        return String(plaintext, Charsets.UTF_8)
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /**
     * Resolve the active session's key or throw.
     */
    @Throws(CryptoException::class)
    private fun activeKey(): SecretKey = lock.withLock {
        val sid = activeSessionId ?: throw CryptoException("No active session set")
        sessionKeys[sid] ?: throw CryptoException("No encryption key set for session '$sid'")
    }

    // -------------------------------------------------------------------------
    // Exception
    // -------------------------------------------------------------------------

    class CryptoException : Exception {
        constructor(message: String) : super(message)
        constructor(message: String, cause: Throwable) : super(message, cause)
    }
}
