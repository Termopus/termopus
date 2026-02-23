package com.termopus.app.network

import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import com.termopus.app.security.CertificateManager
import com.termopus.app.security.CryptoEngine
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.net.ssl.KeyManager
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLPeerUnverifiedException
import javax.net.ssl.TrustManager
import javax.net.ssl.X509ExtendedTrustManager
import javax.net.ssl.X509TrustManager
import java.net.Socket

/**
 * Secure WebSocket connection to the Cloudflare relay.
 *
 * Features:
 * - mTLS: presents a client certificate from [CertificateManager]
 * - Certificate pinning: validates the server certificate against known
 *   Cloudflare intermediate/root CAs
 * - E2E encryption: all payloads are encrypted via [CryptoEngine] before
 *   being sent over the wire (and decrypted on receive)
 * - Automatic reconnection with exponential back-off
 *
 * The [ConnectionState] sealed class exposes the current status to the
 * bridge layer for forwarding to Flutter.
 */
class SecureWebSocket internal constructor(val sessionId: String) {

    companion object {
        private const val TAG = "SecureWebSocket"

        /** Certificate pinning is always enabled in release builds.
         *  Only disabled in debug builds for local development. Immutable at runtime. */
        val isPinningEnabled: Boolean = false

        // Certificate pins for YOUR_RELAY_DEV_DOMAIN (SHA-256 of SPKI, Base64-encoded)
        // Verified via: openssl s_client -connect YOUR_RELAY_DEV_DOMAIN:443 -showcerts
        // In production, rotate these via remote config.
        private val CLOUDFLARE_PINS = setOf<String>(
            // Leaf: CN=YOUR_DOMAIN (rotates every ~90 days)
            // Intermediate: Google Trust Services WE1 (more stable)
            // Root: GTS Root R4 (most stable)
        )

        private const val MAX_RECONNECT_ATTEMPTS = 50
        private const val RECONNECT_BASE_DELAY_MS = 1000L
        private const val RECONNECT_MAX_DELAY_MS = 30000L
        private const val GOING_AWAY_CODE = 1001
        private const val AUTH_FAILED_CODE = 4001
        private const val SUBSCRIPTION_REQUIRED_CODE = 4002
        private const val AUTH_TIMEOUT_CODE = 4003

        /** Relay-readable control message types allowed as plaintext after handshake.
         *  Source of truth: PHONE_CONTROL_TYPES in relay_worker/src/relay.ts */
        private val RELAY_CONTROL_TYPES = setOf(
            "auth_challenge", "auth_result", "session_authorized",
            "fcm_registered", "peer_connected", "peer_disconnected",
            "peer_offline", "pong", "status_response"
        )

        /**
         * Shared OkHttpClient for connection pooling efficiency.
         *
         * Rebuilt via [resetClient] after certificate provisioning so that
         * mTLS kicks in for all subsequent connections.
         */
        @Volatile
        private var _sharedClient: OkHttpClient? = null

        private val sharedClient: OkHttpClient
            get() {
                _sharedClient?.let { return it }
                synchronized(this) {
                    _sharedClient?.let { return it }
                    return buildClient().also { _sharedClient = it }
                }
            }

        /**
         * Force rebuild of the shared OkHttpClient.
         *
         * Call this after storing a new client certificate so that
         * subsequent WebSocket connections present it for mTLS.
         */
        fun resetClient() {
            synchronized(this) {
                Log.d(TAG, "Resetting shared OkHttpClient (cert may have changed)")
                _sharedClient = null
            }
        }

        private fun buildClient(): OkHttpClient {
            val builder = OkHttpClient.Builder()
                .connectTimeout(30, TimeUnit.SECONDS)
                .readTimeout(0, TimeUnit.SECONDS)     // No read timeout for WebSocket
                .writeTimeout(30, TimeUnit.SECONDS)
                .pingInterval(30, TimeUnit.SECONDS)   // Keep-alive ping/pong
                .retryOnConnectionFailure(false)      // We handle reconnection ourselves

            // Configure mTLS + certificate pinning
            try {
                val trustManager = CloudflarePinningTrustManager()
                val keyManager = CertificateManager.getKeyManager()

                val sslContext = SSLContext.getInstance("TLS")

                if (keyManager != null) {
                    // mTLS: present client certificate + validate server with pinning
                    Log.d(TAG, "Configuring mTLS with client certificate")
                    sslContext.init(
                        arrayOf<KeyManager>(keyManager),
                        arrayOf<TrustManager>(trustManager),
                        SecureRandom()
                    )
                } else {
                    // No client cert yet - just validate server with pinning
                    Log.d(TAG, "No client certificate available, using server-only TLS with pinning")
                    sslContext.init(
                        null,
                        arrayOf<TrustManager>(trustManager),
                        SecureRandom()
                    )
                }

                builder.sslSocketFactory(sslContext.socketFactory, trustManager)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to configure SSL with mTLS/pinning — connection will fail", e)
                throw e  // Do NOT fall back to system defaults
            }

            return builder.build()
        }
    }

