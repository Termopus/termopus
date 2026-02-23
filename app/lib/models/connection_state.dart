/// The current status of the WebSocket connection to the relay.
enum ConnectionStatus {
  /// No active connection.
  disconnected,

  /// Actively attempting to connect.
  connecting,

  /// A live connection is established.
  connected,

  /// Connection was lost and is being re-established.
  reconnecting,

  /// An unrecoverable error occurred.
  error,

  /// Session key is missing or expired — re-pairing required.
  sessionExpired,

}
