import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../core/providers/http_tunnel_provider.dart';

/// Displays the live browser view via local HTTP proxy.
/// The WebView loads from localhost:8888 which is proxied
/// through the encrypted relay to the computer's localhost.
class BrowserView extends ConsumerStatefulWidget {
  const BrowserView({super.key});

  @override
  ConsumerState<BrowserView> createState() => _BrowserViewState();
}

class _BrowserViewState extends ConsumerState<BrowserView> {
  WebViewController? _controller;
  bool _hasLoadedUrl = false;
  int? _loadedPort;
  int _lastRefreshCount = 0;

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {},
        onPageFinished: (_) {},
        onWebResourceError: (error) {
          debugPrint('[BrowserView] WebView error: ${error.description}');
        },
      ));
  }

  @override
  Widget build(BuildContext context) {
    final tunnel = ref.watch(httpTunnelProvider);

    if (!tunnel.isActive) {
      _hasLoadedUrl = false;
      _loadedPort = null;
      return _buildPlaceholder(context, tunnel.error);
    }

    // Load URL when tunnel becomes active or target port changes.
    // Recreate the controller to guarantee a completely fresh WebView —
    // clearCache() alone isn't reliable on all Android WebView versions.
    if (!_hasLoadedUrl || _loadedPort != tunnel.targetPort) {
      _hasLoadedUrl = true;
      _loadedPort = tunnel.targetPort;
      final cacheBust = DateTime.now().millisecondsSinceEpoch;
      final url = '${tunnel.proxyUrl}?_t=$cacheBust';
      debugPrint('[BrowserView] Loading tunnel port=${tunnel.targetPort} url=$url');
      _initWebView();
      _controller!.clearCache();
      _controller!.clearLocalStorage();
      _controller!.loadRequest(Uri.parse(url));
      _lastRefreshCount = tunnel.refreshCount;
    }

    // Auto-refresh when bridge signals file change (Edit/Write).
    if (tunnel.refreshCount != _lastRefreshCount) {
      _lastRefreshCount = tunnel.refreshCount;
      debugPrint('[BrowserView] Auto-refresh triggered (refreshCount=${tunnel.refreshCount})');
      _controller?.reload();
    }

    return Container(
      color: Colors.white,
      child: Stack(
        children: [
          WebViewWidget(controller: _controller!),

          // Active indicator
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Colors.green,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'PORT ${tunnel.targetPort ?? "?"}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Close + Refresh buttons
          Positioned(
            top: 8,
            left: 8,
            child: Row(
              children: [
                GestureDetector(
                  onTap: () =>
                      ref.read(httpTunnelProvider.notifier).requestClose(),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () => _controller?.reload(),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.refresh,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder(BuildContext context, String? error) {
    return Container(
      color: Colors.black87,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.web,
              color: Colors.white38,
              size: 48,
            ),
            const SizedBox(height: 12),
            Text(
              error ?? 'Browser tunnel not active',
              style: const TextStyle(color: Colors.white54, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
