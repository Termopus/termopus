import 'dart:async';

import '../platform/security_channel.dart';

/// Result of an individual security check.
class CheckResult {
  final String name;
  final bool passed;
  final String? detail;

  const CheckResult({
    required this.name,
    required this.passed,
    this.detail,
  });

  @override
  String toString() => '$name: ${passed ? "OK" : "FAIL"}${detail != null ? " ($detail)" : ""}';
}

/// Aggregate result of all security checks.
class SecurityResult {
  final List<CheckResult> checks;
  final String? signedIntegrity;
  final DateTime timestamp;

  SecurityResult({
    required this.checks,
    this.signedIntegrity,
  }) : timestamp = DateTime.now();

  /// True if all checks passed.
  bool get passed => checks.every((c) => c.passed);

  /// Names of failed checks.
  List<String> get failedChecks =>
      checks.where((c) => !c.passed).map((c) => c.name).toList();

  @override
  String toString() {
    final status = passed ? 'PASS' : 'FAIL';
    final details = checks.map((c) => c.toString()).join(', ');
    return 'SecurityResult($status: $details)';
  }
}

/// Orchestrates security checks from the native layer.
///
/// Runs configurable checks in parallel via [SecurityChannel] and
/// aggregates results. Each check can be independently enabled/disabled
/// (e.g., from remote config).
class SecurityService {
  static final SecurityService instance = SecurityService._();
  SecurityService._();

  final SecurityChannel _channel = SecurityChannel();

  /// Per-check configuration — can be updated from remote config.
  final Map<String, bool> _checkEnabled = {
    'integrity': true,
    'biometric': true,
    'screenLock': true,
    'vpn': false, // Informational only, off by default
  };

  /// Update check configuration (e.g., from remote config or settings).
  void updateConfig(Map<String, bool> config) {
    _checkEnabled.addAll(config);
  }

  /// Whether a specific check is enabled.
  bool isCheckEnabled(String name) => _checkEnabled[name] ?? false;

  /// Run all enabled checks in parallel, return aggregate result.
  ///
  /// The integrity check returns a MAC-signed result string which is
  /// immediately validated via [enforceSecurityResult] — crashes if tampered.
  Future<SecurityResult> runAllChecks() async {
    final futures = <Future<CheckResult>>[];

    if (_checkEnabled['integrity'] == true) {
      futures.add(_runIntegrityCheck());
    }
    if (_checkEnabled['biometric'] == true) {
      futures.add(_runBiometricAvailabilityCheck());
    }

    final results = await Future.wait(futures);

    // Get the signed integrity result and immediately enforce it
    String? signedIntegrity;
    if (_checkEnabled['integrity'] == true) {
      signedIntegrity = await _channel.checkDeviceIntegritySigned();
      if (signedIntegrity != null) {
        // Validate HMAC in native — crashes if tampered
        await _channel.enforceSecurityResult(signedIntegrity);
      }
    }

    return SecurityResult(
      checks: results,
      signedIntegrity: signedIntegrity,
    );
  }

  /// Validate a signed integrity result in native code.
  ///
  /// Crashes the app if the result is tampered (via __builtin_trap).
  Future<void> enforceResult(SecurityResult result) async {
    if (result.signedIntegrity != null) {
      await _channel.enforceSecurityResult(result.signedIntegrity!);
    }
  }

  // ---------------------------------------------------------------------------
  // Individual checks
  // ---------------------------------------------------------------------------

  Future<CheckResult> _runIntegrityCheck() async {
    try {
      final passed = await _channel.checkDeviceIntegrity();
      return CheckResult(
        name: 'integrity',
        passed: passed,
        detail: passed ? 'All native checks passed' : 'Device may be compromised',
      );
    } catch (e) {
      return CheckResult(
        name: 'integrity',
        passed: false,
        detail: 'Check failed: $e',
      );
    }
  }

  Future<CheckResult> _runBiometricAvailabilityCheck() async {
    try {
      final available = await _channel.isBiometricAvailable();
      return CheckResult(
        name: 'biometric',
        passed: available,
        detail: available ? 'Biometric hardware available' : 'No biometric hardware',
      );
    } catch (e) {
      return CheckResult(
        name: 'biometric',
        passed: false,
        detail: 'Check failed: $e',
      );
    }
  }
}
