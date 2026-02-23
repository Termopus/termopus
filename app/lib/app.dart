import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/auth/biometric_lock_screen.dart';
import 'features/chat/chat_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/pairing/qr_scanner_screen.dart';
import 'features/sessions/sessions_list_screen.dart';
import 'features/settings/app_settings_screen.dart';
import 'features/settings/settings_screen.dart';
import 'main.dart' show sharedPreferencesProvider;
import 'shared/constants.dart';
import 'shared/theme.dart';

/// Onboarding status — reads synchronously from the pre-loaded
/// [SharedPreferences] so GoRouter redirects work on the very first frame.
final onboardingCompleteProvider = Provider<bool>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return prefs.getBool(AppConstants.prefOnboardingComplete) ?? false;
});

/// Top-level GoRouter configuration.
///
/// Routes:
///   /              -> sessions list (home)
///   /onboarding    -> welcome & setup flow
///   /pair          -> QR scanner for new pairing
///   /chat/:sid     -> chat screen for a given session
///   /settings      -> application settings
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    redirect: (context, state) {
      final isComplete = ref.read(onboardingCompleteProvider);
      final isOnboardingRoute = state.matchedLocation == '/onboarding';

      // Not onboarded yet — force to /onboarding (unless already there).
      if (!isComplete && !isOnboardingRoute) return '/onboarding';

      // Already onboarded — don't let them back into /onboarding.
      if (isComplete && isOnboardingRoute) return '/';

      return null;
    },
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        name: 'sessions',
        builder: (context, state) => const SessionsListScreen(),
      ),
      GoRoute(
        path: '/onboarding',
        name: 'onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: '/pair',
        name: 'pair',
        builder: (context, state) => const QrScannerScreen(),
      ),
      GoRoute(
        path: '/chat/:sessionId',
        name: 'chat',
        builder: (context, state) {
          final sessionId = state.pathParameters['sessionId']!;
          return ChatScreen(sessionId: sessionId);
        },
      ),
      GoRoute(
        path: '/settings',
        name: 'settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/app-settings',
        name: 'app-settings',
        builder: (context, state) => const AppSettingsScreen(),
      ),
    ],
  );
});

/// Root application widget.
class ClaudeRemoteApp extends ConsumerWidget {
  const ClaudeRemoteApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'Claude Code Remote',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      routerConfig: router,
      builder: (context, child) {
        return BiometricLockScreen(child: child ?? const SizedBox.shrink());
      },
    );
  }
}
