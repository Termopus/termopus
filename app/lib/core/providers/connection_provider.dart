import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/connection_state.dart';
import '../platform/security_channel.dart';

/// Riverpod provider for the WebSocket connection status.
final connectionProvider =
    NotifierProvider<ConnectionNotifier, ConnectionStatus>(
        ConnectionNotifier.new);

/// Pure event-driven connection state machine.
///
/// State transitions:
///   disconnected → connecting   (connect() called)
///   connecting   → connected    (relay: peer_connected / bridge data / 5s optimistic timeout)
///   connecting   → disconnected (relay: peer_offline)
///   connected    → disconnected (relay: peer_disconnected)
///   any          → disconnected (disconnect() called)
///   any          → error        (native exception)
///   any          → sessionExpired (NO_SESSION exception)
///
/// NO POLLING. State changes come exclusively from:
///   1. Explicit API calls (connect/disconnect)
///   2. Relay events routed via setPeerConnected() / setPeerDisconnected()
///   3. Optimistic fallback timeout (when no relay event arrives)
class ConnectionNotifier extends Notifier<ConnectionStatus> {
  final SecurityChannel _security = SecurityChannel();

  /// Timer that fires if no relay event arrives after connect().
  Timer? _connectTimeout;

  /// Auto-retry count for transient errors (reset on successful connection).
  int _autoRetryCount = 0;

  /// Timer for auto-retry backoff after transient errors.
  Timer? _retryTimer;

  /// Periodic keepalive to prevent relay inactivity timeout (30 min).
  /// Only runs while a peer is connected (phone foregrounded).
  Timer? _keepaliveTimer;

  /// The session we're currently connecting/connected to.
  String? _currentSessionId;
  String? _currentRelay;

  @override
  ConnectionStatus build() {
    ref.onDispose(() {
      _connectTimeout?.cancel();
      _retryTimer?.cancel();
      _keepaliveTimer?.cancel();
    });
    return ConnectionStatus.disconnected;
  }

  /// The session ID currently being connected/connected to.
  String? get currentSessionId => _currentSessionId;

  // ---------------------------------------------------------------------------
  // Connect
  // ---------------------------------------------------------------------------

