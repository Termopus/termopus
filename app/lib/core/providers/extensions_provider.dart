import 'package:flutter_riverpod/flutter_riverpod.dart';

/// An installed Claude Code plugin.
class InstalledPlugin {
  final String id;
  final String name;
  final String? description;
  final String version;
  final bool enabled;
  final String? author;
  final int skillCount;

  const InstalledPlugin({
    required this.id,
    required this.name,
    this.description,
    required this.version,
    required this.enabled,
    this.author,
    this.skillCount = 0,
  });

  factory InstalledPlugin.fromMap(Map<String, dynamic> m) {
    return InstalledPlugin(
      id: m['id'] as String? ?? '',
      name: m['name'] as String? ?? '',
      description: m['description'] as String?,
      version: m['version'] as String? ?? '',
      enabled: m['enabled'] as bool? ?? false,
      author: m['author'] as String?,
      skillCount: (m['skill_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// A Claude Code skill (global or plugin-bundled).
class ClaudeSkill {
  final String name;
  final String description;
  final String source;

  const ClaudeSkill({
    required this.name,
    required this.description,
    required this.source,
  });

  factory ClaudeSkill.fromMap(Map<String, dynamic> m) {
    return ClaudeSkill(
      name: m['name'] as String? ?? '',
      description: m['description'] as String? ?? '',
      source: m['source'] as String? ?? 'unknown',
    );
  }

  /// User-friendly source label.
  String get sourceLabel {
    if (source == 'global') return 'Built-in';
    return source;
  }
}

/// A Claude Code rules file.
class ClaudeRule {
  final String filename;
  final String content;
  final String scope;

  const ClaudeRule({
    required this.filename,
    required this.content,
    required this.scope,
  });

  factory ClaudeRule.fromMap(Map<String, dynamic> m) {
    return ClaudeRule(
      filename: m['filename'] as String? ?? '',
      content: m['content'] as String? ?? '',
      scope: m['scope'] as String? ?? 'global',
    );
  }

  /// User-friendly scope label.
  String get scopeLabel {
    if (scope == 'project') return 'This Project';
    return 'Global';
  }
}

/// State for extensions data (plugins, skills, rules).
class ExtensionsState {
  final List<InstalledPlugin> plugins;
  final List<ClaudeSkill> skills;
  final List<ClaudeRule> rules;

  const ExtensionsState({
    this.plugins = const [],
    this.skills = const [],
    this.rules = const [],
  });

  ExtensionsState copyWith({
    List<InstalledPlugin>? plugins,
    List<ClaudeSkill>? skills,
    List<ClaudeRule>? rules,
  }) {
    return ExtensionsState(
      plugins: plugins ?? this.plugins,
      skills: skills ?? this.skills,
      rules: rules ?? this.rules,
    );
  }
}

/// Manages plugins, skills, and rules data from the bridge.
class ExtensionsNotifier extends Notifier<ExtensionsState> {
  @override
  ExtensionsState build() => const ExtensionsState();

  void setPlugins(List<InstalledPlugin> plugins) {
    state = state.copyWith(plugins: plugins);
  }

  void setSkills(List<ClaudeSkill> skills) {
    state = state.copyWith(skills: skills);
  }

  void setRules(List<ClaudeRule> rules) {
    state = state.copyWith(rules: rules);
  }

  void clear() {
    state = const ExtensionsState();
  }
}

final extensionsProvider =
    NotifierProvider<ExtensionsNotifier, ExtensionsState>(
  ExtensionsNotifier.new,
);
