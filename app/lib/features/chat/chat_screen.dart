import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/providers/active_agents_provider.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/providers/chat_provider.dart';
import '../../core/providers/claude_config_provider.dart';
import '../../core/providers/connection_provider.dart';
import '../../core/providers/session_provider.dart';
import '../../models/connection_state.dart';
import '../../core/platform/security_channel.dart';
import '../../models/message.dart';
import '../../shared/responsive.dart';
import '../../shared/theme.dart';
import 'widgets/action_buttons.dart';
import 'widgets/active_agents_bar.dart';
import 'widgets/browser_view.dart';
import 'widgets/file_transfer_bar.dart';
import 'widgets/task_progress_bar.dart';
import 'widgets/input_bar.dart';
import 'widgets/message_bubble.dart';
import '../../core/providers/http_tunnel_provider.dart';

/// Main chat screen - Clean, WhatsApp-like interface.
///
/// Focuses on the conversation with Claude. Advanced controls are
/// accessible through the "+" button and settings menu.
class ChatScreen extends ConsumerStatefulWidget {
  final String sessionId;

  const ChatScreen({super.key, required this.sessionId});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with WidgetsBindingObserver {
  final ScrollController _scrollController = ScrollController();
  bool _smartMode = true; // true = rich cards, false = terminal text
  bool _isConnecting = false; // guard against duplicate connect calls
  bool _deferredReconnect = false; // reconnect after biometric unlock
  double _browserSplitRatio = 0.4; // 40% browser, 60% chat

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Defer connection to after the first frame to avoid modifying
    // providers during the widget tree build phase (Riverpod restriction).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _connectToSession();
    });
    // When biometric lock releases, reconnect if we deferred earlier.
    ref.listenManual(biometricLockActiveProvider, (prev, next) {
      if (prev == true && next == false && _deferredReconnect) {
        _deferredReconnect = false;
        debugPrint('[ChatScreen] Biometric lock released, reconnecting...');
        _connectToSession();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // App came back to foreground
      ref.read(chatProvider.notifier).clearStaleThinking();
      ref.read(activeAgentsProvider.notifier).removeStale();
      // If biometric lock is active, defer reconnection until after unlock.
      // Reconnecting now would contend with the native biometric prompt.
      if (ref.read(biometricLockActiveProvider)) {
        debugPrint('[ChatScreen] App resumed, deferring reconnect (biometric lock active)');
        _deferredReconnect = true;
      } else {
        debugPrint('[ChatScreen] App resumed, reconnecting...');
        _connectToSession();
      }
    }
  }

  Future<void> _connectToSession() async {
    // Guard against duplicate calls (initState + lifecycle resumed can
    // both fire on launch, creating redundant WebSocket connections).
    if (_isConnecting) return;
    _isConnecting = true;
    try {
      // Route messages to this session's list before connecting.
      try {
        await ref.read(chatProvider.notifier).setActiveSession(widget.sessionId);
      } catch (e) {
        debugPrint('[ChatScreen] setActiveSession error: $e');
      }
      // Look up relay URL from the persisted session metadata.
      final sessions = ref.read(sessionProvider);
      final session =
          sessions.where((s) => s.id == widget.sessionId).firstOrNull;
      final notifier = ref.read(connectionProvider.notifier);
      await notifier.connect(widget.sessionId, relay: session?.relay);
    } finally {
      _isConnecting = false;
    }
  }

  /// Wait for the native WebSocket to be connected, polling up to [maxWaitMs].
  /// Queries native layer directly to avoid Riverpod state propagation lag.
  Future<bool> _waitForConnection({int maxWaitMs = 15000}) async {
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsedMilliseconds < maxWaitMs) {
      final nativeState = await SecurityChannel().getConnectionState();
      if (nativeState.toLowerCase() == 'connected') return true;
      await Future.delayed(const Duration(milliseconds: 300));
    }
    final finalState = await SecurityChannel().getConnectionState();
    return finalState.toLowerCase() == 'connected';
  }

  Future<void> _pickAndSendPhoto(BuildContext context) async {
    try {
      final picker = ImagePicker();
      final image = await picker.pickImage(source: ImageSource.gallery);
      if (image == null) return;

      // File picker may background the app, causing WS to reconnect.
      // Query native state directly (Riverpod state can lag behind).
      final nativeState = await SecurityChannel().getConnectionState();
      if (nativeState.toLowerCase() != 'connected') {
        debugPrint('[ChatScreen] WS not connected ($nativeState), waiting...');
        if (!await _waitForConnection()) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Not connected — please try again')),
            );
          }
          return;
        }
      }

      final mimeType = lookupMimeType(image.path) ?? 'image/jpeg';
      final fileName = image.name;

      final sent = await SecurityChannel().sendFile(
        filePath: image.path,
        fileName: fileName,
        mimeType: mimeType,
      );
      if (sent) {
        ref.read(chatProvider.notifier).addFileSentMessage(fileName);
      }
    } catch (e) {
      debugPrint('[ChatScreen] Photo pick error: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send photo: $e')),
        );
      }
    }
  }

  Future<void> _pickAndSendFile(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles();
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.path == null) return;

      // File picker may background the app, causing WS to reconnect.
      // Query native state directly (Riverpod state can lag behind).
      final nativeState = await SecurityChannel().getConnectionState();
      if (nativeState.toLowerCase() != 'connected') {
        debugPrint('[ChatScreen] WS not connected ($nativeState), waiting...');
        if (!await _waitForConnection()) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Not connected — please try again')),
            );
          }
          return;
        }
      }

      final mimeType = lookupMimeType(file.path!) ?? 'application/octet-stream';

      final sent = await SecurityChannel().sendFile(
        filePath: file.path!,
        fileName: file.name,
        mimeType: mimeType,
      );
      if (sent) {
        ref.read(chatProvider.notifier).addFileSentMessage(file.name);
      }
    } catch (e) {
      debugPrint('[ChatScreen] File pick error: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send file: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(chatProvider);
    final connection = ref.watch(connectionProvider);
    final sessions = ref.watch(sessionProvider);

    final session = sessions
        .where((s) => s.id == widget.sessionId)
        .firstOrNull;

    final pendingAction = _findPendingAction(messages);
    if (pendingAction != null) {
      debugPrint('[HOOK_TRACE] 5. BUILD: pendingAction found! id=${pendingAction.id}, msgs=${messages.length}');
    }
    final chatNotifier = ref.read(chatProvider.notifier);
    // NOTE: handedOff changes always accompany a state list update
    // (via _addSystemMessage or StateSnapshot handler), so ref.read()
    // captures the correct value during rebuilds from ref.watch(chatProvider).
    final isHandedOff = chatNotifier.handedOff;

    return Scaffold(
      backgroundColor: AppTheme.background,
      resizeToAvoidBottomInset: false,
      appBar: _buildAppBar(context, session?.name, connection),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final tunnel = ref.watch(httpTunnelProvider);
          final showBrowser = tunnel.isActive;
          final bottomInset = MediaQuery.of(context).viewInsets.bottom;
          final keyboardOpen = bottomInset > 0;

          final chatChildren = <Widget>[
            // Connection status banner
            if (connection == ConnectionStatus.error)
              _ConnectionBanner(text: 'Connection error. Trying to reconnect...'),
            if (connection == ConnectionStatus.disconnected)
              _ConnectionBanner(
                text: 'Session ended — computer is offline',
                icon: Icons.cloud_off_rounded,
              ),

            // Background agents indicator
            const ActiveAgentsBar(),

            // Task list progress
            const TaskProgressBar(),

            // File transfers indicator
            const FileTransferBar(),

            // Message list
            Expanded(
              child: messages.isEmpty
                  ? _EmptyState()
                  : _MessageList(
                      messages: messages,
                      filteredMessages: chatNotifier.filteredMessages(_smartMode),
                      scrollController: _scrollController,
                      smartMode: _smartMode,
                      isMessageQueued: chatNotifier.isMessageQueued,
                      onSendMessage: (text) {
                        ref.read(chatProvider.notifier).sendMessage(text);
                      },
                    ),
            ),

            // Handoff observer banner
            if (isHandedOff)
              _HandoffBanner(
                onTakeBack: () => chatNotifier.sendTakeBack(),
              ),

            // Action buttons (when permission prompt is pending) — ALWAYS show,
            // even when keyboard is open. This is the most critical UI element.
            if (pendingAction != null && !isHandedOff)
              ActionButtonsBar(
                action: pendingAction,
                onResponse: (response) {
                  chatNotifier.respondToAction(pendingAction.id, response);
                },
              ),

            // Controls bar — hide when keyboard open
            if (!keyboardOpen)
              _ControlsBar(
                smartMode: _smartMode,
                onToggleMode: () => setState(() => _smartMode = !_smartMode),
              ),

            // Input bar
            InputBar(
              smartMode: _smartMode,
              isThinking: messages.any((m) => m.type == MessageType.thinking),
              isHandedOff: isHandedOff,
              keyboardVisible: keyboardOpen,
              onHandoff: () => chatNotifier.sendHandoff(),
              onSendText: (text) {
                chatNotifier.sendMessage(text);
              },
              onSendKey: (key) {
                chatNotifier.sendKey(key);
              },
              onCommand: (command, args) {
                chatNotifier.sendCommand(command, args: args);
              },
              onPickPhoto: () => _pickAndSendPhoto(context),
              onPickFile: () => _pickAndSendFile(context),
              onSettings: () => context.push('/settings'),
            ),

            // Keyboard spacer
            SizedBox(height: bottomInset),
          ];

          if (!showBrowser) {
            return Column(children: chatChildren);
          }

          // Split-view: browser on top, chat on bottom
          return Column(
            children: [
              SizedBox(
                height: constraints.maxHeight * _browserSplitRatio,
                child: const BrowserView(),
              ),
              // Drag handle
              GestureDetector(
                onVerticalDragUpdate: (details) {
                  setState(() {
                    _browserSplitRatio = (_browserSplitRatio +
                            details.delta.dy / constraints.maxHeight)
                        .clamp(0.15, 0.7);
                  });
                },
                child: Container(
                  height: 20,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
              // Chat area
              Expanded(
                child: Column(children: chatChildren),
              ),
            ],
          );
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    String? sessionName,
    ConnectionStatus connection,
  ) {
    return AppBar(
      backgroundColor: AppTheme.surface,
      elevation: 0,
      leading: IconButton(
        icon: Icon(Icons.arrow_back_ios_rounded, size: context.rIconSize),
        onPressed: () => context.go('/'),
      ),
      title: Row(
        children: [
          // Termopus avatar
          Container(
            width: context.rValue(mobile: 32.0, tablet: 40.0),
            height: context.rValue(mobile: 32.0, tablet: 40.0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
            ),
            clipBehavior: Clip.antiAlias,
            child: Image.asset(
              'assets/images/app_icon.png',
              fit: BoxFit.cover,
            ),
          ),
          SizedBox(width: context.rSpacing * 1.5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sessionName ?? 'Claude',
                  style: TextStyle(
                    fontSize: context.bodyFontSize,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: context.rSpacing * 0.25),
                Row(
                  children: [
                    Flexible(child: _StatusText(status: connection)),
                    SizedBox(width: context.rSpacing),
                    _AppBarModelChip(),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.more_vert_rounded),
          onPressed: () => _showMenu(context),
        ),
        SizedBox(width: context.rSpacing * 0.5),
      ],
    );
  }

  void _showMenu(BuildContext context) {
    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _MenuSheet(
        onFiles: () {
          Navigator.pop(ctx);
          _showFilesHistory(context);
        },
        onOpenFolder: () {
          Navigator.pop(ctx);
          ref.read(chatProvider.notifier).sendCommand('open_folder');
        },
        onSettings: () {
          Navigator.pop(ctx);
          context.push('/settings');
        },
        onDisconnect: () {
          Navigator.pop(ctx);
          ref.read(connectionProvider.notifier).disconnect();
          ref.read(sessionProvider.notifier).markDisconnected(widget.sessionId);
          context.go('/');
        },
        onClearChat: () {
          Navigator.pop(ctx);
          ref.read(chatProvider.notifier).clearMessages();
        },
      ),
    );
  }

  void _showFilesHistory(BuildContext context) {
    final messages = ref.read(chatProvider);
    final fileMessages = messages
        .where((m) => m.type == MessageType.fileComplete)
        .toList()
        .reversed
        .toList();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _FilesHistorySheet(files: fileMessages),
    );
  }

  PendingAction? _findPendingAction(List<Message> messages) {
    for (final msg in messages.reversed) {
      if (msg.action != null && !msg.action!.responded) {
        return msg.action;
      }
    }
    return null;
  }

}

/// Connection status text indicator.
class _StatusText extends StatelessWidget {
  final ConnectionStatus status;

  const _StatusText({required this.status});

  @override
  Widget build(BuildContext context) {
    final String text;
    final Color color;

    switch (status) {
      case ConnectionStatus.connected:
        text = 'Online';
        color = AppTheme.statusOnline;
      case ConnectionStatus.connecting:
        text = 'Connecting...';
        color = AppTheme.statusWorking;
      case ConnectionStatus.reconnecting:
        text = 'Reconnecting...';
        color = AppTheme.statusWorking;
      case ConnectionStatus.error:
        text = 'Connection error';
        color = AppTheme.error;
      case ConnectionStatus.sessionExpired:
        text = 'Session expired — re-pair needed';
        color = AppTheme.error;
      case ConnectionStatus.disconnected:
        text = 'Offline';
        color = AppTheme.statusOffline;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: context.rValue(mobile: 8.0, tablet: 10.0),
          height: context.rValue(mobile: 8.0, tablet: 10.0),
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        SizedBox(width: context.rSpacing * 0.75),
        Flexible(
          child: Text(
            text,
            style: TextStyle(
              fontSize: context.captionFontSize,
              color: color,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Compact model chip for the AppBar — shows colored dot + model name.
class _AppBarModelChip extends ConsumerWidget {
  const _AppBarModelChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(claudeConfigProvider);
    final model = config.selectedModel;
    final modelColor = Color(model.colorValue);

    return GestureDetector(
      onTap: () => _showModelPicker(context, ref, model),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.rSpacing * 0.75,
          vertical: context.rSpacing * 0.25,
        ),
        decoration: BoxDecoration(
          color: modelColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: modelColor,
                shape: BoxShape.circle,
              ),
            ),
            SizedBox(width: context.rSpacing * 0.5),
            Text(
              model.displayName,
              style: TextStyle(
                fontSize: context.rFontSize(mobile: 11, tablet: 13),
                fontWeight: FontWeight.w600,
                color: modelColor,
              ),
            ),
            SizedBox(width: context.rSpacing * 0.25),
            Icon(
              Icons.expand_more_rounded,
              size: 12,
              color: modelColor.withValues(alpha: 0.6),
            ),
          ],
        ),
      ),
    );
  }

  void _showModelPicker(BuildContext context, WidgetRef ref, ClaudeModel current) {
    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: EdgeInsets.only(top: context.rSpacing * 1.5, bottom: context.rSpacing),
                width: context.rValue(mobile: 40.0, tablet: 48.0),
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.textMuted.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: EdgeInsets.all(context.rHorizontalPadding),
                child: Text(
                  'Select Model',
                  style: TextStyle(
                    fontSize: context.rFontSize(mobile: 16, tablet: 18),
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
              RadioGroup<ClaudeModel>(
                groupValue: current,
                onChanged: (val) {
                  if (val != null) {
                    HapticFeedback.mediumImpact();
                    ref.read(claudeConfigProvider.notifier).setModel(val);
                    ref.read(chatProvider.notifier).setModel(val.id);
                    Navigator.pop(ctx);
                  }
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final m in ClaudeModel.values)
                      RadioListTile<ClaudeModel>(
                        title: Text(
                          m.displayName,
                          style: TextStyle(color: AppTheme.textPrimary, fontSize: context.bodyFontSize),
                        ),
                        subtitle: Text(
                          m.description,
                          style: TextStyle(color: AppTheme.textMuted, fontSize: context.captionFontSize),
                        ),
                        value: m,
                        activeColor: AppTheme.primary,
                      ),
                  ],
                ),
              ),
              SizedBox(height: context.rSpacing),
            ],
          ),
        ),
      ),
    );
  }
}

