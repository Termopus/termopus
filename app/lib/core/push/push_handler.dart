import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../platform/security_channel.dart';

/// Top-level background message handler.
///
/// Must be a top-level function (not a class method) for Firebase to
/// invoke it in a background isolate on Android.
///
/// Because the relay sends **data-only silent pushes**, this handler is
/// called for every push — even when the app is terminated.  On Android
/// the [SilentPushService] handles the native side; this Dart handler
/// covers iOS and any Dart-level processing.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Data-only push — the relay sent { type: "wake", sessionId: "..." }.
  // On iOS, the OS will keep the app alive briefly. We cannot do much
  // here without a Flutter engine, but the native side (content-available)
  // can trigger a background fetch if configured in Xcode.
  debugPrint('[PushHandler] Background push: ${message.data}');
}

/// Manages FCM token lifecycle and incoming push messages at the Dart layer.
///
/// Responsibilities:
///  1. Obtain the FCM token and register it with the relay (via native bridge).
///  2. Listen for token refreshes and re-register.
///  3. Handle foreground data-only pushes (display local notification or
///     trigger WebSocket reconnect).
class PushHandler {
  static final PushHandler _instance = PushHandler._internal();
  factory PushHandler() => _instance;
  PushHandler._internal();

  final SecurityChannel _security = SecurityChannel();
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  StreamSubscription<RemoteMessage>? _foregroundSubscription;
  StreamSubscription<String>? _tokenRefreshSubscription;

  bool _initialized = false;

  /// Initialize push handling.
  ///
  /// Call this once after Firebase.initializeApp() completes.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Register the background handler
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Request notification permission (iOS; Android 13+ POST_NOTIFICATIONS)
    await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    // Get the current token and register it
    final token = await _messaging.getToken();
    if (token != null) {
      await _security.registerFcmToken(token);
    }

    // Listen for token refreshes
    _tokenRefreshSubscription = _messaging.onTokenRefresh.listen((newToken) async {
      try {
        await _security.registerFcmToken(newToken);
      } catch (error) {
        debugPrint('[PushHandler] Failed to register refreshed FCM token: $error');
      }
    });

    // Handle foreground data-only pushes
    _foregroundSubscription =
        FirebaseMessaging.onMessage.listen(_handleForegroundPush);
  }

  /// Handle a data-only push received while the app is in the foreground.
  ///
  /// Since the user is already in the app with an active WebSocket, the
  /// encrypted message will arrive through the normal channel.  We only
  /// need to handle edge cases (e.g., WebSocket was just disconnected).
  void _handleForegroundPush(RemoteMessage message) {
    final type = message.data['type'];
    final sessionId = message.data['sessionId'];

    debugPrint('[PushHandler] Foreground push: type=$type, sessionId=$sessionId');

    // The WebSocket should already be delivering messages in foreground.
    // If the connection dropped, the auto-reconnect logic in the native
    // SecureWebSocket will re-establish it.  No action needed here.
  }

  /// Clean up listeners.
  void dispose() {
    _foregroundSubscription?.cancel();
    _tokenRefreshSubscription?.cancel();
    _foregroundSubscription = null;
    _tokenRefreshSubscription = null;
    _initialized = false;
  }
}
