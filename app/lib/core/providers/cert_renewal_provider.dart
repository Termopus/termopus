import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shared/constants.dart';
import '../platform/security_channel.dart';
import 'connection_provider.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class CertRenewalState {
  const CertRenewalState({
    this.expiresAt,
    this.isRenewing = false,
    this.lastError,
    this.lastRenewalAttempt,
  });

  final DateTime? expiresAt;
  final bool isRenewing;
  final String? lastError;
  final DateTime? lastRenewalAttempt;

  CertRenewalState copyWith({
    DateTime? expiresAt,
    bool? isRenewing,
    String? lastError,
    DateTime? lastRenewalAttempt,
  }) {
    return CertRenewalState(
      expiresAt: expiresAt ?? this.expiresAt,
      isRenewing: isRenewing ?? this.isRenewing,
      lastError: lastError,
      lastRenewalAttempt: lastRenewalAttempt ?? this.lastRenewalAttempt,
    );
  }

  bool get needsRenewal {
    if (expiresAt == null) return false;
    // Renew if less than 6 hours remaining
    return expiresAt!.difference(DateTime.now()).inHours < 6;
  }

  bool get isExpired {
    if (expiresAt == null) return true;
    return DateTime.now().isAfter(expiresAt!);
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final certRenewalProvider =
    NotifierProvider<CertRenewalNotifier, CertRenewalState>(
        CertRenewalNotifier.new);

class CertRenewalNotifier extends Notifier<CertRenewalState> {
  final SecurityChannel _security = SecurityChannel();
  Timer? _checkTimer;
  static const _maxRetries = 3;

  @override
  CertRenewalState build() {
    ref.onDispose(() {
      _checkTimer?.cancel();
    });
    _loadExpiresAt();
    _startCheckTimer();
    return const CertRenewalState();
  }

  /// Trigger WS reconnect to use the new certificate.
  void _onCertRenewed() {
    try {
      final connectionNotifier = ref.read(connectionProvider.notifier);
      connectionNotifier.reconnect();
    } catch (_) {
      // Connection provider may not be available — cert is stored either way
    }
  }

  /// Load cert expiry from SharedPreferences.
  Future<void> _loadExpiresAt() async {
    final prefs = await SharedPreferences.getInstance();
    final expiresAtStr = prefs.getString('cert_expires_at');
    if (expiresAtStr != null) {
      try {
        state = state.copyWith(expiresAt: DateTime.parse(expiresAtStr));
      } catch (_) {
        // Invalid date — ignore
      }
    }
  }

  /// Check cert expiry every hour; renew if needed.
  void _startCheckTimer() {
    _checkTimer = Timer.periodic(const Duration(hours: 1), (_) async {
      if (state.needsRenewal && !state.isRenewing) {
        await renewCert();
      }
    });
  }

  /// Store expiry timestamp received from provisioning response.
  Future<void> setExpiresAt(DateTime expiresAt) async {
    state = state.copyWith(expiresAt: expiresAt);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cert_expires_at', expiresAt.toIso8601String());
  }

  /// Attempt certificate renewal with retries.
  Future<bool> renewCert() async {
    if (state.isRenewing) return false;

    state = state.copyWith(
      isRenewing: true,
      lastError: null,
      lastRenewalAttempt: DateTime.now(),
    );

    for (int attempt = 0; attempt < _maxRetries; attempt++) {
      try {
        final success = await _performRenewal();
        if (success) {
          state = state.copyWith(isRenewing: false);
          return true;
        }
      } catch (e) {
        if (attempt == _maxRetries - 1) {
          state = state.copyWith(
            isRenewing: false,
            lastError: e.toString(),
          );
          return false;
        }
        // Wait before retry (exponential backoff)
        await Future.delayed(Duration(seconds: 2 << attempt));
      }
    }

    state = state.copyWith(isRenewing: false);
    return false;
  }

  /// Fetch a single-use challenge nonce from the server.
  Future<String> _fetchChallenge(String deviceId) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('${AppConstants.provisioningApiBase}/provision/challenge'),
      );
      request.headers.set('Content-Type', 'application/json');
      request.write(jsonEncode({'deviceId': deviceId}));

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        throw Exception('Challenge fetch failed: ${response.statusCode}');
      }

      final data = jsonDecode(body) as Map<String, dynamic>;
      return data['challenge'] as String;
    } finally {
      client.close();
    }
  }

  Future<bool> _performRenewal() async {
    // 1. Check we have a cert to renew
    final hasCert = await _security.hasCertificate();
    if (!hasCert) return false;

    // 2. Generate new CSR
    final csr = await _security.generateCSR();
    if (csr == null) throw Exception('CSR generation failed');

    // 3. Get device ID
    final prefs = await SharedPreferences.getInstance();
    final deviceId = prefs.getString('device_id');
    if (deviceId == null) throw Exception('No device ID');

    // 4. Fetch server challenge (single-use nonce, 5-min TTL)
    final challenge = await _fetchChallenge(deviceId);

    // 5. Get attestation using the server challenge as nonce
    final attestation = await _security.getAttestationToken(challenge);
    if (attestation == null) throw Exception('Attestation failed');

    // 6. Get the current (possibly expired) cert PEM from native Keychain/Keystore
    final expiredCertPem = await _security.getCertificatePEM();
    if (expiredCertPem == null) throw Exception('No stored cert PEM');

    // 7. Call renewal endpoint
    final platform = Platform.isIOS ? 'ios' : 'android';
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('${AppConstants.provisioningApiBase}/provision/renew'),
      );
      request.headers.set('Content-Type', 'application/json');
      request.write(jsonEncode({
        'csr': csr,
        'attestation': attestation,
        'platform': platform,
        'deviceId': deviceId,
        'expiredCert': expiredCertPem,
        'challenge': challenge,
      }));

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == 402) {
        throw Exception('Subscription required for renewal');
      }

      if (response.statusCode != 200) {
        final error = jsonDecode(body);
        throw Exception(error['error'] ?? 'Renewal failed');
      }

      final data = jsonDecode(body) as Map<String, dynamic>;
      final newCert = data['certificate'] as String;
      final expiresAtStr = data['expiresAt'] as String;

      // 8. Store new cert
      final stored = await _security.storeCertificate(newCert);
      if (!stored) throw Exception('Failed to store renewed certificate');

      // 9. Update expiry
      final expiresAt = DateTime.parse(expiresAtStr);
      await setExpiresAt(expiresAt);

      // cert PEM is stored securely in native Keychain/Keystore via storeCertificate() above.
      // Clean up any legacy plaintext cert storage from previous versions.
      prefs.remove('cert_pem');

      // Trigger WS reconnect so the new certificate is used immediately
      _onCertRenewed();

      return true;
    } finally {
      client.close();
    }
  }
}
