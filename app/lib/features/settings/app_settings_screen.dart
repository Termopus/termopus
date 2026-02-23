import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shared/constants.dart';
import '../../shared/responsive.dart';
import '../../shared/theme.dart';
import 'about_screen.dart';
import 'bridge_controls.dart';
import 'security_settings.dart';

/// App-level settings screen (accessible from home gear icon).
///
/// Contains Security, Bridge Controls, and About sections.
/// Chat-specific settings live in [SettingsScreen] instead.
class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({super.key});

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  bool _biometricEnabled = false;
  int _timeoutMinutes = 5;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _biometricEnabled =
          prefs.getBool(AppConstants.prefBiometricEnabled) ?? false;
      _timeoutMinutes =
          prefs.getInt(AppConstants.prefSessionTimeoutMinutes) ?? 5;
    });
  }

  Future<void> _setBiometric(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.prefBiometricEnabled, value);
    if (!mounted) return;
    setState(() => _biometricEnabled = value);
  }

  Future<void> _setTimeout(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(AppConstants.prefSessionTimeoutMinutes, minutes);
    if (!mounted) return;
    setState(() => _timeoutMinutes = minutes);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        elevation: 0,
        title: Text(
          'App Settings',
          style: TextStyle(
            fontSize: context.titleFontSize,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_rounded, size: context.rIconSize),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: EdgeInsets.symmetric(vertical: context.rSpacing),
        children: [
          // ---- Security section ----
          _SectionHeader(title: 'Security', icon: Icons.shield_outlined),
          _SettingsCard(
            children: [
              _ToggleTile(
                icon: Icons.fingerprint_rounded,
                title: 'Biometric Auth',
                subtitle: 'Face ID / fingerprint on launch',
                value: _biometricEnabled,
                onChanged: _setBiometric,
              ),
              _tileDivider(),
              _NavTile(
                icon: Icons.timer_outlined,
                title: 'Session Timeout',
                trailing: '$_timeoutMinutes min',
                onTap: () => _showTimeoutPicker(context),
              ),
              _tileDivider(),
              _NavTile(
                icon: Icons.lock_outline_rounded,
                title: 'Security Details',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SecuritySettingsScreen(),
                    ),
                  );
                },
              ),
              _tileDivider(),
              _NavTile(
                icon: Icons.dns_outlined,
                title: 'Computer Controls',
                subtitle: 'Manage bridge agent',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const BridgeControlsScreen(),
                    ),
                  );
                },
              ),
            ],
          ),


          // ---- About section ----
          _SectionHeader(title: 'About', icon: Icons.info_outline_rounded),
          _SettingsCard(
            children: [
              _NavTile(
                icon: Icons.rocket_launch_outlined,
                title: 'About Termopus',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AboutScreen(),
                    ),
                  );
                },
              ),
              _tileDivider(),
              _NavTile(
                icon: Icons.description_outlined,
                title: 'Licenses',
                onTap: () {
                  showLicensePage(
                    context: context,
                    applicationName: 'Termopus',
                    applicationVersion: '1.0.0',
                  );
                },
              ),
            ],
          ),

          SizedBox(height: context.rSpacing * 4),
        ],
      ),
    );
  }

  Widget _tileDivider() => Divider(
        height: 0.5,
        indent: context.rValue(mobile: 52.0, tablet: 62.0),
        endIndent: context.rHorizontalPadding,
        color: AppTheme.divider.withValues(alpha: 0.3),
      );

  Future<void> _showTimeoutPicker(BuildContext context) async {
    final options = [5, 10, 15, 30, 60];
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: EdgeInsets.only(top: context.rSpacing * 1.5, bottom: context.rSpacing),
                width: context.rValue(mobile: 40.0, tablet: 48.0),
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.textMuted.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: EdgeInsets.all(context.rSpacing * 2),
                child: Text(
                  'Session Timeout',
                  style: TextStyle(
                    fontSize: context.rFontSize(mobile: 16, tablet: 18),
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
              RadioGroup<int>(
                groupValue: _timeoutMinutes,
                onChanged: (val) => Navigator.of(ctx).pop(val),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: options.map(
                    (m) => RadioListTile<int>(
                      title: Text(
                        '$m minutes',
                        style: const TextStyle(color: AppTheme.textPrimary),
                      ),
                      value: m,
                      activeColor: AppTheme.primary,
                    ),
                  ).toList(),
                ),
              ),
              SizedBox(height: context.rSpacing),
            ],
          ),
        );
      },
    );

    if (selected != null) {
      await _setTimeout(selected);
    }
  }
}

// =============================================================================
// Reusable widgets (matching settings_screen.dart style)
// =============================================================================

class _SectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;

  const _SectionHeader({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(context.rHorizontalPadding, context.rSpacing * 3, context.rHorizontalPadding, context.rSpacing),
      child: Row(
        children: [
          Icon(icon, size: context.rValue(mobile: 16.0, tablet: 18.0), color: AppTheme.textMuted),
          SizedBox(width: context.rSpacing),
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: context.captionFontSize,
              fontWeight: FontWeight.w700,
              color: AppTheme.textMuted,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  final List<Widget> children;

  const _SettingsCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppTheme.divider.withValues(alpha: 0.3),
          width: 0.5,
        ),
      ),
      child: Column(children: children),
    );
  }
}

class _NavTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? trailing;
  final VoidCallback onTap;

  const _NavTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding, vertical: context.rSpacing * 1.75),
          child: Row(
            children: [
              Container(
                width: context.rValue(mobile: 32.0, tablet: 38.0),
                height: context.rValue(mobile: 32.0, tablet: 38.0),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: context.rValue(mobile: 18.0, tablet: 20.0), color: AppTheme.textSecondary),
              ),
              SizedBox(width: context.rSpacing * 1.5),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: context.bodyFontSize,
                        fontWeight: FontWeight.w500,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: context.captionFontSize,
                          color: AppTheme.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
              if (trailing != null)
                Padding(
                  padding: EdgeInsets.only(right: context.rSpacing * 0.5),
                  child: Text(
                    trailing!,
                    style: TextStyle(
                      fontSize: context.captionFontSize,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ),
              Icon(
                Icons.chevron_right_rounded,
                size: context.rIconSize,
                color: AppTheme.textMuted.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToggleTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding, vertical: context.rSpacing * 1.25),
      child: Row(
        children: [
          Container(
            width: context.rValue(mobile: 32.0, tablet: 38.0),
            height: context.rValue(mobile: 32.0, tablet: 38.0),
            decoration: BoxDecoration(
              color: AppTheme.surfaceLight,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: context.rValue(mobile: 18.0, tablet: 20.0), color: AppTheme.textSecondary),
          ),
          SizedBox(width: context.rSpacing * 1.5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: context.bodyFontSize,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.textPrimary,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: context.captionFontSize,
                    color: AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeTrackColor: AppTheme.primary,
          ),
        ],
      ),
    );
  }
}
