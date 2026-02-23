import 'dart:async';

import 'package:flutter/services.dart';

import '../../shared/constants.dart';

/// Bridge to the native security module (Swift / Kotlin).
///
/// Every method here is a thin Dart wrapper that delegates the real work --
/// encryption, key management, biometrics, attestation, mTLS WebSocket --
/// to platform-specific native code via [MethodChannel] and [EventChannel].
///
/// **No cryptographic material is ever handled in Dart.**
class SecurityChannel {
  // -------------------------------------------------------------------------
  // Singleton
  // -------------------------------------------------------------------------

  static final SecurityChannel _instance = SecurityChannel._internal();
  factory SecurityChannel() => _instance;
  SecurityChannel._internal();

  // -------------------------------------------------------------------------
  // Channels
  // -------------------------------------------------------------------------

  static const MethodChannel _method = MethodChannel(
    AppConstants.securityMethodChannel,
  );
  static const EventChannel _event = EventChannel(
    AppConstants.messagesEventChannel,
  );

  // -------------------------------------------------------------------------
  // Message stream
  // -------------------------------------------------------------------------

  Stream<Map<String, dynamic>>? _messageStream;

  /// A broadcast stream of decrypted messages coming from the native layer.
  ///
  /// Each event is a JSON map that can be parsed into a [Message].
  Stream<Map<String, dynamic>> get messages {
    _messageStream ??= _event
        .receiveBroadcastStream()
        .map((dynamic data) => Map<String, dynamic>.from(data as Map));
    return _messageStream!;
  }

  // =========================================================================
  // BIOMETRIC
  // =========================================================================

  /// Returns `true` when the device has usable biometric hardware.
  Future<bool> isBiometricAvailable() async {
    final result = await _method.invokeMethod<bool>('biometric.isAvailable');
    return result ?? false;
  }

  /// Prompt the user for biometric authentication.
  ///
  /// Returns `true` on success.
  Future<bool> authenticateWithBiometric({
    String reason = 'Authenticate to continue',
  }) async {
    final result = await _method.invokeMethod<bool>(
      'biometric.authenticate',
      <String, dynamic>{'reason': reason},
    );
    return result ?? false;
  }

  /// Secure biometric authentication that returns an HMAC-signed proof.
  ///
  /// Unlike [authenticateWithBiometric] which returns a hookable boolean,
  /// this method uses a hardware-backed CryptoObject/SecureEnclave flow:
  /// native generates a nonce, the biometric key signs it, the signature
  /// is verified in native, and the result is HMAC-signed.
  ///
  /// Returns the HMAC-signed string (e.g. "BIOMETRIC_OK:...:hmac") on
  /// success, or null if the user cancelled. On tamper detection, the
  /// native layer crashes the app.
  Future<String?> biometricAuthenticateSecure({
    String reason = 'Authenticate to continue',
  }) async {
    try {
      final result = await _method.invokeMethod<Map>(
        'biometric.authenticateSecure',
        <String, dynamic>{'reason': reason},
      );
      return result?['signedResult'] as String?;
    } on PlatformException catch (e) {
      if (e.code == 'BIOMETRIC_FAILED') return null;
      rethrow;
    }
  }

  // =========================================================================
  // DEVICE INTEGRITY / ATTESTATION
  // =========================================================================

  /// Run local device integrity checks (jailbreak / root / debugger).
  ///
  /// Returns `true` if all checks passed. The native side returns a
  /// MAC-signed string (format: "STATUS:details:timestamp:hmac");
  /// this method parses it to a boolean for backward compatibility.
  Future<bool> checkDeviceIntegrity() async {
    final result = await _method.invokeMethod<dynamic>('device.checkIntegrity');
    if (result is bool) return result;
    if (result is String) return result.startsWith('CLEAN:');
    return false;
  }

