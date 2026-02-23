import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/security_channel.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/providers/session_provider.dart';
import '../../models/session.dart';
import '../../shared/responsive.dart';
import '../../shared/theme.dart';
import 'pairing_success.dart';

/// Shows animated step indicators while the native layer performs the
/// ECDH key exchange and establishes the encrypted WebSocket.
class PairingProgress extends ConsumerStatefulWidget {
  final String relay;
  final String sessionId;
  final String peerPublicKey;
  final String computerName;

  const PairingProgress({
    super.key,
    required this.relay,
    required this.sessionId,
    required this.peerPublicKey,
    required this.computerName,
  });

  @override
  ConsumerState<PairingProgress> createState() => _PairingProgressState();
}

class _PairingProgressState extends ConsumerState<PairingProgress>
    with SingleTickerProviderStateMixin {
  final SecurityChannel _security = SecurityChannel();

  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  int _currentStep = 0; // 0=connecting, 1=exchanging, 2=establishing
  bool _failed = false;
  String? _error;

  static const _steps = [
    ('Connecting to relay...', Icons.cell_tower_rounded),
    ('Exchanging keys...', Icons.vpn_key_rounded),
    ('Establishing secure channel...', Icons.lock_rounded),
  ];

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _startPairing();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _startPairing() async {
    try {
      setState(() {
        _currentStep = 0;
        _failed = false;
        _error = null;
      });

      // Small delay to show the first step
      await Future<void>.delayed(const Duration(milliseconds: 400));

      setState(() => _currentStep = 1);

      // Pass biometric proof from auth state for native validation
      final biometricProof = ref.read(authProvider).biometricProof;

      final success = await _security.startPairing(
        relay: widget.relay,
        sessionId: widget.sessionId,
        peerPublicKey: widget.peerPublicKey,
        biometricProof: biometricProof,
      );

      if (!success) {
        throw Exception('Pairing handshake failed');
      }

      if (!mounted) return;
      setState(() => _currentStep = 2);

      // Give the native layer a moment to confirm the connection.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Save session metadata.
      final session = Session(
        id: widget.sessionId,
        name: widget.computerName,
        relay: widget.relay,
        pairedAt: DateTime.now(),
        lastConnected: DateTime.now(),
        isConnected: true,
      );
      await ref.read(sessionProvider.notifier).addSession(session);

      if (!mounted) return;

      HapticFeedback.heavyImpact();
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => PairingSuccess(
            computerName: widget.computerName,
            sessionId: widget.sessionId,
          ),
        ),
      );
    } catch (e) {
      HapticFeedback.vibrate();
      if (mounted) {
        setState(() {
          _failed = true;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            // ── Top bar ──
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.rSpacing, vertical: context.rSpacing),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    color: AppTheme.textSecondary,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const Spacer(),
                ],
              ),
            ),

            const Spacer(flex: 2),

            // ── Animated lock icon ──
            AnimatedBuilder(
              animation: _pulseAnim,
              builder: (context, child) {
                return Container(
                  width: context.rValue(mobile: 100.0, tablet: 120.0),
                  height: context.rValue(mobile: 100.0, tablet: 120.0),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (_failed ? AppTheme.error : AppTheme.primary)
                        .withValues(alpha: 0.1),
                    boxShadow: _failed
                        ? null
                        : [
                            BoxShadow(
                              color: AppTheme.primary
                                  .withValues(alpha: 0.15 * _pulseAnim.value),
                              blurRadius: 32 * _pulseAnim.value,
                              spreadRadius: 8 * _pulseAnim.value,
                            ),
                          ],
                  ),
                  child: Icon(
                    _failed
                        ? Icons.error_outline_rounded
                        : _steps[_currentStep].$2,
                    size: context.rValue(mobile: 44.0, tablet: 52.0),
                    color: _failed ? AppTheme.error : AppTheme.primary,
                  ),
                );
              },
            ),
            SizedBox(height: context.rSpacing * 5),

            // ── Computer name ──
            Text(
              widget.computerName,
              style: TextStyle(
                fontSize: context.titleFontSize,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
            SizedBox(height: context.rSpacing * 4),

            // ── Step indicators ──
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 3),
              child: Column(
                children: List.generate(_steps.length, (i) {
                  final isActive = i == _currentStep && !_failed;
                  final isDone = i < _currentStep && !_failed;
                  final isFailed = _failed && i == _currentStep;

                  return Padding(
                    padding: EdgeInsets.only(bottom: context.rSpacing * 2),
                    child: Row(
                      children: [
                        // Step circle
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          width: context.rValue(mobile: 32.0, tablet: 40.0),
                          height: context.rValue(mobile: 32.0, tablet: 40.0),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isDone
                                ? AppTheme.primary
                                : isFailed
                                    ? AppTheme.error
                                    : isActive
                                        ? AppTheme.primary
                                            .withValues(alpha: 0.15)
                                        : AppTheme.surface,
                            border: isActive
                                ? Border.all(
                                    color: AppTheme.primary, width: 2)
                                : null,
                          ),
                          child: isDone
                              ? Icon(Icons.check_rounded,
                                  size: context.rValue(mobile: 18.0, tablet: 22.0), color: Colors.white)
                              : isFailed
                                  ? Icon(Icons.close_rounded,
                                      size: context.rValue(mobile: 18.0, tablet: 22.0), color: Colors.white)
                                  : isActive
                                      ? SizedBox(
                                          width: context.rValue(mobile: 14.0, tablet: 18.0),
                                          height: context.rValue(mobile: 14.0, tablet: 18.0),
                                          child:
                                              CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: AppTheme.primary,
                                          ),
                                        )
                                      : Text(
                                          '${i + 1}',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            fontSize: context.captionFontSize,
                                            fontWeight: FontWeight.w600,
                                            color: AppTheme.textMuted,
                                          ),
                                        ),
                        ),
                        SizedBox(width: context.rSpacing * 1.75),

                        // Step label
                        Expanded(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 300),
                            style: TextStyle(
                              fontSize: context.bodyFontSize,
                              fontWeight: isActive || isDone
                                  ? FontWeight.w500
                                  : FontWeight.w400,
                              color: isDone
                                  ? AppTheme.textPrimary
                                  : isFailed
                                      ? AppTheme.error
                                      : isActive
                                          ? AppTheme.textPrimary
                                          : AppTheme.textMuted,
                            ),
                            child: Text(_steps[i].$1),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ),
            ),

            // ── Error message + retry ──
            if (_failed && _error != null) ...[
              SizedBox(height: context.rSpacing),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 3),
                child: Text(
                  _error!,
                  style: TextStyle(
                    fontSize: context.captionFontSize,
                    color: AppTheme.error,
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              SizedBox(height: context.rSpacing * 3),
              SizedBox(
                width: context.rValue(mobile: 200.0, tablet: 240.0),
                height: context.rValue(mobile: 48.0, tablet: 56.0),
                child: ElevatedButton(
                  onPressed: _startPairing,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                  child: Text(
                    'Try Again',
                    style: TextStyle(
                      fontSize: context.buttonFontSize,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],

            const Spacer(flex: 3),

            // ── Security note ──
            Padding(
              padding: EdgeInsets.only(bottom: context.rSpacing * 3),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.shield_rounded,
                      size: context.rValue(mobile: 14.0, tablet: 18.0), color: AppTheme.textMuted),
                  SizedBox(width: context.rSpacing * 0.75),
                  Text(
                    'End-to-end encrypted with ECDH',
                    style: TextStyle(
                      fontSize: context.captionFontSize,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
