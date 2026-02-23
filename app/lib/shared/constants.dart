/// Application-wide constants for Claude Code Remote.
///
/// All channel names, API URLs, timeouts, and other configuration values
/// are centralized here. No security-sensitive secrets are stored in Dart.
class AppConstants {
  AppConstants._();

  // ---------------------------------------------------------------------------
  // Platform channel names
  // ---------------------------------------------------------------------------

  static const String securityMethodChannel = 'app.clauderemote/security';
  static const String messagesEventChannel = 'app.clauderemote/messages';

  // ---------------------------------------------------------------------------
  // API URLs
  // ---------------------------------------------------------------------------

  /// Provisioning API URL.
  /// Replace 'YOUR_PROVISIONING_API_URL' with your deployed provisioning
  /// worker URL (e.g., 'https://termopus-provisioning-dev.yourname.workers.dev').
  /// Run scripts/setup.sh to set this automatically.
  static const String provisioningApiBase =
      bool.fromEnvironment('dart.vm.product')
          ? 'https://YOUR_PROVISIONING_API_URL'
          : 'https://YOUR_API_DEV_DOMAIN';
  static const String provisioningCertEndpoint =
      '$provisioningApiBase/provision/cert';
  static const String provisioningChallengeEndpoint =
      '$provisioningApiBase/provision/challenge';

  // ---------------------------------------------------------------------------
  // Timeouts & intervals
  // ---------------------------------------------------------------------------

  /// WebSocket reconnection delay.
  static const Duration reconnectDelay = Duration(seconds: 3);

  /// Default session timeout before requiring re-authentication.
  static const Duration defaultSessionTimeout = Duration(minutes: 15);

  /// QR code expiration tolerance.
  static const Duration qrExpirationTolerance = Duration(minutes: 5);

  // ---------------------------------------------------------------------------
  // QR code protocol version
  // ---------------------------------------------------------------------------

  static const int qrProtocolVersion = 1;

  // ---------------------------------------------------------------------------
  // SharedPreferences keys (non-sensitive metadata only)
  // ---------------------------------------------------------------------------

  static const String prefSessionsKey = 'sessions';
  static const String prefOnboardingComplete = 'onboarding_complete';
  static const String prefBiometricEnabled = 'biometric_enabled';
  static const String prefSessionTimeoutMinutes = 'session_timeout_minutes';

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  static const double maxChatBubbleWidthFraction = 0.80;
  static const double codeBlockBorderRadius = 8.0;
  static const double actionButtonHeight = 48.0;
  static const double actionButtonWidth = 120.0;
}
