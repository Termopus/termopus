package com.termopus.app.security

import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.ByteArrayInputStream
import java.security.KeyStore
import java.security.PrivateKey
import java.security.PublicKey
import java.security.cert.Certificate
import java.security.MessageDigest
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.X509KeyManager

/**
 * Manages client certificates for mTLS with Cloudflare Access.
 *
 * The workflow:
 * 1. [generateCSR] — create a PKCS#10 Certificate Signing Request using the
 *    EC key pair already in Android KeyStore (from [SecureKeyManager]).
 * 2. The CSR is sent to the provisioning server, which returns a signed
 *    X.509 certificate.
 * 3. [storeCertificate] — stores the signed certificate in KeyStore, paired
 *    with the existing private key entry.
 * 4. [getClientCertificateChain] / [getPrivateKeyForSSL] — provide the
 *    credential to OkHttp's [X509KeyManager] for mTLS.
 *
 * We build a minimal DER-encoded PKCS#10 CSR manually to avoid pulling in
 * Bouncy Castle as a runtime dependency. The CSR structure is straightforward
 * for an EC key (no extensions needed).
 */
object CertificateManager {

    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val KEY_ALIAS = "app.clauderemote.session.key"
    private const val CERT_ALIAS = "app.clauderemote.client.cert"

    private val keyStore: KeyStore by lazy {
        KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
    }

    // -------------------------------------------------------------------------
    // CSR generation
    // -------------------------------------------------------------------------

    /**
     * Generate a PEM-encoded PKCS#10 Certificate Signing Request.
     *
     * Uses the EC P-256 key pair stored in Android KeyStore under [KEY_ALIAS].
     * The CSR subject is `CN=claude-remote-device,O=ClaudeRemote`.
     *
     * @return PEM string starting with "-----BEGIN CERTIFICATE REQUEST-----"
     * @throws CertException if key is unavailable or signing fails
     */
    @Throws(CertException::class)
    fun generateCSR(): String {
        val publicKey = SecureKeyManager.getPublicKey()
            ?: throw CertException("No public key available for CSR")
        val privateKey = SecureKeyManager.getPrivateKey()
            ?: throw CertException("No private key available for CSR signing")

        try {
            val csrDer = buildPkcs10CSR(publicKey, privateKey)
            return pemEncode(csrDer, "CERTIFICATE REQUEST")
        } catch (e: Exception) {
            throw CertException("Failed to generate CSR", e)
        }
    }

    // -------------------------------------------------------------------------
    // Certificate storage
    // -------------------------------------------------------------------------

    /**
     * Store a PEM-encoded X.509 certificate returned by the provisioning server.
     *
     * The certificate is associated with the private key already in KeyStore
     * by replacing the key entry with a KeyStore.PrivateKeyEntry that includes
     * the certificate chain.
     *
     * @param pemCertificate PEM-encoded certificate
     * @return `true` if stored successfully
     */
    fun storeCertificate(pemCertificate: String): Boolean {
        return try {
            val certFactory = CertificateFactory.getInstance("X.509")
            val certBytes = pemDecode(pemCertificate)
            val certificate = certFactory.generateCertificate(
                ByteArrayInputStream(certBytes)
            ) as X509Certificate

            // Android KeyStore requires setting the certificate on the existing
            // private key entry. We do this by storing it as a trusted certificate
            // entry alongside the key.
            keyStore.setCertificateEntry(CERT_ALIAS, certificate)

            // Also update the private key entry's certificate chain if possible.
            val privateKey = keyStore.getKey(KEY_ALIAS, null) as? PrivateKey
            if (privateKey != null) {
                keyStore.setKeyEntry(
                    KEY_ALIAS,
                    privateKey,
                    null, // No password for Android KeyStore
                    arrayOf(certificate)
                )
            }

            true
        } catch (e: Exception) {
            false
        }
    }

    // -------------------------------------------------------------------------
    // Certificate queries
    // -------------------------------------------------------------------------