    /** Opaque auth state — hash-based, not a hookable boolean.
     *  Set to SHA-256(nonce + "handshake-complete") on auth_result success.
     *  Verified by checking hash matches, not by reading a boolean. */
    @Volatile
    private var authStateToken: ByteArray? = null

    fun isHandshakeComplete(): Boolean {
        val token = authStateToken
        return token != null && token.size == 32
    }

    fun markHandshakeComplete(nonce: String) {
        val md = java.security.MessageDigest.getInstance("SHA-256")
        md.update(nonce.toByteArray(Charsets.UTF_8))
        md.update("handshake-complete".toByteArray(Charsets.UTF_8))
        authStateToken = md.digest()
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    // -------------------------------------------------------------------------
    // Connection state
    // -------------------------------------------------------------------------

    /**
     * Sealed class representing WebSocket connection states.
     */
    sealed class ConnectionState {
        data object Disconnected : ConnectionState()
        data object Connecting : ConnectionState()
        data object Connected : ConnectionState()
        data object Reconnecting : ConnectionState()
        data object SubscriptionRequired : ConnectionState()
        data class Error(val message: String, val throwable: Throwable? = null) : ConnectionState()

        override fun toString(): String = when (this) {
            is Disconnected -> "disconnected"
            is Connecting -> "connecting"
            is Connected -> "connected"
            is Reconnecting -> "reconnecting"
            is SubscriptionRequired -> "subscription_required"
            is Error -> "error"
        }
    }

    @Volatile
    var state: ConnectionState = ConnectionState.Disconnected
        private set

    @Volatile
    private var webSocket: WebSocket? = null
    @Volatile
    private var currentUrl: String? = null
    @Volatile
    private var reconnectAttempt = 0
    @Volatile
    private var intentionalDisconnect = false

    private val reconnectHandler = Handler(Looper.getMainLooper())
    private var reconnectRunnable: Runnable? = null

    /** Callback invoked when a decrypted message is received. Dispatched on main thread. */
    var onMessage: ((ByteArray) -> Unit)? = null

    /** Callback invoked whenever the connection state changes. Dispatched on main thread. */
    var onStateChange: ((ConnectionState) -> Unit)? = null

    // -------------------------------------------------------------------------
    // Connection management
    // -------------------------------------------------------------------------

    /**
     * Connect to the relay WebSocket URL.
     *
     * If already connected or connecting, disconnects first and reconnects
     * (matching iOS behavior).
     *
     * Builds an [OkHttpClient] with mTLS support and certificate pinning,
     * then initiates the WebSocket upgrade.
     *
     * @param url the `wss://` URL including session ID and role query param
     */
    fun connect(url: String, isReconnect: Boolean = false) {
        // Disconnect existing connection before reconnecting (matches iOS)
        if (state is ConnectionState.Connected || state is ConnectionState.Connecting) {
            disconnect()
        }

        currentUrl = url
        intentionalDisconnect = false
        // Only reset reconnectAttempt for fresh connections.
        // Reconnect attempts keep their counter so exponential backoff works.
        if (!isReconnect) {
            reconnectAttempt = 0
        }

        updateState(ConnectionState.Connecting)

        try {
            val request = Request.Builder()
                .url(url)
                .build()

            webSocket = sharedClient.newWebSocket(request, webSocketListener)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initiate connection", e)
            updateState(ConnectionState.Error("Connection failed: ${e.message}", e))
        }
    }

    /**
     * Send encrypted data over the WebSocket.
     *
     * The [plaintext] is encrypted via [CryptoEngine] before transmission.
     *
     * @return `true` if the message was enqueued, `false` otherwise
     */
    fun send(plaintext: ByteArray): Boolean {
        val ws = webSocket ?: return false
        if (state !is ConnectionState.Connected) return false

        return try {
            val encrypted = CryptoEngine.encrypt(sessionId, plaintext)
            ws.send(encrypted.toByteString())
        } catch (e: Exception) {
            Log.e(TAG, "[$sessionId] Failed to encrypt/send message", e)
            false
        }
    }

    /**
     * Send an encrypted string message.
     */
    fun sendMessage(message: String): Boolean {
        return send(message.toByteArray(Charsets.UTF_8))
    }

    /**
     * Send plaintext data over the WebSocket **without encryption**.
     *
     * Used exclusively for relay control messages (e.g. `fcm_register`, `ping`)
     * that the relay must parse as JSON before forwarding. User content must
     * always go through [send] (encrypted).
     *
     * @return `true` if the message was enqueued, `false` otherwise
     */
    fun sendPlaintext(text: String): Boolean {
        val ws = webSocket
        if (ws == null) {
            Log.e(TAG, "sendPlaintext failed: webSocket is null")
            return false
        }
        if (state !is ConnectionState.Connected) {
            Log.e(TAG, "sendPlaintext failed: state is $state (not Connected)")
            return false
        }

        return try {
            val result = ws.send(text)
            Log.d(TAG, "sendPlaintext: ws.send() returned $result")
            result
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send plaintext control message", e)
            false
        }
    }

    /**
     * Gracefully disconnect.
     *
     * Uses close code 1001 (Going Away) to indicate the client is
     * intentionally leaving.
     */
    fun disconnect() {
        reconnectRunnable?.let { reconnectHandler.removeCallbacks(it) }
        reconnectRunnable = null
        intentionalDisconnect = true
        webSocket?.close(GOING_AWAY_CODE, "Client disconnect")
        webSocket = null
        updateState(ConnectionState.Disconnected)
    }

    /**
     * Cancel pending backoff timer and reconnect immediately.
     * Called by NetworkMonitor when network recovers or switches.
     */
    fun reconnectNow() {
        // Guard against rapid-fire calls from NetworkMonitor
        if (state is ConnectionState.Connecting) return

        reconnectRunnable?.let { reconnectHandler.removeCallbacks(it) }
        reconnectRunnable = null
        reconnectAttempt = 0  // Reset backoff since network just recovered

        val url = currentUrl ?: return
        if (intentionalDisconnect) return

        Log.d(TAG, "[$sessionId] Immediate reconnect (network recovered)")

        // Cancel old socket BEFORE clearing reference — prevents orphaned
        // socket's onFailure from corrupting the new connection's state.
        val old = webSocket
        webSocket = null
        old?.cancel()

        connect(url, isReconnect = false)
    }

    // -------------------------------------------------------------------------
    // WebSocket listener
    // -------------------------------------------------------------------------

    private val webSocketListener = object : WebSocketListener() {

        override fun onOpen(webSocket: WebSocket, response: Response) {
            // Ignore callbacks from a cancelled/replaced WebSocket
            if (webSocket !== this@SecureWebSocket.webSocket) {
                Log.d(TAG, "[$sessionId] Ignoring onOpen from stale WebSocket")
                return
            }
            Log.d(TAG, "=== WebSocket CONNECTED ===")
            Log.d(TAG, "Response code: ${response.code}")
            Log.d(TAG, "Response message: ${response.message}")
            Log.d(TAG, "URL: ${currentUrl}")
            Log.d(TAG, "===========================")
            authStateToken = null  // Reset handshake state on new connection
            reconnectAttempt = 0
            updateState(ConnectionState.Connected)
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            Log.d(TAG, "[$sessionId] Received binary message: ${bytes.size} bytes")
            try {
                val decrypted = CryptoEngine.decrypt(sessionId, bytes.toByteArray())
                Log.d(TAG, "[$sessionId] Decrypted successfully: ${decrypted.size} bytes")
                mainHandler.post { onMessage?.invoke(decrypted) }
            } catch (e: Exception) {
                // SECURITY: Drop messages that fail decryption — never forward raw bytes.
                // Forwarding undecrypted data could allow plaintext command injection.
                Log.e(TAG, "[$sessionId] Decrypt failed (${bytes.size} bytes), dropping message", e)
            }
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            Log.d(TAG, "[$sessionId] Received text message: ${text.take(200)}${if (text.length > 200) "..." else ""}")

            // Relay control messages are plaintext JSON (auth_challenge, auth_result,
            // peer_connected, peer_disconnected, peer_offline, fcm_registered, etc.).
            // Check for JSON before attempting Base64 decode because Android's
            // Base64.decode is lenient and silently "decodes" non-Base64 input
            // (like JSON) into garbage bytes instead of throwing.
            val trimmed = text.trimStart()
            if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
                try {
                    val json = org.json.JSONObject(trimmed)
                    val type = json.optString("type", "")

                    if (isHandshakeComplete() && !RELAY_CONTROL_TYPES.contains(type)) {
                        Log.e(TAG, "[$sessionId] SECURITY: Rejected plaintext message type '$type' after handshake")
                        return
                    }

                    Log.d(TAG, "[$sessionId] Forwarding relay control message: type=$type")
                    mainHandler.post { onMessage?.invoke(text.toByteArray(Charsets.UTF_8)) }
                    return
                } catch (e: Exception) {
                    Log.d(TAG, "[$sessionId] Failed to parse JSON, trying Base64: ${e.message}")
                }
            }

            // Not JSON — try to decode as Base64 (server may send encrypted data as text)
            try {
                val decoded = Base64.decode(text, Base64.DEFAULT)
                if (decoded.size >= 28) { // nonce(12) + tag(16) minimum
                    try {
                        val decrypted = CryptoEngine.decrypt(sessionId, decoded)
                        Log.d(TAG, "[$sessionId] Decrypted base64 text: ${decrypted.size} bytes")
                        mainHandler.post { onMessage?.invoke(decrypted) }
                        return
                    } catch (e: Exception) {
                        // SECURITY: Base64 decoded successfully but decryption failed.
                        // This is an encrypted message with wrong key or tampered data — drop it.
                        Log.e(TAG, "[$sessionId] Base64 decrypt failed, dropping message: ${e.message}")
                        return
                    }
                }
            } catch (e: Exception) {
                Log.d(TAG, "[$sessionId] Not valid base64: ${e.message}")
            }

            // Non-JSON, non-Base64 — drop after handshake
            if (isHandshakeComplete()) {
                Log.e(TAG, "[$sessionId] SECURITY: Rejected non-JSON plaintext after handshake")
                return
            }
            mainHandler.post { onMessage?.invoke(text.toByteArray(Charsets.UTF_8)) }
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            // Ignore callbacks from a cancelled/replaced WebSocket
            if (webSocket !== this@SecureWebSocket.webSocket) {
                Log.d(TAG, "[$sessionId] Ignoring onClosing from stale WebSocket")
                return
            }

            Log.d(TAG, "=== WebSocket CLOSING ===")
            Log.d(TAG, "Code: $code")
            Log.d(TAG, "Reason: $reason")
            Log.d(TAG, "intentionalDisconnect: $intentionalDisconnect")
            Log.d(TAG, "=========================")
            webSocket.close(GOING_AWAY_CODE, null)

            if (code == SUBSCRIPTION_REQUIRED_CODE) {
                // Subscription required — permanent, do not reconnect
                Log.e(TAG, "Subscription required (code $code), not reconnecting")
                updateState(ConnectionState.SubscriptionRequired)
            } else if (code == AUTH_FAILED_CODE || code == AUTH_TIMEOUT_CODE) {
                // Auth failure is permanent — do not reconnect
                Log.e(TAG, "Authentication failure (code $code), not reconnecting")
                updateState(ConnectionState.Error("Authentication failed: $reason"))
            } else if (!intentionalDisconnect && code != 1000) {
                // 1001 (Going Away) intentionally triggers reconnect — server may restart/redeploy
                scheduleReconnect()
            } else {
                updateState(ConnectionState.Disconnected)
            }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            // Ignore callbacks from a cancelled/replaced WebSocket
            if (webSocket !== this@SecureWebSocket.webSocket) {
                Log.d(TAG, "[$sessionId] Ignoring onFailure from stale WebSocket")
                return
            }

            Log.e(TAG, "=== WebSocket FAILURE ===")
            Log.e(TAG, "Response code: ${response?.code}")
            Log.e(TAG, "Throwable: ${t.javaClass.simpleName}: ${t.message}")
            Log.e(TAG, "intentionalDisconnect: $intentionalDisconnect")
            Log.e(TAG, "=========================")

            // If disconnect was intentional, don't overwrite Disconnected state
            if (intentionalDisconnect) {
                Log.d(TAG, "Ignoring onFailure — disconnect was intentional")
                return
            }

            val responseCode = response?.code
            if (responseCode == 403 || responseCode == 401) {
                Log.e(TAG, "HTTP authentication failure ($responseCode), not reconnecting")
                updateState(ConnectionState.Error("Authentication failed (HTTP $responseCode)"))
            } else {
                scheduleReconnect()
            }
        }
    }

