import 'package:flutter/material.dart';

import '../core/models/session_capabilities.dart';

/// A single Claude Code slash command.
///
/// Represents a command that can be sent to Claude Code, with metadata
/// for display in the UI (icon, description, category) and argument hints.
class ClaudeCommand {
  final String command;
  final String description;
  final String category;
  final IconData icon;
  final bool needsArgs;
  final String? argsHint;

  const ClaudeCommand({
    required this.command,
    required this.description,
    required this.category,
    required this.icon,
    this.needsArgs = false,
    this.argsHint,
  });

  /// Create from a dynamic [CommandEntry] (stream-json system/init).
  factory ClaudeCommand.fromCommandEntry(CommandEntry entry) {
    return ClaudeCommand(
      command: entry.name.replaceFirst('/', ''),
      description: entry.description,
      category: _inferCategory(entry.name),
      icon: _inferIcon(entry.name),
    );
  }

  static String _inferCategory(String name) {
    final n = name.replaceFirst('/', '').toLowerCase();
    const sessionCmds = {'clear', 'compact', 'resume', 'rewind', 'exit'};
    const infoCmds = {'help', 'cost', 'status', 'stats', 'doctor', 'debug'};
    const configCmds = {'model', 'config', 'permissions', 'memory', 'theme', 'vim', 'statusline'};
    const projectCmds = {'init', 'context', 'export', 'plan', 'mcp', 'hooks'};
    if (sessionCmds.contains(n)) return 'Session';
    if (infoCmds.contains(n)) return 'Info';
    if (configCmds.contains(n)) return 'Config';
    if (projectCmds.contains(n)) return 'Project';
    return 'Dev';
  }

  static IconData _inferIcon(String name) {
    const iconMap = <String, IconData>{
      'clear': Icons.clear_all,
      'compact': Icons.compress,
      'resume': Icons.play_arrow,
      'rewind': Icons.replay,
      'exit': Icons.exit_to_app,
      'help': Icons.help_outline,
      'cost': Icons.attach_money,
      'status': Icons.info_outline,
      'stats': Icons.bar_chart,
      'doctor': Icons.medical_services_outlined,
      'debug': Icons.bug_report_outlined,
      'model': Icons.smart_toy_outlined,
      'config': Icons.settings_outlined,
      'permissions': Icons.shield_outlined,
      'memory': Icons.memory,
      'theme': Icons.palette_outlined,
      'vim': Icons.keyboard_outlined,
      'statusline': Icons.view_headline,
      'init': Icons.rocket_launch_outlined,
      'context': Icons.attach_file,
      'export': Icons.download_outlined,
      'plan': Icons.map_outlined,
      'mcp': Icons.dns_outlined,
      'hooks': Icons.webhook_outlined,
      'review': Icons.rate_review_outlined,
      'copy': Icons.copy_outlined,
    };
    final n = name.replaceFirst('/', '').toLowerCase();
    return iconMap[n] ?? Icons.terminal;
  }
}

/// Single source of truth for all Claude Code slash commands.
///
/// Every widget that needs to display or reference slash commands should
/// pull from [ClaudeCommands.all] instead of maintaining its own list.
class ClaudeCommands {
  ClaudeCommands._();

  // ---------------------------------------------------------------------------
  // Categories
  // ---------------------------------------------------------------------------

  static const List<String> categories = [
    'Session',
    'Info',
    'Config',
    'Project',
    'Dev',
  ];

  // ---------------------------------------------------------------------------
  // All commands (26 total)
  // ---------------------------------------------------------------------------