/// Controls bar — permission mode, smart/terminal toggle, browser toggle.
/// Sits between the message list and the input area.
class _ControlsBar extends ConsumerWidget {
  final bool smartMode;
  final VoidCallback onToggleMode;

  const _ControlsBar({
    required this.smartMode,
    required this.onToggleMode,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(claudeConfigProvider);
    final mode = config.permissionMode;
    final modeColor = Color(mode.colorValue);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: context.rSpacing * 1.5, vertical: context.rSpacing * 0.75),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(
          top: BorderSide(
            color: AppTheme.divider.withValues(alpha: 0.2),
            width: 0.5,
          ),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // Permission mode
            _ControlPill(
              icon: mode.icon,
              label: mode.label,
              color: modeColor,
              onTap: () => _showModePicker(context, ref, mode),
            ),

            SizedBox(width: context.rSpacing * 2),

            // Smart/Terminal toggle
            _ControlPill(
              icon: smartMode ? Icons.auto_awesome : Icons.terminal,
              label: smartMode ? 'Smart' : 'Terminal',
              color: smartMode ? AppTheme.primary : AppTheme.textSecondary,
              onTap: () {
                HapticFeedback.selectionClick();
                onToggleMode();
              },
            ),

            SizedBox(width: context.rSpacing),

            // Browser tunnel toggle
            Consumer(
              builder: (context, ref, child) {
                final tunnel = ref.watch(httpTunnelProvider);
                return _ControlPill(
                  icon: tunnel.isActive ? Icons.stop_circle : Icons.web,
                  label: tunnel.isActive ? 'Close Tunnel' : 'Browser',
                  color: tunnel.isActive ? Colors.red : AppTheme.textSecondary,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    if (tunnel.isActive) {
                      ref.read(httpTunnelProvider.notifier).requestClose();
                    } else {
                      ref.read(httpTunnelProvider.notifier).requestOpen(tunnel.lastTargetPort);
                    }
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showModePicker(BuildContext context, WidgetRef ref, PermissionMode current) {
    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: EdgeInsets.only(top: context.rSpacing * 1.5, bottom: context.rSpacing),
                width: context.rValue(mobile: 40.0, tablet: 48.0),
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.textMuted.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: EdgeInsets.all(context.rHorizontalPadding),
                child: Text(
                  'Permission Mode',
                  style: TextStyle(
                    fontSize: context.rFontSize(mobile: 16, tablet: 18),
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
              for (final m in PermissionMode.switchable)
                _PermissionModeOption(
                  mode: m,
                  isActive: m == current,
                  onTap: () {
                    if (m != current) {
                      HapticFeedback.mediumImpact();
                      ref.read(claudeConfigProvider.notifier).setPermissionMode(m);
                      ref.read(chatProvider.notifier).sendCommandSilent('permissions', args: 'set ${m.cliValue}');
                    }
                    Navigator.pop(ctx);
                  },
                ),
              SizedBox(height: context.rSpacing),
            ],
          ),
        ),
      ),
    );
  }
}

class _ControlPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ControlPill({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: context.rSpacing * 1.25, vertical: context.rSpacing * 0.625),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: context.rValue(mobile: 14.0, tablet: 16.0), color: color),
            SizedBox(width: context.rSpacing * 0.625),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: context.captionFontSize,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            SizedBox(width: context.rSpacing * 0.25),
            Icon(Icons.expand_more_rounded, size: context.rValue(mobile: 14.0, tablet: 16.0), color: color.withValues(alpha: 0.6)),
          ],
        ),
      ),
    );
  }
}

