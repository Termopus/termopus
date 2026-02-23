import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/security_channel.dart';

class HttpTunnelState {
  /// Whether the tunnel is active
  final bool isActive;

  /// Local proxy server port (phone-side)
  final int localPort;

  /// Remote target port (computer-side localhost)
  final int? targetPort;

  /// Last used target port (persists after tunnel close, for Browser button)
  final int lastTargetPort;

  /// Monotonic counter — incremented on every tunnel open or refresh.
  /// BrowserView watches this to know when to reload.
  final int refreshCount;

  /// Error message
  final String? error;

  const HttpTunnelState({
    this.isActive = false,
    this.localPort = 8888,
    this.targetPort,
    this.lastTargetPort = 3000,
    this.refreshCount = 0,
    this.error,
  });

  HttpTunnelState copyWith({
    bool? isActive,
    int? localPort,
    int? targetPort,
    int? lastTargetPort,
    int? refreshCount,
    String? error,
    bool clearError = false,
    bool clearTarget = false,
  }) {
    return HttpTunnelState(
      isActive: isActive ?? this.isActive,
      localPort: localPort ?? this.localPort,
      targetPort: clearTarget ? null : (targetPort ?? this.targetPort),
      lastTargetPort: lastTargetPort ?? this.lastTargetPort,
      refreshCount: refreshCount ?? this.refreshCount,
      error: clearError ? null : (error ?? this.error),
    );
  }

  /// The URL the WebView should load
  String get proxyUrl => 'http://127.0.0.1:$localPort/';
}

class HttpTunnelNotifier extends Notifier<HttpTunnelState> {
  final SecurityChannel _security = SecurityChannel();
  HttpServer? _server;

  /// Pending requests waiting for responses, keyed by requestId.
  final Map<String, Completer<_ProxiedResponse>> _pending = {};

  /// Monotonic counter for unique request IDs.
  int _nextRequestId = 0;

  @override
  HttpTunnelState build() {
    ref.onDispose(() {
      _stopLocalServer();
    });
    return const HttpTunnelState();
  }

  /// Called when an http_tunnel_status message arrives from bridge (via ChatProvider).
  void onTunnelStatus(bool active, int? port, String? error) {
    if (active && port != null) {
      // If target port changed, restart the local proxy so requests go to the new port.
      final portChanged = state.targetPort != null && state.targetPort != port;
      state = state.copyWith(
        isActive: true,
        targetPort: port,
        lastTargetPort: port,
        refreshCount: state.refreshCount + 1,
        clearError: true,
      );
      if (portChanged) {
        debugPrint('[HttpTunnel] Port changed to $port, restarting local proxy');
        _stopLocalServer();
      }
      _startLocalServer();
    } else {
      state = state.copyWith(
        isActive: false,
        clearTarget: true,
        error: error,
      );
      _stopLocalServer();
    }
  }

  /// Called when bridge sends http_tunnel_refresh (file was edited while tunnel active).
  void onRefresh() {
    if (state.isActive) {
      debugPrint('[HttpTunnel] Refresh requested');
      state = state.copyWith(refreshCount: state.refreshCount + 1);
    }
  }

  /// Called when an http_response message arrives from bridge (via ChatProvider).
  void onHttpResponse(String requestId, int status,
      Map<String, String> headers, String bodyBase64) {
    final completer = _pending.remove(requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(_ProxiedResponse(
        status: status,
        headers: headers,
        bodyBase64: bodyBase64,
      ));
    } else {
      debugPrint('[HttpTunnel] No pending request for $requestId');
    }
  }

  /// Request bridge to open HTTP tunnel to a port.
  Future<void> requestOpen(int port) async {
    try {
      await _security.sendHttpTunnelOpen(port: port);
    } catch (e) {
      state = state.copyWith(error: 'Failed to open tunnel: $e');
    }
  }

  /// Request bridge to close HTTP tunnel.
  Future<void> requestClose() async {
    try {
      await _security.sendHttpTunnelClose();
      _stopLocalServer();
    } catch (e) {
      state = state.copyWith(error: 'Failed to close tunnel: $e');
    }
  }

  /// Start the local HTTP server that the WebView will connect to.
  Future<void> _startLocalServer() async {
    if (_server != null) return;

    try {
      _server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        state.localPort,
      );
      debugPrint(
          '[HttpTunnel] Local proxy server started on port ${state.localPort}');

      _server!.listen(_handleRequest);
    } catch (e) {
      debugPrint('[HttpTunnel] Failed to start local server: $e');
      state = state.copyWith(error: 'Failed to start local proxy: $e');
    }
  }

  /// Stop the local HTTP server.
  void _stopLocalServer() {
    _server?.close(force: true);
    _server = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError('Tunnel closed');
      }
    }
    _pending.clear();
  }

  /// Handle an incoming HTTP request from the WebView.
  Future<void> _handleRequest(HttpRequest request) async {
    final requestId = '${_nextRequestId++}';

    try {
      // Read request body
      final bodyBytes = await request.fold<List<int>>(
        <int>[],
        (prev, chunk) => prev..addAll(chunk),
      );
      final bodyBase64 =
          bodyBytes.isNotEmpty ? base64Encode(bodyBytes) : null;

      // Collect headers
      final headers = <String, String>{};
      request.headers.forEach((name, values) {
        headers[name] = values.join(', ');
      });

      // Create completer for this request
      final completer = Completer<_ProxiedResponse>();
      _pending[requestId] = completer;

      // Send through relay via platform channel
      await _security.sendHttpRequest(
        requestId: requestId,
        method: request.method,
        path: request.uri.toString(),
        headers: headers,
        body: bodyBase64,
      );

      // Wait for response (with timeout)
      final response = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          _pending.remove(requestId);
          return _ProxiedResponse(
            status: 504,
            headers: {},
            bodyBase64: base64Encode(utf8.encode('Gateway Timeout')),
          );
        },
      );

      // Write response back to WebView
      request.response.statusCode = response.status;
      response.headers.forEach((key, value) {
        final lower = key.toLowerCase();
        if (lower != 'transfer-encoding') {
          request.response.headers.set(key, value);
        }
      });
      // Prevent WebView from caching proxied responses — stale cache
      // causes the "stuck on old page" bug when tunnel port changes.
      request.response.headers.set('Cache-Control', 'no-store, no-cache, must-revalidate');
      request.response.headers.set('Pragma', 'no-cache');

      final responseBody = base64Decode(response.bodyBase64);
      request.response.add(responseBody);
      await request.response.close();
    } catch (e) {
      debugPrint('[HttpTunnel] Error handling request: $e');
      _pending.remove(requestId);
      try {
        request.response.statusCode = 502;
        request.response.write('Proxy Error: $e');
        await request.response.close();
      } catch (_) {}
    }
  }

}

class _ProxiedResponse {
  final int status;
  final Map<String, String> headers;
  final String bodyBase64;

  _ProxiedResponse({
    required this.status,
    required this.headers,
    required this.bodyBase64,
  });
}

final httpTunnelProvider =
    NotifierProvider<HttpTunnelNotifier, HttpTunnelState>(
        HttpTunnelNotifier.new);
