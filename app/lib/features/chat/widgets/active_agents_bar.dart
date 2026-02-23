import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/active_agents_provider.dart';
import '../../../shared/responsive.dart';
import '../../../shared/theme.dart';

/// Slim bar showing active background agents (subagents spawned via Task tool).
///
/// Collapses to zero height when no agents are running.
/// Tapping opens a bottom sheet with per-agent details.
class ActiveAgentsBar extends ConsumerWidget {
  const ActiveAgentsBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agents = ref.watch(activeAgentsProvider);

    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      child: agents.isEmpty
          ? const SizedBox.shrink()
          : GestureDetector(
              onTap: () => _showAgentDetails(context, agents),
              child: Container(
                width: double.infinity,
                padding:
                    EdgeInsets.symmetric(vertical: context.rSpacing, horizontal: context.rHorizontalPadding),
                color: AppTheme.surface,
                child: Row(
                  children: [
                    SizedBox(
                      width: context.rValue(mobile: 16.0, tablet: 18.0),
                      height: context.rValue(mobile: 16.0, tablet: 18.0),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppTheme.brandCyan,
                      ),
                    ),
                    SizedBox(width: context.rSpacing * 1.25),
                    Expanded(
                      child: Text(
                        _summaryText(agents),
                        style: TextStyle(
                          fontSize: context.rFontSize(mobile: 13, tablet: 15),
                          color: AppTheme.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      Icons.expand_more_rounded,
                      size: context.rValue(mobile: 18.0, tablet: 20.0),
                      color: AppTheme.textMuted,
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  String _summaryText(List<ActiveAgent> agents) {
    if (agents.length == 1) {
      return '${agents.first.agentType} agent running';
    }
    return '${agents.length} agents running';
  }

  void _showAgentDetails(BuildContext context, List<ActiveAgent> agents) {
    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _AgentDetailsSheet(agents: agents),
    );
  }
}

class _AgentDetailsSheet extends StatelessWidget {
  final List<ActiveAgent> agents;

  const _AgentDetailsSheet({required this.agents});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
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
              padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 2, vertical: context.rSpacing),
              child: Row(
                children: [
                  Text(
                    'Background Agents',
                    style: TextStyle(
                      fontSize: context.rFontSize(mobile: 16, tablet: 18),
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding:
                        EdgeInsets.symmetric(horizontal: context.rSpacing, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.brandCyan.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${agents.length}',
                      style: TextStyle(
                        fontSize: context.rFontSize(mobile: 13, tablet: 15),
                        fontWeight: FontWeight.w600,
                        color: AppTheme.brandCyan,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ...agents.map((agent) => _AgentTile(agent: agent)),
            SizedBox(height: context.rSpacing * 2),
          ],
        ),
      ),
    );
  }
}

class _AgentTile extends StatelessWidget {
  final ActiveAgent agent;

  const _AgentTile({required this.agent});

  @override
  Widget build(BuildContext context) {
    final elapsed = DateTime.now().difference(agent.startedAt);
    final durationText = elapsed.inMinutes > 0
        ? '${elapsed.inMinutes}m ${elapsed.inSeconds % 60}s'
        : '${elapsed.inSeconds}s';

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 2, vertical: context.rSpacing * 1.25),
      child: Row(
        children: [
          Icon(
            _iconForType(agent.agentType),
            size: context.rIconSize,
            color: AppTheme.brandCyan,
          ),
          SizedBox(width: context.rSpacing * 1.5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  agent.agentType,
                  style: TextStyle(
                    fontSize: context.bodyFontSize,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.textPrimary,
                  ),
                ),
                Text(
                  'Running for $durationText',
                  style: TextStyle(
                    fontSize: context.captionFontSize,
                    color: AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: context.rValue(mobile: 14.0, tablet: 16.0),
            height: context.rValue(mobile: 14.0, tablet: 16.0),
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: AppTheme.brandCyan,
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconForType(String type) {
    switch (type) {
      case 'Explore':
        return Icons.search_rounded;
      case 'Bash':
        return Icons.terminal_rounded;
      case 'Plan':
        return Icons.architecture_rounded;
      default:
        return Icons.smart_toy_rounded;
    }
  }
}
