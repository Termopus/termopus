import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Claude Code model options.
enum ClaudeModel {
  opus('opus', 'Opus', 'Most capable, best for complex tasks'),
  sonnet('sonnet', 'Sonnet', 'Balanced speed and capability'),
  haiku('haiku', 'Haiku', 'Fastest, best for simple tasks');

  final String id;
  final String displayName;
  final String description;

  const ClaudeModel(this.id, this.displayName, this.description);

  /// Get the color associated with this model.
  int get colorValue {
    switch (this) {
      case ClaudeModel.opus:
        return 0xFF9C27B0; // Purple
      case ClaudeModel.sonnet:
        return 0xFF2196F3; // Blue
      case ClaudeModel.haiku:
        return 0xFF4CAF50; // Green
    }
  }

  /// Look up model by string ID (e.g. "opus", "sonnet", "haiku").
  static ClaudeModel? fromId(String id) {
    final lower = id.toLowerCase();
    for (final m in ClaudeModel.values) {
      if (lower.contains(m.id)) return m;
    }
    return null;
  }
}

/// Claude Code permission modes (matches CLI Shift+Tab cycle).
enum PermissionMode {
  // Modes in the Shift+Tab cycle (can be switched from phone)
  ask('default', 'Ask', 'Asks before each action'),
  autoEdit('acceptEdits', 'Auto Edit', 'Auto-approves file edits'),
  plan('plan', 'Plan', 'Plans first, then executes'),
  // Modes NOT in the Shift+Tab cycle (set at startup only)
  dontAsk('dontAsk', "Don't Ask", 'Auto-approves without prompts'),
  delegate('delegate', 'Delegate', 'Delegates to sub-agents'),
  fullAuto('bypassPermissions', 'Full Auto', 'Bypasses all permissions');

  final String cliValue; // Value sent to /permissions set <value>
  final String label;
  final String description;

  const PermissionMode(this.cliValue, this.label, this.description);

  /// Color associated with this mode.
  int get colorValue {
    switch (this) {
      case PermissionMode.ask:
        return 0xFFF5A623; // Amber
      case PermissionMode.plan:
        return 0xFF7DD3FC; // Blue (primary)
      case PermissionMode.autoEdit:
        return 0xFF4CD964; // Green
      case PermissionMode.dontAsk:
        return 0xFFFF9500; // Orange
      case PermissionMode.delegate:
        return 0xFF5856D6; // Indigo
      case PermissionMode.fullAuto:
        return 0xFFFF453A; // Red
    }
  }

  /// Icon associated with this mode.
  IconData get icon {
    switch (this) {
      case PermissionMode.ask:
        return Icons.shield_outlined;
      case PermissionMode.plan:
        return Icons.architecture_rounded;
      case PermissionMode.autoEdit:
        return Icons.edit_note_rounded;
      case PermissionMode.dontAsk:
        return Icons.check_circle_outline;
      case PermissionMode.delegate:
        return Icons.groups_rounded;
      case PermissionMode.fullAuto:
        return Icons.flash_on_rounded;
    }
  }

  /// Whether this mode can be toggled via Shift+Tab (BTab) from the phone.
  /// Only default, acceptEdits, and plan are in the cycle.
  /// dontAsk, delegate, bypassPermissions require CLI startup flags.
  bool get isSwitchable =>
      this == ask || this == autoEdit || this == plan;

  /// Modes the user can switch to from the phone (the Shift+Tab cycle).
  static List<PermissionMode> get switchable =>
      values.where((m) => m.isSwitchable).toList();

  /// Look up mode from CLI value (e.g. "default", "plan", "acceptEdits").
  static PermissionMode fromCli(String value) {
    for (final m in PermissionMode.values) {
      if (m.cliValue == value) return m;
    }
    return PermissionMode.ask; // fallback
  }
}

/// Configuration state for Claude Code.
class ClaudeConfigState {
  final ClaudeModel selectedModel;
  final PermissionMode permissionMode;
  final bool autoCompact;
  final bool showTokenCount;
  final List<String> permissionAllowRules;
  final List<String> permissionDenyRules;

  const ClaudeConfigState({
    this.selectedModel = ClaudeModel.opus,
    this.permissionMode = PermissionMode.ask,
    this.autoCompact = true,
    this.showTokenCount = false,
    this.permissionAllowRules = const [],
    this.permissionDenyRules = const [],
  });

  ClaudeConfigState copyWith({
    ClaudeModel? selectedModel,
    PermissionMode? permissionMode,
    bool? autoCompact,
    bool? showTokenCount,
    List<String>? permissionAllowRules,
    List<String>? permissionDenyRules,
  }) {
    return ClaudeConfigState(
      selectedModel: selectedModel ?? this.selectedModel,
      permissionMode: permissionMode ?? this.permissionMode,
      autoCompact: autoCompact ?? this.autoCompact,
      showTokenCount: showTokenCount ?? this.showTokenCount,
      permissionAllowRules: permissionAllowRules ?? this.permissionAllowRules,
      permissionDenyRules: permissionDenyRules ?? this.permissionDenyRules,
    );
  }
}

/// Provider for Claude Code configuration state.
final claudeConfigProvider =
    NotifierProvider<ClaudeConfigNotifier, ClaudeConfigState>(
        ClaudeConfigNotifier.new);

/// Notifier for managing Claude Code configuration.
class ClaudeConfigNotifier extends Notifier<ClaudeConfigState> {
  @override
  ClaudeConfigState build() => const ClaudeConfigState();

  /// Set the selected model.
  void setModel(ClaudeModel model) {
    state = state.copyWith(selectedModel: model);
  }

  /// Set model from string ID (from bridge ConfigSync).
  void setModelFromId(String id) {
    final model = ClaudeModel.fromId(id);
    if (model != null) {
      state = state.copyWith(selectedModel: model);
    }
  }

  /// Set the permission mode.
  void setPermissionMode(PermissionMode mode) {
    state = state.copyWith(permissionMode: mode);
  }

  /// Set permission mode from CLI value (from bridge ConfigSync).
  void setPermissionModeFromCli(String value) {
    state = state.copyWith(permissionMode: PermissionMode.fromCli(value));
  }

  /// Toggle auto-compact setting.
  void toggleAutoCompact() {
    state = state.copyWith(autoCompact: !state.autoCompact);
  }

  /// Toggle token count display.
  void toggleShowTokenCount() {
    state = state.copyWith(showTokenCount: !state.showTokenCount);
  }

  /// Set auto-compact setting.
  void setAutoCompact(bool value) {
    state = state.copyWith(autoCompact: value);
  }

  /// Set token count display.
  void setShowTokenCount(bool value) {
    state = state.copyWith(showTokenCount: value);
  }

  /// Set permission rules from bridge PermissionRulesSync.
  void setPermissionRules(List<String> allow, List<String> deny) {
    state = state.copyWith(
      permissionAllowRules: allow,
      permissionDenyRules: deny,
    );
  }
}
