import 'package:flutter/services.dart';
import '../../shared/constants.dart';

/// Centralised references to the platform channels used by the app.
///
/// The actual method/event channels are thin wrappers -- all real work
/// (encryption, key management, mTLS) happens on the native side.
class MethodChannels {
  MethodChannels._();

  /// MethodChannel for invoking native security operations.
  static const MethodChannel security = MethodChannel(
    AppConstants.securityMethodChannel,
  );

  /// EventChannel for receiving decrypted messages from native.
  static const EventChannel messages = EventChannel(
    AppConstants.messagesEventChannel,
  );
}