  static const List<ClaudeCommand> all = [
    // ---- Session ----
    ClaudeCommand(
      command: 'clear',
      description: 'Clear conversation history',
      category: 'Session',
      icon: Icons.clear_all,
    ),
    ClaudeCommand(
      command: 'compact',
      description: 'Compact conversation to save context',
      category: 'Session',
      icon: Icons.compress,
    ),
    ClaudeCommand(
      command: 'resume',
      description: 'Resume a previous conversation',
      category: 'Session',
      icon: Icons.play_arrow,
    ),
    ClaudeCommand(
      command: 'rewind',
      description: 'Undo the last message or action',
      category: 'Session',
      icon: Icons.replay,
    ),
    ClaudeCommand(
      command: 'exit',
      description: 'Exit Claude Code',
      category: 'Session',
      icon: Icons.exit_to_app,
    ),

    // ---- Info ----
    ClaudeCommand(
      command: 'help',
      description: 'Show help and available commands',
      category: 'Info',
      icon: Icons.help_outline,
    ),
    ClaudeCommand(
      command: 'cost',
      description: 'Show token usage and costs',
      category: 'Info',
      icon: Icons.attach_money,
    ),
    ClaudeCommand(
      command: 'status',
      description: 'Show session status',
      category: 'Info',
      icon: Icons.info_outline,
    ),
    ClaudeCommand(
      command: 'stats',
      description: 'Show session statistics',
      category: 'Info',
      icon: Icons.bar_chart,
    ),
    ClaudeCommand(
      command: 'doctor',
      description: 'Run diagnostic checks',
      category: 'Info',
      icon: Icons.medical_services_outlined,
    ),
    ClaudeCommand(
      command: 'debug',
      description: 'Toggle debug mode',
      category: 'Info',
      icon: Icons.bug_report_outlined,
    ),

    // ---- Config ----
    ClaudeCommand(
      command: 'model',
      description: 'Switch AI model',
      category: 'Config',
      icon: Icons.smart_toy_outlined,
      needsArgs: true,
      argsHint: 'opus | sonnet | haiku',
    ),
    ClaudeCommand(
      command: 'config',
      description: 'View or update configuration',
      category: 'Config',
      icon: Icons.settings_outlined,
      needsArgs: true,
      argsHint: 'key value',
    ),
    ClaudeCommand(
      command: 'permissions',
      description: 'View or update permissions',
      category: 'Config',
      icon: Icons.shield_outlined,
    ),
    ClaudeCommand(
      command: 'memory',
      description: 'View or update memory',
      category: 'Config',
      icon: Icons.memory,
    ),
    ClaudeCommand(
      command: 'theme',
      description: 'Change visual theme',
      category: 'Config',
      icon: Icons.palette_outlined,
    ),
    ClaudeCommand(
      command: 'vim',
      description: 'Toggle vim keybindings',
      category: 'Config',
      icon: Icons.keyboard_outlined,
    ),
    ClaudeCommand(
      command: 'statusline',
      description: 'Configure status line',
      category: 'Config',
      icon: Icons.view_headline,
    ),

    // ---- Project ----
    ClaudeCommand(
      command: 'init',
      description: 'Initialize Claude Code in project',
      category: 'Project',
      icon: Icons.rocket_launch_outlined,
    ),
    ClaudeCommand(
      command: 'context',
      description: 'View or add context files',
      category: 'Project',
      icon: Icons.attach_file,
      needsArgs: true,
      argsHint: '@file or text',
    ),
    ClaudeCommand(
      command: 'export',
      description: 'Export conversation transcript',
      category: 'Project',
      icon: Icons.download_outlined,
    ),
    ClaudeCommand(
      command: 'plan',
      description: 'Enter plan mode',
      category: 'Project',
      icon: Icons.map_outlined,
    ),
    ClaudeCommand(
      command: 'mcp',
      description: 'Manage MCP servers',
      category: 'Project',
      icon: Icons.dns_outlined,
    ),
    ClaudeCommand(
      command: 'hooks',
      description: 'Manage hooks',
      category: 'Project',
      icon: Icons.webhook_outlined,
    ),

    // ---- Dev ----
    ClaudeCommand(
      command: 'review',
      description: 'Review code changes',
      category: 'Dev',
      icon: Icons.rate_review_outlined,
    ),
    ClaudeCommand(
      command: 'copy',
      description: 'Copy last response to clipboard',
      category: 'Dev',
      icon: Icons.copy_outlined,
    ),
  ];

  // ---------------------------------------------------------------------------
  // Quick commands (most-used subset for chips / quick-access bar)
  // ---------------------------------------------------------------------------

  static List<ClaudeCommand> get quickCommands {
    // Only show commands not already available as native buttons in Settings.
    // Settings now covers: clear, compact, cost, model, permissions, resume,
    // plan, rewind, export, memory, status, doctor.
    const quickNames = ['help', 'context', 'copy', 'review'];
    return [
      for (final name in quickNames)
        all.firstWhere((c) => c.command == name),
    ];
  }

  // ---------------------------------------------------------------------------
  // Dynamic commands from session capabilities
  // ---------------------------------------------------------------------------

  /// Returns commands from live session capabilities when available,
  /// falling back to the hardcoded [all] list.
  static List<ClaudeCommand> fromCapabilities(SessionCapabilities? caps) {
    if (caps == null || caps.slashCommands.isEmpty) return all;
    return caps.slashCommands
        .map((e) => ClaudeCommand.fromCommandEntry(e))
        .toList();
  }

  /// Returns categories derived from the given command list.
  static List<String> categoriesFrom(List<ClaudeCommand> commands) {
    final seen = <String>{};
    final result = <String>[];
    for (final cmd in commands) {
      if (seen.add(cmd.category)) result.add(cmd.category);
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Returns all commands belonging to [category].
  static List<ClaudeCommand> byCategory(String category) {
    return all.where((c) => c.category == category).toList();
  }

  /// Returns commands belonging to [category] from the given list.
  static List<ClaudeCommand> byCategoryFrom(
      String category, List<ClaudeCommand> commands) {
    return commands.where((c) => c.category == category).toList();
  }

  /// Case-insensitive search across command name and description.
  static List<ClaudeCommand> search(String query) {
    final q = query.toLowerCase();
    return all
        .where((c) =>
            c.command.toLowerCase().contains(q) ||
            c.description.toLowerCase().contains(q))
        .toList();
  }

  /// Case-insensitive search within a given command list.
  static List<ClaudeCommand> searchIn(
      String query, List<ClaudeCommand> commands) {
    final q = query.toLowerCase();
    return commands
        .where((c) =>
            c.command.toLowerCase().contains(q) ||
            c.description.toLowerCase().contains(q))
        .toList();
  }
}
