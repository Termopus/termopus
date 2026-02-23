import 'package:freezed_annotation/freezed_annotation.dart';

part 'session.freezed.dart';
part 'session.g.dart';

/// Represents a paired computer running Claude Code.
@freezed
class Session with _$Session {
  const factory Session({
    /// Unique session identifier (matches the relay session id).
    required String id,

    /// Human-readable name for the paired computer.
    required String name,

    /// Relay URL used to reach this computer.
    required String relay,

    /// When this device was first paired.
    required DateTime pairedAt,

    /// Last time a connection was established.
    DateTime? lastConnected,

    /// Whether a live WebSocket connection is currently active.
    @Default(false) bool isConnected,
  }) = _Session;

  factory Session.fromJson(Map<String, dynamic> json) =>
      _$SessionFromJson(json);
}
