/// Capabilities reported by a Claude Code session at init time.
///
/// Populated from the stream-json `system/init` event via a
/// `SessionCapabilities` bridge message. When available, the app
/// uses these to populate slash-command autocomplete, model info,
/// MCP server status, etc. instead of hardcoded fallbacks.
class SessionCapabilities {
  final String sessionId;
  final String model;
  final List<String> tools;
  final List<CommandEntry> slashCommands;
  final List<CommandEntry> skills;
  final List<CommandEntry> agents;
  final List<ServerEntry> mcpServers;
  final List<PluginEntry> plugins;
  final String permissionMode;
  final String cwd;
  final String cliVersion;
  final String fastMode; // "off" | "on"
  final String apiKeySource; // "none" | "env" | "config"

  const SessionCapabilities({
    required this.sessionId,
    required this.model,
    this.tools = const [],
    this.slashCommands = const [],
    this.skills = const [],
    this.agents = const [],
    this.mcpServers = const [],
    this.plugins = const [],
    this.permissionMode = 'default',
    this.cwd = '',
    this.cliVersion = '',
    this.fastMode = 'off',
    this.apiKeySource = 'none',
  });

  bool get isFastMode => fastMode == 'on';

  factory SessionCapabilities.fromJson(Map<String, dynamic> json) {
    return SessionCapabilities(
      sessionId: json['sessionId'] as String? ?? '',
      model: json['model'] as String? ?? '',
      tools: List<String>.from(json['tools'] as List? ?? []),
      slashCommands: (json['slashCommands'] as List? ?? [])
          .map((e) => CommandEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      skills: (json['skills'] as List? ?? [])
          .map((e) => CommandEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      agents: (json['agents'] as List? ?? [])
          .map((e) => CommandEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      mcpServers: (json['mcpServers'] as List? ?? [])
          .map((e) => ServerEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      plugins: (json['plugins'] as List? ?? [])
          .map((e) => PluginEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      permissionMode: json['permissionMode'] as String? ?? 'default',
      cwd: json['cwd'] as String? ?? '',
      cliVersion: json['cliVersion'] as String? ?? '',
      fastMode: json['fastMode'] as String? ?? 'off',
      apiKeySource: json['apiKeySource'] as String? ?? 'none',
    );
  }
}

class CommandEntry {
  final String name;
  final String description;
  const CommandEntry({required this.name, required this.description});
  factory CommandEntry.fromJson(Map<String, dynamic> json) =>
      CommandEntry(
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
      );
}

class ServerEntry {
  final String name;
  final String status;
  const ServerEntry({required this.name, required this.status});
  factory ServerEntry.fromJson(Map<String, dynamic> json) =>
      ServerEntry(
        name: json['name'] as String? ?? '',
        status: json['status'] as String? ?? '',
      );
}

class PluginEntry {
  final String name;
  final String version;
  const PluginEntry({required this.name, required this.version});
  factory PluginEntry.fromJson(Map<String, dynamic> json) =>
      PluginEntry(
        name: json['name'] as String? ?? '',
        version: json['version'] as String? ?? '',
      );
}