class _PermissionModeOption extends StatelessWidget {
  final PermissionMode mode;
  final bool isActive;
  final VoidCallback onTap;

  const _PermissionModeOption({
    required this.mode,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = Color(mode.colorValue);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding, vertical: context.rSpacing * 1.75),
          child: Row(
            children: [
              Container(
                width: context.rValue(mobile: 36.0, tablet: 44.0),
                height: context.rValue(mobile: 36.0, tablet: 44.0),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(mode.icon, size: context.rValue(mobile: 18.0, tablet: 20.0), color: color),
              ),
              SizedBox(width: context.rSpacing * 1.5),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mode.label,
                      style: TextStyle(
                        fontSize: context.bodyFontSize,
                        fontWeight: FontWeight.w600,
                        color: isActive ? color : AppTheme.textPrimary,
                      ),
                    ),
                    Text(
                      mode.description,
                      style: TextStyle(
                        fontSize: context.captionFontSize,
                        color: isActive
                            ? color.withValues(alpha: 0.7)
                            : AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (isActive)
                Icon(Icons.check_rounded, size: context.rIconSize, color: color),
            ],
          ),
        ),
      ),
    );
  }
}

/// Handoff observer banner — shown when session is on computer.
class _HandoffBanner extends StatelessWidget {
  final VoidCallback onTakeBack;