  /// Run device integrity checks and return the raw MAC-signed result.
  ///
  /// Returns a string like "OK:details:timestamp:hmac" or
  /// "FAIL:details:timestamp:hmac". Use [enforceSecurityResult] to
  /// validate in native code (crashes if tampered).
  Future<String?> checkDeviceIntegritySigned() async {
    return _method.invokeMethod<String>('device.checkIntegrity');
  }

  /// Obtain a platform attestation token for the given [challenge].
  ///
  /// Uses App Attest (iOS) or Play Integrity (Android).
  /// Returns the base-64 encoded attestation blob, or `null` on failure.
  Future<String?> getAttestationToken(String challenge) async {
    return _method.invokeMethod<String>(
      'device.attest',
      <String, dynamic>{'challenge': challenge},
    );
  }

  // =========================================================================
  // BIOMETRIC CRYPTO (challenge signing with hardware-backed key)
  // =========================================================================

  /// Sign a Base64-encoded challenge with the biometric-protected key.
  ///
  /// Triggers Face ID / Touch ID / fingerprint automatically.
  /// Returns the Base64-encoded signature on success.
  Future<String?> biometricSignChallenge({
    required String challenge,
    String reason = 'Sign security challenge',
  }) async {
    final result = await _method.invokeMethod<Map>(
      'biometric.signChallenge',
      <String, dynamic>{'challenge': challenge, 'reason': reason},
    );
    return result?['signature'] as String?;
  }

  /// Get the biometric signing public key (X9.63 / SubjectPublicKeyInfo format).
  ///
  /// Returns Base64-encoded public key bytes.
  Future<String?> biometricGetPublicKey() async {
    final result = await _method.invokeMethod<Map>('biometric.getPublicKey');
    return result?['publicKey'] as String?;
  }

  // =========================================================================
  // HARDWARE ENCRYPTION (silent at-rest encryption)
  // =========================================================================

  /// Encrypt data using the hardware-backed key (no biometric prompt).
  ///
  /// Takes Base64-encoded plaintext, returns Base64-encoded ciphertext.
  Future<String?> hardwareEncrypt(String dataBase64) async {
    final result = await _method.invokeMethod<Map>(
      'hardware.encrypt',
      <String, dynamic>{'data': dataBase64},
    );
    return result?['data'] as String?;
  }

  /// Decrypt data using the hardware-backed key (no biometric prompt).
  ///
  /// Takes Base64-encoded ciphertext, returns Base64-encoded plaintext.
  Future<String?> hardwareDecrypt(String dataBase64) async {
    final result = await _method.invokeMethod<Map>(
      'hardware.decrypt',
      <String, dynamic>{'data': dataBase64},
    );
    return result?['data'] as String?;
  }

  // =========================================================================
  // SECURITY ENFORCEMENT
  // =========================================================================

  /// Validate a MAC-signed security result in native code.
  ///
  /// If the HMAC is valid and the status is "OK", returns normally.
  /// If invalid or tampered, the native layer crashes the app via
  /// `__builtin_trap()` — this cannot be hooked or intercepted.
  Future<bool> enforceSecurityResult(String signedResult) async {
    final result = await _method.invokeMethod<bool>(
      'security.enforceResult',
      <String, dynamic>{'signedResult': signedResult},
    );
    return result ?? false;
  }

  /// Get the hardware-bound device identifier derived from SHA-256(SPKI).
  ///
  /// The native layer computes SHA-256 over the SubjectPublicKeyInfo DER
  /// encoding of the Secure Enclave / StrongBox public key. The result is
  /// a 64-character lowercase hex string that is stable across app restarts
  /// and identical on both platforms for the same key material.
  Future<String> getDeviceId() async {
    final result = await _method.invokeMethod<String>('security.getDeviceId');
    if (result == null) throw Exception('Failed to get device ID');
    return result;
  }

  /// Get an obfuscated endpoint URL from the native secrets layer.
  ///
  /// Available keys: "relay"
  Future<String?> getEndpoint(String key) async {
    return _method.invokeMethod<String>(
      'security.getEndpoint',
      <String, dynamic>{'key': key},
    );
  }

