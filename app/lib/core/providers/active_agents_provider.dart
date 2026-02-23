import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A currently-running background agent.
class ActiveAgent {
  final String agentId;
  final String agentType;
  final DateTime startedAt;

  const ActiveAgent({
    required this.agentId,
    required this.agentType,
    required this.startedAt,
  });
}

/// Riverpod provider for tracking active background agents.
final activeAgentsProvider =
    NotifierProvider<ActiveAgentsNotifier, List<ActiveAgent>>(
  ActiveAgentsNotifier.new,
);

/// Tracks background agents spawned by Claude Code (Task tool subagents).
class ActiveAgentsNotifier extends Notifier<List<ActiveAgent>> {
  @override
  List<ActiveAgent> build() => [];

  /// Register a new agent (dedup by id).
  void agentStarted(String id, String type) {
    if (state.any((a) => a.agentId == id)) return;
    state = [
      ...state,
      ActiveAgent(agentId: id, agentType: type, startedAt: DateTime.now()),
    ];
  }

  /// Remove an agent when it finishes.
  void agentStopped(String id) {
    state = state.where((a) => a.agentId != id).toList();
  }

  /// Clear all agents (on disconnect / session switch).
  void clear() {
    state = [];
  }

  /// Remove agents older than [maxAge] (safety net for missed SubagentStop).
  void removeStale({Duration maxAge = const Duration(minutes: 30)}) {
    final cutoff = DateTime.now().subtract(maxAge);
    final before = state.length;
    state = state.where((a) => a.startedAt.isAfter(cutoff)).toList();
    if (state.length != before) {
      // Stale agents were cleaned up
    }
  }
}
