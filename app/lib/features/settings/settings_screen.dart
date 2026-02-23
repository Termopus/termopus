import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/providers/chat_provider.dart';
import '../../core/providers/claude_config_provider.dart';
import '../../models/message.dart';
import '../../core/providers/extensions_provider.dart';
import '../../core/providers/memory_provider.dart';
import '../../core/providers/session_picker_provider.dart';
import '../../shared/responsive.dart';
import '../../shared/theme.dart';

/// Top-level settings screen with styled sections.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final config = ref.watch(claudeConfigProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        elevation: 0,
        title: Text(
          'Settings',
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
          // ---- Claude section ----
          _SectionHeader(title: 'Claude', icon: Icons.auto_awesome_rounded),
          _SettingsCard(
            children: [
              _ModelTile(
                selectedModel: config.selectedModel,
                onModelSelected: (model) {
                  ref.read(claudeConfigProvider.notifier).setModel(model);
                  ref.read(chatProvider.notifier).setModel(model.id);
                },
              ),
              const _TileDivider(),
              _PermissionModeTile(
                currentMode: config.permissionMode,
                onModeSelected: (mode) {
                  HapticFeedback.mediumImpact();
                  ref.read(claudeConfigProvider.notifier).setPermissionMode(mode);
                  ref.read(chatProvider.notifier).sendCommandSilent('permissions', args: 'set ${mode.cliValue}');
                },
              ),
              const _TileDivider(),
              _ToggleTile(
                icon: Icons.compress_rounded,
                title: 'Auto-compact',
                subtitle: 'Compact context when large',
                value: config.autoCompact,
                onChanged: (value) {
                  ref.read(claudeConfigProvider.notifier).setAutoCompact(value);
                },
              ),
            ],
          ),

          // ---- Session Actions section ----
          _SectionHeader(title: 'Session', icon: Icons.chat_bubble_outline_rounded),
          _SettingsCard(
            children: [
              _ActionTile(
                icon: Icons.history_rounded,
                title: 'Resume Session',
                subtitle: 'Continue a previous conversation',
                color: AppTheme.brandCyan,
                onTap: () => _showSessionPicker(context),
              ),
              const _TileDivider(),
              _ActionTile(
                icon: Icons.compress_rounded,
                title: 'Optimize Chat',
                subtitle: 'Summarize conversation to free up memory',
                color: Colors.orange,
                onTap: () {
                  ref.read(chatProvider.notifier).sendCommand('compact');
                  Navigator.pop(context);
                },
              ),
              const _TileDivider(),
              _ActionTile(
                icon: Icons.cleaning_services_rounded,
                title: 'Start Fresh',
                subtitle: 'Clear chat memory and begin again',
                color: Colors.redAccent,
                onTap: () {
                  _confirmAction(
                    context,
                    title: 'Clear Context?',
                    message: 'This will clear Claude\'s memory of the current conversation.',
                    onConfirm: () {
                      ref.read(chatProvider.notifier).sendCommand('clear');
                      Navigator.pop(context);
                    },
                  );
                },
              ),
              const _TileDivider(),
              _ActionTile(
                icon: Icons.analytics_outlined,
                title: 'Statistics',
                subtitle: 'View usage, tokens, and activity',
                color: Colors.green,
                onTap: () {
                  ref.read(chatProvider.notifier).sendCommand('cost');
                  Navigator.pop(context);
                },
              ),
              const _TileDivider(),
              _ActionTile(
                icon: Icons.undo_rounded,
                title: 'Undo Last',
                subtitle: 'Take back the last message or action',
                color: Colors.amber,
                onTap: () {
                  _confirmAction(
                    context,
                    title: 'Undo Last Action?',
                    message: 'This will rewind Claude\'s last message or tool use.',
                    onConfirm: () {
                      ref.read(chatProvider.notifier).sendCommand('rewind');
                      Navigator.pop(context);
                    },
                  );
                },
              ),
              const _TileDivider(),
              _ActionTile(
                icon: Icons.map_outlined,
                title: 'Plan Mode',
                subtitle: 'Ask Claude to plan before coding',
                color: AppTheme.primary,
                onTap: () {
                  ref.read(chatProvider.notifier).sendCommand('plan');
                  Navigator.pop(context);
                },
              ),
            ],
          ),

          // ---- Tools section ----
          _SectionHeader(title: 'Tools', icon: Icons.build_outlined),
          _SettingsCard(
            children: [
              _ActionTile(
                icon: Icons.save_alt_rounded,
                title: 'Save Chat History',
                subtitle: 'Share conversation as text',
                color: AppTheme.brandCyan,
                onTap: () => _exportChat(context),
              ),
              const _TileDivider(),
              _ActionTile(
                icon: Icons.psychology_outlined,
                title: 'Project Notes',
                subtitle: 'What Claude remembers about your project',
                color: Colors.purple,
                onTap: () => _showMemory(context),
              ),
              const _TileDivider(),
              _ActionTile(
                icon: Icons.info_outline_rounded,
                title: 'Session Status',
                subtitle: 'Current session details and state',
                color: Colors.blue,
                onTap: () {
                  ref.read(chatProvider.notifier).sendCommand('status');
                  Navigator.pop(context);
                },
              ),
              const _TileDivider(),
              _ActionTile(
                icon: Icons.medical_services_outlined,
                title: 'Health Check',
                subtitle: 'Make sure everything is working',
                color: Colors.teal,
                onTap: () {
                  final notifier = ref.read(chatProvider.notifier);
                  notifier.sendCommand('doctor');
                  // Auto-press Enter to bypass "Press Enter to continue" prompt.
                  // Capture notifier before pop — ref is invalid after dispose.
                  Future.delayed(const Duration(milliseconds: 500), () {
                    notifier.sendKey('Enter');
                  });
                  Navigator.pop(context);
                },
              ),
            ],
          ),

          // ---- Extensions section ----
          _SectionHeader(title: 'Extensions', icon: Icons.extension_rounded),
          _SettingsCard(
            children: [
              _ActionTile(
                icon: Icons.widgets_outlined,
                title: 'Plugins',
                subtitle: 'Installed extensions and tools',
                color: Colors.deepPurple,
                onTap: () => _showPlugins(context),
              ),
              const _TileDivider(),
              _ActionTile(
                icon: Icons.auto_awesome_outlined,
                title: 'Skills',
                subtitle: 'Available capabilities and workflows',
                color: AppTheme.brandCyan,
                onTap: () => _showSkills(context),
              ),
              const _TileDivider(),
              _ActionTile(
                icon: Icons.rule_rounded,
                title: 'Instructions',
                subtitle: 'Custom rules and guidelines for Claude',
                color: Colors.amber,
                onTap: () => _showRules(context),
              ),
            ],
          ),

          // ---- Permission Rules section ----
          _SectionHeader(title: 'Permission Rules', icon: Icons.verified_user_rounded),
          _SettingsCard(
            children: [
              _PermissionRulesContent(),
            ],
          ),

          SizedBox(height: context.rSpacing * 4),
        ],
      ),
    );
  }

  void _showPlugins(BuildContext context) {
    ref.read(chatProvider.notifier).requestExtensions();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const _PluginsSheet(),
    );
  }

  void _showSkills(BuildContext context) {
    ref.read(chatProvider.notifier).requestExtensions();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const _SkillsSheet(),
    );
  }

  void _showMemory(BuildContext context) {
    ref.read(chatProvider.notifier).requestMemory();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const _MemorySheet(),
    );
  }

  void _showRules(BuildContext context) {
    ref.read(chatProvider.notifier).requestExtensions();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const _RulesSheet(),
    );
  }

  void _showSessionPicker(BuildContext context) {
    // Request the session list from bridge (reads sessions-index.json)
    ref.read(chatProvider.notifier).requestSessions();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _SessionPickerSheet(
        onResume: (sessionId) {
          Navigator.pop(ctx);
          ref.read(chatProvider.notifier).resumeSession(sessionId);
          Navigator.pop(context); // Close settings too
        },
      ),
    );
  }

  void _confirmAction(
    BuildContext context, {
    required String title,
    required String message,
    required VoidCallback onConfirm,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title, style: const TextStyle(color: AppTheme.textPrimary)),
        content: Text(message, style: const TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: AppTheme.textMuted)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              onConfirm();
            },
            child: const Text('Confirm', style: TextStyle(color: AppTheme.primary)),
          ),
        ],
      ),
    );
  }

  void _exportChat(BuildContext context) {
    final messages = ref.read(chatProvider);
    if (messages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No messages to export')),
      );
      return;
    }

    final buffer = StringBuffer('Termopus Chat Export\n');
    buffer.writeln('=' * 40);
    buffer.writeln('Date: ${DateTime.now().toIso8601String()}\n');

    for (final msg in messages) {
      final sender = msg.sender == MessageSender.user ? 'You' : 'Claude';
      final time = '${msg.timestamp.hour}:${msg.timestamp.minute.toString().padLeft(2, '0')}';
      if (msg.content.isNotEmpty) {
        buffer.writeln('[$time] $sender: ${msg.content}');
      }
    }

    Navigator.pop(context);
    SharePlus.instance.share(ShareParams(text: buffer.toString(), subject: 'Termopus Chat Export'));
  }
}

