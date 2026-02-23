/// Re-export the action-related types from the message model.
///
/// This file exists so that consumers can import [PendingAction] directly
/// without needing to know it lives inside `message.dart`.
export 'message.dart' show PendingAction;
