import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/providers/auth_provider.dart';
import '../../shared/constants.dart';
import '../../shared/responsive.dart';
import '../../shared/theme.dart';
import 'provisioning_screen.dart';

/// Screen where the user enables biometric authentication.
///
/// Checks whether the device supports biometrics, explains why it is
/// required, and prompts the user to authenticate once to confirm.
class BiometricSetupScreen extends ConsumerStatefulWidget {
  const BiometricSetupScreen({super.key});

  @override
  ConsumerState<BiometricSetupScreen> createState() =>
      _BiometricSetupScreenState();
}

class _BiometricSetupScreenState extends ConsumerState<BiometricSetupScreen> {
  bool _checking = true;
  bool _available = false;
  bool _authenticated = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkAvailability();
  }

  Future<void> _checkAvailability() async {
    await ref.read(authProvider.notifier).checkBiometricAvailability();
    final auth = ref.read(authProvider);
    if (mounted) {
      setState(() {
        _checking = false;
        _available = auth.isBiometricAvailable;
      });
    }
  }

  Future<void> _requestBiometric() async {
    setState(() => _error = null);

    final success = await ref.read(authProvider.notifier).authenticate(
          reason: 'Enable biometric authentication for Claude Code Remote',
        );

    if (!mounted) return;

    if (success) {
      setState(() => _authenticated = true);
      // Persist the preference so the lock screen activates on app resume.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(AppConstants.prefBiometricEnabled, true);
      // Short delay so the user sees the success state.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const ProvisioningScreen(),
          ),
        );
      }
    } else {
      setState(() => _error = 'Authentication failed. Please try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Biometric Setup')),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 2),
          child: Column(
            children: [
              const Spacer(flex: 2),

              // ---- Icon ----
              Icon(
                _authenticated
                    ? Icons.check_circle_outline
                    : Icons.fingerprint,
                size: context.rValue(mobile: 80.0, tablet: 96.0),
                color: _authenticated ? AppTheme.primary : AppTheme.accent,
              ),
              SizedBox(height: context.rSpacing * 4),

              // ---- Title ----
              Text(
                _authenticated
                    ? 'Biometric Enabled'
                    : 'Enable Biometric Auth',
                style: Theme.of(context).textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              SizedBox(height: context.rSpacing * 2),

              // ---- Body ----
              if (_checking)
                const CircularProgressIndicator()
              else if (!_available)
                Text(
                  'No biometric hardware was detected on this device. '
                  'Biometric authentication is required for security.',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: AppTheme.error,
                        height: 1.5,
                      ),
                  textAlign: TextAlign.center,
                )
              else
                Text(
                  'Claude Code Remote requires Face ID or fingerprint '
                  'authentication to protect your sessions. Tap below '
                  'to enable it now.',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: AppTheme.textSecondary,
                        height: 1.5,
                      ),
                  textAlign: TextAlign.center,
                ),

              if (_error != null) ...[
                SizedBox(height: context.rSpacing * 2),
                Text(
                  _error!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppTheme.error,
                      ),
                  textAlign: TextAlign.center,
                ),
              ],

              const Spacer(flex: 3),

              // ---- CTA ----
              if (_available && !_authenticated)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _requestBiometric,
                    icon: const Icon(Icons.fingerprint),
                    label: const Text('Enable Biometrics'),
                  ),
                ),

              SizedBox(height: context.rSpacing * 4),
            ],
          ),
        ),
      ),
    );
  }
}