  // =========================================================================
  // CERTIFICATE PROVISIONING
  // =========================================================================

  /// Generate a key pair in the Secure Enclave / StrongBox and return a CSR
  /// (PEM-encoded string).
  ///
  /// If [challenge] is provided (Android only), the key is generated with
  /// Android Key Attestation enabled. The returned map will contain:
  ///   - `csr`: the PEM-encoded CSR string
  ///   - `keyAttestationChain`: list of Base64-encoded DER certificates
  ///     (leaf → intermediate → Google root CA), or absent if attestation
  ///     is not supported on this device.
  ///
  /// Without [challenge], returns just the CSR string (backward compatible).
  Future<String?> generateCSR({String? challenge}) async {
    _lastKeyAttestationChain = null;  // Clear stale state from previous attempts
    if (challenge != null) {
      // Android Key Attestation flow: returns a map
      final result = await _method.invokeMethod<Map>(
        'cert.generateCSR',
        <String, dynamic>{'challenge': challenge},
      );
      // Store the cert chain in a field so the caller can access it
      if (result != null) {
        _lastKeyAttestationChain = result['keyAttestationChain'] != null
            ? List<String>.from(result['keyAttestationChain'] as List)
            : null;
        return result['csr'] as String?;
      }
      return null;
    }
    return _method.invokeMethod<String>('cert.generateCSR');
  }

  /// The Key Attestation certificate chain from the last [generateCSR] call
  /// with a challenge parameter. Null if attestation was not available or
  /// no challenge was provided.
  List<String>? _lastKeyAttestationChain;
  List<String>? get lastKeyAttestationChain => _lastKeyAttestationChain;

  /// Store a PEM-encoded signed certificate received from the provisioning API.
  Future<bool> storeCertificate(String certificate) async {
    final result = await _method.invokeMethod<bool>(
      'cert.store',
      <String, dynamic>{'certificate': certificate},
    );
    return result ?? false;
  }

  /// Check whether a valid client certificate already exists on device.
  Future<bool> hasCertificate() async {
    final result = await _method.invokeMethod<bool>('cert.exists');
    return result ?? false;
  }

  /// Get the PEM-encoded client certificate from native Keychain/Keystore.
  ///
  /// Returns the PEM string or `null` if no certificate is stored.
  Future<String?> getCertificatePEM() async {
    return _method.invokeMethod<String>('cert.getPEM');
  }

  // =========================================================================
  // SESSION / PAIRING
  // =========================================================================

  /// Begin the pairing handshake with a remote computer.
  ///
  /// The native layer will:
  /// 1. Validate the [biometricProof] HMAC (crashes if tampered)
  /// 2. Run device integrity checks (crashes if tampered)
  /// 3. Perform ECDH key exchange
  /// 4. Establish the encrypted WebSocket via the relay
  Future<bool> startPairing({
    required String relay,
    required String sessionId,
    required String peerPublicKey,
    String? biometricProof,
  }) async {
    final result = await _method.invokeMethod<bool>(
      'session.pair',
      <String, dynamic>{
        'relay': relay,
        'sessionId': sessionId,
        'peerPublicKey': peerPublicKey,
        if (biometricProof != null) 'biometricProof': biometricProof,
      },
    );
    return result ?? false;
  }

  /// Reconnect to an already-paired session.
  ///
  /// Pass [relay] so the native layer knows which relay server to connect to
  /// (needed when restoring from persisted peer key after app kill).
  Future<bool> connectToSession(String sessionId, {String? relay}) async {
    final result = await _method.invokeMethod<bool>(
      'session.connect',
      <String, dynamic>{
        'sessionId': sessionId,
        if (relay != null) 'relay': relay,
      },
    );
    return result ?? false;
  }