    /**
     * Check whether a client certificate exists in the KeyStore.
     */
    fun hasCertificate(): Boolean {
        return try {
            keyStore.containsAlias(CERT_ALIAS) ||
                (keyStore.containsAlias(KEY_ALIAS) &&
                 keyStore.getCertificateChain(KEY_ALIAS)?.isNotEmpty() == true)
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Get the client certificate chain for mTLS.
     *
     * @return array of [X509Certificate] or null
     */
    fun getClientCertificateChain(): Array<X509Certificate>? {
        return try {
            val chain = keyStore.getCertificateChain(KEY_ALIAS)
            if (chain != null && chain.isNotEmpty()) {
                chain.map { it as X509Certificate }.toTypedArray()
            } else {
                val cert = keyStore.getCertificate(CERT_ALIAS) as? X509Certificate
                if (cert != null) arrayOf(cert) else null
            }
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Compute the SHA-256 fingerprint of the stored client certificate (DER encoding).
     * Returns lowercase hex string, or null if no certificate.
     */
    fun getCertificateFingerprint(): String? {
        val chain = getClientCertificateChain() ?: return null
        val cert = chain.firstOrNull() ?: return null
        val der = cert.encoded
        val digest = MessageDigest.getInstance("SHA-256").digest(der)
        return digest.joinToString("") { "%02x".format(it) }
    }

    /**
     * Get the PEM-encoded client certificate.
     */
    fun getCertificatePEM(): String? {
        val chain = getClientCertificateChain() ?: return null
        val cert = chain.firstOrNull() ?: return null
        val base64 = Base64.encodeToString(cert.encoded, Base64.NO_WRAP)
        return "-----BEGIN CERTIFICATE-----\n${base64.chunked(64).joinToString("\n")}\n-----END CERTIFICATE-----"
    }

    /**
     * Get the private key for SSL/TLS client authentication.
     *
     * The returned [PrivateKey] is an opaque handle; the actual key material
     * remains inside the secure hardware.
     */
    fun getPrivateKeyForSSL(): PrivateKey? {
        return SecureKeyManager.getPrivateKey()
    }

    /**
     * Build an [X509KeyManager] for OkHttp's SSL socket factory.
     *
     * This key manager provides the client certificate and private key
     * when the server requests client authentication during the TLS handshake.
     */
    fun getKeyManager(): X509KeyManager? {
        val chain = getClientCertificateChain() ?: return null
        val privateKey = getPrivateKeyForSSL() ?: return null

        return object : X509KeyManager {
            override fun getClientAliases(
                keyType: String?,
                issuers: Array<java.security.Principal>?
            ): Array<String> = arrayOf(KEY_ALIAS)

            override fun chooseClientAlias(
                keyType: Array<out String>?,
                issuers: Array<out java.security.Principal>?,
                socket: java.net.Socket?
            ): String = KEY_ALIAS

            override fun getServerAliases(
                keyType: String?,
                issuers: Array<java.security.Principal>?
            ): Array<String>? = null

            override fun chooseServerAlias(
                keyType: String?,
                issuers: Array<out java.security.Principal>?,
                socket: java.net.Socket?
            ): String? = null

            override fun getCertificateChain(alias: String?): Array<X509Certificate> = chain

            override fun getPrivateKey(alias: String?): PrivateKey = privateKey
        }
    }

    /**
     * Delete stored certificates.
     */
    fun deleteCertificate() {
        try {
            if (keyStore.containsAlias(CERT_ALIAS)) {
                keyStore.deleteEntry(CERT_ALIAS)
            }
        } catch (_: Exception) {
            // Best-effort
        }
    }

    // -------------------------------------------------------------------------
    // PKCS#10 CSR builder (minimal DER encoding, no Bouncy Castle)
    // -------------------------------------------------------------------------

    /**
     * Build a DER-encoded PKCS#10 CSR with subject
     * `CN=claude-remote-device,O=ClaudeRemote` and sign it with ECDSA-SHA256.
     */
    private fun buildPkcs10CSR(publicKey: PublicKey, privateKey: PrivateKey): ByteArray {
        // Subject: CN=claude-remote-device, O=ClaudeRemote
        val subject = buildDistinguishedName(
            mapOf(
                "2.5.4.3" to "claude-remote-device",  // CN
                "2.5.4.10" to "ClaudeRemote"           // O
            )
        )

        // SubjectPublicKeyInfo — use the key's X.509 encoding directly
        val spki = publicKey.encoded

        // CertificationRequestInfo
        //   version INTEGER (0)
        //   subject Name
        //   subjectPKInfo SubjectPublicKeyInfo
        //   attributes [0] IMPLICIT SET OF Attribute (empty)
        val version = derInteger(0)
        val attributes = derTaggedImplicit(0, ByteArray(0)) // empty attributes
        val certReqInfo = derSequence(version + subject + spki + attributes)

        // Sign the CertificationRequestInfo
        val signature = java.security.Signature.getInstance("SHA256withECDSA")
        signature.initSign(privateKey)
        signature.update(certReqInfo)
        val signatureBytes = signature.sign()

        // SignatureAlgorithm — ecdsa-with-SHA256 (OID 1.2.840.10045.4.3.2)
        val signatureAlgorithm = derSequence(
            derOid(byteArrayOf(
                0x2A, 0x86.toByte(), 0x48, 0xCE.toByte(), 0x3D, 0x04, 0x03, 0x02
            ))
        )

        // Signature value as BIT STRING
        val signatureBitString = derBitString(signatureBytes)

        // CertificationRequest = SEQUENCE { certReqInfo, sigAlg, sig }
        return derSequence(certReqInfo + signatureAlgorithm + signatureBitString)
    }

    // ── DER encoding helpers ────────────────────────────────────────────────

    private fun derSequence(content: ByteArray): ByteArray =
        derTag(0x30, content)

    private fun derSet(content: ByteArray): ByteArray =
        derTag(0x31, content)

    private fun derInteger(value: Int): ByteArray {
        val bytes = if (value == 0) byteArrayOf(0) else {
            var v = value
            val result = mutableListOf<Byte>()
            while (v > 0) {
                result.add(0, (v and 0xFF).toByte())
                v = v shr 8
            }
            if (result[0].toInt() and 0x80 != 0) {
                result.add(0, 0)
            }
            result.toByteArray()
        }
        return derTag(0x02, bytes)
    }

    private fun derOid(encodedValue: ByteArray): ByteArray =
        derTag(0x06, encodedValue)

    private fun derUtf8String(value: String): ByteArray =
        derTag(0x0C, value.toByteArray(Charsets.UTF_8))

    private fun derBitString(data: ByteArray): ByteArray {
        val content = ByteArray(1 + data.size)
        content[0] = 0x00 // unused bits
        System.arraycopy(data, 0, content, 1, data.size)
        return derTag(0x03, content)
    }

    private fun derTaggedImplicit(tagNumber: Int, content: ByteArray): ByteArray =
        derTag(0xA0 or tagNumber, content)

    private fun derTag(tag: Int, content: ByteArray): ByteArray {
        val length = derLength(content.size)
        val result = ByteArray(1 + length.size + content.size)
        result[0] = tag.toByte()
        System.arraycopy(length, 0, result, 1, length.size)
        System.arraycopy(content, 0, result, 1 + length.size, content.size)
        return result
    }

    private fun derLength(length: Int): ByteArray {
        return when {
            length < 0x80 -> byteArrayOf(length.toByte())
            length < 0x100 -> byteArrayOf(0x81.toByte(), length.toByte())
            length < 0x10000 -> byteArrayOf(
                0x82.toByte(),
                (length shr 8).toByte(),
                (length and 0xFF).toByte()
            )
            else -> throw IllegalArgumentException("Length too large: $length")
        }
    }

    /**
     * Build an X.500 distinguished name from OID -> value pairs.
     *
     * Each pair becomes an RDN: SET { SEQUENCE { OID, UTF8String } }
     */
    private fun buildDistinguishedName(attributes: Map<String, String>): ByteArray {
        var rdns = ByteArray(0)
        for ((oidStr, value) in attributes) {
            val oidEncoded = encodeOid(oidStr)
            val attrValue = derUtf8String(value)
            val attrTypeAndValue = derSequence(derOid(oidEncoded) + attrValue)
            rdns += derSet(attrTypeAndValue)
        }
        return derSequence(rdns)
    }

    /**
     * Encode a dotted OID string (e.g. "2.5.4.3") to its DER value bytes.
     */
    private fun encodeOid(oid: String): ByteArray {
        val parts = oid.split(".").map { it.toInt() }
        require(parts.size >= 2) { "OID must have at least two components" }

        val result = mutableListOf<Byte>()
        // First two components are encoded as 40*X + Y
        result.add((40 * parts[0] + parts[1]).toByte())

        for (i in 2 until parts.size) {
            val value = parts[i]
            if (value < 128) {
                result.add(value.toByte())
            } else {
                // Base-128 encoding
                val bytes = mutableListOf<Byte>()
                var v = value
                bytes.add((v and 0x7F).toByte())
                v = v shr 7
                while (v > 0) {
                    bytes.add(0, ((v and 0x7F) or 0x80).toByte())
                    v = v shr 7
                }
                result.addAll(bytes)
            }
        }

        return result.toByteArray()
    }

    // ── PEM helpers ─────────────────────────────────────────────────────────

    private fun pemEncode(der: ByteArray, type: String): String {
        val base64 = Base64.encodeToString(der, Base64.NO_WRAP)
        val lines = base64.chunked(64)
        return buildString {
            appendLine("-----BEGIN $type-----")
            for (line in lines) {
                appendLine(line)
            }
            appendLine("-----END $type-----")
        }
    }

    private fun pemDecode(pem: String): ByteArray {
        val stripped = pem
            .replace(Regex("-----BEGIN [^-]+-----"), "")
            .replace(Regex("-----END [^-]+-----"), "")
            .replace("\\s".toRegex(), "")
        return Base64.decode(stripped, Base64.DEFAULT)
    }

    // -------------------------------------------------------------------------
    // Exception
    // -------------------------------------------------------------------------

    class CertException : Exception {
        constructor(message: String) : super(message)
        constructor(message: String, cause: Throwable) : super(message, cause)
    }
}
