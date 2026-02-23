
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../shared/responsive.dart';
import '../../shared/theme.dart';
import 'biometric_setup.dart';

/// Welcome screen shown on first launch.
///
/// Shows subscription options first — the user must subscribe or restore
/// an existing account before proceeding to biometric setup and provisioning.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {

  @override
  void initState() {
    super.initState();
  }






  void _advanceToBiometric() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const BiometricSetupScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding:
              EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 2),
          child: Column(
            children: [
              const Spacer(flex: 2),

              // ---- Icon / Logo ----
              Container(
                width: context.rValue(mobile: 96.0, tablet: 120.0),
                height: context.rValue(mobile: 96.0, tablet: 120.0),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Icon(
                  Icons.terminal_rounded,
                  size: context.rValue(mobile: 48.0, tablet: 56.0),
                  color: AppTheme.primary,
                ),
              ),
              SizedBox(height: context.rSpacing * 4),

              // ---- Title ----
              Text(
                'Claude Code Remote',
                style: Theme.of(context).textTheme.headlineLarge,
                textAlign: TextAlign.center,
              ),
              SizedBox(height: context.rSpacing * 2),

              // ---- Description ----
              Text(
                'Control Claude Code running on your computer, right from '
                'your phone. Review actions, approve changes, and chat -- '
                'all with bank-grade end-to-end encryption.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: AppTheme.textSecondary,
                      height: 1.5,
                    ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: context.rSpacing * 5),

              // ---- Feature highlights ----
              const _FeatureRow(
                icon: Icons.lock_outline,
                text: 'End-to-end encrypted via hardware keys',
              ),
              SizedBox(height: context.rSpacing * 2),
              const _FeatureRow(
                icon: Icons.fingerprint,
                text: 'Biometric authentication required',
              ),
              SizedBox(height: context.rSpacing * 2),
              const _FeatureRow(
                icon: Icons.qr_code_scanner_rounded,
                text: 'Pair with a single QR scan',
              ),

              const Spacer(flex: 3),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _advanceToBiometric,
                  child: const Text('Get Started'),
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

class _FeatureRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _FeatureRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon,
            color: AppTheme.primary,
            size: context.rValue(mobile: 22.0, tablet: 28.0)),
        SizedBox(width: context.rSpacing * 2),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                ),
          ),
        ),
      ],
    );
  }
}
