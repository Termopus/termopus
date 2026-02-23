package com.termopus.app.security

/** Stub -- native security removed for open source builds. */
object NativeSecrets {
    fun signSecurityResult(status: String): String = status
    fun enforceSecurityResult(signedResult: String) {}
    fun verifyCertificatePin(spkiHash: String): String = "VALID"
    fun getEndpoint(key: String): String = ""
    fun secureExit() {}
}