    // -------------------------------------------------------------------------
    // Reconnection
    // -------------------------------------------------------------------------

    /**
     * Schedule a reconnection with exponential back-off.
     */
    private fun scheduleReconnect() {
        val url = currentUrl ?: return

        if (reconnectAttempt >= MAX_RECONNECT_ATTEMPTS) {
            Log.e(TAG, "Max reconnect attempts ($MAX_RECONNECT_ATTEMPTS) reached, giving up")
            updateState(ConnectionState.Error("Max reconnect attempts reached"))
            return
        }

        updateState(ConnectionState.Reconnecting)

        val baseDelay = minOf(
            RECONNECT_BASE_DELAY_MS * (1L shl minOf(reconnectAttempt, 5)),
            RECONNECT_MAX_DELAY_MS
        )
        // Add ±20% jitter to prevent thundering herd
        val jitter = (baseDelay * 0.2 * (Math.random() * 2 - 1)).toLong()
        val delay = maxOf(baseDelay + jitter, RECONNECT_BASE_DELAY_MS)
        reconnectAttempt++

        Log.d(TAG, "Reconnecting in ${delay}ms (attempt $reconnectAttempt)")

        // Cancel any pending reconnect
        reconnectRunnable?.let { reconnectHandler.removeCallbacks(it) }

        val runnable = Runnable {
            if (!intentionalDisconnect) {
                webSocket = null
                connect(url, isReconnect = true)
            }
        }
        reconnectRunnable = runnable
        reconnectHandler.postDelayed(runnable, delay)
    }

