import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/security_channel.dart';
import '../../shared/responsive.dart';
import '../../shared/theme.dart';

/// Bridge control commands that can be sent to the computer
enum BridgeCommand {
  pair,
  checkRequirements,
  listSessions,
  reconnect,
  installClaude,
}

/// Screen for controlling the bridge agent on the computer.
///
/// Provides buttons to trigger bridge actions like:
/// - Force new pairing
/// - Check requirements
/// - List sessions
/// - Reconnect
/// - Install Claude Code
class BridgeControlsScreen extends ConsumerStatefulWidget {
  const BridgeControlsScreen({super.key});

  @override
  ConsumerState<BridgeControlsScreen> createState() =>
      _BridgeControlsScreenState();
}

class _BridgeControlsScreenState extends ConsumerState<BridgeControlsScreen> {
  bool _isLoading = false;
  String? _lastResult;
  BridgeCommand? _activeCommand;

  Future<void> _sendCommand(BridgeCommand command) async {
    setState(() {
      _isLoading = true;
      _activeCommand = command;
      _lastResult = null;
    });

    try {
      final result = await SecurityChannel.sendBridgeCommand(
        command.name,
        timeout: const Duration(seconds: 30),
      );

      setState(() {
        _lastResult = result;
        _isLoading = false;
        _activeCommand = null;
      });
    } catch (e) {
      setState(() {
        _lastResult = 'Error: $e';
        _isLoading = false;
        _activeCommand = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bridge Controls'),
      ),
      body: ListView(
        padding: EdgeInsets.all(context.rSpacing * 2),
        children: [
          // Status card
          Card(
            child: Padding(
              padding: EdgeInsets.all(context.rSpacing * 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.computer,
                        color: AppTheme.primary,
                      ),
                      SizedBox(width: context.rSpacing),
                      Text(
                        'Computer Bridge',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  SizedBox(height: context.rSpacing),
                  Text(
                    'Send commands to the bridge agent running on your computer.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.textMuted,
                        ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: context.rSpacing * 3),

          // Command buttons
          _CommandButton(
            icon: Icons.qr_code,
            label: 'New Pairing',
            description: 'Generate new QR code and start fresh pairing',
            isLoading: _activeCommand == BridgeCommand.pair,
            onPressed: _isLoading ? null : () => _sendCommand(BridgeCommand.pair),
          ),
          SizedBox(height: context.rSpacing * 1.5),

          _CommandButton(
            icon: Icons.checklist,
            label: 'Check Requirements',
            description: 'Verify Claude Code and dependencies are installed',
            isLoading: _activeCommand == BridgeCommand.checkRequirements,
            onPressed: _isLoading
                ? null
                : () => _sendCommand(BridgeCommand.checkRequirements),
          ),
          SizedBox(height: context.rSpacing * 1.5),

          _CommandButton(
            icon: Icons.list,
            label: 'List Sessions',
            description: 'Show all saved pairing sessions',
            isLoading: _activeCommand == BridgeCommand.listSessions,
            onPressed: _isLoading
                ? null
                : () => _sendCommand(BridgeCommand.listSessions),
          ),
          SizedBox(height: context.rSpacing * 1.5),

          _CommandButton(
            icon: Icons.refresh,
            label: 'Reconnect',
            description: 'Force reconnection to relay server',
            isLoading: _activeCommand == BridgeCommand.reconnect,
            onPressed:
                _isLoading ? null : () => _sendCommand(BridgeCommand.reconnect),
          ),
          SizedBox(height: context.rSpacing * 1.5),

          _CommandButton(
            icon: Icons.download,
            label: 'Install Claude Code',
            description: 'Install or update Claude Code CLI on computer',
            isLoading: _activeCommand == BridgeCommand.installClaude,
            onPressed: _isLoading
                ? null
                : () => _sendCommand(BridgeCommand.installClaude),
          ),

          // Result display
          if (_lastResult != null) ...[
            SizedBox(height: context.rSpacing * 3),
            Card(
              color: _lastResult!.startsWith('Error')
                  ? Colors.red.shade50
                  : Colors.green.shade50,
              child: Padding(
                padding: EdgeInsets.all(context.rSpacing * 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _lastResult!.startsWith('Error')
                              ? Icons.error_outline
                              : Icons.check_circle_outline,
                          color: _lastResult!.startsWith('Error')
                              ? Colors.red
                              : Colors.green,
                          size: context.rIconSize,
                        ),
                        SizedBox(width: context.rSpacing),
                        Text(
                          'Result',
                          style:
                              Theme.of(context).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                        ),
                      ],
                    ),
                    SizedBox(height: context.rSpacing),
                    Text(
                      _lastResult!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CommandButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;
  final bool isLoading;
  final VoidCallback? onPressed;

  const _CommandButton({
    required this.icon,
    required this.label,
    required this.description,
    required this.isLoading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: EdgeInsets.all(context.rSpacing * 2),
          decoration: BoxDecoration(
            border: Border.all(color: AppTheme.divider),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Container(
                width: context.rValue(mobile: 48.0, tablet: 56.0),
                height: context.rValue(mobile: 48.0, tablet: 56.0),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: isLoading
                    ? Padding(
                        padding: EdgeInsets.all(context.rSpacing * 1.5),
                        child: const CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(icon, color: AppTheme.primary),
              ),
              SizedBox(width: context.rSpacing * 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    SizedBox(height: context.rSpacing * 0.25),
                    Text(
                      description,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textMuted,
                          ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: AppTheme.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
