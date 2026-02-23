import 'package:flutter/material.dart';

import '../../shared/responsive.dart';
import '../../shared/theme.dart';

/// About screen showing app version, description, and links.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: EdgeInsets.all(context.rHorizontalPadding * 1.5),
        children: [
          // ---- App icon / branding ----
          Center(
            child: Container(
              width: context.rValue(mobile: 80.0, tablet: 96.0),
              height: context.rValue(mobile: 80.0, tablet: 96.0),
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                Icons.terminal_rounded,
                size: context.rValue(mobile: 40.0, tablet: 48.0),
                color: AppTheme.primary,
              ),
            ),
          ),
          SizedBox(height: context.rSpacing * 2.5),
          Text(
            'Claude Code Remote',
            style: Theme.of(context).textTheme.headlineMedium,
            textAlign: TextAlign.center,
          ),
          SizedBox(height: context.rSpacing * 0.5),
          Text(
            'Version 1.0.0 (build 1)',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          SizedBox(height: context.rSpacing * 3),
          Text(
            'Control Claude Code running on your computer from your '
            'phone with bank-grade end-to-end encryption.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                  height: 1.5,
                ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: context.rSpacing * 4),
          const Divider(),
          SizedBox(height: context.rSpacing * 2),

          // ---- Info rows ----
          _InfoRow(
            label: 'Security Model',
            value: '7-layer defense in depth',
          ),
          SizedBox(height: context.rSpacing * 1.5),
          _InfoRow(
            label: 'Encryption',
            value: 'AES-256-GCM (E2E)',
          ),
          SizedBox(height: context.rSpacing * 1.5),
          _InfoRow(
            label: 'Key Storage',
            value: 'Secure Enclave / StrongBox',
          ),
          SizedBox(height: context.rSpacing * 1.5),
          _InfoRow(
            label: 'Transport',
            value: 'mTLS via Cloudflare Access',
          ),
          SizedBox(height: context.rSpacing * 1.5),
          _InfoRow(
            label: 'Relay',
            value: 'Cloudflare Durable Objects',
          ),
          SizedBox(height: context.rSpacing * 4),
          const Divider(),
          SizedBox(height: context.rSpacing * 2),

          // ---- Links ----
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Open Source Licenses'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              showLicensePage(
                context: context,
                applicationName: 'Claude Code Remote',
                applicationVersion: '1.0.0',
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy Policy'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              // Open privacy policy URL.
            },
          ),
          ListTile(
            leading: const Icon(Icons.article_outlined),
            title: const Text('Terms of Service'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              // Open terms URL.
            },
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppTheme.textMuted,
              ),
        ),
        SizedBox(width: context.rSpacing),
        Flexible(
          child: Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textPrimary,
                ),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }
}
