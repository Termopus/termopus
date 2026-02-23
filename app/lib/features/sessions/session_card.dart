import 'package:flutter/material.dart';

import '../../models/session.dart';
import '../../shared/extensions.dart';
import '../../shared/responsive.dart';
import '../../shared/theme.dart';

/// A card representing a paired computer session.
///
/// Displays the computer name, connection status, and last connected time.
class SessionCard extends StatelessWidget {
  final Session session;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback? onRename;

  const SessionCard({
    super.key,
    required this.session,
    required this.onTap,
    required this.onDelete,
    this.onRename,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.all(context.rSpacing * 2),
          child: Row(
            children: [
              // ---- Leading icon ----
              Container(
                width: context.rValue(mobile: 48.0, tablet: 56.0),
                height: context.rValue(mobile: 48.0, tablet: 56.0),
                decoration: BoxDecoration(
                  color: session.isConnected
                      ? AppTheme.primary.withValues(alpha: 0.15)
                      : AppTheme.surfaceLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.computer,
                  color: session.isConnected
                      ? AppTheme.primary
                      : AppTheme.textMuted,
                ),
              ),
              SizedBox(width: context.rSpacing * 2),

              // ---- Text content ----
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.name,
                      style: Theme.of(context).textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: context.rSpacing * 0.5),
                    Row(
                      children: [
                        _StatusDot(isConnected: session.isConnected),
                        SizedBox(width: context.rSpacing * 0.75),
                        Text(
                          session.isConnected ? 'Online' : 'Offline',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: session.isConnected
                                        ? AppTheme.primary
                                        : AppTheme.textMuted,
                                  ),
                        ),
                        if (session.lastConnected != null) ...[
                          SizedBox(width: context.rSpacing * 1.5),
                          Text(
                            session.lastConnected!.relativeString,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),

              // ---- Trailing actions ----
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: AppTheme.textMuted),
                color: AppTheme.surface,
                onSelected: (value) {
                  if (value == 'delete') onDelete();
                  if (value == 'rename') onRename?.call();
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'rename',
                    child: Row(
                      children: [
                        Icon(Icons.edit_outlined, color: AppTheme.textSecondary, size: context.rIconSize),
                        SizedBox(width: context.rSpacing),
                        const Text('Rename'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline, color: AppTheme.error, size: context.rIconSize),
                        SizedBox(width: context.rSpacing),
                        const Text('Remove'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final bool isConnected;

  const _StatusDot({required this.isConnected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: context.rValue(mobile: 8.0, tablet: 10.0),
      height: context.rValue(mobile: 8.0, tablet: 10.0),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isConnected ? AppTheme.primary : AppTheme.textMuted,
      ),
    );
  }
}