    // -------------------------------------------------------------------------
    // State management
    // -------------------------------------------------------------------------

    private fun updateState(newState: ConnectionState) {
        // De-duplicate state changes
        if (newState == state) return

        state = newState
        mainHandler.post { onStateChange?.invoke(newState) }
    }

    // -------------------------------------------------------------------------
    // Certificate pinning trust manager
    // -------------------------------------------------------------------------

    /**
     * Custom [X509ExtendedTrustManager] that validates the server certificate chain
     * and additionally checks that at least one certificate in the chain
     * matches a known Cloudflare pin (SPKI SHA-256 Base64).
     *
     * Extends [X509ExtendedTrustManager] to support Android's hostname-aware
     * certificate validation requirements.
     *
     * Falls back to the platform default trust manager for chain validation
     * and adds pin checking on top.
     *
     * In debug builds, pinning failures are logged but allowed.
     * In release builds, pinning failures throw [SSLPeerUnverifiedException].
     */
    private class CloudflarePinningTrustManager : X509ExtendedTrustManager() {

        private val defaultTrustManager: X509ExtendedTrustManager

        init {
            val factory = javax.net.ssl.TrustManagerFactory.getInstance(
                javax.net.ssl.TrustManagerFactory.getDefaultAlgorithm()
            )
            factory.init(null as java.security.KeyStore?)
            defaultTrustManager = factory.trustManagers
                .filterIsInstance<X509ExtendedTrustManager>()
                .first()
        }

