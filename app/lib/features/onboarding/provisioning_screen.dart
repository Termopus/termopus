import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app.dart';
import '../../core/platform/security_channel.dart';
import '../../main.dart' show sharedPreferencesProvider;
import '../../shared/constants.dart';
import '../../shared/responsive.dart';
import '../../shared/theme.dart';

/// Certificate provisioning flow.
///
/// Steps:
///  1. Request a challenge nonce from the provisioning API.
///  2. Generate a key pair in the Secure Enclave and produce a CSR.
///  3. Obtain a device attestation token bound to the challenge.
///  4. POST the CSR + attestation + challenge to the provisioning API.
///  5. Store the returned signed certificate.
///
/// The entire crypto flow happens in native code; Dart only orchestrates
/// the UI and passes opaque blobs between native and the API.
class ProvisioningScreen extends ConsumerStatefulWidget {
  const ProvisioningScreen({super.key});

  @override
  ConsumerState<ProvisioningScreen> createState() =>
      _ProvisioningScreenState();
}

enum _Step {
  idle,
  fetchingChallenge,
  generatingCSR,
  attesting,
  submitting,
  storing,
  done,
  error,
}

class _ProvisioningScreenState extends ConsumerState<ProvisioningScreen> {
  final SecurityChannel _security = SecurityChannel();

