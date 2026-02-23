import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/providers/auth_provider.dart';
import '../../shared/theme.dart';

/// Biometric lock screen shown on cold start and when resuming after timeout.
///
/// Respects `biometric_enabled` preference and `session_timeout_minutes`.
/// If biometric auth is not enabled in settings, the screen is never shown.
class BiometricLockScreen extends ConsumerStatefulWidget {
  final Widget child;

  const BiometricLockScreen({super.key, required this.child});

  @override
  ConsumerState<BiometricLockScreen> createState() =>
      _BiometricLockScreenState();
}

class _BiometricLockScreenState extends ConsumerState<BiometricLockScreen>
    with WidgetsBindingObserver {
  bool _locked = false;
  bool _authenticating = false;
  bool _unlocked = false; // Once unlocked in this session, don't re-lock until paused
  DateTime? _lastPausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Lock on cold start (process killed → reopened).
    _lockOnColdStart();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _lastPausedAt = DateTime.now();
      _unlocked = false; // Reset so next resume can lock again
    } else if (state == AppLifecycleState.resumed) {
      _checkAndLock();
    }
  }

  /// Always require biometric on cold start (fresh process).
  Future<void> _lockOnColdStart() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('biometric_enabled') ?? false;
    if (!enabled) return;

    final auth = ref.read(authProvider.notifier);
    await auth.checkBiometricAvailability();
    final authState = ref.read(authProvider);
    if (!authState.isBiometricAvailable) return;

    if (mounted && !_unlocked) {
      setState(() => _locked = true);
      ref.read(biometricLockActiveProvider.notifier).lock();
      await _authenticate();
    }
  }

  /// Lock on resume from background if the session timeout has elapsed.
  Future<void> _checkAndLock() async {
    if (_unlocked) return; // Already unlocked this session

    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('biometric_enabled') ?? false;
    if (!enabled) return;

    final timeoutMinutes = prefs.getInt('session_timeout_minutes') ?? 5;
    if (_lastPausedAt != null) {
      final elapsed = DateTime.now().difference(_lastPausedAt!).inMinutes;
      if (elapsed < timeoutMinutes) return;
    }

    // Check if biometric is available
    final auth = ref.read(authProvider.notifier);
    await auth.checkBiometricAvailability();
    final authState = ref.read(authProvider);
    if (!authState.isBiometricAvailable) return;

    if (mounted && !_unlocked) {
      setState(() => _locked = true);
      ref.read(biometricLockActiveProvider.notifier).lock();
      await _authenticate();
    }
  }

  Future<void> _authenticate() async {
    if (_authenticating) return;
    setState(() => _authenticating = true);

    final auth = ref.read(authProvider.notifier);
    try {
      final success = await auth.authenticate(
        reason: 'Unlock Termopus',
      );

      if (mounted) {
        setState(() {
          _authenticating = false;
          if (success) {
            _locked = false;
            _unlocked = true; // Prevent immediate re-lock
          }
        });
        if (success) {
          ref.read(biometricLockActiveProvider.notifier).unlock();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _authenticating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_locked) return widget.child;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.lock_outline,
              size: 64,
              color: AppTheme.primary,
            ),
            const SizedBox(height: 24),
            Text(
              'Termopus is Locked',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                  ),
            ),
            const SizedBox(height: 12),
            Text(
              'Authenticate to continue',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _authenticating ? null : _authenticate,
              icon: _authenticating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.fingerprint),
              label: Text(_authenticating ? 'Authenticating...' : 'Unlock'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(200, 48),
                backgroundColor: AppTheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