  const _HandoffBanner({required this.onTakeBack});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: context.rHorizontalPadding,
        vertical: context.rSpacing * 1.5,
      ),
      color: const Color(0xFFA78BFA).withValues(alpha: 0.12),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                Icons.computer_rounded,
                size: context.rValue(mobile: 20.0, tablet: 24.0),
                color: const Color(0xFFA78BFA),
              ),
              SizedBox(width: context.rSpacing),
              Expanded(
                child: Text(
                  'Session on computer',
                  style: TextStyle(
                    fontSize: context.bodyFontSize,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFFA78BFA),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: context.rSpacing),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                HapticFeedback.mediumImpact();
                onTakeBack();
              },
              icon: Icon(
                Icons.phone_android_rounded,
                size: context.rValue(mobile: 18.0, tablet: 20.0),
              ),
              label: Text(
                'Take Back Control',
                style: TextStyle(fontSize: context.bodyFontSize),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFA78BFA),
                foregroundColor: Colors.white,
                padding: EdgeInsets.symmetric(vertical: context.rSpacing * 1.25),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Connection status banner (error / offline).
class _ConnectionBanner extends StatelessWidget {
  final String text;
  final IconData icon;

  const _ConnectionBanner({
    this.text = 'Connection lost. Trying to reconnect...',
    this.icon = Icons.wifi_off_rounded,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(vertical: context.rSpacing * 1.25, horizontal: context.rHorizontalPadding),
      color: AppTheme.error.withValues(alpha: 0.1),
      child: Row(
        children: [
          Icon(
            icon,
            size: context.rValue(mobile: 18.0, tablet: 24.0),
            color: AppTheme.error,
          ),
          SizedBox(width: context.rSpacing * 1.25),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: context.captionFontSize,
                color: AppTheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}


/// Empty state when no messages.
class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final iconSize = context.rValue(mobile: 72.0, tablet: 96.0);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: iconSize,
            height: iconSize,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              boxShadow: AppTheme.glowShadow,
            ),
            clipBehavior: Clip.antiAlias,
            child: Image.asset(
              'assets/images/app_icon.png',
              fit: BoxFit.cover,
            ),
          ),
          SizedBox(height: context.rSpacing * 3),
          Text(
            'Connected to Claude',
            style: TextStyle(
              fontSize: context.titleFontSize,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          SizedBox(height: context.rSpacing),
          Text(
            'Messages will appear here',
            style: TextStyle(
              fontSize: context.bodyFontSize,
              color: AppTheme.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// Message list widget.
class _MessageList extends StatelessWidget {
  /// All messages (unfiltered) — used for thinking progress lookup.
  final List<Message> messages;
  /// Pre-filtered messages from the provider (avoids O(n) filter per build).
  final List<Message> filteredMessages;
  final ScrollController scrollController;
  final bool smartMode;
  final bool Function(String id) isMessageQueued;
  final void Function(String text)? onSendMessage;

  const _MessageList({
    required this.messages,
    required this.filteredMessages,
    required this.scrollController,
    required this.smartMode,
    required this.isMessageQueued,
    this.onSendMessage,
  });

  @override
  Widget build(BuildContext context) {
    // Use pre-filtered list from the provider instead of inline O(n) filter.
    final filtered = List<Message>.of(filteredMessages);

    // When Claude is thinking, include the last text message as
    // a compact progress line below the spinner. Works in both modes.
    final hasThinking = filtered.any(
        (m) => m.type == MessageType.thinking);
    if (hasThinking) {
      Message? lastText;
      for (final m in messages.reversed) {
        if (m.type == MessageType.text &&
            m.sender == MessageSender.claude &&
            m.content.trim().isNotEmpty) {
          lastText = m;
          break;
        }
      }
      if (lastText != null) {
        final thinkingIdx = filtered.indexWhere(
            (m) => m.type == MessageType.thinking);
        if (thinkingIdx >= 0) {
          final progressMsg = lastText.copyWith(
            id: 'progress_${lastText.id}',
          );
          filtered.insert(thinkingIdx + 1, progressMsg);
        }
      }
    }
    final displayMessages = filtered;

    if (displayMessages.isEmpty && smartMode) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(context.rSpacing * 4),
          child: Text(
            'Waiting for Claude to use tools...\nSwitch to terminal view to see raw output.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: context.bodyFontSize,
            ),
          ),
        ),
      );
    }

    // Group consecutive tool use messages (2+) into collapsible groups.
    final groupedItems = <_ListItem>[];
    int i = 0;
    while (i < displayMessages.length) {
      if (smartMode && displayMessages[i].type == MessageType.toolUse) {
        // Collect consecutive tool use messages
        final toolGroup = <Message>[displayMessages[i]];
        int j = i + 1;
        while (j < displayMessages.length &&
            displayMessages[j].type == MessageType.toolUse) {
          toolGroup.add(displayMessages[j]);
          j++;
        }
        if (toolGroup.length >= 2) {
          groupedItems.add(_ListItem.group(toolGroup));
        } else {
          groupedItems.add(_ListItem.single(toolGroup.first));
        }
        i = j;
      } else {
        groupedItems.add(_ListItem.single(displayMessages[i]));
        i++;
      }
    }

    return ListView.builder(
      controller: scrollController,
      reverse: true,
      padding: EdgeInsets.symmetric(
        horizontal: smartMode ? context.rHorizontalPadding : context.rSpacing,
        vertical: context.rSpacing * 2,
      ),
      itemCount: groupedItems.length,
      itemBuilder: (context, index) {
        final item = groupedItems[groupedItems.length - 1 - index];
        if (item.isGroup) {
          return Padding(
            padding: EdgeInsets.only(bottom: context.rSpacing),
            child: _ToolGroup(
              messages: item.messages,
              smartMode: smartMode,
              onSendMessage: onSendMessage,
            ),
          );
        }
        return Padding(
          padding: EdgeInsets.only(bottom: context.rSpacing),
          child: MessageBubble(
            message: item.message!,
            smartMode: smartMode,
            isQueued: isMessageQueued(item.message!.id),
            onSendMessage: onSendMessage,
          ),
        );
      },
    );
  }
}

/// Represents either a single message or a group of tool use messages.
class _ListItem {
  final Message? message;
  final List<Message> messages;
  final bool isGroup;

  _ListItem.single(Message msg) : message = msg, messages = [msg], isGroup = false;
  _ListItem.group(this.messages) : message = null, isGroup = true;
}

/// Collapsible group of tool use cards.
class _ToolGroup extends StatefulWidget {
  final List<Message> messages;
  final bool smartMode;
  final void Function(String text)? onSendMessage;

  const _ToolGroup({
    required this.messages,
    required this.smartMode,
    this.onSendMessage,
  });

  @override
  State<_ToolGroup> createState() => _ToolGroupState();
}

class _ToolGroupState extends State<_ToolGroup> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final count = widget.messages.length;

    // Build summary of tool types
    final toolCounts = <String, int>{};
    for (final m in widget.messages) {
      final name = m.toolName ?? 'Tool';
      toolCounts[name] = (toolCounts[name] ?? 0) + 1;
    }
    final summary = toolCounts.entries
        .map((e) => '${e.value} ${e.key}')
        .join(', ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Group header
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: context.rSpacing * 1.5,
              vertical: context.rSpacing * 1.25,
            ),
            decoration: BoxDecoration(
              color: AppTheme.surfaceLight.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppTheme.divider.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.build_rounded,
                  size: context.rValue(mobile: 16.0, tablet: 18.0),
                  color: AppTheme.primary,
                ),
                SizedBox(width: context.rSpacing),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$count tool operations',
                        style: TextStyle(
                          fontSize: context.captionFontSize,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      SizedBox(height: context.rSpacing * 0.125),
                      Text(
                        summary,
                        style: TextStyle(
                          fontSize: context.rFontSize(mobile: 11, tablet: 13),
                          color: AppTheme.textMuted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: context.rValue(mobile: 18.0, tablet: 22.0),
                  color: AppTheme.textMuted,
                ),
              ],
            ),
          ),
        ),
        // Expanded tool cards
        if (_expanded)
          ...widget.messages.map((msg) => Padding(
                padding: EdgeInsets.only(top: context.rSpacing * 0.5),
                child: MessageBubble(
                  message: msg,
                  smartMode: widget.smartMode,
                  onSendMessage: widget.onSendMessage,
                ),
              )),
      ],
    );
  }
}

