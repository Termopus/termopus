import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/push/push_handler.dart';

/// Pre-loaded [SharedPreferences] instance, available synchronously after
/// [main] completes. Must be overridden via [ProviderScope.overrides].
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('Override in ProviderScope'),
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Pre-load SharedPreferences so that providers (e.g. onboarding status)
  // resolve synchronously and GoRouter redirects work on first frame.
  final prefs = await SharedPreferences.getInstance();

  // Initialise Firebase and push handling. Failures here must not crash the
  // app — the user can still use the WebSocket flow without push.
  try {
    await Firebase.initializeApp();
    await PushHandler().initialize();
  } catch (e) {
    debugPrint('[main] Firebase/PushHandler init failed: $e');
  }

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const ClaudeRemoteApp(),
    ),
  );
}