  /// Clear persisted peer key data for a session from native secure storage.
  Future<void> clearSessionData(String sessionId) async {
    await _method.invokeMethod<void>(
      'session.clearData',
      <String, dynamic>{'sessionId': sessionId},
    );
  }

  /// Disconnect from the current session.
  Future<void> disconnect() async {
    await _method.invokeMethod<void>('session.disconnect');
  }

  /// Disconnect a specific session's WebSocket (without affecting others).
  Future<void> disconnectSession(String sessionId) async {
    await _method.invokeMethod<void>(
      'session.disconnect',
      <String, dynamic>{'sessionId': sessionId},
    );
  }

  /// Poll the native layer for the current connection state string.
  ///
  /// Possible values: `connected`, `connecting`, `reconnecting`,
  /// `error`, `disconnected`.
  Future<String> getConnectionState() async {
    final result = await _method.invokeMethod<String>('session.state');
    return result ?? 'disconnected';
  }

  /// Send a lightweight keepalive to the relay (plaintext, not encrypted).
  /// Resets the relay's inactivity timer so the session isn't killed.
  Future<bool> keepalive(String sessionId) async {
    final r = await _method.invokeMethod<bool>(
      'session.keepalive',
      <String, dynamic>{'sessionId': sessionId},
    );
    return r ?? false;
  }

  // =========================================================================
  // MESSAGING
  // =========================================================================

  /// Send a text message (with automatic Enter at the end).
  ///
  /// The native layer encrypts it before transmitting over the WebSocket.
  /// The bridge will type the text and press Enter.
  Future<bool> sendMessage(String content) async {
    final result = await _method.invokeMethod<bool>(
      'message.send',
      <String, dynamic>{'content': content},
    );
    return result ?? false;
  }

  /// Send a special key press (Enter, Escape, Arrow keys, etc.)
  ///
  /// Supported keys: Enter, Escape, Tab, Space, Backspace,
  /// Up, Down, Left, Right, Home, End, PageUp, PageDown,
  /// Ctrl+C, Ctrl+D, Ctrl+Z, F1-F12
  Future<bool> sendKey(String key) async {
    final result = await _method.invokeMethod<bool>(
      'message.sendKey',
      <String, dynamic>{'key': key},
    );
    return result ?? false;
  }

  /// Send raw input without automatic newline.
  ///
  /// Use this for sending text that shouldn't automatically press Enter.
  Future<bool> sendRawInput(String content) async {
    final result = await _method.invokeMethod<bool>(
      'message.sendInput',
      <String, dynamic>{'content': content},
    );
    return result ?? false;
  }

  /// Respond to a pending action (e.g. "allow" or "deny").
  Future<bool> sendActionResponse({
    required String actionId,
    required String response,
  }) async {
    final result = await _method.invokeMethod<bool>(
      'message.respond',
      <String, dynamic>{
        'actionId': actionId,
        'response': response,
      },
    );
    return result ?? false;
  }

  /// Notify the bridge to delete a session (kill Claude process + clean storage).
  ///
  /// Sends delete_session command on the session-specific WebSocket.
  /// Returns true if sent successfully, false if bridge is offline.
  Future<bool> deleteSession(String sessionId) async {
    final result = await _method.invokeMethod<bool>(
      'session.delete',
      <String, dynamic>{'sessionId': sessionId},
    );
    return result ?? false;
  }

  /// Send a Claude Code slash command (e.g., /help, /clear, /model).
  ///
  /// The command should not include the leading slash.
  Future<bool> sendCommand(String command, {String? args}) async {
    final result = await _method.invokeMethod<bool>(
      'message.command',
      <String, dynamic>{
        'command': command,
        'args': args,
      },
    );
    return result ?? false;
  }

  /// Set the Claude Code model.
  ///
  /// Supported models: opus, sonnet, haiku
  Future<bool> setModel(String model) async {
    final result = await _method.invokeMethod<bool>(
      'message.setModel',
      <String, dynamic>{
        'model': model,
      },
    );
    return result ?? false;
  }