// =============================================================================
// Section header with icon
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

// =============================================================================
// Settings card container
// =============================================================================

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

// =============================================================================
// Tile divider
// =============================================================================

class _TileDivider extends StatelessWidget {
  const _TileDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 0.5,
      indent: context.rValue(mobile: 52.0, tablet: 62.0),
      endIndent: context.rHorizontalPadding,
      color: AppTheme.divider.withValues(alpha: 0.3),
    );
  }
}

// =============================================================================
// Toggle tile (switch)
// =============================================================================

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

// =============================================================================
// Model selector tile
// =============================================================================

class _ModelTile extends StatelessWidget {
  final ClaudeModel selectedModel;
  final ValueChanged<ClaudeModel> onModelSelected;

  const _ModelTile({
    required this.selectedModel,
    required this.onModelSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding, vertical: context.rSpacing * 1.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: context.rValue(mobile: 32.0, tablet: 38.0),
                height: context.rValue(mobile: 32.0, tablet: 38.0),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.memory_rounded,
                    size: context.rValue(mobile: 18.0, tablet: 20.0), color: AppTheme.textSecondary),
              ),
              SizedBox(width: context.rSpacing * 1.5),
              Text(
                'Model',
                style: TextStyle(
                  fontSize: context.bodyFontSize,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.textPrimary,
                ),
              ),
            ],
          ),
          SizedBox(height: context.rSpacing * 1.5),
          Row(
            children: ClaudeModel.values.map((model) {
              final isSelected = model == selectedModel;
              final modelColor = Color(model.colorValue);
              return Expanded(
                child: GestureDetector(
                  onTap: () => onModelSelected(model),
                  child: Container(
                    margin: EdgeInsets.only(
                      right: model != ClaudeModel.values.last ? context.rSpacing : 0,
                    ),
                    padding: EdgeInsets.symmetric(vertical: context.rSpacing * 1.25),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? modelColor.withValues(alpha: 0.15)
                          : AppTheme.surfaceLight,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected
                            ? modelColor
                            : AppTheme.divider.withValues(alpha: 0.3),
                        width: isSelected ? 1.5 : 0.5,
                      ),
                    ),
                    child: Column(
                      children: [
                        Container(
                          width: context.rValue(mobile: 10.0, tablet: 12.0),
                          height: context.rValue(mobile: 10.0, tablet: 12.0),
                          decoration: BoxDecoration(
                            color: modelColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        SizedBox(height: context.rSpacing * 0.5),
                        Text(
                          model.displayName,
                          style: TextStyle(
                            fontSize: context.captionFontSize,
                            fontWeight:
                                isSelected ? FontWeight.w600 : FontWeight.w400,
                            color: isSelected
                                ? modelColor
                                : AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Permission mode tile
// =============================================================================

// =============================================================================
// Action tile (colored icon, tappable)
// =============================================================================

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
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
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: context.rValue(mobile: 18.0, tablet: 20.0), color: color),
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
              Icon(Icons.chevron_right_rounded, size: context.rIconSize, color: color.withValues(alpha: 0.5)),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Session picker bottom sheet (native /resume replacement)
// =============================================================================

class _SessionPickerSheet extends ConsumerStatefulWidget {
  final void Function(String sessionId) onResume;

  const _SessionPickerSheet({required this.onResume});

  @override
  ConsumerState<_SessionPickerSheet> createState() => _SessionPickerSheetState();
}

class _SessionPickerSheetState extends ConsumerState<_SessionPickerSheet> {
  bool _timedOut = false;

  @override
  void initState() {
    super.initState();
    // Show empty state after 5 seconds if no sessions arrive
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted && ref.read(sessionPickerProvider).isEmpty) {
        setState(() => _timedOut = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(sessionPickerProvider);

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
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
            // Header
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 1.5, vertical: context.rSpacing),
              child: Row(
                children: [
                  Icon(Icons.history_rounded, size: context.rIconSize, color: AppTheme.brandCyan),
                  SizedBox(width: context.rSpacing),
                  Text(
                    'Resume Session',
                    style: TextStyle(
                      fontSize: context.titleFontSize,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: context.rSpacing * 0.5),

            if (sessions.isEmpty && !_timedOut)
              Padding(
                padding: EdgeInsets.all(context.rSpacing * 5),
                child: Column(
                  children: [
                    SizedBox(
                      width: context.rValue(mobile: 24.0, tablet: 28.0),
                      height: context.rValue(mobile: 24.0, tablet: 28.0),
                      child: const CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppTheme.brandCyan,
                      ),
                    ),
                    SizedBox(height: context.rSpacing * 2),
                    Text(
                      'Loading sessions...',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: context.bodyFontSize),
                    ),
                  ],
                ),
              )
            else if (sessions.isEmpty && _timedOut)
              Padding(
                padding: EdgeInsets.all(context.rSpacing * 5),
                child: Column(
                  children: [
                    Icon(Icons.inbox_rounded, size: context.rValue(mobile: 48.0, tablet: 56.0), color: AppTheme.textMuted),
                    SizedBox(height: context.rSpacing * 2),
                    Text(
                      'No previous sessions found',
                      style: TextStyle(color: AppTheme.textSecondary, fontSize: context.bodyFontSize),
                    ),
                    SizedBox(height: context.rSpacing * 0.5),
                    Text(
                      'Start a conversation first, then you can resume it later.',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: context.captionFontSize),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            else
              Flexible(
                child: _GroupedSessionList(
                  sessions: sessions,
                  onResume: widget.onResume,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GroupedSessionList extends StatefulWidget {
  final List<ResumableSession> sessions;
  final void Function(String sessionId) onResume;

  const _GroupedSessionList({required this.sessions, required this.onResume});

  @override
  State<_GroupedSessionList> createState() => _GroupedSessionListState();
}

class _GroupedSessionListState extends State<_GroupedSessionList> {
  final Set<String> _expanded = {};

  @override
  Widget build(BuildContext context) {
    // Group sessions by project
    final grouped = <String, List<ResumableSession>>{};
    for (final s in widget.sessions) {
      grouped.putIfAbsent(s.project, () => []).add(s);
    }

    // Sort project names alphabetically
    final projectNames = grouped.keys.toList()..sort();

    return ListView.builder(
      shrinkWrap: true,
      padding: EdgeInsets.only(bottom: context.rSpacing * 2),
      itemCount: projectNames.length,
      itemBuilder: (context, index) {
        final project = projectNames[index];
        final projectSessions = grouped[project]!;
        final isExpanded = _expanded.contains(project);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Tappable section header
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => setState(() {
                  if (isExpanded) {
                    _expanded.remove(project);
                  } else {
                    _expanded.add(project);
                  }
                }),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.rHorizontalPadding * 1.5,
                    vertical: context.rSpacing,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isExpanded ? Icons.folder_open_outlined : Icons.folder_outlined,
                        size: context.rValue(mobile: 16.0, tablet: 18.0),
                        color: isExpanded ? AppTheme.brandCyan : AppTheme.textMuted,
                      ),
                      SizedBox(width: context.rSpacing * 0.75),
                      Expanded(
                        child: Text(
                          project,
                          style: TextStyle(
                            fontSize: context.bodyFontSize,
                            fontWeight: FontWeight.w500,
                            color: isExpanded ? AppTheme.textPrimary : AppTheme.textSecondary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${projectSessions.length}',
                        style: TextStyle(
                          fontSize: context.captionFontSize,
                          color: AppTheme.textMuted,
                        ),
                      ),
                      SizedBox(width: context.rSpacing * 0.5),
                      Icon(
                        isExpanded ? Icons.expand_less : Icons.expand_more,
                        size: context.rValue(mobile: 18.0, tablet: 20.0),
                        color: AppTheme.textMuted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Collapsible sessions
            if (isExpanded)
              ...projectSessions.map((session) => _SessionTile(
                session: session,
                onTap: () => widget.onResume(session.sessionId),
              )),
          ],
        );
      },
    );
  }
}

class _SessionTile extends StatelessWidget {
  final ResumableSession session;
  final VoidCallback onTap;

  const _SessionTile({required this.session, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 1.5, vertical: context.rSpacing * 1.5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: context.rValue(mobile: 36.0, tablet: 44.0),
                height: context.rValue(mobile: 36.0, tablet: 44.0),
                decoration: BoxDecoration(
                  color: AppTheme.brandCyan.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: context.rValue(mobile: 18.0, tablet: 20.0),
                  color: AppTheme.brandCyan,
                ),
              ),
              SizedBox(width: context.rSpacing * 1.5),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.summary,
                      style: TextStyle(
                        fontSize: context.bodyFontSize,
                        fontWeight: FontWeight.w500,
                        color: AppTheme.textPrimary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: context.rSpacing * 0.25),
                    Row(
                      children: [
                        Text(
                          session.timeAgo,
                          style: TextStyle(
                            fontSize: context.captionFontSize,
                            color: AppTheme.textMuted,
                          ),
                        ),
                        SizedBox(width: context.rSpacing),
                        Text(
                          '${session.messageCount} msgs',
                          style: TextStyle(
                            fontSize: context.captionFontSize,
                            color: AppTheme.textMuted,
                          ),
                        ),
                        if (session.gitBranch != null) ...[
                          SizedBox(width: context.rSpacing),
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.purple.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                session.gitBranch!,
                                style: TextStyle(
                                  fontSize: context.rFontSize(mobile: 10, tablet: 12),
                                  color: Colors.purpleAccent,
                                  fontFamily: 'monospace',
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.play_arrow_rounded,
                size: context.rIconSize,
                color: AppTheme.brandCyan,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Plugins sheet
// =============================================================================

class _PluginsSheet extends ConsumerStatefulWidget {
  const _PluginsSheet();

  @override
  ConsumerState<_PluginsSheet> createState() => _PluginsSheetState();
}

class _PluginsSheetState extends ConsumerState<_PluginsSheet> {
  bool _timedOut = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted && ref.read(extensionsProvider).plugins.isEmpty) {
        setState(() => _timedOut = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final plugins = ref.watch(extensionsProvider).plugins;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sheetHandle(context),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 1.5, vertical: context.rSpacing),
              child: Row(
                children: [
                  Icon(Icons.widgets_outlined, size: context.rIconSize, color: Colors.deepPurple),
                  SizedBox(width: context.rSpacing),
                  Text('Plugins', style: TextStyle(
                    fontSize: context.titleFontSize, fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  )),
                ],
              ),
            ),
            SizedBox(height: context.rSpacing * 0.5),
            if (plugins.isEmpty && !_timedOut)
              _loadingIndicator(context, 'Loading plugins...')
            else if (plugins.isEmpty && _timedOut)
              _emptyState(context, Icons.extension_off_rounded, 'No plugins installed',
                  'Install plugins using the Claude Code CLI.')
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.only(bottom: context.rSpacing * 2),
                  itemCount: plugins.length,
                  itemBuilder: (context, index) {
                    final plugin = plugins[index];
                    return _PluginTile(plugin: plugin);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PluginTile extends StatelessWidget {
  final InstalledPlugin plugin;
  const _PluginTile({required this.plugin});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 1.5, vertical: context.rSpacing * 1.25),
      child: Row(
        children: [
          Container(
            width: context.rValue(mobile: 40.0, tablet: 48.0),
            height: context.rValue(mobile: 40.0, tablet: 48.0),
            decoration: BoxDecoration(
              color: (plugin.enabled ? Colors.deepPurple : AppTheme.textMuted)
                  .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              _iconForPlugin(plugin.name),
              size: context.rValue(mobile: 22.0, tablet: 26.0),
              color: plugin.enabled ? Colors.deepPurple : AppTheme.textMuted,
            ),
          ),
          SizedBox(width: context.rSpacing * 1.5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plugin.name,
                  style: TextStyle(
                    fontSize: context.bodyFontSize, fontWeight: FontWeight.w500,
                    color: AppTheme.textPrimary,
                  ),
                ),
                if (plugin.description != null)
                  Text(
                    plugin.description!,
                    style: TextStyle(fontSize: context.captionFontSize, color: AppTheme.textMuted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                Row(
                  children: [
                    Text(
                      'v${plugin.version}',
                      style: TextStyle(fontSize: context.rFontSize(mobile: 11, tablet: 13), color: AppTheme.textMuted),
                    ),
                    if (plugin.author != null) ...[
                      SizedBox(width: context.rSpacing),
                      Flexible(
                        child: Text(
                          'by ${plugin.author}',
                          style: TextStyle(fontSize: context.rFontSize(mobile: 11, tablet: 13), color: AppTheme.textMuted),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                    ],
                    if (plugin.skillCount > 0) ...[
                      SizedBox(width: context.rSpacing),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppTheme.brandCyan.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${plugin.skillCount} skills',
                          style: TextStyle(
                            fontSize: context.rFontSize(mobile: 10, tablet: 12), color: AppTheme.brandCyan,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          Container(
            padding: EdgeInsets.symmetric(horizontal: context.rSpacing, vertical: context.rSpacing * 0.5),
            decoration: BoxDecoration(
              color: (plugin.enabled ? Colors.green : AppTheme.textMuted)
                  .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              plugin.enabled ? 'Active' : 'Off',
              style: TextStyle(
                fontSize: context.rFontSize(mobile: 11, tablet: 13),
                fontWeight: FontWeight.w600,
                color: plugin.enabled ? Colors.green : AppTheme.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconForPlugin(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('lsp') || lower.contains('analyzer')) return Icons.code_rounded;
    if (lower.contains('superpowers')) return Icons.bolt_rounded;
    return Icons.extension_rounded;
  }
}

// =============================================================================
// Skills sheet
// =============================================================================

class _SkillsSheet extends ConsumerStatefulWidget {
  const _SkillsSheet();

  @override
  ConsumerState<_SkillsSheet> createState() => _SkillsSheetState();
}

class _SkillsSheetState extends ConsumerState<_SkillsSheet> {
  bool _timedOut = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted && ref.read(extensionsProvider).skills.isEmpty) {
        setState(() => _timedOut = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final skills = ref.watch(extensionsProvider).skills;

    // Group by source
    final grouped = <String, List<ClaudeSkill>>{};
    for (final skill in skills) {
      grouped.putIfAbsent(skill.sourceLabel, () => []).add(skill);
    }

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sheetHandle(context),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 1.5, vertical: context.rSpacing),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome_outlined, size: context.rIconSize, color: AppTheme.brandCyan),
                  SizedBox(width: context.rSpacing),
                  Text('Skills', style: TextStyle(
                    fontSize: context.titleFontSize, fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  )),
                  const Spacer(),
                  if (skills.isNotEmpty)
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: context.rSpacing, vertical: context.rSpacing * 0.25),
                      decoration: BoxDecoration(
                        color: AppTheme.brandCyan.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${skills.length}',
                        style: TextStyle(
                          fontSize: context.captionFontSize, fontWeight: FontWeight.w600,
                          color: AppTheme.brandCyan,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(height: context.rSpacing * 0.5),
            if (skills.isEmpty && !_timedOut)
              _loadingIndicator(context, 'Loading skills...')
            else if (skills.isEmpty && _timedOut)
              _emptyState(context, Icons.auto_awesome_outlined, 'No skills found',
                  'Skills provide specialized capabilities to Claude.')
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.only(bottom: context.rSpacing * 2),
                  children: [
                    for (final group in grouped.entries) ...[
                      Padding(
                        padding: EdgeInsets.fromLTRB(context.rHorizontalPadding * 1.5, context.rSpacing * 1.5, context.rHorizontalPadding * 1.5, context.rSpacing * 0.5),
                        child: Text(
                          group.key.toUpperCase(),
                          style: TextStyle(
                            fontSize: context.rFontSize(mobile: 11, tablet: 13), fontWeight: FontWeight.w700,
                            color: AppTheme.textMuted, letterSpacing: 1,
                          ),
                        ),
                      ),
                      for (final skill in group.value)
                        _SkillTile(skill: skill),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SkillTile extends StatelessWidget {
  final ClaudeSkill skill;
  const _SkillTile({required this.skill});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 1.5, vertical: context.rSpacing),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: context.rValue(mobile: 36.0, tablet: 44.0),
            height: context.rValue(mobile: 36.0, tablet: 44.0),
            decoration: BoxDecoration(
              color: AppTheme.brandCyan.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.auto_awesome_rounded,
              size: context.rValue(mobile: 18.0, tablet: 20.0),
              color: AppTheme.brandCyan,
            ),
          ),
          SizedBox(width: context.rSpacing * 1.5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  skill.name,
                  style: TextStyle(
                    fontSize: context.bodyFontSize, fontWeight: FontWeight.w500,
                    color: AppTheme.textPrimary,
                  ),
                ),
                if (skill.description.isNotEmpty)
                  Text(
                    skill.description,
                    style: TextStyle(fontSize: context.captionFontSize, color: AppTheme.textMuted),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Rules sheet
// =============================================================================

class _RulesSheet extends ConsumerStatefulWidget {
  const _RulesSheet();

  @override
  ConsumerState<_RulesSheet> createState() => _RulesSheetState();
}

class _RulesSheetState extends ConsumerState<_RulesSheet> {
  bool _timedOut = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted && ref.read(extensionsProvider).rules.isEmpty) {
        setState(() => _timedOut = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final rules = ref.watch(extensionsProvider).rules;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sheetHandle(context),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 1.5, vertical: context.rSpacing),
              child: Row(
                children: [
                  Icon(Icons.rule_rounded, size: context.rIconSize, color: Colors.amber),
                  SizedBox(width: context.rSpacing),
                  Text('Instructions', style: TextStyle(
                    fontSize: context.titleFontSize, fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  )),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 1.5),
              child: Text(
                'Custom rules and guidelines that Claude follows in every conversation.',
                style: TextStyle(fontSize: context.captionFontSize, color: AppTheme.textMuted),
              ),
            ),
            SizedBox(height: context.rSpacing),
            if (rules.isEmpty && !_timedOut)
              _loadingIndicator(context, 'Loading instructions...')
            else if (rules.isEmpty && _timedOut)
              _emptyState(context, Icons.rule_rounded, 'No custom instructions',
                  'Add rules in ~/.claude/rules/ to customize Claude\'s behavior.')
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.only(bottom: context.rSpacing * 2),
                  itemCount: rules.length,
                  itemBuilder: (context, index) {
                    final rule = rules[index];
                    return _RuleTile(
                      rule: rule,
                      onTap: () => _showRuleContent(context, rule),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showRuleContent(BuildContext context, ClaudeRule rule) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        decoration: const BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sheetHandle(context),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 1.5, vertical: context.rSpacing),
                child: Row(
                  children: [
                    Icon(Icons.description_outlined, size: context.rIconSize, color: Colors.amber),
                    SizedBox(width: context.rSpacing),
                    Expanded(
                      child: Text(rule.filename, style: TextStyle(
                        fontSize: context.rFontSize(mobile: 16, tablet: 18), fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      )),
                    ),
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: context.rSpacing, vertical: context.rSpacing * 0.25),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        rule.scopeLabel,
                        style: TextStyle(
                          fontSize: context.rFontSize(mobile: 11, tablet: 13), fontWeight: FontWeight.w600,
                          color: Colors.amber,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppTheme.divider),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(context.rHorizontalPadding * 1.5),
                  child: SelectableText(
                    rule.content,
                    style: TextStyle(
                      fontSize: context.captionFontSize,
                      color: AppTheme.textSecondary,
                      fontFamily: 'monospace',
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RuleTile extends StatelessWidget {
  final ClaudeRule rule;
  final VoidCallback onTap;
  const _RuleTile({required this.rule, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final preview = rule.content.split('\n')
        .where((l) => l.trim().isNotEmpty)
        .take(2)
        .join(' ')
        .trim();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 1.5, vertical: context.rSpacing * 1.25),
          child: Row(
            children: [
              Container(
                width: context.rValue(mobile: 36.0, tablet: 44.0),
                height: context.rValue(mobile: 36.0, tablet: 44.0),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.description_outlined,
                  size: context.rValue(mobile: 18.0, tablet: 20.0),
                  color: Colors.amber,
                ),
              ),
              SizedBox(width: context.rSpacing * 1.5),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rule.filename,
                      style: TextStyle(
                        fontSize: context.bodyFontSize, fontWeight: FontWeight.w500,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    Text(
                      preview.length > 80 ? '${preview.substring(0, 77)}...' : preview,
                      style: TextStyle(fontSize: context.captionFontSize, color: AppTheme.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  rule.scopeLabel,
                  style: TextStyle(
                    fontSize: context.rFontSize(mobile: 10, tablet: 12), fontWeight: FontWeight.w600,
                    color: Colors.amber,
                  ),
                ),
              ),
              SizedBox(width: context.rSpacing * 0.5),
              Icon(Icons.chevron_right_rounded, size: context.rValue(mobile: 18.0, tablet: 20.0), color: AppTheme.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Memory sheet (Project Notes — native /memory replacement)
// =============================================================================

class _MemorySheet extends ConsumerStatefulWidget {
  const _MemorySheet();

  @override
  ConsumerState<_MemorySheet> createState() => _MemorySheetState();
}

class _MemorySheetState extends ConsumerState<_MemorySheet> {
  bool _timedOut = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted && ref.read(memoryProvider).isEmpty) {
        setState(() => _timedOut = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(memoryProvider);

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sheetHandle(context),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 1.5, vertical: context.rSpacing),
              child: Row(
                children: [
                  Icon(Icons.psychology_outlined, size: context.rIconSize, color: Colors.purple),
                  SizedBox(width: context.rSpacing),
                  Text('Project Notes', style: TextStyle(
                    fontSize: context.titleFontSize, fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  )),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 1.5),
              child: Text(
                'What Claude remembers about your project (CLAUDE.md files).',
                style: TextStyle(fontSize: context.captionFontSize, color: AppTheme.textMuted),
              ),
            ),
            SizedBox(height: context.rSpacing),
            if (entries.isEmpty && !_timedOut)
              _loadingIndicator(context, 'Loading project notes...')
            else if (entries.isEmpty && _timedOut)
              _emptyState(context, Icons.psychology_outlined, 'No project notes',
                  'Create a CLAUDE.md file in your project to add notes for Claude.')
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.only(bottom: context.rSpacing * 2),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return _MemoryTile(
                      entry: entry,
                      onTap: () => _showMemoryContent(context, entry),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showMemoryContent(BuildContext context, MemoryEntry entry) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        decoration: const BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sheetHandle(context),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 1.5, vertical: context.rSpacing),
                child: Row(
                  children: [
                    Icon(Icons.description_outlined, size: context.rIconSize, color: Colors.purple),
                    SizedBox(width: context.rSpacing),
                    Expanded(
                      child: Text(entry.filename, style: TextStyle(
                        fontSize: context.rFontSize(mobile: 16, tablet: 18), fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      )),
                    ),
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: context.rSpacing, vertical: context.rSpacing * 0.25),
                      decoration: BoxDecoration(
                        color: Colors.purple.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        entry.scopeLabel,
                        style: TextStyle(
                          fontSize: context.rFontSize(mobile: 11, tablet: 13), fontWeight: FontWeight.w600,
                          color: Colors.purple,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppTheme.divider),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(context.rHorizontalPadding * 1.5),
                  child: SelectableText(
                    entry.content,
                    style: TextStyle(
                      fontSize: context.captionFontSize,
                      color: AppTheme.textSecondary,
                      fontFamily: 'monospace',
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MemoryTile extends StatelessWidget {
  final MemoryEntry entry;
  final VoidCallback onTap;
  const _MemoryTile({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final preview = entry.content.split('\n')
        .where((l) => l.trim().isNotEmpty)
        .take(2)
        .join(' ')
        .trim();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 1.5, vertical: context.rSpacing * 1.25),
          child: Row(
            children: [
              Container(
                width: context.rValue(mobile: 36.0, tablet: 44.0),
                height: context.rValue(mobile: 36.0, tablet: 44.0),
                decoration: BoxDecoration(
                  color: Colors.purple.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.description_outlined,
                  size: context.rValue(mobile: 18.0, tablet: 20.0),
                  color: Colors.purple,
                ),
              ),
              SizedBox(width: context.rSpacing * 1.5),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.filename,
                      style: TextStyle(
                        fontSize: context.bodyFontSize, fontWeight: FontWeight.w500,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    Text(
                      preview.length > 80 ? '${preview.substring(0, 77)}...' : preview,
                      style: TextStyle(fontSize: context.captionFontSize, color: AppTheme.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.purple.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  entry.scopeLabel,
                  style: TextStyle(
                    fontSize: context.rFontSize(mobile: 10, tablet: 12), fontWeight: FontWeight.w600,
                    color: Colors.purple,
                  ),
                ),
              ),
              SizedBox(width: context.rSpacing * 0.5),
              Icon(Icons.chevron_right_rounded, size: context.rValue(mobile: 18.0, tablet: 20.0), color: AppTheme.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Permission Rules content (inline in settings card)
// =============================================================================

class _PermissionRulesContent extends ConsumerWidget {
  void _confirmRuleDelete(BuildContext context, WidgetRef ref, String list, String rule) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Remove Rule?', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          'Remove "$rule" from $list list?\nYou\'ll need to tap "Always" again to re-add it.',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: AppTheme.textMuted)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(chatProvider.notifier).sendCommandSilent(
                'permission-rules',
                args: 'remove $list $rule',
              );
            },
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(claudeConfigProvider);
    final allowRules = config.permissionAllowRules;
    final denyRules = config.permissionDenyRules;

    if (allowRules.isEmpty && denyRules.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(context.rSpacing * 2.5),
        child: Column(
          children: [
            Icon(Icons.verified_user_outlined, size: context.rValue(mobile: 32.0, tablet: 40.0), color: AppTheme.textMuted),
            SizedBox(height: context.rSpacing),
            Text(
              'No permission rules yet',
              style: TextStyle(fontSize: context.bodyFontSize, color: AppTheme.textSecondary),
            ),
            SizedBox(height: context.rSpacing * 0.5),
            Text(
              "Tap 'Always' on a permission prompt to add rules",
              style: TextStyle(fontSize: context.captionFontSize, color: AppTheme.textMuted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (allowRules.isNotEmpty) ...[
          Padding(
            padding: EdgeInsets.fromLTRB(context.rHorizontalPadding, context.rSpacing * 1.5, context.rHorizontalPadding, context.rSpacing * 0.5),
            child: Text(
              'ALLOW',
              style: TextStyle(
                fontSize: context.rFontSize(mobile: 11, tablet: 13), fontWeight: FontWeight.w700,
                color: AppTheme.textMuted, letterSpacing: 1,
              ),
            ),
          ),
          for (final rule in allowRules)
            _PermissionRuleTile(
              rule: rule,
              isAllow: true,
              onDelete: () => _confirmRuleDelete(context, ref, 'allow', rule),
            ),
        ],
        if (denyRules.isNotEmpty) ...[
          if (allowRules.isNotEmpty) const _TileDivider(),
          Padding(
            padding: EdgeInsets.fromLTRB(context.rHorizontalPadding, context.rSpacing * 1.5, context.rHorizontalPadding, context.rSpacing * 0.5),
            child: Text(
              'DENY',
              style: TextStyle(
                fontSize: context.rFontSize(mobile: 11, tablet: 13), fontWeight: FontWeight.w700,
                color: AppTheme.textMuted, letterSpacing: 1,
              ),
            ),
          ),
          for (final rule in denyRules)
            _PermissionRuleTile(
              rule: rule,
              isAllow: false,
              onDelete: () => _confirmRuleDelete(context, ref, 'deny', rule),
            ),
        ],
        SizedBox(height: context.rSpacing),
      ],
    );
  }
}

class _PermissionRuleTile extends StatelessWidget {
  final String rule;
  final bool isAllow;
  final VoidCallback onDelete;

  const _PermissionRuleTile({
    required this.rule,
    required this.isAllow,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final color = isAllow ? Colors.green : Colors.red;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding, vertical: context.rSpacing * 0.75),
      child: Row(
        children: [
          Icon(
            isAllow ? Icons.check_circle_rounded : Icons.block_rounded,
            size: context.rValue(mobile: 18.0, tablet: 20.0),
            color: color,
          ),
          SizedBox(width: context.rSpacing * 1.25),
          Expanded(
            child: Text(
              rule,
              style: TextStyle(
                fontSize: context.captionFontSize,
                color: AppTheme.textPrimary,
                fontFamily: 'monospace',
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.close_rounded, size: context.rValue(mobile: 18.0, tablet: 20.0), color: AppTheme.textMuted),
            onPressed: onDelete,
            padding: EdgeInsets.zero,
            constraints: BoxConstraints(minWidth: context.rValue(mobile: 32.0, tablet: 38.0), minHeight: context.rValue(mobile: 32.0, tablet: 38.0)),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Shared sheet helpers
// =============================================================================

Widget _sheetHandle(BuildContext context) {
  return Container(
    margin: EdgeInsets.only(top: context.rSpacing * 1.5, bottom: context.rSpacing),
    width: context.rValue(mobile: 40.0, tablet: 48.0),
    height: 4,
    decoration: BoxDecoration(
      color: AppTheme.textMuted.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(2),
    ),
  );
}

Widget _loadingIndicator(BuildContext context, String text) {
  return Padding(
    padding: EdgeInsets.all(context.rSpacing * 5),
    child: Column(
      children: [
        SizedBox(
          width: context.rValue(mobile: 24.0, tablet: 28.0),
          height: context.rValue(mobile: 24.0, tablet: 28.0),
          child: const CircularProgressIndicator(
            strokeWidth: 2, color: AppTheme.brandCyan,
          ),
        ),
        SizedBox(height: context.rSpacing * 2),
        Text(text, style: TextStyle(color: AppTheme.textMuted, fontSize: context.bodyFontSize)),
      ],
    ),
  );
}

Widget _emptyState(BuildContext context, IconData icon, String title, String subtitle) {
  return Padding(
    padding: EdgeInsets.all(context.rSpacing * 5),
    child: Column(
      children: [
        Icon(icon, size: context.rValue(mobile: 48.0, tablet: 56.0), color: AppTheme.textMuted),
        SizedBox(height: context.rSpacing * 2),
        Text(title, style: TextStyle(
          color: AppTheme.textSecondary, fontSize: context.bodyFontSize,
        )),
        SizedBox(height: context.rSpacing * 0.5),
        Text(subtitle,
          style: TextStyle(color: AppTheme.textMuted, fontSize: context.captionFontSize),
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );
}

class _PermissionModeTile extends StatelessWidget {
  final PermissionMode currentMode;
  final ValueChanged<PermissionMode> onModeSelected;

  const _PermissionModeTile({
    required this.currentMode,
    required this.onModeSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding, vertical: context.rSpacing * 1.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: context.rValue(mobile: 32.0, tablet: 38.0),
                height: context.rValue(mobile: 32.0, tablet: 38.0),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.shield_outlined,
                    size: context.rValue(mobile: 18.0, tablet: 20.0), color: AppTheme.textSecondary),
              ),
              SizedBox(width: context.rSpacing * 1.5),
              Text(
                'Permission Mode',
                style: TextStyle(
                  fontSize: context.bodyFontSize,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.textPrimary,
                ),
              ),
            ],
          ),
          SizedBox(height: context.rSpacing * 1.5),
          Row(
            children: PermissionMode.switchable.map((mode) {
              final isSelected = mode == currentMode;
              final modeColor = Color(mode.colorValue);
              return Expanded(
                child: GestureDetector(
                  onTap: () => onModeSelected(mode),
                  child: Container(
                    margin: EdgeInsets.only(
                      right: mode != PermissionMode.switchable.last ? context.rSpacing * 0.75 : 0,
                    ),
                    padding: EdgeInsets.symmetric(vertical: context.rSpacing),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? modeColor.withValues(alpha: 0.15)
                          : AppTheme.surfaceLight,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected
                            ? modeColor
                            : AppTheme.divider.withValues(alpha: 0.3),
                        width: isSelected ? 1.5 : 0.5,
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(mode.icon,
                            size: context.rValue(mobile: 16.0, tablet: 18.0), color: isSelected ? modeColor : AppTheme.textMuted),
                        SizedBox(height: context.rSpacing * 0.25),
                        Text(
                          mode.label,
                          style: TextStyle(
                            fontSize: context.rFontSize(mobile: 11, tablet: 13),
                            fontWeight:
                                isSelected ? FontWeight.w600 : FontWeight.w400,
                            color: isSelected
                                ? modeColor
                                : AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