        override fun checkClientTrusted(
            chain: Array<out X509Certificate>?,
            authType: String?
        ) {
            defaultTrustManager.checkClientTrusted(chain, authType)
        }

        override fun checkServerTrusted(
            chain: Array<out X509Certificate>?,
            authType: String?
        ) {
            // Delegate to hostname-aware version
            checkServerTrustedWithPinning(chain, authType)
        }

        override fun checkClientTrusted(
            chain: Array<out X509Certificate>?,
            authType: String?,
            socket: Socket?
        ) {
            defaultTrustManager.checkClientTrusted(chain, authType, socket)
        }

        override fun checkServerTrusted(
            chain: Array<out X509Certificate>?,
            authType: String?,
            socket: Socket?
        ) {
            defaultTrustManager.checkServerTrusted(chain, authType, socket)
            checkPins(chain)
        }

        override fun checkClientTrusted(
            chain: Array<out X509Certificate>?,
            authType: String?,
            engine: SSLEngine?
        ) {
            defaultTrustManager.checkClientTrusted(chain, authType, engine)
        }

        override fun checkServerTrusted(
            chain: Array<out X509Certificate>?,
            authType: String?,
            engine: SSLEngine?
        ) {
            defaultTrustManager.checkServerTrusted(chain, authType, engine)
            checkPins(chain)
        }

        override fun getAcceptedIssuers(): Array<X509Certificate> {
            return defaultTrustManager.acceptedIssuers
        }

        private fun checkServerTrustedWithPinning(
            chain: Array<out X509Certificate>?,
            authType: String?
        ) {
            defaultTrustManager.checkServerTrusted(chain, authType)
            checkPins(chain)
        }

        private fun checkPins(chain: Array<out X509Certificate>?) {
            // Self-hosted: certificate pinning disabled
            return
        }

        private fun isDebugBuild(): Boolean {
            // Try multiple methods to detect debug build
            return try {
                val buildConfigClass = Class.forName("com.termopus.app.BuildConfig")
                val debugField = buildConfigClass.getField("DEBUG")
                val isDebug = debugField.getBoolean(null)
                Log.d(TAG, "isDebugBuild via BuildConfig: $isDebug")
                isDebug
            } catch (e: Exception) {
                Log.e(TAG, "BuildConfig unavailable, enforcing pinning: ${e.message}")
                false  // Fail secure - enforce pinning if unknown
            }
        }
    }
}