  /// Send a configuration update to Claude Code.
  Future<bool> sendConfig(String key, dynamic value) async {
    final result = await _method.invokeMethod<bool>(
      'message.config',
      <String, dynamic>{
        'key': key,
        'value': value,
      },
    );
    return result ?? false;
  }

  // =========================================================================
  // HTTP TUNNEL
  // =========================================================================

  /// Request the bridge to open an HTTP tunnel to localhost:port.
  Future<bool> sendHttpTunnelOpen({required int port}) async {
    final result = await _method.invokeMethod<bool>(
      'httpTunnel.open',
      <String, dynamic>{'port': port},
    );
    return result ?? false;
  }

  /// Request the bridge to close the HTTP tunnel.
  Future<bool> sendHttpTunnelClose() async {
    final result = await _method.invokeMethod<bool>('httpTunnel.close');
    return result ?? false;
  }

  /// Send an HTTP request through the tunnel to be proxied by the bridge.
  Future<bool> sendHttpRequest({
    required String requestId,
    required String method,
    required String path,
    required Map<String, String> headers,
    String? body,
  }) async {
    final result = await _method.invokeMethod<bool>(
      'httpTunnel.request',
      <String, dynamic>{
        'requestId': requestId,
        'method': method,
        'path': path,
        'headers': headers,
        if (body != null) 'body': body,
      },
    );
    return result ?? false;
  }

  // =========================================================================
  // FILE TRANSFER
  // =========================================================================

  /// Initiate sending a file from phone to computer.
  /// The native layer reads the file, computes SHA-256,
  /// chunks it, and streams encrypted chunks over WebSocket.
  Future<bool> sendFile({
    required String filePath,
    required String fileName,
    required String mimeType,
  }) async {
    final result = await _method.invokeMethod<bool>(
      'file.send',
      <String, dynamic>{
        'filePath': filePath,
        'fileName': fileName,
        'mimeType': mimeType,
      },
    );
    return result ?? false;
  }

  /// Accept an incoming file transfer from computer.
  Future<bool> acceptFileTransfer(String transferId) async {
    final result = await _method.invokeMethod<bool>(
      'file.accept',
      <String, dynamic>{'transferId': transferId},
    );
    return result ?? false;
  }

  /// Cancel/decline a file transfer (either direction).
  Future<bool> cancelFileTransfer(String transferId) async {
    final result = await _method.invokeMethod<bool>(
      'file.cancel',
      <String, dynamic>{'transferId': transferId},
    );
    return result ?? false;
  }

  // =========================================================================
  // FCM
  // =========================================================================

  /// Register the Firebase Cloud Messaging token with the relay so that
  /// push notifications can be delivered when the app is backgrounded.
  Future<bool> registerFcmToken(String token) async {
    final result = await _method.invokeMethod<bool>(
      'fcm.register',
      <String, dynamic>{'token': token},
    );
    return result ?? false;
  }

  // =========================================================================
  // BRIDGE CONTROLS
  // =========================================================================

  /// Send a command to the bridge agent on the computer.
  ///
  /// Available commands:
  /// - `pair`: Force new pairing (show QR code)
  /// - `checkRequirements`: Check if Claude Code is installed
  /// - `listSessions`: List all saved sessions
  /// - `reconnect`: Force reconnection to relay
  /// - `installClaude`: Install Claude Code CLI
  ///
  /// Returns the command result as a string.
  static Future<String> sendBridgeCommand(
    String command, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final result = await _method
        .invokeMethod<String>(
          'bridge.command',
          <String, dynamic>{'command': command},
        )
        .timeout(timeout);
    return result ?? 'No response';
  }

  /// Get the bridge agent status
  static Future<Map<String, dynamic>> getBridgeStatus() async {
    final result = await _method.invokeMethod<Map>('bridge.status');
    if (result == null) {
      return {'status': 'unknown'};
    }
    return Map<String, dynamic>.from(result);
  }
}
