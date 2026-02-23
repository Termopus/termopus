import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/session_live_state.dart';

/// Riverpod provider for per-session live state (Claude status, agents, etc.)
///
/// Keyed by session ID. Updated from `LiveStateUpdate` bridge messages.
/// NOT persisted — rebuilt from bridge events on each connection.
final liveStateProvider =
    NotifierProvider<LiveStateNotifier, Map<String, SessionLiveState>>(
        LiveStateNotifier.new);

class LiveStateNotifier extends Notifier<Map<String, SessionLiveState>> {
  @override
  Map<String, SessionLiveState> build() => {};

  /// Update the live state for a specific session.
  void update(String sessionId, SessionLiveState liveState) {
    state = {...state, sessionId: liveState};
  }

  /// Get the live state for a session (null if no update received yet).
  SessionLiveState? forSession(String sessionId) => state[sessionId];

  /// Clear live state for a removed session.
  void remove(String sessionId) {
    state = Map.from(state)..remove(sessionId);
  }

  /// Clear all live state (e.g. on app reset).
  void clear() {
    state = {};
  }
}
