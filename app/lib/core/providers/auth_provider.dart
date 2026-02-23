import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/security_channel.dart';

/// Riverpod provider for the authentication state.
final authProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);

/// Whether the biometric lock screen is currently active.
///
/// Set by [BiometricLockScreen], read by [ChatScreen] to defer
/// reconnection until after the user has authenticated.
final biometricLockActiveProvider =
    NotifierProvider<BiometricLockNotifier, bool>(BiometricLockNotifier.new);

class BiometricLockNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void lock() => state = true;
  void unlock() => state = false;
}

/// Immutable snapshot of the current authentication state.
class AuthState {
  final bool isAuthenticated;
  final bool isBiometricAvailable;
  final bool isDeviceIntegrityValid;
  final bool isLoading;
  final String? error;

  /// HMAC-signed biometric proof from the last successful authentication.
  /// Used as the biometricProof parameter for session pairing.
  final String? biometricProof;

  const AuthState({
    this.isAuthenticated = false,
    this.isBiometricAvailable = false,
    this.isDeviceIntegrityValid = true,
    this.isLoading = false,
    this.error,
    this.biometricProof,
  });

  AuthState copyWith({
    bool? isAuthenticated,
    bool? isBiometricAvailable,
    bool? isDeviceIntegrityValid,
    bool? isLoading,
    String? error,
    String? biometricProof,
  }) {
    return AuthState(
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      isBiometricAvailable:
          isBiometricAvailable ?? this.isBiometricAvailable,
      isDeviceIntegrityValid:
          isDeviceIntegrityValid ?? this.isDeviceIntegrityValid,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      biometricProof: biometricProof ?? this.biometricProof,
    );
  }
}

/// Manages biometric authentication and device integrity checks.
///
/// All actual security work is delegated to the native layer via
/// [SecurityChannel].
class AuthNotifier extends Notifier<AuthState> {
  final SecurityChannel _security = SecurityChannel();

  @override
  AuthState build() => const AuthState();

  /// Query the native layer for biometric hardware availability.
  Future<void> checkBiometricAvailability() async {
    final available = await _security.isBiometricAvailable();
    state = state.copyWith(isBiometricAvailable: available);
  }

  /// Prompt the user for secure biometric authentication.
  ///
  /// Uses the hardware-backed CryptoObject/SecureEnclave flow:
  /// native generates a nonce, the biometric key signs it, the signature
  /// is verified in native, and the result is HMAC-signed.
  ///
  /// The HMAC proof is validated via [enforceSecurityResult] which crashes
  /// the app if the proof has been tampered with (Frida-resistant).
  ///
  /// On success, [AuthState.isAuthenticated] becomes `true` and
  /// [AuthState.biometricProof] is set for downstream use (e.g. pairing).
  Future<bool> authenticate({String? reason}) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final signedResult = await _security.biometricAuthenticateSecure(
        reason: reason ?? 'Authenticate to access Claude Code Remote',
      );

      if (signedResult == null) {
        // User cancelled biometric prompt
        state = state.copyWith(
          isLoading: false,
          error: 'Authentication cancelled',
        );
        return false;
      }

      // Validate HMAC in native — crashes if tampered
      await _security.enforceSecurityResult(signedResult);

      state = state.copyWith(
        isAuthenticated: true,
        isLoading: false,
        biometricProof: signedResult,
        error: null,
      );

      return true;
    } on PlatformException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.message ?? 'Biometric authentication failed',
      );
      return false;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
      return false;
    }
  }

  /// Run local device integrity checks (jailbreak, root, debugger).
  ///
  /// Uses the MAC-signed flow: native returns an HMAC-signed result string
  /// which is validated via [enforceSecurityResult] (crashes if tampered).
  ///
  /// Sets [AuthState.isDeviceIntegrityValid] accordingly.
  Future<bool> checkIntegrity() async {
    try {
      final signedResult = await _security.checkDeviceIntegritySigned();
      if (signedResult == null) {
        state = state.copyWith(
          isDeviceIntegrityValid: false,
          error: 'Device integrity check returned null',
        );
        return false;
      }

      // Validate HMAC in native — crashes if tampered
      await _security.enforceSecurityResult(signedResult);

      // Parse the status from the signed result
      final valid = signedResult.startsWith('CLEAN:');
      state = state.copyWith(isDeviceIntegrityValid: valid);
      return valid;
    } catch (e) {
      state = state.copyWith(
        isDeviceIntegrityValid: false,
        error: 'Device integrity check failed: $e',
      );
      return false;
    }
  }

  /// Reset the authentication state (e.g. on session timeout).
  void deauthenticate() {
    state = state.copyWith(isAuthenticated: false);
  }
}