  _Step _step = _Step.idle;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startProvisioning();
  }

  Future<void> _startProvisioning() async {
    try {
      // ---- 1. Check if we already have a cert ----
      final hasCert = await _security.hasCertificate();
      if (hasCert) {
        setState(() => _step = _Step.done);
        await _markOnboardingComplete();
        ref.invalidate(onboardingCompleteProvider);
        return;
      }

      // ---- 2. Fetch challenge from server ----
      setState(() => _step = _Step.fetchingChallenge);
      final deviceId = await _getDeviceId();
      final challengeResponse = await _fetchChallenge(deviceId);
      final challenge = challengeResponse['challenge'] as String;

      // ---- 3. Generate CSR ----
      // On Android, pass the challenge to enable Key Attestation (binds
      // the generated hardware key to the server-issued challenge).
      setState(() => _step = _Step.generatingCSR);
      final csr = Platform.isAndroid
          ? await _security.generateCSR(challenge: challenge)
          : await _security.generateCSR();
      if (csr == null) throw Exception('CSR generation failed');
      final keyAttestationChain = _security.lastKeyAttestationChain;

      // After CSR generation the hardware key exists, so derive the
      // canonical deviceId = SHA-256(SPKI). This is what the server
      // computes from the CSR (step 4a) to bind deviceId to the key.
      final hwDeviceId = await _getDeviceId();

      // ---- 4. Get attestation ----
      setState(() => _step = _Step.attesting);
      final attestation = await _security.getAttestationToken(challenge);
      if (attestation == null) throw Exception('Attestation failed');

      // ---- 5. Submit to provisioning API ----
      setState(() => _step = _Step.submitting);
      final certResponse = await _submitProvisioning(
        csr: csr,
        attestation: attestation,
        challenge: challenge,
        deviceId: hwDeviceId,
        keyAttestationChain: keyAttestationChain,
      );

      final signedCert = certResponse['certificate'] as String;
      final expiresAt = certResponse['expiresAt'] as String?;

      // ---- 6. Store certificate ----
      setState(() => _step = _Step.storing);
      final stored = await _security.storeCertificate(signedCert);
      if (!stored) throw Exception('Failed to store certificate');

      // cert PEM is stored securely in native Keychain/Keystore via storeCertificate().
      // Only persist expiry for the renewal scheduler.
      final prefs = ref.read(sharedPreferencesProvider);
      if (expiresAt != null) {
        await prefs.setString('cert_expires_at', expiresAt);
      }
      // Clean up legacy plaintext cert storage
      prefs.remove('cert_pem');

      // Update device_id to the hardware-derived ID so that app-side
      // subscription checks (sessions list, settings) use the same ID
      // the relay uses. The server migrates the subscription record
      // from the fallback ID to this hardware ID during provisioning.
      await prefs.setString('device_id', hwDeviceId);

      // ---- Done ----
      setState(() => _step = _Step.done);
      await _markOnboardingComplete();
      // Invalidate the cached onboarding status so the router redirect updates.
      ref.invalidate(onboardingCompleteProvider);
    } catch (e) {
      setState(() {
        _step = _Step.error;
        _error = e.toString();
      });
    }
  }

  Future<void> _markOnboardingComplete() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setBool(AppConstants.prefOnboardingComplete, true);
  }

  /// Get a stable device identifier from the native layer.
  ///
  /// Prefers the hardware-derived SHA-256(SPKI) device ID, which matches
  /// what the server derives from the CSR. Falls back to a persisted ID
  /// for the initial challenge request (before the hardware key exists).
  Future<String> _getDeviceId() async {
    try {
      final hwDeviceId = await _security.getDeviceId();
      if (hwDeviceId.isNotEmpty) {
        return hwDeviceId;
      }
    } catch (_) {}
    // Fallback for first-time provisioning when key doesn't exist yet.
    // After key generation, the real deviceId will be used by the server.
    final integrity = await _security.checkDeviceIntegrity();
    final prefs = ref.read(sharedPreferencesProvider);
    var deviceId = prefs.getString('device_id');
    if (deviceId == null) {
      deviceId = DateTime.now().millisecondsSinceEpoch.toRadixString(36) +
          '-' + (integrity ? 'verified' : 'unverified');
      await prefs.setString('device_id', deviceId);
    }
    return deviceId;
  }

  /// Fetch a challenge nonce from the provisioning API.
  Future<Map<String, dynamic>> _fetchChallenge(String deviceId) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse(AppConstants.provisioningChallengeEndpoint),
      );
      request.headers.set('Content-Type', 'application/json');
      request.write(jsonEncode({'deviceId': deviceId}));

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        throw Exception(
          'Challenge request failed (${response.statusCode}): $body',
        );
      }

      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  /// Submit the CSR + attestation to the provisioning API.
  Future<Map<String, dynamic>> _submitProvisioning({
    required String csr,
    required String attestation,
    required String challenge,
    required String deviceId,
    List<String>? keyAttestationChain,
  }) async {
    final platform = Platform.isIOS ? 'ios' : 'android';

    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse(AppConstants.provisioningCertEndpoint),
      );
      request.headers.set('Content-Type', 'application/json');
      final requestBody = <String, dynamic>{
        'csr': csr,
        'attestation': attestation,
        'platform': platform,
        'deviceId': deviceId,
        'challenge': challenge,
      };
      // Include Android Key Attestation cert chain if available.
      // This allows the server to verify the CSR public key was
      // generated in hardware on this specific device.
      if (keyAttestationChain != null) {
        requestBody['keyAttestationChain'] = keyAttestationChain;
      }
      request.write(jsonEncode(requestBody));

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        final error = jsonDecode(responseBody);
        throw Exception(
          'Provisioning failed (${response.statusCode}): ${error['error'] ?? responseBody}',
        );
      }

      return jsonDecode(responseBody) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Device Provisioning')),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 2),
          child: Column(
            children: [
              const Spacer(flex: 2),

              if (_step == _Step.error) ...[
                Icon(Icons.error_outline, size: context.rValue(mobile: 64.0, tablet: 80.0), color: AppTheme.error),
                SizedBox(height: context.rSpacing * 3),
                Text(
                  'Provisioning Failed',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                SizedBox(height: context.rSpacing * 1.5),
                Text(
                  _error ?? 'An unknown error occurred.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppTheme.error,
                      ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: context.rSpacing * 3),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _step = _Step.idle;
                      _error = null;
                    });
                    _startProvisioning();
                  },
                  child: const Text('Retry'),
                ),
              ] else if (_step == _Step.done) ...[
                Icon(
                  Icons.verified_outlined,
                  size: context.rValue(mobile: 64.0, tablet: 80.0),
                  color: AppTheme.primary,
                ),
                SizedBox(height: context.rSpacing * 3),
                Text(
                  'Device Provisioned',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                SizedBox(height: context.rSpacing * 1.5),
                Text(
                  'Your device has been securely provisioned with a '
                  'client certificate. You can now pair with a computer.',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: AppTheme.textSecondary,
                        height: 1.5,
                      ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: context.rSpacing * 4),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      // Pop all Navigator-pushed screens (BiometricSetup + Provisioning)
                      // back to the GoRouter root, then navigate via GoRouter.
                      Navigator.of(context).popUntil((route) => route.isFirst);
                      context.go('/');
                    },
                    child: const Text('Continue'),
                  ),
                ),
              ] else ...[
                const CircularProgressIndicator(),
                SizedBox(height: context.rSpacing * 4),
                Text(
                  _stepLabel,
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: context.rSpacing * 1.5),
                Text(
                  _stepDescription,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                  textAlign: TextAlign.center,
                ),
              ],

              const Spacer(flex: 3),
            ],
          ),
        ),
      ),
    );
  }

  String get _stepLabel => switch (_step) {
        _Step.idle => 'Preparing...',
        _Step.fetchingChallenge => 'Contacting server...',
        _Step.generatingCSR => 'Generating key pair...',
        _Step.attesting => 'Verifying device...',
        _Step.submitting => 'Requesting certificate...',
        _Step.storing => 'Storing certificate...',
        _ => '',
      };

  String get _stepDescription => switch (_step) {
        _Step.fetchingChallenge =>
          'Requesting a challenge nonce from the provisioning server.',
        _Step.generatingCSR =>
          'Creating a hardware-backed key in the Secure Enclave.',
        _Step.attesting =>
          'Proving to the server that this is a genuine device.',
        _Step.submitting =>
          'Sending the certificate signing request to the provisioning API.',
        _Step.storing =>
          'Saving the signed certificate on device.',
        _ => '',
      };
}
