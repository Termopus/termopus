import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../shared/responsive.dart';
import '../../shared/theme.dart';

/// Confirmation screen shown after a successful pairing.
/// Plays a success animation and auto-navigates to chat.
class PairingSuccess extends StatefulWidget {
  final String computerName;
  final String sessionId;

  const PairingSuccess({
    super.key,
    required this.computerName,
    required this.sessionId,
  });

  @override
  State<PairingSuccess> createState() => _PairingSuccessState();
}

class _PairingSuccessState extends State<PairingSuccess>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;
  late Animation<double> _fadeAnim;
  late Animation<double> _checkAnim;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _scaleAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.6, curve: Curves.elasticOut),
      ),
    );

    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.3, 0.7, curve: Curves.easeOut),
      ),
    );

    _checkAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.4, 1.0, curve: Curves.easeOut),
      ),
    );

    HapticFeedback.heavyImpact();
    _controller.forward();

    // Auto-navigate to chat after 2.5 seconds
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted) {
        context.go('/chat/${widget.sessionId}');
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 2),
          child: Column(
            children: [
              const Spacer(flex: 2),

              // ── Animated check icon ──
              AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  return Transform.scale(
                    scale: _scaleAnim.value,
                    child: Container(
                      width: context.rValue(mobile: 110.0, tablet: 130.0),
                      height: context.rValue(mobile: 110.0, tablet: 130.0),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppTheme.primary.withValues(alpha: 0.12),
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.primary
                                .withValues(alpha: 0.2 * _scaleAnim.value),
                            blurRadius: 40,
                            spreadRadius: 10,
                          ),
                        ],
                      ),
                      child: Center(
                        child: Container(
                          width: context.rValue(mobile: 72.0, tablet: 88.0),
                          height: context.rValue(mobile: 72.0, tablet: 88.0),
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppTheme.primary,
                          ),
                          child: Icon(
                            Icons.check_rounded,
                            size: context.rValue(mobile: 42.0, tablet: 50.0) * _checkAnim.value,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
              SizedBox(height: context.rSpacing * 4.5),

              // ── Title ──
              FadeTransition(
                opacity: _fadeAnim,
                child: Text(
                  'Paired Successfully',
                  style: TextStyle(
                    fontSize: context.headlineFontSize,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                    letterSpacing: -0.5,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              SizedBox(height: context.rSpacing * 2),

              // ── Subtitle ──
              FadeTransition(
                opacity: _fadeAnim,
                child: Text(
                  'Securely connected to',
                  style: TextStyle(
                    fontSize: context.bodyFontSize,
                    color: AppTheme.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              SizedBox(height: context.rSpacing * 1.5),

              // ── Computer name chip ──
              FadeTransition(
                opacity: _fadeAnim,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.rSpacing * 2.5,
                    vertical: context.rSpacing * 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: AppTheme.primary.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: context.rValue(mobile: 36.0, tablet: 44.0),
                        height: context.rValue(mobile: 36.0, tablet: 44.0),
                        decoration: BoxDecoration(
                          color: AppTheme.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.laptop_mac_rounded,
                          color: AppTheme.primary,
                          size: context.rIconSize,
                        ),
                      ),
                      SizedBox(width: context.rSpacing * 1.5),
                      Flexible(
                        child: Text(
                          widget.computerName,
                          style: TextStyle(
                            fontSize: context.rFontSize(mobile: 15, tablet: 17),
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: context.rSpacing * 3.5),

              // ── Encryption note ──
              FadeTransition(
                opacity: _fadeAnim,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.lock_rounded,
                        size: context.rValue(mobile: 14.0, tablet: 18.0), color: AppTheme.textMuted),
                    SizedBox(width: context.rSpacing * 0.75),
                    Text(
                      'End-to-end encrypted',
                      style: TextStyle(
                        fontSize: context.captionFontSize,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: context.rSpacing * 5),

              // ── Auto-redirect indicator ──
              FadeTransition(
                opacity: _fadeAnim,
                child: Column(
                  children: [
                    SizedBox(
                      width: context.rValue(mobile: 20.0, tablet: 24.0),
                      height: context.rValue(mobile: 20.0, tablet: 24.0),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppTheme.textMuted,
                      ),
                    ),
                    SizedBox(height: context.rSpacing * 1.25),
                    Text(
                      'Opening chat...',
                      style: TextStyle(
                        fontSize: context.captionFontSize,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),

              const Spacer(flex: 3),
            ],
          ),
        ),
      ),
    );
  }
}
