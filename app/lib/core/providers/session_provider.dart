import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/session.dart';
import '../../shared/constants.dart';
import '../platform/security_channel.dart';

/// Riverpod provider for the list of paired sessions.
final sessionProvider =
    NotifierProvider<SessionNotifier, List<Session>>(SessionNotifier.new);

/// Manages the persisted list of paired computer sessions.
///
/// Session metadata (name, relay URL, timestamps) is stored in
/// [SharedPreferences]. **No sensitive material** (keys, secrets) is
/// ever written to shared preferences -- those live exclusively inside
/// the native Secure Enclave / StrongBox.
class SessionNotifier extends Notifier<List<Session>> {
  @override
  List<Session> build() {
    loadSessions();
    return [];
  }

  // -------------------------------------------------------------------------
  // Persistence
  // -------------------------------------------------------------------------

  /// Load sessions from [SharedPreferences].
  Future<void> loadSessions() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(AppConstants.prefSessionsKey);
    if (raw == null || raw.isEmpty) return;

    final sessions = raw
        .map((json) {
          try {
            return Session.fromJson(
              jsonDecode(json) as Map<String, dynamic>,
            );
          } catch (_) {
            return null;
          }
        })
        .whereType<Session>()
        .toList();

    // Keep last-known isConnected state so the home screen shows a
    // useful status immediately.  Relay events will correct stale values
    // when the user enters a session.
    state = sessions;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = state.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList(AppConstants.prefSessionsKey, raw);
  }

  // -------------------------------------------------------------------------
  // CRUD
  // -------------------------------------------------------------------------

  /// Add a newly paired session and persist.
  Future<void> addSession(Session session) async {
    // Avoid duplicates.
    state = [
      ...state.where((s) => s.id != session.id),
      session,
    ];
    await _persist();
  }

  /// Remove a session by its [id] and persist.
  ///
  /// Notifies the bridge to kill the Claude process and clean up,
  /// then clears the persisted peer key from native secure storage.
  Future<void> removeSession(String id) async {
    // Notify bridge to kill Claude process + clean up
    try {
      await SecurityChannel().deleteSession(id);
    } catch (_) {
      // Bridge may be offline — phone cleans up locally
    }
    try {
      await SecurityChannel().clearSessionData(id);
    } catch (_) {
      // Don't block session removal if native cleanup fails
    }
    state = state.where((s) => s.id != id).toList();
    await _persist();
  }

  /// Mark a session as connected and update [lastConnected].
  void markConnected(String id) {
    final existing = state.where((s) => s.id == id).firstOrNull;
    if (existing == null || existing.isConnected) return;
    debugPrint('[Session] markConnected($id)');
    state = state.map((s) {
      if (s.id == id) {
        return s.copyWith(isConnected: true, lastConnected: DateTime.now());
      }
      return s;
    }).toList();
    _persist();
  }

  /// Mark a session as disconnected.
  void markDisconnected(String id) {
    debugPrint('[Session] markDisconnected($id)');
    state = state.map((s) {
      if (s.id == id) {
        return s.copyWith(isConnected: false);
      }
      return s;
    }).toList();
    _persist();
  }

  /// Update the display name of a session.
  Future<void> renameSession(String id, String newName) async {
    state = state.map((s) {
      if (s.id == id) return s.copyWith(name: newName);
      return s;
    }).toList();
    await _persist();
  }
}