/// Menu bottom sheet.
class _MenuSheet extends StatelessWidget {
  final VoidCallback onFiles;
  final VoidCallback onSettings;
  final VoidCallback onDisconnect;
  final VoidCallback onClearChat;
  final VoidCallback onOpenFolder;

  const _MenuSheet({
    required this.onFiles,
    required this.onSettings,
    required this.onDisconnect,
    required this.onClearChat,
    required this.onOpenFolder,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              margin: EdgeInsets.only(top: context.rSpacing * 1.5, bottom: context.rSpacing),
              width: context.rValue(mobile: 40.0, tablet: 48.0),
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.textMuted.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            _MenuItem(icon: Icons.file_copy_rounded, label: 'Files', onTap: onFiles),
            _MenuItem(icon: Icons.folder_open_rounded, label: 'Open Remote Folder', onTap: onOpenFolder),
            _MenuItem(icon: Icons.tune_rounded, label: 'Settings', onTap: onSettings),
            _MenuItem(icon: Icons.delete_outline_rounded, label: 'Clear Chat', onTap: onClearChat),
            _MenuItem(icon: Icons.logout_rounded, label: 'Disconnect', color: AppTheme.error, onTap: onDisconnect),

            SizedBox(height: context.rSpacing * 2),
          ],
        ),
      ),
    );
  }
}