  /// Ask the native layer to open a WebSocket to the relay for [sessionId].
  ///
  /// The native layer maintains per-session WebSockets, so switching sessions
  /// does NOT tear down the old connection. Background sessions stay connected
  /// and continue receiving messages (routed by ChatNotifier).
  ///
  /// Sets state to `connecting`. The state will move to `connected` when
  /// a relay event or bridge data arrives, or after a 5s optimistic timeout.
  Future<void> connect(String sessionId, {String? relay}) async {
    final switching = sessionId != _currentSessionId;

    // If already connected or connecting to THIS session, nothing to do.
    if (!switching &&
        (state == ConnectionStatus.connected ||
         state == ConnectionStatus.connecting)) {
      debugPrint('[Connection] connect($sessionId): already $state');
      return;
    }

    // ── Session switch: keep old WebSocket alive ──
    // The native layer maintains a per-session WebSocket pool. When switching
    // sessions, we just update _currentSessionId and connect the new one.
    // The old session's WebSocket stays alive so it continues receiving
    // messages (routed by ChatNotifier to the background session).
    if (switching && _currentSessionId != null) {
      debugPrint('[Connection] Switching from $_currentSessionId → $sessionId');
      _connectTimeout?.cancel();
    }

    _currentSessionId = sessionId;
    _currentRelay = relay;

    debugPrint('[Connection] connect($sessionId): → connecting');
    state = ConnectionStatus.connecting;
    _connectTimeout?.cancel();

    try {
      final success = await _security.connectToSession(sessionId, relay: relay);
      if (!success) {
        debugPrint('[Connection] connect($sessionId): native returned false → error');
        state = ConnectionStatus.error;
        return;
      }

      // Native success = WebSocket to relay is open. NOT peer online.
      // Wait for relay event. Fallback: assume connected after 5s
      // (the old polling did the same — getConnectionState() always
      // returned "connected" because the relay WebSocket IS open).
      // If the peer is truly offline, a relay event will correct this.
      _connectTimeout = Timer(const Duration(seconds: 5), () {
        if (state == ConnectionStatus.connecting) {
          debugPrint('[Connection] connect($sessionId): timeout → connected (optimistic)');
          state = ConnectionStatus.connected;
        }
      });
    } on PlatformException catch (e) {
      final newState = e.code == 'NO_SESSION'
          ? ConnectionStatus.sessionExpired
          : ConnectionStatus.error;
      debugPrint('[Connection] connect($sessionId): ${e.code} → $newState');
      state = newState;

      // Transient errors: schedule auto-retry with exponential backoff.
      // Permanent errors (bad cert, auth failure, expired session) are not retried.
      final isTransient = e.code != 'INVALID_CERT' &&
                          e.code != 'AUTH_FAILED' &&
                          e.code != 'NO_SESSION';
      if (isTransient && _autoRetryCount < 5) {
        _autoRetryCount++;
        final delay = Duration(seconds: const [1, 2, 4, 8, 15][_autoRetryCount - 1]);
        _retryTimer?.cancel();
        _retryTimer = Timer(delay, () {
          if (state == ConnectionStatus.error) {
            debugPrint('[Connection] Auto-retry #$_autoRetryCount for $sessionId');
            reconnect();
          }
        });
      }
    } catch (e) {
      debugPrint('[Connection] connect($sessionId): exception → error ($e)');
      state = ConnectionStatus.error;

      // Generic exceptions are likely transient (network issues, DNS, etc.)
      if (_autoRetryCount < 5) {
        _autoRetryCount++;
        final delay = Duration(seconds: const [1, 2, 4, 8, 15][_autoRetryCount - 1]);
        _retryTimer?.cancel();
        _retryTimer = Timer(delay, () {
          if (state == ConnectionStatus.error) {
            debugPrint('[Connection] Auto-retry #$_autoRetryCount for $sessionId');
            reconnect();
          }
        });
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Relay event handlers (called by ChatNotifier)
  // ---------------------------------------------------------------------------

  /// Peer is confirmed online. Called when:
  /// - Relay sends `peer_connected`
  /// - Any real (non-relay-control) bridge data arrives
  void setPeerConnected() {
    _connectTimeout?.cancel();
    _retryTimer?.cancel();
    _autoRetryCount = 0;
    if (state != ConnectionStatus.connected) {
      debugPrint('[Connection] setPeerConnected: $state → connected');
      state = ConnectionStatus.connected;
    }
    _startKeepalive();
  }

  /// Native WebSocket is reconnecting after a connection drop.
  /// Called when native layer emits connectionState = 'reconnecting'.
  void setReconnecting() {
    _connectTimeout?.cancel();
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
    if (state != ConnectionStatus.reconnecting) {
      debugPrint('[Connection] setReconnecting: $state → reconnecting');
      state = ConnectionStatus.reconnecting;
    }
  }

  /// Native WebSocket is actively connecting.
  /// Called when native layer emits connectionState = 'connecting'.
  void setConnecting() {
    _connectTimeout?.cancel();
    if (state != ConnectionStatus.connecting) {
      debugPrint('[Connection] setConnecting: $state → connecting');
      state = ConnectionStatus.connecting;
    }
  }


  /// Network reachability changed (from native NetworkMonitor).
  /// If network goes down while connected, move to reconnecting.
  void setNetworkState({required bool isReachable, required String transport}) {
    debugPrint('[Connection] networkState: reachable=$isReachable transport=$transport');
    if (!isReachable && state == ConnectionStatus.connected) {
      state = ConnectionStatus.reconnecting;
    }
  }

  /// Peer is confirmed offline. Called when:
  /// - Relay sends `peer_disconnected`
  /// - Relay sends `peer_offline`
  void setPeerDisconnected() {
    _connectTimeout?.cancel();
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
    if (state != ConnectionStatus.disconnected) {
      debugPrint('[Connection] setPeerDisconnected: $state → disconnected');
      state = ConnectionStatus.disconnected;
    }
  }

  // ---------------------------------------------------------------------------
  // Disconnect
  // ---------------------------------------------------------------------------

  /// Ask the native layer to disconnect the current session.
  Future<void> disconnect() async {
    _connectTimeout?.cancel();
    _retryTimer?.cancel();
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
    _autoRetryCount = 0;
    try {
      if (_currentSessionId != null) {
        await _security.disconnectSession(_currentSessionId!);
      } else {
        await _security.disconnect();
      }
    } finally {
      _currentSessionId = null;
      _currentRelay = null;
      state = ConnectionStatus.disconnected;
    }
  }

  // ---------------------------------------------------------------------------
  // Reconnect
  // ---------------------------------------------------------------------------

  /// Force reconnect to the current session.
  Future<void> reconnect() async {
    if (_currentSessionId != null) {
      await connect(_currentSessionId!, relay: _currentRelay);
    }
  }

  // ---------------------------------------------------------------------------
  // Keepalive
  // ---------------------------------------------------------------------------

  /// Sends a keepalive every 10 minutes to prevent the relay's 30-minute
  /// inactivity timeout from killing the session. 10 min = 1/3 of timeout,
  /// so two consecutive misses are tolerated before the session is at risk.
  void _startKeepalive() {
    if (_keepaliveTimer != null) return; // already running, keep steady cadence
    final sid = _currentSessionId;
    if (sid == null) return;
    _keepaliveTimer = Timer.periodic(
      const Duration(minutes: 10),
      (_) async {
        try {
          await _security.keepalive(sid);
        } catch (_) {
          // WebSocket may have closed; timer will be cancelled
          // by setPeerDisconnected or disconnect.
        }
      },
    );
  }

}
