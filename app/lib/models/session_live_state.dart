/// Real-time Claude Code status for a session.
///
/// Populated from `LiveStateUpdate` messages sent by the bridge.
/// NOT persisted — rebuilt from bridge events on reconnect.
class SessionLiveState {
  final String claudeStatus; // idle, thinking, responding, tool_running, awaiting_input, exited, respawning
  final int activeAgents;
  final String lastActivity;
  final String? model;
  final String? permissionMode;
  final String? toolName; // Only set when claudeStatus == 'tool_running'
  final int thinkingElapsedSecs;
  final DateTime updatedAt;

  SessionLiveState({
    this.claudeStatus = 'idle',
    this.activeAgents = 0,
    this.lastActivity = '',
    this.model,
    this.permissionMode,
    this.toolName,
    this.thinkingElapsedSecs = 0,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  factory SessionLiveState.fromJson(Map<String, dynamic> json) {
    return SessionLiveState(
      claudeStatus: json['claudeStatus'] as String? ?? 'idle',
      activeAgents: (json['activeAgents'] as num?)?.toInt() ?? 0,
      lastActivity: json['lastActivity'] as String? ?? '',
      model: json['model'] as String?,
      permissionMode: json['permissionMode'] as String?,
      toolName: json['toolName'] as String?,
      thinkingElapsedSecs: (json['thinkingElapsedSecs'] as num?)?.toInt() ?? 0,
    );
  }

  bool get isIdle => claudeStatus == 'idle';
  bool get isThinking => claudeStatus == 'thinking';
  bool get isResponding => claudeStatus == 'responding';
  bool get isToolRunning => claudeStatus == 'tool_running';
  bool get isAwaitingInput => claudeStatus == 'awaiting_input';
  bool get isExited => claudeStatus == 'exited';
  bool get isRespawning => claudeStatus == 'respawning';
  bool get isHandedOff => claudeStatus == 'handed_off';
  bool get isBusy => isThinking || isResponding || isToolRunning;

  /// Human-readable status label for UI display.
  String get statusLabel {
    switch (claudeStatus) {
      case 'thinking':
        return thinkingElapsedSecs > 0
            ? 'Thinking (${_formatDuration(thinkingElapsedSecs)})'
            : 'Thinking...';
      case 'responding':
        return 'Responding...';
      case 'tool_running':
        return toolName != null ? 'Running $toolName' : 'Running tool...';
      case 'awaiting_input':
        return 'Waiting for approval';
      case 'exited':
        return 'Exited';
      case 'respawning':
        return 'Restarting...';
      case 'handed_off':
        return 'On computer';
      case 'idle':
      default:
        return 'Idle';
    }
  }

  static String _formatDuration(int secs) {
    if (secs >= 60) return '${secs ~/ 60}m ${secs % 60}s';
    return '${secs}s';
  }
}