/// Files history bottom sheet — shows all received files.
class _FilesHistorySheet extends StatelessWidget {
  final List<Message> files;

  const _FilesHistorySheet({required this.files});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.6,
      ),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              margin: EdgeInsets.only(top: context.rSpacing * 1.5, bottom: context.rSpacing),
              width: context.rValue(mobile: 40.0, tablet: 48.0),
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.textMuted.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 2, vertical: context.rSpacing),
              child: Row(
                children: [
                  Text(
                    'Files',
                    style: TextStyle(
                      fontSize: context.bodyFontSize,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  if (files.isNotEmpty)
                    Container(
                      padding: EdgeInsets.symmetric(
                          horizontal: context.rSpacing, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.brandCyan.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${files.length}',
                        style: TextStyle(
                          fontSize: context.rFontSize(mobile: 13, tablet: 15),
                          fontWeight: FontWeight.w600,
                          color: AppTheme.brandCyan,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(height: context.rSpacing * 0.5),
            if (files.isEmpty)
              Padding(
                padding: EdgeInsets.all(context.rSpacing * 4),
                child: Text(
                  'No files yet',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: context.bodyFontSize),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.only(bottom: context.rSpacing * 2),
                  itemCount: files.length,
                  itemBuilder: (context, index) =>
                      _FileHistoryTile(file: files[index]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Single file row in the history sheet.
class _FileHistoryTile extends StatelessWidget {
  final Message file;

  const _FileHistoryTile({required this.file});

  @override
  Widget build(BuildContext context) {
    final success = file.transferSuccess == true;
    final timeAgo = _timeAgo(file.timestamp);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 2, vertical: context.rSpacing),
      child: Row(
        children: [
          Container(
            width: context.rValue(mobile: 36.0, tablet: 44.0),
            height: context.rValue(mobile: 36.0, tablet: 44.0),
            decoration: BoxDecoration(
              color: (success ? Colors.green : AppTheme.error)
                  .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              success
                  ? Icons.insert_drive_file_rounded
                  : Icons.error_rounded,
              size: context.rIconSize,
              color: success ? Colors.green : AppTheme.error,
            ),
          ),
          SizedBox(width: context.rSpacing * 1.5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  file.fileName ?? 'Unknown file',
                  style: TextStyle(
                    fontSize: context.bodyFontSize,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${_formatSize(file.fileSize ?? 0)} · $timeAgo',
                  style: TextStyle(
                      fontSize: context.captionFontSize, color: AppTheme.textMuted),
                ),
              ],
            ),
          ),
          if (success && file.localFilePath != null) ...[
            IconButton(
              icon: Icon(Icons.share_rounded, size: context.rIconSize),
              color: AppTheme.textSecondary,
              onPressed: () {
                HapticFeedback.selectionClick();
                SharePlus.instance.share(ShareParams(files: [XFile(file.localFilePath!)]));
              },
            ),
            IconButton(
              icon: Icon(Icons.open_in_new_rounded, size: context.rIconSize),
              color: Colors.green,
              onPressed: () {
                HapticFeedback.mediumImpact();
                final type = lookupMimeType(file.localFilePath!) ?? 'application/octet-stream';
                OpenFilex.open(file.localFilePath!, type: type);
              },
            ),
          ],
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _timeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

/// Menu item widget.
class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final itemColor = color ?? AppTheme.textPrimary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.rHorizontalPadding * 2,
            vertical: context.rSpacing * 2,
          ),
          child: Row(
            children: [
              Icon(icon, color: itemColor, size: context.rValue(mobile: 22.0, tablet: 28.0)),
              SizedBox(width: context.rSpacing * 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: context.bodyFontSize,
                  color: itemColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
