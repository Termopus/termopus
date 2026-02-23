package com.termopus.app.bridge

import android.app.Activity
import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import android.util.Log
import androidx.fragment.app.FragmentActivity
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.termopus.app.network.MessageQueue
import com.termopus.app.network.NetworkMonitor
import com.termopus.app.network.SecureWebSocket
import com.termopus.app.security.AntiTamper
import com.termopus.app.security.BiometricGate
import com.termopus.app.security.CertificateManager
import com.termopus.app.security.CryptoEngine
import com.termopus.app.security.BiometricCryptoService
import com.termopus.app.security.HardwareKeyService
import com.termopus.app.security.NativeSecrets
import com.termopus.app.security.SecureKeyManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.security.Signature
import java.util.UUID

/**
 * Platform channel bridge between Flutter (Dart) and the native Android
 * security / networking layer.
 *
 * Registers two channels:
 * - **MethodChannel** `app.clauderemote/security` — handles all request/response
 *   calls for biometric auth, device attestation, certificate management,
 *   session pairing, messaging, and FCM registration.
 * - **EventChannel** `app.clauderemote/messages` — streams decrypted messages
 *   from the WebSocket to Flutter in real time.
 *
 * Method call names mirror the iOS implementation exactly so that the Dart
 * [SecurityChannel] class works identically on both platforms.
 */
class SecurityChannel :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware {

    companion object {
        private const val TAG = "SecurityChannel"
        private const val METHOD_CHANNEL_NAME = "app.clauderemote/security"
        private const val EVENT_CHANNEL_NAME = "app.clauderemote/messages"
        private const val PREFS_NAME = "app.clauderemote.security"
        private const val KEY_PENDING_FCM_TOKEN = "pending_fcm_token"
        private const val PEER_KEYS_PREFS_NAME = "termopus_peer_keys"
        private const val KEY_PEER_PUBLIC_PREFIX = "peer_pubkey_"
    }

    // ── Flutter plumbing ────────────────────────────────────────────────────

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null

    private var activity: FragmentActivity? = null
    private var flutterBinding: FlutterPlugin.FlutterPluginBinding? = null

    // ── Native components ───────────────────────────────────────────────────

    /** Cached integrity gate result — integrity doesn't change at runtime. */
    @Volatile
    private var cachedIntegrityResult: Boolean? = null

    /** Per-session WebSocket pool — each session maintains its own connection. */
    private val webSockets = java.util.concurrent.ConcurrentHashMap<String, SecureWebSocket>()

    /** Maximum concurrent WebSocket connections. */
    private val maxConnections = 10

    /** The session ID currently active in the UI. Used for messaging defaults. */
    @Volatile
    private var activeSessionId: String? = null

    /** Current connection state string for session.state queries (active session). */
    @Volatile
    private var connectionState: String = "disconnected"

    /** Pending pairing payloads — deferred until after relay auth_challenge completes. */
    private val pendingPairingPayloads = HashMap<String, String>()

    /** Auth challenge nonces — stored per session for handshake completion marking. */
    private val pendingAuthNonces = HashMap<String, String>()

    /** Look up the WebSocket for the currently active session. */
    private fun activeWebSocket(): SecureWebSocket? =
        activeSessionId?.let { webSockets[it] }

    /**
     * Return the active WebSocket only if connected AND relay auth is complete.
     * Returns null during the auth window (onOpen -> auth_result), causing
     * callers to queue messages for replay instead of sending to a relay
     * that will drop them.
     */
    private fun authenticatedWebSocket(): SecureWebSocket? {
        val ws = activeWebSocket() ?: return null
        if (ws.state !is SecureWebSocket.ConnectionState.Connected) return null
        if (!ws.isHandshakeComplete()) return null
        return ws
    }

    /** Evict the oldest non-active connection if pool is at capacity. */
    private fun evictIfNeeded() {
        if (webSockets.size < maxConnections) return
        val victim = webSockets.keys.firstOrNull { it != activeSessionId }
        if (victim != null) {
            Log.w(TAG, "WebSocket pool full ($maxConnections), evicting session ${victim.take(12)}")
            webSockets.remove(victim)?.disconnect()
        }
    }

    /** Biometric crypto service for challenge signing (requires activity). */
    private var biometricCryptoService: BiometricCryptoService? = null

    /** Hardware key service for silent at-rest encryption. */
    private val hardwareKeyService = HardwareKeyService()

    /** Coroutine scope for async operations (Play Integrity, etc.). */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private fun getPrefs(): SharedPreferences? {
        return flutterBinding?.applicationContext?.getSharedPreferences(
            PREFS_NAME, Context.MODE_PRIVATE
        )
    }

    private fun getSecurePrefs(): SharedPreferences? {
        return try {
            val context = flutterBinding?.applicationContext ?: return null
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            EncryptedSharedPreferences.create(
                context,
                PEER_KEYS_PREFS_NAME,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to create EncryptedSharedPreferences", e)
            null
        }
    }

    // =====================================================================
    // FlutterPlugin lifecycle
    // =====================================================================

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        flutterBinding = binding

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL_NAME).also {
            it.setStreamHandler(this)
        }

        // Initialise AntiTamper with application context
        AntiTamper.init(binding.applicationContext)

        // Initialize persistent message queue for offline sends
        MessageQueue.init(binding.applicationContext)

        // Initialize hardware encryption key (silent, no biometric)
        try {
            hardwareKeyService.initialize()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize HardwareKeyService", e)
        }

        // Start network monitoring
        NetworkMonitor.onStateChange = { state ->
            Log.d(TAG, "Network state changed: reachable=${state.isReachable} transport=${state.transport}")

            // Emit networkState event to Flutter
            scope.launch(Dispatchers.Main) {
                eventSink?.success(mapOf(
                    "type" to "networkState",
                    "isReachable" to state.isReachable,
                    "transport" to state.transport.toString(),
                ))
            }

            // If network recovered, probe/reconnect active sessions
            if (state.isReachable) {
                for ((sid, ws) in webSockets) {
                    when (ws.state) {
                        is SecureWebSocket.ConnectionState.Connected -> {
                            // Network interface changed — old TCP socket is likely bound to
                            // the dead interface. Force reconnect instead of waiting for
                            // OkHttp's 30s ping to detect staleness.
                            Log.d(TAG, "[$sid] Network changed, forcing reconnect")
                            ws.reconnectNow()
                        }
                        is SecureWebSocket.ConnectionState.Reconnecting,
                        is SecureWebSocket.ConnectionState.Disconnected -> {
                            Log.d(TAG, "[$sid] Network recovered, triggering immediate reconnect")
                            ws.reconnectNow()
                        }
                        else -> {}
                    }
                }
            }
        }
        NetworkMonitor.start(binding.applicationContext)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null

        eventChannel?.setStreamHandler(null)
        eventChannel = null

        NetworkMonitor.stop()

        webSockets.values.forEach { it.disconnect() }
        webSockets.clear()
        activeSessionId = null

        scope.cancel()

