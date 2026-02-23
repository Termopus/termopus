import 'package:flutter/material.dart';

/// A quick action that sends a text prompt to Claude Code.
///
/// Unlike slash commands (which are CLI directives), quick actions send
/// natural-language prompts through [sendMessage] so the LLM processes them
/// as regular user input.
class QuickAction {
  final String label;
  final String prompt;
  final IconData icon;
  final Color color;
  final String category;

  const QuickAction({
    required this.label,
    required this.prompt,
    required this.icon,
    required this.color,
    this.category = 'general',
  });
}

/// Single source of truth for all quick-action prompts.
///
/// Widgets that display quick-action chips or buttons should reference
/// [QuickActions.code], [QuickActions.git], or [QuickActions.all] instead of
/// maintaining their own lists.
class QuickActions {
  QuickActions._();

  // ---------------------------------------------------------------------------
  // Brand palette colors (private)
  // ---------------------------------------------------------------------------

  static const Color _cyan = Color(0xFF7DD3FC);
  static const Color _purple = Color(0xFF9D8CFF);
  static const Color _green = Color(0xFF4ADE80);
  static const Color _orange = Color(0xFFFB923C);
  static const Color _blue = Color(0xFF60A5FA);
  static const Color _pink = Color(0xFFF472B6);

  // ---------------------------------------------------------------------------
  // Code actions
  // ---------------------------------------------------------------------------

  static const List<QuickAction> code = [
    QuickAction(
      label: 'Explain',
      prompt: 'explain this code',
      icon: Icons.lightbulb,
      color: _cyan,
      category: 'code',
    ),
    QuickAction(
      label: 'Refactor',
      prompt: 'refactor this code to be cleaner',
      icon: Icons.auto_fix_high,
      color: _purple,
      category: 'code',
    ),
    QuickAction(
      label: 'Fix Bug',
      prompt: 'find and fix the bug',
      icon: Icons.bug_report,
      color: _orange,
      category: 'code',
    ),
    QuickAction(
      label: 'Tests',
      prompt: 'write tests for this',
      icon: Icons.science,
      color: _green,
      category: 'code',
    ),
    QuickAction(
      label: 'Continue',
      prompt: 'continue',
      icon: Icons.play_arrow,
      color: _blue,
      category: 'code',
    ),
    QuickAction(
      label: 'Docs',
      prompt: 'add documentation',
      icon: Icons.description,
      color: _cyan,
      category: 'code',
    ),
  ];

  // ---------------------------------------------------------------------------
  // Git actions
  // ---------------------------------------------------------------------------

  static const List<QuickAction> git = [
    QuickAction(
      label: 'Commit',
      prompt: 'create a git commit with a descriptive message for the changes',
      icon: Icons.check_circle_outline,
      color: _green,
      category: 'git',
    ),
    QuickAction(
      label: 'Push',
      prompt: 'push the current branch to remote',
      icon: Icons.upload,
      color: _blue,
      category: 'git',
    ),
    QuickAction(
      label: 'PR',
      prompt: 'create a pull request for the current branch',
      icon: Icons.merge,
      color: _purple,
      category: 'git',
    ),
    QuickAction(
      label: 'Status',
      prompt: 'show git status and recent commits',
      icon: Icons.info_outline,
      color: _cyan,
      category: 'git',
    ),
    QuickAction(
      label: 'Diff',
      prompt: 'show the current git diff',
      icon: Icons.difference,
      color: _orange,
      category: 'git',
    ),
    QuickAction(
      label: 'Stash',
      prompt: 'stash the current changes',
      icon: Icons.archive,
      color: _pink,
      category: 'git',
    ),
  ];

  // ---------------------------------------------------------------------------
  // Combined
  // ---------------------------------------------------------------------------

  /// All quick actions (code + git).
  static List<QuickAction> get all => [...code, ...git];
}
