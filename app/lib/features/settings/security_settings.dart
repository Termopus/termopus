import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/platform/security_channel.dart';
import '../../core/providers/cert_renewal_provider.dart';
import '../../core/providers/chat_provider.dart';
import '../../shared/responsive.dart';
import '../../shared/theme.dart';

/// Detailed security settings and status screen.
///
/// Displays the state of each security layer: biometric availability,
/// device integrity, certificate status, and connection security.
class SecuritySettingsScreen extends ConsumerStatefulWidget {
  const SecuritySettingsScreen({super.key});

  @override
  ConsumerState<SecuritySettingsScreen> createState() =>
      _SecuritySettingsScreenState();
}

class _SecuritySettingsScreenState
    extends ConsumerState<SecuritySettingsScreen> {
  final SecurityChannel _security = SecurityChannel();

  bool _loading = true;
  bool _biometricAvailable = false;
  bool _integrityValid = false;
  bool _hasCertificate = false;
  String _connectionState = 'disconnected';
  String? _certExpiryDate;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    setState(() => _loading = true);

    final biometric = await _security.isBiometricAvailable();
    final integrity = await _security.checkDeviceIntegrity();
    final cert = await _security.hasCertificate();
    final connState = await _security.getConnectionState();

    // Read cert expiry from prefs
    final prefs = await SharedPreferences.getInstance();
    final expiresAtStr = prefs.getString('cert_expires_at');
    String? expiryDisplay;
    if (expiresAtStr != null) {
      try {
        final dt = DateTime.parse(expiresAtStr);
        expiryDisplay = '${dt.month}/${dt.day}/${dt.year} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
      } catch (_) {
        // Invalid date
      }
    }

    if (mounted) {
      setState(() {
        _biometricAvailable = biometric;
        _integrityValid = integrity;
        _hasCertificate = cert;
        _connectionState = connState.toLowerCase();
        _certExpiryDate = expiryDisplay;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final certState = ref.watch(certRenewalProvider);
    final isConnected = _connectionState == 'connected';
    final isMtlsActive = isConnected && _hasCertificate;
    final isE2eActive = isConnected;

    return Scaffold(
      appBar: AppBar(title: const Text('Security')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.all(context.rHorizontalPadding),
              children: [
                _StatusTile(
                  icon: Icons.fingerprint,
                  title: 'Biometric Hardware',
                  subtitle: _biometricAvailable
                      ? 'Available and active'
                      : 'Not available on this device',
                  ok: _biometricAvailable,
                ),
                SizedBox(height: context.rSpacing * 1.5),
                _StatusTile(
                  icon: Icons.verified_user_outlined,
                  title: 'Device Integrity',
                  subtitle: _integrityValid
                      ? 'All checks passed'
                      : 'Integrity compromised -- app may not work securely',
                  ok: _integrityValid,
                ),
                SizedBox(height: context.rSpacing * 1.5),
                _StatusTile(
                  icon: Icons.badge_outlined,
                  title: 'Client Certificate',
                  subtitle: _hasCertificate
                      ? 'Provisioned and stored in Secure Enclave'
                          '${_certExpiryDate != null ? '\nExpires: $_certExpiryDate' : ''}'
                          '${certState.isRenewing ? '\nRenewing...' : ''}'
                      : 'Not provisioned',
                  ok: _hasCertificate,
                ),
                SizedBox(height: context.rSpacing * 1.5),
                _StatusTile(
                  icon: Icons.lock_outline,
                  title: 'End-to-End Encryption',
                  subtitle: isE2eActive
                      ? 'Active — AES-256-GCM with hardware-backed keys'
                      : 'Inactive — connect to a session to enable',
                  ok: isE2eActive,
                ),
                SizedBox(height: context.rSpacing * 1.5),
                _StatusTile(
                  icon: Icons.vpn_lock_outlined,
                  title: 'mTLS Transport',
                  subtitle: isMtlsActive
                      ? 'Active — mutual TLS via Cloudflare Access'
                      : !_hasCertificate
                          ? 'Inactive — device not provisioned'
                          : 'Inactive — not connected',
                  ok: isMtlsActive,
                ),

                SizedBox(height: context.rSpacing * 4),

                // ---- Connection status ----
                Card(
                  child: Padding(
                    padding: EdgeInsets.all(context.rSpacing * 2),
                    child: Row(
                      children: [
                        Icon(
                          _connectionStateIcon(),
                          color: _connectionStateColor(),
                          size: context.rIconSize,
                        ),
                        SizedBox(width: context.rSpacing),
                        Expanded(
                          child: Text(
                            'Connection: ${_connectionState[0].toUpperCase()}${_connectionState.substring(1)}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                SizedBox(height: context.rSpacing * 2),

                // ---- Reset Bridge PIN button ----
                Center(
                  child: OutlinedButton.icon(
                    onPressed: () => _confirmResetPin(context),
                    icon: const Icon(Icons.lock_reset),
                    label: const Text('Reset Bridge PIN'),
                  ),
                ),

                SizedBox(height: context.rSpacing * 2),

                // ---- Refresh button ----
                Center(
                  child: OutlinedButton.icon(
                    onPressed: _loadStatus,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh Status'),
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _confirmResetPin(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Bridge PIN'),
        content: const Text(
          'This will remove the current PIN on the bridge. '
          'You will be asked to set a new PIN on the next session pairing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      ref.read(chatProvider.notifier).sendCommand('reset_bridge_pin');
      messenger.showSnackBar(
        const SnackBar(content: Text('Bridge PIN reset command sent')),
      );
    }
  }

  IconData _connectionStateIcon() {
    switch (_connectionState) {
      case 'connected':
        return Icons.wifi;
      case 'connecting':
      case 'reconnecting':
        return Icons.wifi_find;
      case 'error':
        return Icons.wifi_off;
      default:
        return Icons.wifi_off;
    }
  }

  Color _connectionStateColor() {
    switch (_connectionState) {
      case 'connected':
        return AppTheme.primary;
      case 'connecting':
      case 'reconnecting':
        return Colors.orange;
      default:
        return AppTheme.error;
    }
  }
}

class _StatusTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool ok;

  const _StatusTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.ok,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(context.rSpacing * 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: context.rValue(mobile: 40.0, tablet: 48.0),
              height: context.rValue(mobile: 40.0, tablet: 48.0),
              decoration: BoxDecoration(
                color: (ok ? AppTheme.primary : AppTheme.error)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                color: ok ? AppTheme.primary : AppTheme.error,
                size: context.rIconSize,
              ),
            ),
            SizedBox(width: context.rSpacing * 1.75),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      Icon(
                        ok ? Icons.check_circle : Icons.cancel,
                        color: ok ? AppTheme.primary : AppTheme.error,
                        size: context.rValue(mobile: 18.0, tablet: 24.0),
                      ),
                    ],
                  ),
                  SizedBox(height: context.rSpacing * 0.5),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.textSecondary,
                          height: 1.4,
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