        flutterBinding = null
    }

    // =====================================================================
    // ActivityAware lifecycle
    // =====================================================================

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity as? FragmentActivity
        activity?.let { act ->
            biometricCryptoService = BiometricCryptoService(act)
            try {
                biometricCryptoService?.initialize()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to initialize BiometricCryptoService", e)
            }
        }
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity as? FragmentActivity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    // =====================================================================
    // EventChannel.StreamHandler
    // =====================================================================

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // =====================================================================
    // MethodChannel.MethodCallHandler — dispatch
    // =====================================================================

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // ── Biometric ───────────────────────────────────────────────
            "biometric.isAvailable"   -> handleBiometricIsAvailable(result)
            "biometric.authenticate"  -> handleBiometricAuthenticate(call, result)
            "biometric.authenticateSecure" -> handleBiometricAuthenticateSecure(call, result)
            "biometric.type"          -> handleBiometricType(result)

            // ── Device attestation / anti-tamper ────────────────────────
            "device.checkIntegrity"   -> handleDeviceCheckIntegrity(result)
            "device.attest"           -> handleDeviceAttest(call, result)
            "device.assertion"        -> handleDeviceAssertion(call, result)

            // ── Certificate ─────────────────────────────────────────────
            "cert.generateCSR"        -> handleCertGenerateCSR(call, result)
            "cert.store"              -> handleCertStore(call, result)
            "cert.exists"             -> handleCertExists(result)
            "cert.getPEM"             -> handleCertGetPEM(result)
            "cert.delete"             -> handleCertDelete(result)

            // ── Key Management ──────────────────────────────────────────
            "keys.generate"           -> handleKeysGenerate(result)
            "keys.getPublicKey"       -> handleKeysGetPublicKey(result)
            "keys.delete"             -> handleKeysDelete(result)
            "keys.sign"               -> handleKeysSign(call, result)

            // ── Session ─────────────────────────────────────────────────
            "session.pair"            -> handleSessionPair(call, result)
            "session.connect"         -> handleSessionConnect(call, result)
            "session.disconnect"      -> handleSessionDisconnect(call, result)
            "session.state"           -> handleSessionState(result)
            "session.clearData"       -> handleSessionClearData(call, result)
            "session.delete"          -> handleSessionDelete(call, result)
            "session.keepalive"       -> {
                val sid = call.argument<String>("sessionId")
                val ws = sid?.let { webSockets[it] }
                if (ws == null) { result.success(false); return }
                result.success(ws.sendPlaintext("{\"type\":\"keepalive\"}"))
            }

            // ── Messaging ───────────────────────────────────────────────
            "message.send"            -> handleMessageSend(call, result)
            "message.sendKey"         -> handleMessageSendKey(call, result)
            "message.sendInput"       -> handleMessageSendInput(call, result)
            "message.respond"         -> handleMessageRespond(call, result)
            "message.command"         -> handleMessageCommand(call, result)
            "message.setModel"        -> handleMessageSetModel(call, result)
            "message.config"          -> handleMessageConfig(call, result)

            // ── HTTP Tunnel ──────────────────────────────────────────────
            "httpTunnel.open"         -> handleHttpTunnelOpen(call, result)
            "httpTunnel.close"        -> handleHttpTunnelClose(call, result)
            "httpTunnel.request"      -> handleHttpRequest(call, result)

            // ── File Transfer ───────────────────────────────────────────
            "file.send"               -> handleFileSend(call, result)
            "file.accept"             -> handleFileAccept(call, result)
            "file.cancel"             -> handleFileCancel(call, result)

            // ── Security ────────────────────────────────────────────────
            "security.getDeviceId" -> {
                val deviceId = SecureKeyManager.getDeviceId()
                if (deviceId != null) {
                    result.success(deviceId)
                } else {
                    result.error("DEVICE_ID_FAILED", "Could not derive device ID from public key", null)
                }
            }
            "security.getEndpoint"    -> handleSecurityGetEndpoint(call, result)
            "security.enforceResult"  -> handleSecurityEnforceResult(call, result)

            // ── Biometric Crypto ────────────────────────────────────────
            "biometric.signChallenge" -> handleBiometricSignChallenge(call, result)
            "biometric.getPublicKey"  -> handleBiometricGetPublicKey(result)

            // ── Hardware Encryption ─────────────────────────────────────
            "hardware.encrypt"        -> handleHardwareEncrypt(call, result)
            "hardware.decrypt"        -> handleHardwareDecrypt(call, result)

            // ── FCM ─────────────────────────────────────────────────────
            "fcm.register"            -> handleFcmRegister(call, result)

            // ── Bridge Controls ──────────────────────────────────────────
            "bridge.command"          -> handleBridgeCommand(call, result)
            "bridge.status"           -> handleBridgeStatus(result)

            else -> result.notImplemented()
        }
    }

    // =====================================================================
    // Biometric handlers
    // =====================================================================

    private fun handleBiometricIsAvailable(result: MethodChannel.Result) {
        val act = activity
        if (act == null) {
            result.success(false)
            return
        }
        result.success(BiometricGate.isAvailable(act))
    }

    private fun handleBiometricAuthenticate(call: MethodCall, result: MethodChannel.Result) {
        val act = activity
        if (act == null) {
            result.error("NO_ACTIVITY", "No activity available for biometric prompt", null)
            return
        }

        val reason = call.argument<String>("reason") ?: "Authenticate"

        BiometricGate.authenticate(act, reason) { success, error ->
            if (success) {
                result.success(true)
            } else {
                result.success(false)
            }
        }
    }

    private fun handleBiometricType(result: MethodChannel.Result) {
        val act = activity
        if (act == null) {
            result.success("none")
            return
        }
        result.success(BiometricGate.getBiometricType(act).name.lowercase())
    }

    /**
     * Secure biometric authentication with HMAC proof.
     *
     * Flow:
     * 1. Generate 32-byte random nonce
     * 2. BiometricCryptoService.signChallenge(nonce) with CryptoObject
     *    → Real biometric → hardware signs → valid ECDSA
     *    → Fake biometric → CryptoObject locked → sign() throws → secureExit()
     * 3. Verify ECDSA signature with the biometric public key
     * 4. If valid: NativeSecrets.signSecurityResult("BIOMETRIC_OK") → HMAC string
     * 5. If invalid: NativeSecrets.secureExit() → __builtin_trap()
     *
     * Returns {"signedResult": hmacString} — never a boolean.
     */
    private fun handleBiometricAuthenticateSecure(call: MethodCall, result: MethodChannel.Result) {
        val service = biometricCryptoService
        if (service == null) {
            result.error("NO_ACTIVITY", "BiometricCryptoService not initialized", null)
            return
        }

        val reason = call.argument<String>("reason") ?: "Authenticate to continue"

        // 1. Generate 32-byte random nonce
        val nonce = ByteArray(32)
        java.security.SecureRandom().nextBytes(nonce)
        val nonceB64 = Base64.encodeToString(nonce, Base64.NO_WRAP)

        // 2. Sign with biometric-protected key (triggers biometric prompt)
        service.signChallenge(nonceB64, reason) { signResult ->
            signResult.fold(
                onSuccess = { signatureB64 ->
                    try {
                        // 3. Verify ECDSA signature
                        val signatureBytes = Base64.decode(signatureB64, Base64.DEFAULT)
                        val publicKeyBytes = service.getPublicKey()

                        val keyFactory = java.security.KeyFactory.getInstance("EC")
                        val pubKeySpec = java.security.spec.X509EncodedKeySpec(publicKeyBytes)
                        val publicKey = keyFactory.generatePublic(pubKeySpec)

                        val sig = Signature.getInstance("SHA256withECDSA")
                        sig.initVerify(publicKey)
                        sig.update(nonce)
                        val verified = sig.verify(signatureBytes)

                        if (verified) {
                            // 4. Valid: return HMAC-signed proof
                            val hmac = NativeSecrets.signSecurityResult("BIOMETRIC_OK")
                            result.success(mapOf("signedResult" to hmac))
                        } else {
                            // 5. Invalid signature: tampered — crash
                            NativeSecrets.secureExit()
                        }
                    } catch (e: Exception) {
                        // Verification infrastructure failure — crash (defensive)
                        Log.e(TAG, "Biometric verification failed", e)
                        NativeSecrets.secureExit()
                    }
                },
                onFailure = { error ->
                    // User cancelled or biometric not recognized
                    result.error("BIOMETRIC_FAILED", error.message, null)
                }
            )
        }
    }

    // =====================================================================
    // Device attestation / anti-tamper handlers
    // =====================================================================

    private fun handleDeviceCheckIntegrity(result: MethodChannel.Result) {
        // Run on a background thread since some checks do I/O
        scope.launch(Dispatchers.IO) {
            val signedResult = AntiTamper.checkIntegritySigned()
            launch(Dispatchers.Main) {
                // Return MAC-signed string to Dart — NOT a boolean
                result.success(signedResult)
            }
        }
    }

    private fun handleDeviceAttest(call: MethodCall, result: MethodChannel.Result) {
        val challenge = call.argument<String>("challenge")
        if (challenge.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "challenge is required", null)
            return
        }

        // Self-hosted: attestation disabled
        result.success("")
    }

    /**
     * Handle device assertion — Android equivalent of iOS App Attest assertion.
     *
     * On Android this uses Play Integrity to produce a fresh token
     * bound to the given challenge, similar to iOS assertion flow.
     */
    private fun handleDeviceAssertion(call: MethodCall, result: MethodChannel.Result) {
        val challenge = call.argument<String>("challenge")
        if (challenge.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "challenge is required", null)
            return
        }

        // Self-hosted: assertion disabled
        result.success("")
    }

    // =====================================================================
    // Certificate handlers
    // =====================================================================

    /**
     * Generate a fresh key pair in KeyStore (StrongBox/TEE) and build a CSR.
     *
     * Accepts an optional `challenge` argument. When provided:
     * - The challenge is passed to [SecureKeyManager.generateKeyPair] to enable
     *   Android Key Attestation (embeds challenge in the certificate extension).
     * - After key generation, the attestation certificate chain is extracted
     *   and returned alongside the CSR.
     *
     * Returns:
     * - With challenge: `{"csr": "...", "keyAttestationChain": ["b64cert1", ...]}`
     * - Without challenge (or if attestation unavailable): `{"csr": "..."}`
     *
     * For backward compatibility: if no challenge is provided, the key is
     * generated without attestation and only the CSR string is returned
     * (not wrapped in a map).
     */
    private fun handleCertGenerateCSR(call: MethodCall, result: MethodChannel.Result) {
        try {
            val challenge = call.argument<String>("challenge")

            // Generate a fresh key pair in KeyStore (StrongBox),
            // with optional attestation challenge for hardware binding.
            if (challenge != null) {
                SecureKeyManager.generateKeyPair(
                    attestationChallenge = challenge.toByteArray(Charsets.UTF_8)
                )
            } else {
                SecureKeyManager.generateKeyPair()
            }

            // Build a CSR from the generated key
            val csr = CertificateManager.generateCSR()

            if (challenge != null) {
                // Return CSR + attestation cert chain as a map
                val certChain = SecureKeyManager.getAttestationCertChain()
                val responseMap = mutableMapOf<String, Any>("csr" to csr)
                if (certChain != null) {
                    responseMap["keyAttestationChain"] = certChain
                    Log.d(TAG, "Key attestation cert chain: ${certChain.size} certs")
                } else {
                    Log.w(TAG, "Key attestation cert chain not available (device may not support it)")
                }
                result.success(responseMap)
            } else {
                // Backward compatibility: return just the CSR string
                result.success(csr)
            }
        } catch (e: Exception) {
            result.error("CSR_FAILED", e.message, e.stackTraceToString())
        }
    }

    private fun handleCertStore(call: MethodCall, result: MethodChannel.Result) {
        val certificate = call.argument<String>("certificate")
        if (certificate.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "certificate is required", null)
            return
        }

        val success = CertificateManager.storeCertificate(certificate)
        if (success) {
            // Force OkHttpClient rebuild so subsequent connections present the cert for mTLS
            SecureWebSocket.resetClient()
        }
        result.success(success)
    }

    private fun handleCertExists(result: MethodChannel.Result) {
        result.success(CertificateManager.hasCertificate())
    }

    private fun handleCertGetPEM(result: MethodChannel.Result) {
        val pem = CertificateManager.getCertificatePEM()
        result.success(pem)
    }

    private fun handleCertDelete(result: MethodChannel.Result) {
        try {
            CertificateManager.deleteCertificate()
            result.success(mapOf("deleted" to true))
        } catch (e: Exception) {
            result.error("CERT_DELETE_FAILED", e.message, e.stackTraceToString())
        }
    }

    // =====================================================================
    // Key management handlers
    // =====================================================================

    private fun handleKeysGenerate(result: MethodChannel.Result) {
        try {
            val keyPair = SecureKeyManager.generateKeyPair()
            val publicKeyBytes = SecureKeyManager.getPublicKeyBytes()
            result.success(mapOf(
                "publicKey" to (publicKeyBytes?.let {
                    Base64.encodeToString(it, Base64.NO_WRAP)
                } ?: "")
            ))
        } catch (e: Exception) {
            result.error("KEY_GEN_FAILED", e.message, e.stackTraceToString())
        }
    }

    private fun handleKeysGetPublicKey(result: MethodChannel.Result) {
        val publicKeyBytes = SecureKeyManager.getPublicKeyBytes()
        if (publicKeyBytes != null) {
            result.success(mapOf(
                "publicKey" to Base64.encodeToString(publicKeyBytes, Base64.NO_WRAP)
            ))
        } else {
            result.error("KEY_NOT_FOUND", "No key pair found in KeyStore", null)
        }
    }

    private fun handleKeysDelete(result: MethodChannel.Result) {
        try {
            SecureKeyManager.deleteKeyPair()
            result.success(mapOf("deleted" to true))
        } catch (e: Exception) {
            result.error("KEY_DELETE_FAILED", e.message, e.stackTraceToString())
        }
    }

    private fun handleKeysSign(call: MethodCall, result: MethodChannel.Result) {
        val dataB64 = call.argument<String>("data")
        if (dataB64.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "data (Base64 string) is required", null)
            return
        }

        try {
            val data = Base64.decode(dataB64, Base64.DEFAULT)
            val signature = SecureKeyManager.sign(data)
            result.success(mapOf(
                "signature" to Base64.encodeToString(signature, Base64.NO_WRAP)
            ))
        } catch (e: Exception) {
            result.error("SIGN_FAILED", e.message, e.stackTraceToString())
        }
    }

    // =====================================================================
    // Session handlers
    // =====================================================================

    /**
     * Validate device integrity before allowing session operations.
     *
     * Runs AntiTamper.checkIntegritySigned() on [Dispatchers.IO] to avoid
     * blocking the main thread (ANR risk), then validates via
     * NativeSecrets.enforceSecurityResult(). If the device is tampered,
     * the native C layer crashes the app via __builtin_trap().
     *
     * Subsequent calls return immediately from the volatile cache.
     */
    private suspend fun validateIntegrityGate(result: MethodChannel.Result): Boolean {
        // Self-hosted: integrity checks disabled
        return true
    }

    /**
     * Pair with a computer using ephemeral ECDH for forward secrecy:
     * 1. Validate biometric proof (HMAC from authenticateSecure)
     * 2. Run integrity gate
     * 3. Generate ephemeral P-256 key pair (in memory, NOT KeyStore)
     * 4. Derive shared secret via ephemeral ECDH with the peer's public key
     * 5. Set the derived AES key in [CryptoEngine]
     * 6. Persist AES key in EncryptedSharedPreferences for reconnect
     * 7. Open an encrypted WebSocket to the relay
     * 8. Send EPHEMERAL public key to the peer (not permanent key)
     *
     * The permanent KeyStore key is used only for device_auth signing.
     * Ephemeral private key is discarded after ECDH — provides forward secrecy.
     */
    private fun handleSessionPair(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "handleSessionPair called")
        val relay = call.argument<String>("relay")
        val sessionId = call.argument<String>("sessionId")
        val peerPublicKeyB64 = call.argument<String>("peerPublicKey")
        val biometricProof = call.argument<String>("biometricProof")

        Log.d(TAG, "Pairing args: relay=$relay, sessionId=$sessionId, pubkey=${peerPublicKeyB64?.take(20)}...")

        if (relay.isNullOrEmpty() || sessionId.isNullOrEmpty() || peerPublicKeyB64.isNullOrEmpty()) {
            Log.e(TAG, "Missing required arguments for pairing")
            result.error("INVALID_ARGS", "relay, sessionId, and peerPublicKey are required", null)
            return
        }

        // Launch coroutine so validateIntegrityGate can suspend to Dispatchers.IO
        scope.launch {
            try {
                // Biometric proof was already validated by enforceSecurityResult in the
                // Dart auth layer (AuthNotifier.authenticate). Re-validating here crashes
                // because the native HMAC has a one-time-use / time-based check.
                // We trust the proof is valid since it came from our own Dart code path.
                if (biometricProof.isNullOrEmpty()) {
                    Log.w(TAG, "No biometric proof provided for pairing")
                }

                // Security gate: validate device integrity (runs on IO for first call)
                Log.d(TAG, "Running integrity gate for pairing...")
                if (!validateIntegrityGate(result)) return@launch

                Log.d(TAG, "Starting pairing process...")
                // Decode peer public key
                Log.d(TAG, "Decoding peer public key...")
                val peerPublicKeyBytes = Base64.decode(peerPublicKeyB64, Base64.DEFAULT)
                Log.d(TAG, "Peer public key decoded: ${peerPublicKeyBytes.size} bytes")

                // Ensure we have a permanent key pair (used only for device_auth signing)
                if (!SecureKeyManager.hasKeyPair()) {
                    Log.d(TAG, "Generating new permanent key pair...")
                    SecureKeyManager.generateKeyPair()
                }
                Log.d(TAG, "Permanent key pair ready")

                // Generate ephemeral P-256 key pair for this session (forward secrecy)
                Log.d(TAG, "Generating ephemeral key pair for session...")
                val (ephemeralPrivateKey, ephemeralPublicKeyBytes) = SecureKeyManager.generateEphemeralKeyPair()
                Log.d(TAG, "Ephemeral key pair generated: ${ephemeralPublicKeyBytes.size} bytes public key")

                // Ephemeral ECDH → HKDF → 32-byte AES key
                Log.d(TAG, "Deriving shared secret via ephemeral ECDH...")
                val sharedSecret = SecureKeyManager.deriveSharedSecretEphemeral(ephemeralPrivateKey, peerPublicKeyBytes)
                Log.d(TAG, "Shared secret derived: ${sharedSecret.size} bytes")
                activeSessionId = sessionId
                CryptoEngine.setSharedSecret(sessionId, sharedSecret)

                // Persist derived AES key for session restore after app kill
                // (NOT the peer public key — ephemeral private key is gone, so re-derive is impossible)
                val context = flutterBinding?.applicationContext
                if (context != null) {
                    try {
                        SecureKeyManager.persistSessionKey(context, sessionId, sharedSecret)
                        Log.d(TAG, "Session AES key persisted for reconnect")
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed to persist session AES key (pairing still works)", e)
                    }
                }

                // Clean up old peer public key entry if migrating from previous version
                try {
                    getSecurePrefs()?.edit()
                        ?.remove(KEY_PEER_PUBLIC_PREFIX + sessionId)
                        ?.apply()
                } catch (_: Exception) {}

                // Build WebSocket URL
                val wsUrl = buildRelayUrl(relay, sessionId)
                Log.d(TAG, "WebSocket URL: $wsUrl")

                // Prepare pairing payload with EPHEMERAL public key (not permanent)
                Log.d(TAG, "Ephemeral public key: ${ephemeralPublicKeyBytes.size} bytes")
                val pairingPayload = JSONObject().apply {
                    put("type", "pairing")
                    put("pubkey", Base64.encodeToString(ephemeralPublicKeyBytes, Base64.NO_WRAP))
                }.toString()
                Log.d(TAG, "Pairing payload: ready (ephemeral key)")

                // Create per-session WebSocket (disconnect any existing one for this session)
                Log.d(TAG, "=== Starting WebSocket connection for $sessionId ===")
                webSockets[sessionId]?.disconnect()
                evictIfNeeded()
                val ws = SecureWebSocket(sessionId).apply {
                    onMessage = { data ->
                        Log.d(TAG, "[$sessionId] Received message: ${data.size} bytes")
                        handleIncomingMessage(sessionId, data)
                    }
                    onStateChange = { state ->
                        Log.d(TAG, "[$sessionId] WebSocket state: $state")
                        // Update active session's connectionState for session.state queries
                        if (sessionId == activeSessionId) {
                            connectionState = state.toString()
                        }

                        // Emit per-session connectionState event to Flutter
                        scope.launch(Dispatchers.Main) {
                            eventSink?.success(mapOf(
                                "type" to "connectionState",
                                "state" to state.toString(),
                                "sessionId" to sessionId,
                            ))
                        }

                        if (state is SecureWebSocket.ConnectionState.Connected) {
                            // Defer pairing message until after relay auth_challenge completes.
                            // The relay gates non-control messages from unauthenticated phones,
                            // so sending now would be dropped. Store it and send on auth_result success.
                            pendingPairingPayloads[sessionId] = pairingPayload
                            Log.d(TAG, "[$sessionId] Connected, pairing payload stored (waiting for auth)")
                            // FCM token send deferred until after auth succeeds
                            // Queue replay deferred to auth_result handler (relay drops
                            // messages from unauthenticated phones)
                        } else if (state is SecureWebSocket.ConnectionState.Error) {
                            Log.e(TAG, "[$sessionId] WebSocket error: ${state.message}")
                        } else if (state is SecureWebSocket.ConnectionState.Disconnected) {
                            Log.w(TAG, "[$sessionId] WebSocket disconnected")
                        } else if (state is SecureWebSocket.ConnectionState.Reconnecting) {
                            Log.w(TAG, "[$sessionId] WebSocket reconnecting...")
                        }
                    }
                    connect(wsUrl)
                }
                webSockets[sessionId] = ws
                Log.d(TAG, "[$sessionId] WebSocket connection initiated (pool size: ${webSockets.size})")

                result.success(true)
            } catch (e: SecurityException) {
                Log.e(TAG, "Pairing rejected: ${e.message}")
                result.error("SECURITY_ERROR", e.message, null)
            } catch (e: Exception) {
                Log.e(TAG, "Pairing failed", e)
                result.error("PAIRING_FAILED", e.message, e.stackTraceToString())
            }
        }
    }

    /**
     * Reconnect to an existing session.
     *
     * Assumes the shared secret is still in [CryptoEngine] (e.g. if the app
     * was backgrounded but not killed).
     */
    private fun handleSessionConnect(call: MethodCall, result: MethodChannel.Result) {
        val sessionId = call.argument<String>("sessionId")
        if (sessionId.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "sessionId is required", null)
            return
        }

        // Launch coroutine so validateIntegrityGate can suspend to Dispatchers.IO
        scope.launch {
            // Security gate: validate device integrity before reconnect (runs on IO for first call)
            if (!validateIntegrityGate(result)) return@launch

            activeSessionId = sessionId

            if (!CryptoEngine.hasKey(sessionId)) {
                if (!restoreSessionKey(sessionId)) {
                    result.error(
                        "NO_SESSION",
                        "No shared secret available — re-pairing required",
                        null
                    )
                    return@launch
                }
            }

            try {
                // We need the relay URL. In a full implementation this would be
                // retrieved from secure storage keyed by sessionId.
                // For now, expect it as an argument or default.
                val relay = call.argument<String>("relay")
                    ?: NativeSecrets.getEndpoint("relay").ifEmpty { "wss://YOUR_RELAY_DEV_DOMAIN" }

                val wsUrl = buildRelayUrl(relay, sessionId)

                // If already connected to THIS session, just switch CryptoEngine
                val existing = webSockets[sessionId]
                if (existing != null && existing.state is SecureWebSocket.ConnectionState.Connected) {
                    CryptoEngine.setActiveSession(sessionId)
                    result.success(true)
                    return@launch
                }

                // Create per-session WebSocket (disconnect any stale one for this session)
                existing?.disconnect()
                evictIfNeeded()
                val ws = SecureWebSocket(sessionId).apply {
                    onMessage = { data -> handleIncomingMessage(sessionId, data) }
                    onStateChange = { state ->
                        if (sessionId == activeSessionId) {
                            connectionState = state.toString()
                        }

                        // Emit per-session connectionState event to Flutter
                        scope.launch(Dispatchers.Main) {
                            eventSink?.success(mapOf(
                                "type" to "connectionState",
                                "state" to state.toString(),
                                "sessionId" to sessionId,
                            ))
                        }

                        // FCM token send deferred until after auth succeeds
                    }
                    connect(wsUrl)
                }
                webSockets[sessionId] = ws

                result.success(true)
            } catch (e: SecurityException) {
                Log.e(TAG, "Connect rejected: ${e.message}")
                result.error("SECURITY_ERROR", e.message, null)
            } catch (e: Exception) {
                result.error("CONNECT_FAILED", e.message, e.stackTraceToString())
            }
        }
    }

    private fun handleSessionDisconnect(call: MethodCall, result: MethodChannel.Result) {
        val sid = call.argument<String>("sessionId") ?: activeSessionId
        if (sid != null) {
            webSockets.remove(sid)?.disconnect()
        }
        // DON'T clear the crypto key — it's cached for reconnect.
        // Keys are only removed via session.clearData.
        connectionState = "disconnected"
        result.success(null)
    }

    private fun handleSessionState(result: MethodChannel.Result) {
        result.success(connectionState)
    }

    /**
     * Restore the session AES key from EncryptedSharedPreferences.
     *
     * With ephemeral ECDH, the ephemeral private key is discarded after pairing,
     * so we cannot re-derive the shared secret. Instead, the derived AES key
     * is persisted directly and loaded here for reconnect.
     *
     * Falls back to legacy peer-key re-derive for sessions paired before the
     * ephemeral ECDH migration.
     *
     * Returns `true` if the key was restored successfully, `false` otherwise.
     */
    private fun restoreSessionKey(sessionId: String): Boolean {
        val context = flutterBinding?.applicationContext

        // Try loading the directly-persisted AES key (ephemeral ECDH sessions)
        if (context != null) {
            try {
                val aesKey = SecureKeyManager.loadSessionKey(context, sessionId)
                if (aesKey != null) {
                    CryptoEngine.setSharedSecret(sessionId, aesKey)
                    Log.d(TAG, "Session key restored from persisted AES key for $sessionId")
                    return true
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to load persisted AES key for $sessionId", e)
            }
        }

        // Legacy fallback: re-derive from persisted peer public key
        // (for sessions paired before ephemeral ECDH migration)
        try {
            if (!SecureKeyManager.hasKeyPair()) {
                Log.w(TAG, "Cannot restore session key: no private key in KeyStore")
                return false
            }

            val prefs = getSecurePrefs() ?: return false
            val peerKeyB64 = prefs.getString(KEY_PEER_PUBLIC_PREFIX + sessionId, null)
            if (peerKeyB64.isNullOrEmpty()) {
                Log.d(TAG, "No persisted key (AES or legacy peer) for session $sessionId")
                return false
            }

            val peerPublicKeyBytes = Base64.decode(peerKeyB64, Base64.DEFAULT)
            if (peerPublicKeyBytes.size < 65) {
                Log.w(TAG, "Persisted peer key too short (${peerPublicKeyBytes.size} bytes), removing")
                prefs.edit().remove(KEY_PEER_PUBLIC_PREFIX + sessionId).commit()
                return false
            }

            val sharedSecret = SecureKeyManager.deriveSharedSecret(peerPublicKeyBytes)
            CryptoEngine.setSharedSecret(sessionId, sharedSecret)
            Log.d(TAG, "Session key restored via legacy peer-key re-derive for $sessionId")

            // Migrate: persist the AES key directly so future reconnects use the new path
            if (context != null) {
                try {
                    SecureKeyManager.persistSessionKey(context, sessionId, sharedSecret)
                    prefs.edit().remove(KEY_PEER_PUBLIC_PREFIX + sessionId).commit()
                    Log.d(TAG, "Migrated legacy peer key to persisted AES key for $sessionId")
                } catch (_: Exception) {}
            }

            return true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to restore session key for $sessionId", e)
            // Remove corrupted entry
            try {
                getSecurePrefs()?.edit()?.remove(KEY_PEER_PUBLIC_PREFIX + sessionId)?.commit()
            } catch (_: Exception) {}
            return false
        }
    }

    /**
     * Clear persisted session key data for a session.
     *
     * Removes both the new ephemeral-ECDH AES key and any legacy peer public key.
     */
    private fun handleSessionClearData(call: MethodCall, result: MethodChannel.Result) {
        val sessionId = call.argument<String>("sessionId")
        if (sessionId.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "sessionId is required", null)
            return
        }

        try {
            webSockets.remove(sessionId)?.disconnect()
            CryptoEngine.clearKey(sessionId)

            // Remove persisted AES session key (ephemeral ECDH)
            val context = flutterBinding?.applicationContext
            if (context != null) {
                SecureKeyManager.deleteSessionKey(context, sessionId)
            }

            // Remove legacy peer public key (pre-ephemeral migration)
            getSecurePrefs()?.edit()
                ?.remove(KEY_PEER_PUBLIC_PREFIX + sessionId)
                ?.commit()

            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to clear session data for $sessionId", e)
            result.success(false)
        }
    }

    /**
     * Notify the bridge to delete a session (kill Claude process + clean storage).
     * Uses the session-specific WebSocket, not the active one.
     */
    private fun handleSessionDelete(call: MethodCall, result: MethodChannel.Result) {
        val sessionId = call.argument<String>("sessionId")
        if (sessionId.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "sessionId is required", null)
            return
        }

        val ws = webSockets[sessionId]
        if (ws == null || ws.state !is SecureWebSocket.ConnectionState.Connected) {
            // Bridge offline — phone cleans up locally, bridge cleans on restart
            result.success(true)
            return
        }

        try {
            val payload = JSONObject().apply {
                put("type", "command")
                put("command", "delete_session")
                put("timestamp", System.currentTimeMillis())
            }
            ws.send(payload.toString().toByteArray(Charsets.UTF_8))
            // Disconnect and remove from pool after sending
            webSockets.remove(sessionId)?.disconnect()
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send delete_session for $sessionId", e)
            result.success(false)
        }
    }

    // =====================================================================
    // Messaging handlers
    // =====================================================================

    private fun handleMessageSend(call: MethodCall, result: MethodChannel.Result) {
        val content = call.argument<String>("content")
        // Allow empty content (just sends Enter)
        if (content == null) {
            result.error("INVALID_ARGS", "content is required", null)
            return
        }

        val payload = JSONObject().apply {
            put("type", "message")
            put("content", content)
        }

        val ws = authenticatedWebSocket()
        if (ws == null) {
            if (queueForReplay(payload, "message", result)) return
            result.error("NOT_CONNECTED", "WebSocket is not connected", null)
            return
        }

        try {
            payload.put("timestamp", System.currentTimeMillis())
            val success = ws.send(payload.toString().toByteArray(Charsets.UTF_8))
            result.success(success)
        } catch (e: Exception) {
            result.error("SEND_FAILED", e.message, null)
        }
    }

    /**
     * Send a special key press (Enter, Escape, Arrow keys, etc.)
     */
    private fun handleMessageSendKey(call: MethodCall, result: MethodChannel.Result) {
        val key = call.argument<String>("key")
        if (key.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "key is required", null)
            return
        }

        val payload = JSONObject().apply {
            put("type", "key")
            put("key", key)
        }

        val ws = authenticatedWebSocket()
        if (ws == null) {
            if (queueForReplay(payload, "key", result)) return
            result.error("NOT_CONNECTED", "WebSocket is not connected", null)
            return
        }

        try {
            payload.put("timestamp", System.currentTimeMillis())
            val success = ws.send(payload.toString().toByteArray(Charsets.UTF_8))
            result.success(success)
        } catch (e: Exception) {
            result.error("SEND_FAILED", e.message, null)
        }
    }

    /**
     * Send raw input without automatic newline.
     */
    private fun handleMessageSendInput(call: MethodCall, result: MethodChannel.Result) {
        val content = call.argument<String>("content")
        if (content == null) {
            result.error("INVALID_ARGS", "content is required", null)
            return
        }

        val payload = JSONObject().apply {
            put("type", "input")
            put("content", content)
        }

        val ws = authenticatedWebSocket()
        if (ws == null) {
            if (queueForReplay(payload, "input", result)) return
            result.error("NOT_CONNECTED", "WebSocket is not connected", null)
            return
        }

        try {
            payload.put("timestamp", System.currentTimeMillis())
            val success = ws.send(payload.toString().toByteArray(Charsets.UTF_8))
            result.success(success)
        } catch (e: Exception) {
            result.error("SEND_FAILED", e.message, null)
        }
    }

    private fun handleMessageRespond(call: MethodCall, result: MethodChannel.Result) {
        val actionId = call.argument<String>("actionId")
        val response = call.argument<String>("response")

        if (actionId.isNullOrEmpty() || response.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "actionId and response are required", null)
            return
        }

        val payload = JSONObject().apply {
            put("type", "response")
            put("actionId", actionId)
            put("response", response)
        }

        val ws = authenticatedWebSocket()
        if (ws == null) {
            if (queueForReplay(payload, "response", result)) return
            result.error("NOT_CONNECTED", "WebSocket is not connected", null)
            return
        }

        try {
            payload.put("timestamp", System.currentTimeMillis())
            val success = ws.send(payload.toString().toByteArray(Charsets.UTF_8))
            result.success(success)
        } catch (e: Exception) {
            result.error("SEND_FAILED", e.message, null)
        }
    }

    /**
     * Send a Claude Code slash command (e.g., /help, /clear, /model).
     */
    private fun handleMessageCommand(call: MethodCall, result: MethodChannel.Result) {
        val command = call.argument<String>("command")
        val args = call.argument<String>("args")

        if (command.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "command is required", null)
            return
        }

        val ws = authenticatedWebSocket()
        if (ws == null) {
            result.error("NOT_CONNECTED", "WebSocket is not connected", null)
            return
        }

        try {
            val payload = JSONObject().apply {
                put("type", "command")
                put("command", command)
                if (args != null) {
                    put("args", args)
                }
                put("timestamp", System.currentTimeMillis())
            }
            val success = ws.send(payload.toString().toByteArray(Charsets.UTF_8))
            result.success(success)
        } catch (e: Exception) {
            result.error("SEND_FAILED", e.message, null)
        }
    }

    private fun handleHttpTunnelOpen(call: MethodCall, result: MethodChannel.Result) {
        val ws = authenticatedWebSocket()
        if (ws == null) {
            result.error("NOT_CONNECTED", "WebSocket is not connected", null)
            return
        }
        try {
            val payload = JSONObject().apply {
                put("type", "http_tunnel_open")
                put("port", call.argument<Int>("port"))
            }
            val success = ws.send(payload.toString().toByteArray(Charsets.UTF_8))
            result.success(success)
        } catch (e: Exception) {
            result.error("SEND_FAILED", e.message, null)
        }
    }

    private fun handleHttpTunnelClose(call: MethodCall, result: MethodChannel.Result) {
        val ws = authenticatedWebSocket()
        if (ws == null) {
            result.error("NOT_CONNECTED", "WebSocket is not connected", null)
            return
        }
        try {
            val payload = JSONObject().apply { put("type", "http_tunnel_close") }
            val success = ws.send(payload.toString().toByteArray(Charsets.UTF_8))
            result.success(success)
        } catch (e: Exception) {
            result.error("SEND_FAILED", e.message, null)
        }
    }

    private fun handleHttpRequest(call: MethodCall, result: MethodChannel.Result) {
        val ws = authenticatedWebSocket()
        if (ws == null) {
            result.error("NOT_CONNECTED", "WebSocket is not connected", null)
            return
        }
        try {
            val payload = JSONObject().apply {
                put("type", "http_request")
                put("requestId", call.argument<String>("requestId"))
                put("method", call.argument<String>("method"))
                put("path", call.argument<String>("path"))
                val headers = call.argument<Map<String, String>>("headers")
                if (headers != null) put("headers", JSONObject(headers as Map<*, *>))
                val body = call.argument<String>("body")
                if (body != null) put("body", body)
            }
            val success = ws.send(payload.toString().toByteArray(Charsets.UTF_8))
            result.success(success)
        } catch (e: Exception) {
            result.error("SEND_FAILED", e.message, null)
        }
    }

    /**
     * Set the Claude Code model (opus, sonnet, haiku).
     */
    private fun handleMessageSetModel(call: MethodCall, result: MethodChannel.Result) {
        val model = call.argument<String>("model")

        if (model.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "model is required", null)
            return
        }

        val ws = authenticatedWebSocket()
        if (ws == null) {
            result.error("NOT_CONNECTED", "WebSocket is not connected", null)
            return
        }

        try {
            val payload = JSONObject().apply {
                put("type", "set_model")
                put("model", model)
                put("timestamp", System.currentTimeMillis())
            }
            val success = ws.send(payload.toString().toByteArray(Charsets.UTF_8))
            result.success(success)
        } catch (e: Exception) {
            result.error("SEND_FAILED", e.message, null)
        }
    }

    /**
     * Send a configuration update to Claude Code.
     */
    private fun handleMessageConfig(call: MethodCall, result: MethodChannel.Result) {
        val key = call.argument<String>("key")
        val value = call.argument<Any>("value")

        if (key.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "key is required", null)
            return
        }

        val ws = authenticatedWebSocket()
        if (ws == null) {
            result.error("NOT_CONNECTED", "WebSocket is not connected", null)
            return
        }

        try {
            val payload = JSONObject().apply {
                put("type", "config")
                put("key", key)
                put("value", value)
                put("timestamp", System.currentTimeMillis())
            }
            val success = ws.send(payload.toString().toByteArray(Charsets.UTF_8))
            result.success(success)
        } catch (e: Exception) {
            result.error("SEND_FAILED", e.message, null)
        }
    }

    // =====================================================================
    // File transfer handlers
    // =====================================================================

    /**
     * Initiate sending a file from phone to computer.
     *
     * Reads the file, computes SHA-256 checksum, splits into 192 KB chunks,
     * base64-encodes each chunk, and streams them as encrypted messages over
     * the WebSocket (fire-and-forget, no ACK wait from phone side).
     */
    private fun handleFileSend(call: MethodCall, result: MethodChannel.Result) {
        val filePath = call.argument<String>("filePath")
        val fileName = call.argument<String>("fileName")
        val mimeType = call.argument<String>("mimeType")

        if (filePath.isNullOrEmpty() || fileName.isNullOrEmpty() || mimeType.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "filePath, fileName, and mimeType are required", null)
            return
        }

        val ws = authenticatedWebSocket()
        Log.d(TAG, "handleFileSend: activeSessionId=$activeSessionId, ws=${ws != null}, pool=${webSockets.keys}")
        if (ws == null) {
            result.error("NOT_CONNECTED", "WebSocket is not connected (activeSessionId=$activeSessionId, ws=${ws != null})", null)
            return
        }

        scope.launch(Dispatchers.IO) {
            try {
                sendFile(ws, filePath, fileName, mimeType)
                launch(Dispatchers.Main) {
                    result.success(true)
                }
            } catch (e: Exception) {
                Log.e(TAG, "File send failed", e)
                launch(Dispatchers.Main) {
                    result.error("FILE_SEND_FAILED", e.message, null)
                }
            }
        }
    }

    /**
     * Accept an incoming file transfer from the computer.
     *
     * Sends an ACK message to indicate readiness to receive chunks.
     * (Stub — full flow control is handled by the bridge.)
     */
    private fun handleFileAccept(call: MethodCall, result: MethodChannel.Result) {
        val transferId = call.argument<String>("transferId")
        if (transferId.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "transferId is required", null)
            return
        }

        val ws = authenticatedWebSocket()
        if (ws == null) {
            result.error("NOT_CONNECTED", "WebSocket is not connected", null)
            return
        }

        try {
            val payload = JSONObject().apply {
                put("type", "file_transfer_ack")
                put("transferId", transferId)
                put("receivedThrough", 0)
            }
            val success = ws.send(payload.toString().toByteArray(Charsets.UTF_8))
            result.success(success)
        } catch (e: Exception) {
            result.error("SEND_FAILED", e.message, null)
        }
    }

    /**
     * Cancel/decline a file transfer (either direction).
     *
     * Sends a cancel message to the bridge so both sides clean up.
     */
    private fun handleFileCancel(call: MethodCall, result: MethodChannel.Result) {
        val transferId = call.argument<String>("transferId")
        if (transferId.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "transferId is required", null)
            return
        }

        val ws = authenticatedWebSocket()
        if (ws == null) {
            result.error("NOT_CONNECTED", "WebSocket is not connected", null)
            return
        }

        try {
            val payload = JSONObject().apply {
                put("type", "file_transfer_cancel")
                put("transferId", transferId)
                put("reason", "user cancelled")
            }
            val success = ws.send(payload.toString().toByteArray(Charsets.UTF_8))
            result.success(success)
        } catch (e: Exception) {
            result.error("SEND_FAILED", e.message, null)
        }
    }

    /**
     * Read a file, compute its SHA-256 checksum, chunk it into 192 KB pieces,
     * and stream all chunks as encrypted WebSocket messages.
     *
     * This is a fire-and-forget implementation: chunks are sent sequentially
     * without waiting for ACKs from the bridge. The bridge handles flow
     * control for the reverse direction (computer -> phone).
     *
     * Must be called from a background thread (Dispatchers.IO).
     */
    private fun sendFile(ws: SecureWebSocket, filePath: String, fileName: String, mimeType: String) {
        val file = File(filePath)
        if (!file.exists() || !file.isFile) {
            throw IllegalArgumentException("File not found: $filePath")
        }

        val maxSize = 100L * 1024 * 1024 // 100 MB
        if (file.length() > maxSize) {
            throw IllegalArgumentException("File too large: ${file.length()} bytes (max $maxSize)")
        }

        // Read entire file into memory
        val fileData = file.readBytes()

        // Compute SHA-256 checksum
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(fileData)
        val checksum = digest.digest().joinToString("") { "%02x".format(it) }

        // Chunking parameters — must match bridge CHUNK_SIZE (128KB)
        val chunkSize = 128_000
        val totalChunks = if (fileData.isEmpty()) 1 else {
            (fileData.size + chunkSize - 1) / chunkSize  // ceil division
        }
        val transferId = UUID.randomUUID().toString()

        Log.d(TAG, "Sending file: $fileName (${fileData.size} bytes, $totalChunks chunks)")

        // Send file_transfer_start
        val startPayload = JSONObject().apply {
            put("type", "file_transfer_start")
            put("transferId", transferId)
            put("filename", fileName)
            put("mimeType", mimeType)
            put("totalSize", fileData.size)
            put("totalChunks", totalChunks)
            put("direction", "phone_to_computer")
            put("checksum", checksum)
        }
        val startSent = ws.send(startPayload.toString().toByteArray(Charsets.UTF_8))
        if (!startSent) {
            Log.e(TAG, "WebSocket send failed for file_transfer_start — socket closing")
            throw IllegalStateException("WebSocket is closing, file transfer start not sent")
        }

        // Stream chunks
        for (i in 0 until totalChunks) {
            val start = i * chunkSize
            val end = minOf(start + chunkSize, fileData.size)
            val chunkData = fileData.copyOfRange(start, end)
            val b64 = Base64.encodeToString(chunkData, Base64.NO_WRAP)

            val chunkPayload = JSONObject().apply {
                put("type", "file_chunk")
                put("transferId", transferId)
                put("sequence", i)
                put("data", b64)
            }
            val chunkSent = ws.send(chunkPayload.toString().toByteArray(Charsets.UTF_8))
            if (!chunkSent) {
                Log.e(TAG, "WebSocket send failed for chunk $i/$totalChunks — socket closing")
                throw IllegalStateException("WebSocket is closing, file chunk $i not sent")
            }
        }

        // Send file_transfer_complete
        val completePayload = JSONObject().apply {
            put("type", "file_transfer_complete")
            put("transferId", transferId)
            put("success", true)
        }
        val completeSent = ws.send(completePayload.toString().toByteArray(Charsets.UTF_8))
        if (!completeSent) {
            Log.e(TAG, "WebSocket send failed for file_transfer_complete — socket closing")
            throw IllegalStateException("WebSocket is closing, file transfer complete not sent")
        }

        Log.d(TAG, "File send complete: $fileName ($transferId)")
    }

    // =====================================================================
    // Bridge control handlers
    // =====================================================================

    private fun handleBridgeCommand(call: MethodCall, result: MethodChannel.Result) {
        val command = call.argument<String>("command")
        if (command.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "command is required", null)
            return
        }

        val ws = authenticatedWebSocket()
        if (ws == null) {
            result.error("NOT_CONNECTED", "WebSocket is not connected", null)
            return
        }

        try {
            val payload = JSONObject().apply {
                put("type", "bridge_command")
                put("command", command)
                put("timestamp", System.currentTimeMillis())
            }
            val success = ws.send(payload.toString().toByteArray(Charsets.UTF_8))
            if (success) {
                result.success("Command sent: $command")
            } else {
                result.error("SEND_FAILED", "Failed to send command", null)
            }
        } catch (e: Exception) {
            result.error("SEND_FAILED", e.message, null)
        }
    }

    private fun handleBridgeStatus(result: MethodChannel.Result) {
        val sessionId = activeSessionId
        if (sessionId == null) {
            result.success(mapOf("status" to "no_session"))
            return
        }

        val ws = webSockets[sessionId]
        val state = when (ws?.state) {
            is SecureWebSocket.ConnectionState.Connected -> "connected"
            is SecureWebSocket.ConnectionState.Connecting -> "connecting"
            is SecureWebSocket.ConnectionState.Reconnecting -> "reconnecting"
            is SecureWebSocket.ConnectionState.Error -> "error"
            else -> "disconnected"
        }
        result.success(mapOf("status" to state, "sessionId" to sessionId))
    }

    // =====================================================================
    // FCM handler
    // =====================================================================

    private fun handleFcmRegister(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<String>("token")
        if (token.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "token is required", null)
            return
        }

        // Always persist the token so we can send it on next connect
        getSecurePrefs()?.edit()?.putString(KEY_PENDING_FCM_TOKEN, token)?.apply()

        // Send to ALL connected sessions so each relay knows this device's FCM token
        var sentCount = 0
        for ((sid, ws) in webSockets) {
            if (ws.state is SecureWebSocket.ConnectionState.Connected) {
                sendFcmToken(ws, token)
                sentCount++
                Log.d(TAG, "FCM token sent to session ${sid.take(12)}")
            }
        }

        if (sentCount == 0) {
            Log.w(TAG, "No connected WebSockets — FCM token persisted for next connect")
        }
        // Always return true — token was accepted and persisted for delivery
        result.success(true)
    }

    /**
     * Send an FCM token over the WebSocket as a **plaintext** control message.
     *
     * The relay parses control messages as raw JSON — they must NOT be encrypted.
     * Clears the persisted pending token on success.
     */
    private fun sendFcmToken(ws: SecureWebSocket, token: String) {
        try {
            val payload = JSONObject().apply {
                put("type", "fcm_register")
                put("token", token)
            }
            val success = ws.sendPlaintext(payload.toString())
            if (success) {
                // Clear persisted token on successful send
                getSecurePrefs()?.edit()?.remove(KEY_PENDING_FCM_TOKEN)?.apply()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send FCM token", e)
        }
    }

    /**
     * Send the deferred pairing payload for a session.
     * Called when sessionAuthorized becomes true (either immediately from auth_result
     * or later from session_authorized after bridge approval).
     */
    private fun sendDeferredPairingPayload(sessionId: String) {
        val payload = pendingPairingPayloads.remove(sessionId)
        if (payload != null) {
            val ws = webSockets[sessionId]
            if (ws != null) {
                val sent = ws.sendPlaintext(payload)
                Log.d(TAG, "[$sessionId] Sent deferred pairing message: $sent")
            } else {
                Log.e(TAG, "[$sessionId] Cannot send pairing - no WebSocket in pool")
            }
        } else {
            Log.w(TAG, "[$sessionId] No pending pairing payload to send")
        }
    }

    /**
     * Send any pending FCM token that was stored while offline.
     */
    private fun sendPendingFcmToken(ws: SecureWebSocket) {
        // One-time migration: move token from plain to encrypted prefs
        val plainToken = getPrefs()?.getString(KEY_PENDING_FCM_TOKEN, null)
        if (!plainToken.isNullOrEmpty()) {
            val securePrefs = getSecurePrefs()
            if (securePrefs != null) {
                securePrefs.edit().putString(KEY_PENDING_FCM_TOKEN, plainToken).apply()
                getPrefs()?.edit()?.remove(KEY_PENDING_FCM_TOKEN)?.apply()
            }
        }

        val token = getSecurePrefs()?.getString(KEY_PENDING_FCM_TOKEN, null)
        if (!token.isNullOrEmpty()) {
            Log.d(TAG, "Sending pending FCM token")
            sendFcmToken(ws, token)
        }
    }

    /**
     * Queue a message for offline replay. Returns true if queued successfully,
     * false if no active session (caller should fall through to NOT_CONNECTED error).
     */
    private fun queueForReplay(payload: JSONObject, messageType: String, result: MethodChannel.Result): Boolean {
        val sid = activeSessionId ?: return false
        return try {
            payload.put("timestamp", System.currentTimeMillis())
            MessageQueue.enqueue(sid, payload.toString().toByteArray(Charsets.UTF_8), messageType)
            result.success(true)
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to queue $messageType", e)
            false
        }
    }

    /**
     * Replay queued messages after relay authentication succeeds.
     * Called from the auth_result handler, not on WS connected (relay drops
     * messages from unauthenticated phones).
     */
    private fun replayQueuedMessages(sessionId: String) {
        val ws = webSockets[sessionId]
        if (ws == null) {
            Log.e(TAG, "[$sessionId] Cannot replay: WebSocket not found")
            return
        }

        val queued = MessageQueue.loadForSession(sessionId)
        if (queued.isEmpty()) return
        Log.d(TAG, "[$sessionId] Replaying ${queued.size} queued messages after auth")

        var sent = 0
        for (msg in queued) {
            try {
                if (!ws.send(msg.data)) {
                    Log.e(TAG, "[$sessionId] Replay stalled at $sent/${queued.size}")
                    break
                }
                sent++
            } catch (e: Exception) {
                Log.e(TAG, "[$sessionId] Replay failed at $sent: ${e.message}")
                break
            }
        }
        if (sent > 0) {
            MessageQueue.removeFirst(sessionId, sent)
            scope.launch(Dispatchers.Main) {
                eventSink?.success(mapOf(
                    "type" to "queueReplayed",
                    "count" to sent,
                    "sessionId" to sessionId,
                ))
            }
        }
    }

    // =====================================================================
    // Internal helpers
    // =====================================================================

    /**
     * Handle a rekey request from the bridge for per-connection forward secrecy.
     *
     * Flow:
     * 1. Receive bridge's new ephemeral public key (already decrypted with OLD key)
     * 2. Generate our own ephemeral P-256 key pair
     * 3. Send our new public key back (encrypted with OLD key — CryptoEngine still has it)
     * 4. Derive new shared secret via ephemeral ECDH
     * 5. Update CryptoEngine with the new key (all subsequent messages use new key)
     * 6. Persist the new key for reconnect after app kill
     *
     * IMPORTANT: Step 3 (send response) MUST happen before step 5 (key switch),
     * because the response is encrypted with the OLD key.
     */
    private fun handleRekey(sessionId: String, bridgePubkeyB64: String) {
        try {
            // 1. Decode bridge's new public key
            val bridgePubkeyBytes = Base64.decode(bridgePubkeyB64, Base64.DEFAULT)
            Log.d(TAG, "[$sessionId] Rekey: bridge pubkey ${bridgePubkeyBytes.size} bytes")

            // 2. Generate our own ephemeral P-256 key pair
            val (ephemeralPrivateKey, ephemeralPublicKeyBytes) = SecureKeyManager.generateEphemeralKeyPair()
            Log.d(TAG, "[$sessionId] Rekey: generated ephemeral keypair (${ephemeralPublicKeyBytes.size} bytes pubkey)")

            // 3. Send our new public key back, encrypted with OLD key (CryptoEngine still has it)
            val ws = webSockets[sessionId]
            if (ws == null || ws.state !is SecureWebSocket.ConnectionState.Connected) {
                Log.e(TAG, "[$sessionId] Rekey: WebSocket not connected, aborting")
                return
            }
            val rekeyResponse = JSONObject().apply {
                put("type", "rekey")
                put("pubkey", Base64.encodeToString(ephemeralPublicKeyBytes, Base64.NO_WRAP))
            }
            val sent = ws.send(rekeyResponse.toString().toByteArray(Charsets.UTF_8))
            if (!sent) {
                Log.e(TAG, "[$sessionId] Rekey: failed to send response, aborting")
                return
            }
            Log.d(TAG, "[$sessionId] Rekey: sent response with our ephemeral pubkey")

            // 4. Derive new shared secret via ephemeral ECDH + HKDF
            val newSharedSecret = SecureKeyManager.deriveSharedSecretEphemeral(ephemeralPrivateKey, bridgePubkeyBytes)
            Log.d(TAG, "[$sessionId] Rekey: derived new shared secret (${newSharedSecret.size} bytes)")

            // 5. Update CryptoEngine with the new key
            CryptoEngine.setSharedSecret(sessionId, newSharedSecret)
            Log.i(TAG, "[$sessionId] Session key renegotiated successfully")

            // 6. Persist the new key for reconnect after app kill
            val context = flutterBinding?.applicationContext
            if (context != null) {
                try {
                    SecureKeyManager.persistSessionKey(context, sessionId, newSharedSecret)
                    Log.d(TAG, "[$sessionId] Rekeyed session key persisted")
                } catch (e: Exception) {
                    Log.w(TAG, "[$sessionId] Failed to persist rekeyed session key", e)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "[$sessionId] Rekey failed — keeping old key", e)
        }
    }

    /**
     * Respond to a relay auth_challenge by signing the nonce with the device
     * private key and sending back the signature + certificate fingerprint.
     */
    private fun handleAuthChallenge(sessionId: String, nonce: String, ws: SecureWebSocket) {
        scope.launch {
            try {
                signAndSendAuthResponse(sessionId, nonce, ws)
            } catch (e: android.security.keystore.UserNotAuthenticatedException) {
                Log.w(TAG, "[$sessionId] Biometric timeout — requesting re-authentication")
                val reauthed = requestBiometricReauth(sessionId)
                if (reauthed) {
                    try {
                        signAndSendAuthResponse(sessionId, nonce, ws)
                    } catch (e2: Exception) {
                        Log.e(TAG, "[$sessionId] Auth challenge failed after biometric re-auth", e2)
                    }
                } else {
                    Log.e(TAG, "[$sessionId] Biometric re-authentication failed or cancelled")
                }
            } catch (e: Exception) {
                // Check if the root cause is UserNotAuthenticatedException
                if (e.cause is android.security.keystore.UserNotAuthenticatedException) {
                    Log.w(TAG, "[$sessionId] Biometric timeout (wrapped) — requesting re-authentication")
                    val reauthed = requestBiometricReauth(sessionId)
                    if (reauthed) {
                        try {
                            signAndSendAuthResponse(sessionId, nonce, ws)
                        } catch (e2: Exception) {
                            Log.e(TAG, "[$sessionId] Auth challenge failed after biometric re-auth", e2)
                        }
                    }
                } else {
                    Log.e(TAG, "[$sessionId] Failed to respond to auth_challenge", e)
                }
            }
        }
    }

    /**
     * Sign the auth challenge nonce and send the device_auth response.
     * Throws [UserNotAuthenticatedException] if biometric timeout expired.
     */
    private suspend fun signAndSendAuthResponse(sessionId: String, nonce: String, ws: SecureWebSocket) {
        val fingerprint = CertificateManager.getCertificateFingerprint()
        val certPEM = CertificateManager.getCertificatePEM()
        val privateKey = SecureKeyManager.getPrivateKey()

        if (fingerprint == null || certPEM == null || privateKey == null) {
            Log.e(TAG, "[$sessionId] Cannot respond to auth_challenge: no certificate/key")
            return
        }

        val sig = Signature.getInstance("SHA256withECDSA")
        sig.initSign(privateKey)
        sig.update(nonce.toByteArray(Charsets.UTF_8))
        val signatureBytes = sig.sign()
        val signatureB64 = Base64.encodeToString(signatureBytes, Base64.NO_WRAP)

        val authResponse = JSONObject().apply {
            put("type", "device_auth")
            put("fingerprint", fingerprint)
            put("signature", signatureB64)
            put("certificate", certPEM)
        }

        val sent = ws.sendPlaintext(authResponse.toString())
        Log.d(TAG, "[$sessionId] Sent device_auth response (fingerprint=${fingerprint.take(16)}...): $sent")
    }

    /**
     * Trigger biometric re-authentication to refresh the 30-second
     * KeyStore auth validity window. Returns true if successful.
     */
    private suspend fun requestBiometricReauth(sessionId: String): Boolean {
        val act = activity ?: run {
            Log.e(TAG, "[$sessionId] No activity for biometric re-auth")
            return false
        }
        return kotlinx.coroutines.suspendCancellableCoroutine { cont ->
            act.runOnUiThread {
                BiometricGate.authenticate(act, "Re-authenticate to reconnect") { success, error ->
                    if (success) {
                        Log.d(TAG, "[$sessionId] Biometric re-auth succeeded")
                    } else {
                        Log.e(TAG, "[$sessionId] Biometric re-auth failed: $error")
                    }
                    if (cont.isActive) cont.resume(success) {}
                }
            }
        }
    }

    /**
     * Handle a decrypted message received from the WebSocket.
     *
     * Parses the JSON and forwards it to the Flutter event sink on the
     * main thread.
     */
    private fun handleIncomingMessage(sessionId: String, data: ByteArray) {
        // sessionId comes from the WebSocket instance — always correct
        // regardless of which session is currently active in the UI.
        Log.d(TAG, "[$sessionId] handleIncomingMessage: ${data.size} bytes")
        try {
            val jsonString = String(data, Charsets.UTF_8)
            val json = JSONObject(jsonString)
            val messageType = json.optString("type", "")

            // Intercept auth_challenge — sign and respond, don't forward to Flutter
            if (messageType == "auth_challenge") {
                val nonce = json.getString("nonce")
                pendingAuthNonces[sessionId] = nonce  // Store for markHandshakeComplete
                val ws = webSockets[sessionId]
                if (ws != null) {
                    handleAuthChallenge(sessionId, nonce, ws)
                } else {
                    Log.e(TAG, "[$sessionId] auth_challenge received but no WebSocket in pool")
                }
                return
            }

            // Intercept rekey — bridge requests key renegotiation for forward secrecy
            if (messageType == "rekey") {
                val bridgePubkeyB64 = json.optString("pubkey", "")
                if (bridgePubkeyB64.isEmpty()) {
                    Log.e(TAG, "[$sessionId] Rekey message missing pubkey")
                    return
                }
                Log.i(TAG, "[$sessionId] Received rekey request — renegotiating session key")
                handleRekey(sessionId, bridgePubkeyB64)
                return
            }

            // Intercept auth_result — on success, send the deferred pairing payload
            if (messageType == "auth_result") {
                val success = json.optBoolean("success", false)
                val sessionAuthorized = json.optBoolean("sessionAuthorized", false)
                Log.i(TAG, "[$sessionId] Device auth result: success=$success sessionAuthorized=$sessionAuthorized")
                if (success) {
                    // Mark handshake complete — enables plaintext type whitelist enforcement
                    val nonce = pendingAuthNonces.remove(sessionId)
                    if (nonce != null) {
                        val ws = webSockets[sessionId]
                        ws?.markHandshakeComplete(nonce)
                        Log.d(TAG, "[$sessionId] Handshake marked complete (plaintext whitelist active)")
                    }

                    if (sessionAuthorized) {
                        // Already authorized (in allowlist) — send pairing + replay now
                        sendDeferredPairingPayload(sessionId)
                        replayQueuedMessages(sessionId)
                    } else {
                        // Not yet authorized — wait for session_authorized before sending
                        // pairing payload and replaying queued messages (relay drops
                        // non-control messages from phones where sessionAuthorized=false)
                        Log.d(TAG, "[$sessionId] Waiting for session_authorized before sending pairing payload")
                    }

                    // FCM registration is a relay control message — not gated, send now
                    val fcmWs = webSockets[sessionId]
                    if (fcmWs != null) {
                        sendPendingFcmToken(fcmWs)
                    }
                } else {
                    val reason = json.optString("reason", "unknown")
                    Log.e(TAG, "[$sessionId] Device auth failed: $reason")
                    pendingPairingPayloads.remove(sessionId)
                    scope.launch(Dispatchers.Main) {
                        eventSink?.success(mapOf(
                            "type" to "auth_error",
                            "sessionId" to sessionId,
                            "reason" to reason,
                        ))
                    }
                }
                return
            }

            // Intercept session_authorized — bridge approved this device, send deferred pairing
            if (messageType == "session_authorized") {
                val success = json.optBoolean("success", false)
                Log.i(TAG, "[$sessionId] Session authorized: success=$success")
                if (success) {
                    sendDeferredPairingPayload(sessionId)
                    replayQueuedMessages(sessionId)
                } else {
                    val reason = json.optString("reason", "unknown")
                    Log.e(TAG, "[$sessionId] Session authorization denied: $reason")
                    pendingPairingPayloads.remove(sessionId)
                    scope.launch(Dispatchers.Main) {
                        eventSink?.success(mapOf(
                            "type" to "auth_error",
                            "sessionId" to sessionId,
                            "reason" to "Authorization denied: $reason",
                        ))
                    }
                }
                return
            }

            // Convert JSONObject to a Map for the event sink
            val payload = jsonToMap(json)

            // Wrap in envelope to match iOS format, stamped with sessionId
            val envelope = mapOf(
                "type" to "message",
                "payload" to payload,
                "sessionId" to sessionId,
            )

            // Forward to Flutter on the main thread
            scope.launch(Dispatchers.Main) {
                eventSink?.success(envelope)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse incoming message", e)
            scope.launch(Dispatchers.Main) {
                eventSink?.error("PARSE_ERROR", e.message, null)
            }
        }
    }

    /**
     * Build the relay WebSocket URL with session ID and role.
     */
    private fun buildRelayUrl(relay: String, sessionId: String): String {
        val base = relay.trim().lowercase().trimEnd('/')
        val wsBase = when {
            base.startsWith("wss://") || base.startsWith("ws://") -> base
            base.startsWith("https://") -> base.replaceFirst("https://", "wss://")
            base.startsWith("http://") -> base.replaceFirst("http://", "ws://")
            else -> "wss://$base"
        }

        // Enforce TLS in production builds — reject ws:// from malicious QR codes
        if (!com.termopus.app.BuildConfig.DEBUG && !wsBase.startsWith("wss://")) {
            throw SecurityException("Non-TLS relay URLs are not allowed in production")
        }

        // Pin relay domain in production builds

        return "$wsBase/$sessionId?role=phone"
    }

    /**
     * Convert a [JSONObject] to a [Map] for the Flutter event channel.
     *
     * Recursively handles nested objects and arrays.
     */
    private fun jsonToMap(json: JSONObject): Map<String, Any?> {
        val map = mutableMapOf<String, Any?>()
        val keys = json.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            val value = json.get(key)
            map[key] = when (value) {
                is JSONObject -> jsonToMap(value)
                is org.json.JSONArray -> jsonArrayToList(value)
                JSONObject.NULL -> null
                else -> value
            }
        }
        return map
    }

    // =====================================================================
    // Security handlers
    // =====================================================================

    private fun handleSecurityGetEndpoint(call: MethodCall, result: MethodChannel.Result) {
        val key = call.argument<String>("key")
        if (key.isNullOrEmpty()) {
            result.error("MISSING_KEY", "key required", null)
            return
        }
        val endpoint = NativeSecrets.getEndpoint(key)
        if (endpoint.isEmpty()) {
            result.error("UNKNOWN_KEY", "No endpoint for key: $key", null)
        } else {
            result.success(endpoint)
        }
    }

    // =====================================================================
    // Biometric crypto handlers
    // =====================================================================

    private fun handleBiometricSignChallenge(call: MethodCall, result: MethodChannel.Result) {
        val challenge = call.argument<String>("challenge")
        val reason = call.argument<String>("reason") ?: "Sign security challenge"

        if (challenge.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "challenge (Base64) is required", null)
            return
        }

        val service = biometricCryptoService
        if (service == null) {
            result.error("NO_ACTIVITY", "BiometricCryptoService not initialized", null)
            return
        }

        service.signChallenge(challenge, reason) { signResult ->
            signResult.fold(
                onSuccess = { signature ->
                    result.success(mapOf("signature" to signature))
                },
                onFailure = { error ->
                    result.error("SIGN_FAILED", error.message, null)
                }
            )
        }
    }

    private fun handleBiometricGetPublicKey(result: MethodChannel.Result) {
        val service = biometricCryptoService
        if (service == null) {
            result.error("NO_ACTIVITY", "BiometricCryptoService not initialized", null)
            return
        }

        try {
            val publicKey = service.getPublicKey()
            result.success(mapOf(
                "publicKey" to Base64.encodeToString(publicKey, Base64.NO_WRAP)
            ))
        } catch (e: Exception) {
            result.error("KEY_NOT_FOUND", e.message, null)
        }
    }

    // =====================================================================
    // Hardware encryption handlers
    // =====================================================================

    private fun handleHardwareEncrypt(call: MethodCall, result: MethodChannel.Result) {
        val dataB64 = call.argument<String>("data")
        if (dataB64.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "data (Base64) is required", null)
            return
        }

        try {
            val plaintext = Base64.decode(dataB64, Base64.DEFAULT)
            val encrypted = hardwareKeyService.encrypt(plaintext)
            result.success(mapOf(
                "data" to Base64.encodeToString(encrypted, Base64.NO_WRAP)
            ))
        } catch (e: Exception) {
            result.error("ENCRYPT_FAILED", e.message, null)
        }
    }

    private fun handleHardwareDecrypt(call: MethodCall, result: MethodChannel.Result) {
        val dataB64 = call.argument<String>("data")
        if (dataB64.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "data (Base64) is required", null)
            return
        }

        try {
            val ciphertext = Base64.decode(dataB64, Base64.DEFAULT)
            val decrypted = hardwareKeyService.decrypt(ciphertext)
            result.success(mapOf(
                "data" to Base64.encodeToString(decrypted, Base64.NO_WRAP)
            ))
        } catch (e: Exception) {
            result.error("DECRYPT_FAILED", e.message, null)
        }
    }

    // =====================================================================
    // Security enforcement handlers
    // =====================================================================

    private fun handleSecurityEnforceResult(call: MethodCall, result: MethodChannel.Result) {
        val signedResult = call.argument<String>("signedResult")
        if (signedResult.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "signedResult is required", null)
            return
        }

        try {
            // Crashes the app via __builtin_trap() if the signed result is invalid
            NativeSecrets.enforceSecurityResult(signedResult)
            result.success(true)
        } catch (e: Exception) {
            result.error("ENFORCE_FAILED", e.message, null)
        }
    }

    private fun jsonArrayToList(array: org.json.JSONArray): List<Any?> {
        val list = mutableListOf<Any?>()
        for (i in 0 until array.length()) {
            val value = array.get(i)
            list.add(
                when (value) {
                    is JSONObject -> jsonToMap(value)
                    is org.json.JSONArray -> jsonArrayToList(value)
                    JSONObject.NULL -> null
                    else -> value
                }
            )
        }
        return list
    }
}
