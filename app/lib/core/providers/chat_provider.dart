import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/connection_state.dart';
import '../../models/message.dart';
import '../../models/session_live_state.dart';
import '../models/session_capabilities.dart';
import '../platform/security_channel.dart';
import 'active_agents_provider.dart';
import 'active_tasks_provider.dart';
import 'active_transfers_provider.dart';
import 'claude_config_provider.dart';
import 'connection_provider.dart';
import 'extensions_provider.dart';
import 'live_state_provider.dart';
import 'memory_provider.dart';
import 'http_tunnel_provider.dart';
import 'session_picker_provider.dart';
import 'session_provider.dart';

/// Riverpod provider for the chat message list.
final chatProvider =
    NotifierProvider<ChatNotifier, List<Message>>(ChatNotifier.new);

/// Manages the in-memory list of chat messages and coordinates with
/// the native layer for sending / receiving.
///
/// Messages arrive via the [SecurityChannel.messages] event stream
/// (already decrypted by native code) and are added to state.
/// Outgoing messages are first added locally for instant UI feedback,
/// then forwarded to the native layer which encrypts and transmits them.
///
/// Maintains per-session message lists so multiple sessions don't mix.
/// Tracks an in-progress file receive from the computer.
class _FileReceiveState {
  final String transferId;
  final String filename;
  final String mimeType;
  final int totalChunks;
  final Map<int, String> chunks = {};

  _FileReceiveState({
    required this.transferId,
    required this.filename,
    required this.mimeType,
    required this.totalChunks,
  });

  void addChunk(int sequence, String data) {
    chunks[sequence] = data;
  }

  bool get isComplete => chunks.length >= totalChunks;

  double get progress => totalChunks > 0 ? chunks.length / totalChunks : 0;

  /// Assemble all chunks into raw bytes.
  List<int> assemble() {
    // Use actual chunk keys — not the estimated count — so we never
    // skip chunks if the estimate was slightly off.
    final keys = chunks.keys.toList()..sort();
    final buffer = <int>[];
    for (final seq in keys) {
      buffer.addAll(base64Decode(chunks[seq]!));
    }
    return buffer;
  }
}

class ChatNotifier extends Notifier<List<Message>> {
  final SecurityChannel _security = SecurityChannel();
  StreamSubscription<Map<String, dynamic>>? _subscription;

  /// Pre-compiled ANSI-cleaning regexes (avoid re-compilation per call)
  static final _ansiEscapeRe = RegExp(
    r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])',
    multiLine: true,
  );
  static final _ansiOscRe = RegExp(r'\x1B\][^\x07]*\x07', multiLine: true);
  static final _controlCharsRe = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]');

  /// Monotonic counter to avoid message ID collisions on fast devices.
  static int _msgIdCounter = 0;

  /// Active file receives from computer, scoped per session.
  /// Outer key = sessionId, inner key = transferId.
  final Map<String, Map<String, _FileReceiveState>> _fileReceives = {};

  /// Per-session message storage.
  final Map<String, List<Message>> _sessionMessages = {};

  /// Per-session config storage (model, permission mode, permission rules).
  final Map<String, ClaudeConfigState> _sessionConfigs = {};

  /// Per-session extensions storage (plugins, skills, rules).
  final Map<String, ExtensionsState> _sessionExtensions = {};

  /// Per-session memory storage (CLAUDE.md entries).
  final Map<String, List<MemoryEntry>> _sessionMemory = {};

  /// Currently active session ID for routing incoming messages.
  String? _activeSessionId;

  /// Index of the current thinking message in the active session (or -1).
  int _thinkingIndex = -1;

  /// Capabilities reported by the active Claude Code session (stream-json).
  SessionCapabilities? _sessionCapabilities;
  SessionCapabilities? get sessionCapabilities => _sessionCapabilities;

  /// Whether the current session is handed off to the computer.
  bool _handedOff = false;
  bool get handedOff => _handedOff;

  /// Whether the bridge peer is currently reachable (for queue detection).
  /// Tracked from relay peer events, not WS-to-relay connectionState.
  /// Starts true (optimistic — avoids false clock on first message before
  /// any relay event arrives).
  bool _peerConnected = true;

  /// Per-session message IDs that were queued (sent while offline).
  final Map<String, Set<String>> _queuedMessageIds = {};

  /// Check if a message is currently queued (sent offline, awaiting replay).
  bool isMessageQueued(String id) {
    final sid = _activeSessionId;
    if (sid == null) return false;
    return _queuedMessageIds[sid]?.contains(id) ?? false;
  }

  /// Session ID currently being loaded from disk during session switch.
  /// Only events for THIS session are suppressed; background sessions pass through.
  String? _loadingSessionId;

  /// Monotonically increasing generation counter for session switches.
  /// Used to detect when a newer setActiveSession call has superseded us.
  int _sessionSwitchGeneration = 0;

  /// Coalescing flag for _syncState microtask batching.
  bool _syncPending = false;

  /// Debounce timer for persisting messages.
  Timer? _persistTimer;

  @override
  List<Message> build() {
    // Sync session list when connection state changes from ANY source
    // (relay events, bridge data, OR optimistic timeout).
    // markConnected/markDisconnected have early-return guards for dedup.
    ref.listen<ConnectionStatus>(connectionProvider, (prev, next) {
      final connectionNotifier = ref.read(connectionProvider.notifier);
      final sessionNotifier = ref.read(sessionProvider.notifier);
      final sessionId = connectionNotifier.currentSessionId;
      if (sessionId == null) return;
      if (next == ConnectionStatus.connected && prev != ConnectionStatus.connected) {
        sessionNotifier.markConnected(sessionId);
      } else if (next == ConnectionStatus.disconnected && prev == ConnectionStatus.connected) {
        sessionNotifier.markDisconnected(sessionId);
      }
    });

    ref.onDispose(() {
      _persistTimer?.cancel();
      for (final timer in _bgPersistTimers.values) {
        timer.cancel();
      }
      _bgPersistTimers.clear();
      _subscription?.cancel();
    });

    _listenToMessages();
    return [];
  }

  // ---------------------------------------------------------------------------
  // Notifier accessors (read sibling providers via ref)
  // ---------------------------------------------------------------------------

  ConnectionNotifier get _connectionNotifier =>
      ref.read(connectionProvider.notifier);
  SessionNotifier get _sessionNotifier =>
      ref.read(sessionProvider.notifier);
  ActiveAgentsNotifier get _activeAgentsNotifier =>
      ref.read(activeAgentsProvider.notifier);
  ActiveTasksNotifier get _activeTasksNotifier =>
      ref.read(activeTasksProvider.notifier);
  ActiveTransfersNotifier get _activeTransfersNotifier =>
      ref.read(activeTransfersProvider.notifier);
  ClaudeConfigNotifier get _claudeConfigNotifier =>
      ref.read(claudeConfigProvider.notifier);
  SessionPickerNotifier get _sessionPickerNotifier =>
      ref.read(sessionPickerProvider.notifier);
  ExtensionsNotifier get _extensionsNotifier =>
      ref.read(extensionsProvider.notifier);
  MemoryNotifier get _memoryNotifier =>
      ref.read(memoryProvider.notifier);
  LiveStateNotifier get _liveStateNotifier =>
      ref.read(liveStateProvider.notifier);
  HttpTunnelNotifier get _httpTunnelNotifier =>
      ref.read(httpTunnelProvider.notifier);

  // ---------------------------------------------------------------------------
  // Callbacks (previously passed via constructor, now use ref directly)
  // ---------------------------------------------------------------------------

  void _onConnectionStateChanged(String stateStr, String? sessionId) {
    try {
      // Only update global connection indicator for the active session.
      if (sessionId != null && sessionId != _connectionNotifier.currentSessionId) {
        if (stateStr != 'disconnected' && stateStr != 'error' && stateStr != 'failed') {
          debugPrint('[Connection] SKIP connectionState $stateStr: event=$sessionId != active=${_connectionNotifier.currentSessionId}');
          return;
        }
      }
      debugPrint('[Connection] APPLY connectionState $stateStr for session=$sessionId');
      switch (stateStr) {
        case 'connected':
          _connectionNotifier.setPeerConnected();
          break;
        case 'disconnected':
        case 'error':
        case 'failed':
          _connectionNotifier.setPeerDisconnected();
          break;
        case 'reconnecting':
          _connectionNotifier.setReconnecting();
          break;
        case 'connecting':
          _connectionNotifier.setConnecting();
          break;
      }
    } catch (_) {
      // Widget may be defunct during session transitions
    }
  }

  void _onNetworkStateChanged(bool isReachable, String transport) {
    try {
      _connectionNotifier.setNetworkState(
        isReachable: isReachable, transport: transport);
    } catch (_) {
      // Widget may be defunct during session transitions
    }
  }

  void _onPeerOnline(String? sessionId) {
    try {
      final effectiveId = sessionId ?? _connectionNotifier.currentSessionId;
      // Only update global connection indicator for the active session.
      // Background session peer events update session list only.
      if (effectiveId == null || effectiveId == _connectionNotifier.currentSessionId) {
        _connectionNotifier.setPeerConnected();
      }
      if (effectiveId != null) {
        _sessionNotifier.markConnected(effectiveId);
      }
    } catch (_) {
      // Widget may be defunct during session transitions
    }
  }

  void _onPeerOffline(String? sessionId) {
    try {
      final effectiveId = sessionId ?? _connectionNotifier.currentSessionId;
      // Only update global connection indicator for the active session.
      if (effectiveId == null || effectiveId == _connectionNotifier.currentSessionId) {
        _connectionNotifier.setPeerDisconnected();
      }
      if (effectiveId != null) {
        _sessionNotifier.markDisconnected(effectiveId);
      }
    } catch (_) {
      // Widget may be defunct during session transitions
    }
  }

  /// Set the active session. Incoming messages will be routed to this
  /// session's list, and [state] will reflect that list.
  ///
  /// Loads persisted messages from disk if they haven't been loaded yet.
  ///
  /// Note: the native layer maintains per-session WebSockets, so incoming
  /// messages on [SecurityChannel.messages] are stamped with the sessionId
  /// they belong to. Background session messages are routed automatically.
  Future<void> setActiveSession(String sessionId) async {
    debugPrint('[Session] setActiveSession: $_activeSessionId → $sessionId');
    final generation = ++_sessionSwitchGeneration;
    _peerConnected = true; // Optimistic — will be corrected by relay events

    // Clear stale UI state IMMEDIATELY — before any async work.
    // Otherwise the old transfers/agents bar flashes until async completes.
    try {
      _activeAgentsNotifier.clear();
      _activeTasksNotifier.clear();
      _activeTransfersNotifier.clear();
    } catch (_) {
      // Don't let provider cleanup break session setup
    }

    // Flush any pending persist for the previous session before switching
    if (_activeSessionId != null && _activeSessionId != sessionId) {
      _persistTimer?.cancel();
      await _persistMessages(_activeSessionId!);
      if (_sessionSwitchGeneration != generation) return; // Superseded by newer switch

      // Save outgoing session's config/extensions/memory
      _saveSessionConfig(_activeSessionId!);
    }

    // Load from disk with a loading flag so incoming messages are
    // suppressed during the async gap, without nulling _activeSessionId
    // (which would break callbacks that read it).
    if (!_sessionMessages.containsKey(sessionId)) {
      _loadingSessionId = sessionId;
      await _loadMessages(sessionId);
      if (_sessionSwitchGeneration != generation) {
        _loadingSessionId = null;
        return; // Superseded by newer switch
      }
      _loadingSessionId = null;
    }

    _activeSessionId = sessionId;
    _thinkingIndex = -1;
    _sessionMessages.putIfAbsent(sessionId, () => []);
    state = List.from(_sessionMessages[sessionId]!);

    // Reset handoff state on session switch. The bridge will re-send
    // HandoffActive (or StateSnapshot with handed_off) if the new session
    // is handed off, restoring the correct state. The bridge-side guard
    // (C2 fix) protects against text sent during the brief transition.
    _handedOff = false;

    // Restore incoming session's config/extensions/memory to global providers
    _restoreSessionConfig(sessionId);

    debugPrint('[Session] setActiveSession: complete, active=$_activeSessionId '
        '(${_sessionMessages[sessionId]!.length} messages loaded)');
  }

  /// Remove stale thinking indicator from the active session.
  ///
  /// Called on app resume — if Claude is still thinking, the bridge will
  /// resend a fresh Thinking message after reconnect.
  void clearStaleThinking() {
    _clearThinkingIndicator();
    _syncState();
  }

  void _clearThinkingIndicator() {
    if (_activeSessionId == null) return;
    final msgs = _sessionMessages[_activeSessionId!];
    if (msgs != null &&
        _thinkingIndex >= 0 && _thinkingIndex < msgs.length &&
        msgs[_thinkingIndex].type == MessageType.thinking) {
      msgs.removeAt(_thinkingIndex);
    }
    _thinkingIndex = -1;
  }

  /// Sync [state] from the active session's message list and schedule persist.
  ///
  /// Uses a coalescing flag so that rapid bursts of updates (e.g. streaming
  /// responses) collapse into a single microtask instead of creating one
  /// per message.
  void _syncState() {
    if (_activeSessionId != null &&
        _sessionMessages.containsKey(_activeSessionId)) {
      final newState = List<Message>.from(_sessionMessages[_activeSessionId]!);
      final hasAction = newState.any((m) => m.type == MessageType.action && !(m.action?.responded ?? true));
      if (hasAction) debugPrint('[_syncState] HAS PENDING ACTION, ${newState.length} msgs');
      try {
        state = newState;
        if (hasAction) debugPrint('[_syncState] state SET ok (${newState.length} msgs)');
      } catch (e) {
        if (hasAction) debugPrint('[_syncState] CAUGHT $e — scheduling microtask (pending=$_syncPending)');
        // Called during build phase — coalesce into single microtask
        if (!_syncPending) {
          _syncPending = true;
          Future.microtask(() {
            _syncPending = false;
            if (_activeSessionId != null &&
                _sessionMessages.containsKey(_activeSessionId)) {
              final latest = List<Message>.from(_sessionMessages[_activeSessionId]!);
              final hasAct = latest.any((m) => m.type == MessageType.action && !(m.action?.responded ?? true));
              if (hasAct) debugPrint('[_syncState] microtask: setting state with action (${latest.length} msgs)');
              try {
                state = latest;
              } catch (_) {}
            }
          });
        }
      }
      _schedulePersist();
    }
  }

  /// Pre-computed filtered messages (excludes terminal-parsed output in smart mode).
  /// Call with the current smartMode setting from the UI.
  List<Message> filteredMessages(bool smartMode) {
    if (!smartMode) return state;
    return state.where((msg) {
      if (msg.sender == MessageSender.user) return true;
      if (msg.type == MessageType.system) return true;
      if (msg.type == MessageType.toolUse) return true;
      if (msg.type == MessageType.action) return true;
      if (msg.type == MessageType.askQuestion) return true;
      if (msg.type == MessageType.claudeResponse) return true;
      if (msg.type == MessageType.thinking) return true;
      if (msg.type == MessageType.fileComplete) return true;
      return false;
    }).toList();
  }

  // -------------------------------------------------------------------------
  // Per-session config isolation
  // -------------------------------------------------------------------------

  /// Save current global provider state into per-session storage.
  void _saveSessionConfig(String sessionId) {
    try {
      _sessionConfigs[sessionId] = _claudeConfigNotifier.state;
      _sessionExtensions[sessionId] = _extensionsNotifier.state;
      _sessionMemory[sessionId] = List.from(_memoryNotifier.state);
    } catch (_) {
      // Provider may be defunct during transitions
    }
  }

  /// Restore per-session config to global providers, or clear if unknown.
  void _restoreSessionConfig(String sessionId) {
    try {
      final config = _sessionConfigs[sessionId];
      if (config != null) {
        _claudeConfigNotifier.setModelFromId(config.selectedModel.id);
        _claudeConfigNotifier.setPermissionMode(config.permissionMode);
        _claudeConfigNotifier.setPermissionRules(
          config.permissionAllowRules,
          config.permissionDenyRules,
        );
      } else {
        // Unknown session — reset to defaults until bridge sends ConfigSync
        _claudeConfigNotifier.setModelFromId('opus');
        _claudeConfigNotifier.setPermissionModeFromCli('default');
        _claudeConfigNotifier.setPermissionRules([], []);
      }

      final extensions = _sessionExtensions[sessionId];
      if (extensions != null) {
        _extensionsNotifier.setPlugins(extensions.plugins);
        _extensionsNotifier.setSkills(extensions.skills);
        _extensionsNotifier.setRules(extensions.rules);
      } else {
        _extensionsNotifier.clear();
      }

      final memory = _sessionMemory[sessionId];
      if (memory != null) {
        _memoryNotifier.setEntries(memory);
      } else {
        _memoryNotifier.clear();
      }
    } catch (_) {
      // Provider may be defunct during transitions
    }
  }

  /// Store metadata from a background session in per-session maps.
  /// Returns true if the message was handled (caller should stop processing).
  bool _storeBackgroundMetadata(
    String sessionId,
    String msgType,
    Map<String, dynamic> payload,
  ) {
    switch (msgType) {
      case 'ConfigSync':
        var config = _sessionConfigs[sessionId] ?? const ClaudeConfigState();
        final model = payload['model'] as String?;
        final permMode = payload['permission_mode'] as String?;
        if (model != null) {
          final m = ClaudeModel.fromId(model);
          if (m != null) config = config.copyWith(selectedModel: m);
        }
        if (permMode != null) {
          config = config.copyWith(permissionMode: PermissionMode.fromCli(permMode));
        }
        _sessionConfigs[sessionId] = config;
        return true;

      case 'PermissionRulesSync':
        var config = _sessionConfigs[sessionId] ?? const ClaudeConfigState();
        final allow = (payload['allow'] as List?)?.map((e) => e.toString()).toList() ?? [];
        final deny = (payload['deny'] as List?)?.map((e) => e.toString()).toList() ?? [];
        _sessionConfigs[sessionId] = config.copyWith(
          permissionAllowRules: allow,
          permissionDenyRules: deny,
        );
        return true;

      case 'PluginList':
        final plugins = (payload['plugins'] as List<dynamic>? ?? [])
            .map((p) => InstalledPlugin.fromMap(
                p is Map ? _convertToStringDynamicMap(p) : <String, dynamic>{}))
            .where((p) => p.id.isNotEmpty)
            .toList();
        final ext = _sessionExtensions[sessionId] ?? const ExtensionsState();
        _sessionExtensions[sessionId] = ext.copyWith(plugins: plugins);
        return true;

      case 'SkillList':
        final skills = (payload['skills'] as List<dynamic>? ?? [])
            .map((s) => ClaudeSkill.fromMap(
                s is Map ? _convertToStringDynamicMap(s) : <String, dynamic>{}))
            .where((s) => s.name.isNotEmpty)
            .toList();
        final ext = _sessionExtensions[sessionId] ?? const ExtensionsState();
        _sessionExtensions[sessionId] = ext.copyWith(skills: skills);
        return true;

      case 'RulesList':
        final rules = (payload['rules'] as List<dynamic>? ?? [])
            .map((r) => ClaudeRule.fromMap(
                r is Map ? _convertToStringDynamicMap(r) : <String, dynamic>{}))
            .where((r) => r.filename.isNotEmpty)
            .toList();
        final ext = _sessionExtensions[sessionId] ?? const ExtensionsState();
        _sessionExtensions[sessionId] = ext.copyWith(rules: rules);
        return true;

      case 'MemoryContent':
        final entries = (payload['entries'] as List<dynamic>? ?? [])
            .map((e) => MemoryEntry.fromMap(
                e is Map ? _convertToStringDynamicMap(e) : <String, dynamic>{}))
            .where((e) => e.content.isNotEmpty)
            .toList();
        _sessionMemory[sessionId] = entries;
        return true;

      case 'SessionCapabilities':
        // Session capabilities are per-session but we only track the active one
        return true;

      default:
        return false;
    }
  }

  // -------------------------------------------------------------------------
  // Persistence
  // -------------------------------------------------------------------------

  static const _msgPrefix = 'chat_messages_';

  /// Load persisted messages for a session from SharedPreferences.
  Future<void> _loadMessages(String sessionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList('$_msgPrefix$sessionId');
      if (raw == null || raw.isEmpty) return;

      final messages = raw
          .map((json) {
            try {
              return Message.fromJson(
                jsonDecode(json) as Map<String, dynamic>,
              );
            } catch (_) {
              return null;
            }
          })
          .whereType<Message>()
          // Strip orphaned thinking messages (transient, should never persist)
          .where((m) => m.type != MessageType.thinking)
          .toList();

      _sessionMessages[sessionId] = messages;
    } catch (_) {
      // Ignore load errors — start with empty list
    }
  }

  /// Schedule a debounced persist (avoids excessive writes during rapid updates).
  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(seconds: 1), () {
      if (_activeSessionId != null) {
        _persistMessages(_activeSessionId!);
      }
    });
  }

  /// Persist messages for a session to SharedPreferences.
  Future<void> _persistMessages(String sessionId) async {
    try {
      final messages = _sessionMessages[sessionId];
      if (messages == null) return;

      // Keep only the last 200 messages to avoid storage bloat.
      // Exclude thinking messages — they're transient UI state.
      final filtered = messages.where((m) => m.type != MessageType.thinking).toList();
      final toSave = filtered.length > 200
          ? filtered.sublist(filtered.length - 200)
          : filtered;

      final prefs = await SharedPreferences.getInstance();
      final raw = toSave.map((m) => jsonEncode(m.toJson())).toList();
      await prefs.setStringList('$_msgPrefix$sessionId', raw);
    } catch (_) {
      // Ignore persist errors
    }
  }

  // -------------------------------------------------------------------------
  // Incoming
  // -------------------------------------------------------------------------

  void _listenToMessages() {
    _subscription = _security.messages.listen(
      (data) => _handleIncoming(data),
      onError: (Object error) {
        _addSystemMessage('Connection error');
      },
      onDone: () {},
    );
  }

  /// Track last message time per session for aggregation.
  final Map<String, DateTime> _lastMessageTimes = {};

  void _handleIncoming(Map<String, dynamic> data) {
    try {
      final eventType = data['type'] as String?;

      if (eventType == 'connectionState') {
        final stateStr = data['state'] as String?;
        final sessionId = data['sessionId'] as String?;
        debugPrint('[Chat] connectionState event: state=$stateStr session=$sessionId');
        if (stateStr != null) {
          _onConnectionStateChanged(stateStr, sessionId);
        }
        return;
      }

      if (eventType == 'networkState') {
        final isReachable = data['isReachable'] as bool? ?? false;
        final transport = data['transport'] as String? ?? 'none';
        debugPrint('[Chat] networkState: reachable=$isReachable transport=$transport');
        _onNetworkStateChanged(isReachable, transport);
        return;
      }

      if (eventType == 'queueReplayed') {
        final count = data['count'] as int? ?? 0;
        final sid = data['sessionId'] as String? ?? _activeSessionId;
        debugPrint('[Chat] $count queued messages replayed (session=$sid)');
        if (sid != null && (_queuedMessageIds[sid]?.isNotEmpty ?? false)) {
          _queuedMessageIds[sid]!.clear();
          if (sid == _activeSessionId) _syncState();
        }
        return;
      }

      // ── Session isolation ──────────────────────────────────────────────
      // Extract session ID early so background events pass through even
      // during a loading window for a different session.
      final eventSessionId = data['sessionId'] as String? ?? '';

      // Suppress events only for the session currently being loaded from disk.
      // Background session events are NOT suppressed — they route normally.
      if (_loadingSessionId != null &&
          (eventSessionId.isEmpty || eventSessionId == _loadingSessionId)) {
        final payloadType = (data['payload'] is Map) ? (data['payload'] as Map)['type'] : null;
        debugPrint('[Session] SUPPRESSED event during session load: ${data['type']} (payload=$payloadType)');
        return;
      }
      if (eventSessionId.isNotEmpty &&
          _activeSessionId != null &&
          eventSessionId != _activeSessionId) {
        final payloadType = (data['payload'] is Map) ? (data['payload'] as Map)['type'] : null;
        if (payloadType == 'Action') {
          debugPrint('[HOOK_TRACE] FAIL: Action routed to BACKGROUND session $eventSessionId (active=$_activeSessionId)');
        }
        _routeToBackgroundSession(eventSessionId, data);
        return;
      }

      if (eventType == 'message') {
        final rawPayload = data['payload'];
        if (rawPayload == null) return;

        final payload = _convertToStringDynamicMap(rawPayload);

        // Any real bridge data (not relay control) proves the peer is online.
        final msgType = payload['type'] as String?;
        if (msgType == 'Action') {
          debugPrint('[HOOK_TRACE] 1. _handleIncoming: Action received, id=${payload['id']}, activeSession=$_activeSessionId');
        }
        if (msgType != null && !_isRelayControlMessage(msgType)) {
          _onPeerOnline(_activeSessionId);
        }

        final message = _parseBridgeMessage(payload);
        if (message != null) {
          if (message.type == MessageType.action) {
            debugPrint('[HOOK_TRACE] 2. _parseBridgeMessage: Action parsed, msg.id=${message.id}, action.id=${message.action?.id}');
          }
          _addOrMergeMessage(message);
        } else if (msgType == 'Action') {
          debugPrint('[HOOK_TRACE] FAIL: _parseBridgeMessage returned null for Action!');
        }
        return;
      }

      // Try direct parse as a fallback
      final convertedData = _convertToStringDynamicMap(data);
      final message = _parseBridgeMessage(convertedData);
      if (message != null) {
        _addOrMergeMessage(message);
      }
    } catch (e) {
      _addSystemMessage('Failed to parse message');
    }
  }

  /// Route a message from a non-active session to that session's message list.
  ///
  /// The message is parsed and stored but does NOT update the UI state
  /// (which always reflects the active session). A persist is scheduled
  /// so the message survives app restarts.
  /// Per-session debounce timers for background message persistence.
  final Map<String, Timer> _bgPersistTimers = {};

  void _routeToBackgroundSession(String sessionId, Map<String, dynamic> data) {
    final eventType = data['type'] as String?;
    if (eventType != 'message') return;

    final rawPayload = data['payload'];
    if (rawPayload == null) return;

    final payload = _convertToStringDynamicMap(rawPayload);
    final msgType = payload['type'] as String?;

    // Intercept metadata messages: store per-session but don't write to
    // global notifiers (which would overwrite the active session's config).
    if (msgType != null && _storeBackgroundMetadata(sessionId, msgType, payload)) {
      return;
    }

    // Handle relay control messages FIRST — before _parseBridgeMessage which
    // has side effects (clearing agents/tasks/transfers) that would corrupt
    // the active session's state.
    if (msgType != null && _isRelayControlMessage(msgType)) {
      if (msgType == 'peer_connected') {
        _onPeerOnline(sessionId);
      } else if (msgType == 'peer_disconnected' || msgType == 'peer_offline') {
        _onPeerOffline(sessionId);
      }
      return;
    }

    final message = _parseBridgeMessage(payload);
    if (message == null) return;

    // Store in background session's list (no UI update)
    final messages = _sessionMessages.putIfAbsent(sessionId, () => []);

    // Mirror the active-session thinking logic:
    // Replace existing thinking with new one, clear on response/tool events.
    if (message.type == MessageType.thinking) {
      messages.removeWhere((m) => m.type == MessageType.thinking);
      if (message.content.isNotEmpty) {
        messages.add(message);
      }
      return; // No persist needed for transient thinking state
    }
    if (message.type == MessageType.claudeResponse ||
        message.type == MessageType.toolUse ||
        message.type == MessageType.action ||
        message.type == MessageType.askQuestion) {
      messages.removeWhere((m) => m.type == MessageType.thinking);
    }

    messages.add(message);

    // Debounced persist — avoid I/O storm during streaming
    _bgPersistTimers[sessionId]?.cancel();
    _bgPersistTimers[sessionId] = Timer(const Duration(seconds: 2), () {
      _persistMessages(sessionId);
      _bgPersistTimers.remove(sessionId);
    });
    debugPrint('[Chat] Routed ${payload['type']} to background session $sessionId');
  }

  /// Add a new message or merge with the last one if they're close in time
  /// and both from Claude. This prevents UI flooding with many tiny messages.
  void _addOrMergeMessage(Message message) {
    if (_activeSessionId == null) {
      if (message.type == MessageType.action) {
        debugPrint('[HOOK_TRACE] FAIL: _addOrMergeMessage: _activeSessionId is null! Action dropped.');
      }
      return;
    }
    if (message.type == MessageType.action) {
      debugPrint('[HOOK_TRACE] 3. _addOrMergeMessage: Action, activeSession=$_activeSessionId, msg.id=${message.id}');
    }

    // Intercept subagent events — route to provider, don't add to chat list
    if (message.type == MessageType.subagentEvent) {
      _handleSubagentEvent(message);
      return;
    }

    // Intercept task management tools — route to live task list, don't add to chat
    if (message.type == MessageType.toolUse && _isTaskTool(message.toolName)) {
      _handleTaskToolEvent(message);
      return;
    }

    final sid = _activeSessionId!;
    final messages = _sessionMessages.putIfAbsent(sid, () => []);
    final now = DateTime.now();
    final lastTime = _lastMessageTimes[sid];

    // Thinking messages: replace or remove the existing one (O(1) via index).
    if (message.type == MessageType.thinking) {
      if (_thinkingIndex >= 0 && _thinkingIndex < messages.length &&
          messages[_thinkingIndex].type == MessageType.thinking) {
        messages.removeAt(_thinkingIndex);
      }
      if (message.content.isNotEmpty) {
        messages.add(message);
        _thinkingIndex = messages.length - 1;
      } else {
        _thinkingIndex = -1;
      }
      _syncState();
      return;
    }
    // Clear thinking indicator + queue icons on Claude response/tool use/action.
    // Claude responding proves the queued messages were delivered.
    if (message.type == MessageType.claudeResponse ||
        message.type == MessageType.toolUse ||
        message.type == MessageType.action ||
        message.type == MessageType.askQuestion) {
      if (_thinkingIndex >= 0 && _thinkingIndex < messages.length &&
          messages[_thinkingIndex].type == MessageType.thinking) {
        messages.removeAt(_thinkingIndex);
      }
      _thinkingIndex = -1;
      // Claude responding proves queued messages were delivered
      final sid = _activeSessionId;
      if (sid != null) _queuedMessageIds[sid]?.clear();
    }

    // When Claude finishes responding (Stop hook), all subagents are done.
    // Clear the agents bar as a safety net for missed SubagentStop events.
    if (message.type == MessageType.claudeResponse) {
      try {
        _activeAgentsNotifier.clear();
      } catch (_) {}
    }

    // Check if we should merge with the last message
    if (messages.isNotEmpty &&
        message.type == MessageType.text &&
        message.sender == MessageSender.claude) {
      final lastMessage = messages.last;

      // Merge if: same sender, same type, within 2 seconds
      if (lastMessage.sender == MessageSender.claude &&
          lastMessage.type == MessageType.text &&
          lastTime != null &&
          now.difference(lastTime).inMilliseconds < 2000) {
        // Merge content
        final mergedContent = '${lastMessage.content}\n${message.content}';
        final mergedMessage = lastMessage.copyWith(content: mergedContent);

        // Replace last message with merged
        messages[messages.length - 1] = mergedMessage;
        _lastMessageTimes[sid] = now;
        _syncState();
        return;
      }
    }

    // Don't add duplicate empty lines or very short messages
    // But always allow action, toolUse, askQuestion messages (they render as cards, not text)
    if (message.content.trim().isEmpty &&
        message.type != MessageType.action &&
        message.type != MessageType.toolUse &&
        message.type != MessageType.askQuestion) {
      return;
    }

    messages.add(message);
    _lastMessageTimes[sid] = now;
    if (message.type == MessageType.action) {
      debugPrint('[HOOK_TRACE] 4. Message added to list, total=${messages.length}, calling _syncState');
    }
    _syncState();
  }

  /// Whether a message type is a relay control message (not bridge data).
  static bool _isRelayControlMessage(String type) {
    return type == 'peer_disconnected' ||
        type == 'peer_offline' ||
        type == 'peer_connected' ||
        type == 'pairing' ||
        type == 'pong' ||
        type == 'status_response' ||
        type == 'fcm_registered';
  }

  /// Route a SubagentEvent message to the active agents provider.
  void _handleSubagentEvent(Message message) {
    final id = message.agentId;
    if (id == null || id.isEmpty) return;

    switch (message.agentStatus) {
      case 'started':
        _activeAgentsNotifier.agentStarted(id, message.agentType ?? 'Agent');
        break;
      case 'stopped':
        _activeAgentsNotifier.agentStopped(id);
        break;
    }
  }

  /// Whether a tool name is a task management tool.
  bool _isTaskTool(String? name) {
    return name == 'TaskCreate' ||
        name == 'TaskUpdate' ||
        name == 'TaskList' ||
        name == 'TaskGet' ||
        name == 'TodoWrite' ||
        name == 'TodoRead';
  }

  /// Route task tool events to the active tasks provider.
  void _handleTaskToolEvent(Message message) {
    final input = message.toolInput ?? {};
    final result = message.toolResult;

    switch (message.toolName) {
      case 'TaskCreate':
        // PostToolUse result text is like "Task #1 created successfully: Fix the bug"
        // Extract the task ID from the result
        final idMatch = RegExp(r'#(\d+)').firstMatch(result ?? '');
        final id = idMatch?.group(1) ?? '${DateTime.now().millisecondsSinceEpoch}_${_msgIdCounter++}';
        final subject = input['subject'] as String? ?? '';
        final description = input['description'] as String? ?? '';
        _activeTasksNotifier.taskCreated(id, subject, description);
        break;

      case 'TaskUpdate':
        final taskId = input['taskId'] as String? ?? '';
        final status = input['status'] as String?;
        final subject = input['subject'] as String?;
        if (taskId.isNotEmpty) {
          _activeTasksNotifier.taskUpdated(taskId, status: status, subject: subject);
        }
        break;

      case 'TaskList':
        // TaskList result is text like "#1. [completed] Fix bug\n#2. [in_progress] Add feature"
        if (result != null && result.isNotEmpty) {
          final tasks = _parseTaskListResult(result);
          if (tasks.isNotEmpty) {
            _activeTasksNotifier.setFromTaskList(tasks);
          }
        }
        break;

      // TaskGet / TodoWrite / TodoRead — just absorb, don't show in chat
      default:
        break;
    }
  }

  /// Parse TaskList result text into TrackedTask objects.
  List<TrackedTask> _parseTaskListResult(String result) {
    final lines = result.split('\n').where((l) => l.trim().isNotEmpty);
    final tasks = <TrackedTask>[];
    final now = DateTime.now();

    for (final line in lines) {
      final idMatch = RegExp(r'#(\d+)').firstMatch(line);
      final statusMatch = RegExp(r'\[([\w_]+)\]').firstMatch(line);

      if (idMatch == null) continue;

      final id = idMatch.group(1)!;
      final status = statusMatch?.group(1) ?? 'pending';
      final textStart = statusMatch != null ? statusMatch.end : idMatch.end;
      final subject = line.substring(textStart).trim();

      tasks.add(TrackedTask(
        id: id,
        subject: subject,
        status: status,
        createdAt: now,
        updatedAt: now,
      ));
    }

    return tasks;
  }

  /// Handle a Catchup payload from the bridge (sent on reconnect).
  ///
  /// Catchup contains the last N messages from the Claude JSONL transcript.
  /// Messages are merged into the session's list with dedup and sorted by
  /// timestamp for correct chronological order.
  void _handleCatchup(Map<String, dynamic> payload) {
    final sid = payload['sessionId'] as String? ?? '';
    if (sid.isEmpty) return;

    final rawMessages = payload['messages'] as List<dynamic>? ?? [];
    if (rawMessages.isEmpty) return;

    final messages = _sessionMessages.putIfAbsent(sid, () => []);

    // Build dedup sets: prefer UUID, fall back to content hash
    final existingUuids = <String>{};
    final existingHashes = <String>{};
    for (final m in messages) {
      if (m.id.startsWith('catchup_')) {
        // Catchup messages use UUID-based IDs when available
        existingUuids.add(m.id);
      }
      existingHashes.add('${m.sender.name}:${m.content.length}:${m.content.length > 100 ? m.content.substring(0, 100) : m.content}');
    }

    final catchupMessages = <Message>[];
    for (final raw in rawMessages) {
      if (raw is! Map) continue;
      final m = _convertToStringDynamicMap(raw);

      final role = m['role'] as String? ?? '';
      final content = m['content'] as String? ?? '';
      final timestamp = m['timestamp'] as String? ?? '';
      final uuid = m['uuid'] as String? ?? '';
      final toolUses = m['tool_uses'] as List<dynamic>? ?? [];

      if (content.isEmpty && toolUses.isEmpty) continue;

      final sender = role == 'user' ? MessageSender.user : MessageSender.claude;
      final type = role == 'user' ? MessageType.text : MessageType.claudeResponse;

      // Build display content — include tool names if present
      String displayContent = content;
      if (toolUses.isNotEmpty && content.isEmpty) {
        final names = toolUses.map((t) {
          if (t is Map) return t['tool_name'] as String? ?? 'Tool';
          return 'Tool';
        }).join(', ');
        displayContent = 'Used: $names';
      }

      // Dedup: check UUID first, then always check content hash as fallback.
      // Live messages have non-catchup IDs, so UUID dedup alone misses them.
      final msgId = uuid.isNotEmpty
          ? 'catchup_$uuid'
          : 'catchup_${DateTime.now().millisecondsSinceEpoch}_${catchupMessages.length}';
      if (uuid.isNotEmpty && existingUuids.contains(msgId)) continue;
      final hash = '${sender.name}:${displayContent.length}:${displayContent.length > 100 ? displayContent.substring(0, 100) : displayContent}';
      if (existingHashes.contains(hash)) continue;

      DateTime ts;
      try {
        ts = DateTime.parse(timestamp);
      } catch (_) {
        ts = DateTime.now();
      }

      catchupMessages.add(Message(
        id: msgId,
        type: type,
        sender: sender,
        content: displayContent,
        timestamp: ts,
      ));
    }

    if (catchupMessages.isEmpty) return;

    // Merge and sort by timestamp for correct chronological order
    messages.addAll(catchupMessages);
    messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    // If this is the active session, sync UI + persist via active timer
    if (sid == _activeSessionId) {
      _syncState();
      _schedulePersist();
    } else {
      // Background session: use per-session persist timer (same pattern as _routeToBackgroundSession)
      _bgPersistTimers[sid]?.cancel();
      _bgPersistTimers[sid] = Timer(const Duration(seconds: 2), () {
        _persistMessages(sid);
        _bgPersistTimers.remove(sid);
      });
    }

    debugPrint('[Chat] Catchup: merged ${catchupMessages.length} messages for session $sid');
  }

  /// Handle an incoming file chunk from the computer.
  void _handleFileChunk(String transferId, int sequence, String data) {
    final sid = _activeSessionId;
    if (sid == null) return;
    final sessionTransfers = _fileReceives[sid];
    final state = sessionTransfers?[transferId];
    if (state == null) {
      debugPrint('[FileTransfer] Chunk for unknown transfer: $transferId');
      return;
    }
    state.addChunk(sequence, data);
    // Update top bar provider with progress
    _activeTransfersNotifier.updateProgress(transferId, state.progress);
  }

  /// Handle file transfer complete from the computer.
  /// Assembles chunks, saves file to phone storage.
  Future<void> _handleFileTransferComplete(
    String transferId,
    bool success,
    String? error,
  ) async {
    final sid = _activeSessionId;
    final state = sid != null
        ? _fileReceives[sid]?.remove(transferId)
        : null;
    if (state == null) {
      debugPrint('[FileTransfer] Complete for unknown transfer: $transferId');
      return;
    }

    if (!success) {
      _activeTransfersNotifier.complete(transferId, false, null);
      return;
    }

    try {
      // Assemble chunks into bytes
      final bytes = state.assemble();

      // Save to app downloads directory
      final dir = await getApplicationDocumentsDirectory();
      final downloadsDir = Directory('${dir.path}/Downloads');
      if (!downloadsDir.existsSync()) {
        downloadsDir.createSync(recursive: true);
      }

      // Avoid overwriting existing files
      var savePath = '${downloadsDir.path}/${state.filename}';
      var file = File(savePath);
      if (file.existsSync()) {
        final ext = state.filename.contains('.')
            ? '.${state.filename.split('.').last}'
            : '';
        final name = state.filename.contains('.')
            ? state.filename.substring(0, state.filename.lastIndexOf('.'))
            : state.filename;
        for (var i = 1; i < 1000; i++) {
          savePath = '${downloadsDir.path}/$name ($i)$ext';
          file = File(savePath);
          if (!file.existsSync()) break;
        }
      }

      await file.writeAsBytes(bytes);
      debugPrint('[FileTransfer] Saved file to: $savePath');

      // Update top bar provider with local path
      _activeTransfersNotifier.complete(transferId, true, savePath);

      // Add a file card to chat for history (tappable to open)
      final fileMsg = Message(
        id: 'file_${DateTime.now().millisecondsSinceEpoch}_${_msgIdCounter++}',
        type: MessageType.fileComplete,
        sender: MessageSender.system,
        content: state.filename,
        timestamp: DateTime.now(),
        transferId: transferId,
        fileName: state.filename,
        fileSize: bytes.length,
        localFilePath: savePath,
        transferSuccess: true,
      );
      _appendMessage(fileMsg);
    } catch (e) {
      debugPrint('[FileTransfer] Failed to save file: $e');
      _activeTransfersNotifier.complete(transferId, false, null);
      _addSystemMessage('File transfer failed: ${state.filename} — $e');
    }
  }

  /// Recursively convert a Map<Object?, Object?> to Map<String, dynamic>
  Map<String, dynamic> _convertToStringDynamicMap(dynamic value) {
    if (value is Map) {
      return value.map((key, val) {
        final newValue = val is Map
            ? _convertToStringDynamicMap(val)
            : val is List
                ? _convertList(val)
                : val;
        return MapEntry(key.toString(), newValue);
      });
    }
    return <String, dynamic>{};
  }

  List<dynamic> _convertList(List<dynamic> list) {
    return list.map((item) {
      if (item is Map) {
        return _convertToStringDynamicMap(item);
      } else if (item is List) {
        return _convertList(item);
      }
      return item;
    }).toList();
  }

  /// Convert a ParsedMessage from the Rust bridge into a Dart [Message].
  ///
  /// The bridge sends messages in the format:
  ///   {"type": "Text", "content": "..."}
  ///   {"type": "Code", "language": "python", "content": "..."}
  ///   {"type": "Action", "id": "...", "prompt": "...", "options": [...]}
  ///   {"type": "Diff", "file": "...", "lines": [...]}
  ///   {"type": "System", "content": "..."}
  Message? _parseBridgeMessage(Map<String, dynamic> payload) {
    final msgType = payload['type'] as String?;
    if (msgType == null) return null;

    // Skip relay control messages - they're not chat messages
    if (msgType == 'pairing' ||
        msgType == 'pong' ||
        msgType == 'status_response' ||
        msgType == 'fcm_registered') {
      return null;
    }

    // Handle peer disconnected/offline — update connection indicator and show message.
    // The relay sends "peer_disconnected" when the peer drops, and "peer_offline"
    // when the peer was already offline when the phone connected.
    if (msgType == 'peer_disconnected' || msgType == 'peer_offline') {
      debugPrint('[Chat] relay event: $msgType (activeSession=$_activeSessionId)');
      _peerConnected = false;
      _onPeerOffline(_activeSessionId);
      try {
        _activeAgentsNotifier.clear();
        _activeTasksNotifier.clear();
        _activeTransfersNotifier.clear();
      } catch (_) {
        // Don't let provider cleanup prevent the disconnect message
      }
      // Clear thinking indicator — Claude is offline, no response is coming
      _clearThinkingIndicator();
      return Message(
        id: 'sys_${DateTime.now().millisecondsSinceEpoch}_${_msgIdCounter++}',
        type: MessageType.system,
        sender: MessageSender.system,
        content: msgType == 'peer_offline'
            ? 'Computer is offline'
            : 'Session ended — computer went offline',
        timestamp: DateTime.now(),
      );
    }

    // Handle peer connected — update connection indicator, clear queue, show message
    if (msgType == 'peer_connected') {
      debugPrint('[Chat] relay event: peer_connected (activeSession=$_activeSessionId)');
      _peerConnected = true;
      // Clear queue indicators for active session — messages replayed by native layer
      final sid = _activeSessionId;
      if (sid != null && (_queuedMessageIds[sid]?.isNotEmpty ?? false)) {
        _queuedMessageIds[sid]!.clear();
        _syncState();
      }
      _onPeerOnline(_activeSessionId);
      return Message(
        id: 'sys_${DateTime.now().millisecondsSinceEpoch}_${_msgIdCounter++}',
        type: MessageType.system,
        sender: MessageSender.system,
        content: 'Computer connected',
        timestamp: DateTime.now(),
      );
    }

    final now = DateTime.now();
    final id = 'bridge_${now.millisecondsSinceEpoch}_${_msgIdCounter++}';

    switch (msgType) {
      // --- HTTP Tunnel (responses routed to provider, not chat) ---
      case 'http_response':
        _httpTunnelNotifier.onHttpResponse(
          payload['requestId'] as String? ?? '',
          (payload['status'] as num?)?.toInt() ?? 502,
          (payload['headers'] as Map?)?.map(
                (k, v) => MapEntry(k.toString(), v.toString()),
              ) ??
              {},
          payload['body'] as String? ?? '',
        );
        return null;

      case 'http_tunnel_status':
        _httpTunnelNotifier.onTunnelStatus(
          payload['active'] as bool? ?? false,
          (payload['port'] as num?)?.toInt(),
          payload['error'] as String?,
        );
        return null;

      case 'http_tunnel_refresh':
        _httpTunnelNotifier.onRefresh();
        return null;

      case 'Text':
        final rawContent = payload['content'] as String? ?? '';
        return Message(
          id: id,
          type: MessageType.text,
          sender: MessageSender.claude,
          content: _cleanAnsiCodes(rawContent),
          timestamp: now,
        );
      case 'Code':
        return Message(
          id: id,
          type: MessageType.code,
          sender: MessageSender.claude,
          content: payload['content'] as String? ?? '',
          language: payload['language'] as String?,
          timestamp: now,
        );
      case 'Diff':
        final rawLines = payload['lines'] as List<dynamic>?;
        final diffLines = rawLines?.map((l) {
          final m = l as Map<String, dynamic>;
          return DiffLine(
            content: m['content'] as String? ?? '',
            type: _parseDiffType(m['type'] as String?),
            lineNumber: m['line_number'] as int? ?? m['lineNumber'] as int? ?? 0,
          );
        }).toList();
        return Message(
          id: id,
          type: MessageType.diff,
          sender: MessageSender.claude,
          content: payload['file'] as String? ?? '',
          diffLines: diffLines,
          timestamp: now,
        );
      case 'Action':
        final options = (payload['options'] as List<dynamic>?)
                ?.map((o) => o.toString())
                .toList() ??
            ['Allow', 'Deny'];
        return Message(
          id: id,
          type: MessageType.action,
          sender: MessageSender.claude,
          content: payload['prompt'] as String? ?? '',
          action: PendingAction(
            id: payload['id'] as String? ?? id,
            prompt: payload['prompt'] as String? ?? '',
            options: options,
          ),
          timestamp: now,
        );
      case 'ActionTimeout':
        final actionId = payload['action_id'] as String? ?? '';
        if (_activeSessionId != null) {
          final messages = _sessionMessages[_activeSessionId!];
          if (messages != null) {
            for (int i = 0; i < messages.length; i++) {
              if (messages[i].action?.id == actionId &&
                  !(messages[i].action?.responded ?? false)) {
                messages[i] = messages[i].copyWith(
                  action: messages[i].action!.copyWith(
                    responded: true,
                    response: 'timed_out',
                  ),
                );
                break;
              }
            }
          }
        }
        _addSystemMessage('Permission request timed out');
        _syncState();
        return null;
      case 'System':
        return Message(
          id: id,
          type: MessageType.system,
          sender: MessageSender.system,
          content: payload['content'] as String? ?? '',
          timestamp: now,
        );
      case 'ToolUse':
        final toolName = payload['tool'] as String? ?? 'Unknown';
        final toolStatus = payload['status'] as String? ?? 'success';
        final toolInput = payload['input'] is Map
            ? Map<String, dynamic>.from(payload['input'] as Map)
            : <String, dynamic>{};
        final rawResult = payload['result'];
        String? toolResult;
        if (rawResult == null) {
          toolResult = null;
        } else if (rawResult is String) {
          toolResult = rawResult;
        } else if (rawResult is Map) {
          // Try common response fields by tool type
          toolResult = rawResult['stdout'] as String?
              ?? rawResult['content'] as String?
              ?? rawResult['output'] as String?
              ?? rawResult['text'] as String?;
          if (toolResult == null) {
            // Format as readable JSON for display
            try {
              toolResult = const JsonEncoder.withIndent('  ').convert(rawResult);
            } catch (_) {
              toolResult = rawResult.toString();
            }
          }
        } else if (rawResult is List) {
          try {
            toolResult = const JsonEncoder.withIndent('  ').convert(rawResult);
          } catch (_) {
            toolResult = rawResult.toString();
          }
        } else {
          toolResult = rawResult.toString();
        }
        final toolError = payload['error'] as String?;

        // Build human-readable content summary
        String content;
        switch (toolName) {
          case 'Edit':
            final file = toolInput['file_path'] as String? ?? 'unknown';
            content = toolStatus == 'error'
                ? 'Failed to edit $file'
                : 'Edited $file';
            break;
          case 'Write':
            final file = toolInput['file_path'] as String? ?? 'unknown';
            content = 'Created $file';
            break;
          case 'Bash':
            final cmd = toolInput['command'] as String? ?? '';
            content = cmd.length > 60 ? '${cmd.substring(0, 57)}...' : cmd;
            break;
          case 'Read':
            final file = toolInput['file_path'] as String? ?? 'unknown';
            content = 'Read $file';
            break;
          default:
            content = toolName;
        }

        return Message(
          id: payload['id'] as String? ?? 'hook_${now.millisecondsSinceEpoch}_${_msgIdCounter++}',
          type: MessageType.toolUse,
          sender: MessageSender.claude,
          content: content,
          timestamp: now,
          toolName: toolName,
          toolStatus: toolStatus,
          toolInput: toolInput,
          toolResult: toolResult,
          toolError: toolError,
        );
      case 'AskQuestion':
        final rawQuestions = payload['questions'] as List<dynamic>? ?? [];
        final questions = rawQuestions.map((q) {
          if (q is Map) {
            return _convertToStringDynamicMap(q);
          }
          return <String, dynamic>{};
        }).toList();

        final firstQ = questions.isNotEmpty ? questions.first : <String, dynamic>{};
        final questionText = firstQ['question'] as String? ?? 'Question from Claude';

        return Message(
          id: payload['id'] as String? ?? id,
          type: MessageType.askQuestion,
          sender: MessageSender.claude,
          content: questionText,
          questions: questions,
          timestamp: now,
        );
      case 'ClaudeResponse':
        final content = payload['content'] as String? ?? '';
        return Message(
          id: id,
          type: MessageType.claudeResponse,
          sender: MessageSender.claude,
          content: _cleanAnsiCodes(content),
          timestamp: now,
        );
      case 'Thinking':
        final status = payload['status'] as String? ?? '';
        return Message(
          id: 'thinking', // Fixed ID so it replaces previous thinking message
          type: MessageType.thinking,
          sender: MessageSender.claude,
          content: status,
          timestamp: now,
        );
      case 'SubagentEvent':
        return Message(
          id: 'agent_${payload['agent_id']}_${now.millisecondsSinceEpoch}_${_msgIdCounter++}',
          type: MessageType.subagentEvent,
          sender: MessageSender.system,
          content: '${payload['agent_type'] ?? 'Agent'} agent ${payload['status']}',
          agentId: payload['agent_id'] as String?,
          agentType: payload['agent_type'] as String?,
          agentStatus: payload['status'] as String?,
          timestamp: now,
        );
      case 'FileOffer':
        // Store metadata for when chunks start arriving — scoped per session
        final sid = _activeSessionId;
        if (sid == null) return null;
        final tid = payload['transfer_id'] as String? ?? '';
        final fname = payload['filename'] as String? ?? 'Unknown file';
        debugPrint('[FileTransfer] FileOffer: file=$fname transfer=$tid session=$sid');
        final mime = payload['mime_type'] as String? ?? 'application/octet-stream';
        final totalSize = (payload['total_size'] as num?)?.toInt() ?? 0;
        final estChunks = totalSize > 0 ? (totalSize / 128000).ceil() : 1; // bridge CHUNK_SIZE=128000
        _fileReceives.putIfAbsent(sid, () => {})[tid] = _FileReceiveState(
          transferId: tid,
          filename: fname,
          mimeType: mime,
          totalChunks: estChunks,
        );
        // Route to top bar provider — not the chat list
        _activeTransfersNotifier.addOffer(tid, fname, totalSize);
        return null;
      case 'FileProgress':
        final transferId = payload['transfer_id'] as String? ?? '';
        final received = (payload['chunks_received'] as num?)?.toInt() ?? 0;
        final total = (payload['total_chunks'] as num?)?.toInt() ?? 1;
        final progress = total > 0 ? received / total : 0.0;
        // Update top bar provider
        _activeTransfersNotifier.updateProgress(transferId, progress);
        return null;
      case 'FileComplete':
        final transferId = payload['transfer_id'] as String? ?? '';
        final success = payload['success'] as bool? ?? false;
        // Update top bar provider (local_path is set by _handleFileTransferComplete)
        // Don't complete here — wait for the phone-side assembly to finish
        if (!success) {
          _activeTransfersNotifier.complete(transferId, false, null);
        }
        return null;

      // ---- RelayMessage types (computer→phone file transfer) ----
      case 'file_chunk':
        final transferId = payload['transferId'] as String? ?? '';
        final sequence = (payload['sequence'] as num?)?.toInt() ?? 0;
        final data = payload['data'] as String? ?? '';
        _handleFileChunk(transferId, sequence, data);
        return null;

      case 'file_transfer_complete':
        final transferId = payload['transferId'] as String? ?? '';
        final success = payload['success'] as bool? ?? false;
        final error = payload['error'] as String?;
        _handleFileTransferComplete(transferId, success, error);
        return null;

      case 'SessionList':
        final rawSessions = payload['sessions'] as List<dynamic>? ?? [];
        final sessions = rawSessions
            .map((s) => ResumableSession.fromMap(
                s is Map ? _convertToStringDynamicMap(s) : <String, dynamic>{}))
            .where((s) => s.sessionId.isNotEmpty)
            .toList();
        _sessionPickerNotifier.setSessions(sessions);
        return null; // Don't add to chat — shown in native picker

      case 'PluginList':
        final rawPlugins = payload['plugins'] as List<dynamic>? ?? [];
        final plugins = rawPlugins
            .map((p) => InstalledPlugin.fromMap(
                p is Map ? _convertToStringDynamicMap(p) : <String, dynamic>{}))
            .where((p) => p.id.isNotEmpty)
            .toList();
        _extensionsNotifier.setPlugins(plugins);
        // Store per-session
        if (_activeSessionId != null) {
          final ext = _sessionExtensions[_activeSessionId!] ?? const ExtensionsState();
          _sessionExtensions[_activeSessionId!] = ext.copyWith(plugins: plugins);
        }
        return null;

      case 'SkillList':
        final rawSkills = payload['skills'] as List<dynamic>? ?? [];
        final skills = rawSkills
            .map((s) => ClaudeSkill.fromMap(
                s is Map ? _convertToStringDynamicMap(s) : <String, dynamic>{}))
            .where((s) => s.name.isNotEmpty)
            .toList();
        _extensionsNotifier.setSkills(skills);
        // Store per-session
        if (_activeSessionId != null) {
          final ext = _sessionExtensions[_activeSessionId!] ?? const ExtensionsState();
          _sessionExtensions[_activeSessionId!] = ext.copyWith(skills: skills);
        }
        return null;

      case 'RulesList':
        final rawRules = payload['rules'] as List<dynamic>? ?? [];
        final rules = rawRules
            .map((r) => ClaudeRule.fromMap(
                r is Map ? _convertToStringDynamicMap(r) : <String, dynamic>{}))
            .where((r) => r.filename.isNotEmpty)
            .toList();
        _extensionsNotifier.setRules(rules);
        // Store per-session
        if (_activeSessionId != null) {
          final ext = _sessionExtensions[_activeSessionId!] ?? const ExtensionsState();
          _sessionExtensions[_activeSessionId!] = ext.copyWith(rules: rules);
        }
        return null;

      case 'MemoryContent':
        final rawEntries = payload['entries'] as List<dynamic>? ?? [];
        final entries = rawEntries
            .map((e) => MemoryEntry.fromMap(
                e is Map ? _convertToStringDynamicMap(e) : <String, dynamic>{}))
            .where((e) => e.content.isNotEmpty)
            .toList();
        _memoryNotifier.setEntries(entries);
        // Store per-session
        if (_activeSessionId != null) {
          _sessionMemory[_activeSessionId!] = entries;
        }
        return null;

      case 'LiveStateUpdate':
      case 'StateSnapshot':
        final sid = payload['sessionId'] as String? ?? '';
        if (sid.isNotEmpty) {
          _liveStateNotifier.update(sid, SessionLiveState.fromJson(payload));
          // Restore handoff state from live state (handles reconnect sync).
          // The bridge re-sends HandoffActive on reconnect, but this is a
          // safety net in case the StateSnapshot arrives first.
          if (sid == _activeSessionId) {
            final status = payload['claudeStatus'] as String? ?? '';
            if (status == 'handed_off' && !_handedOff) {
              _handedOff = true;
              _addSystemMessage('Session is on computer (reconnected).');
            } else if (status != 'handed_off' && _handedOff) {
              _handedOff = false;
            }
          }
        }
        return null; // Live state metadata — no chat message

      case 'Catchup':
        _handleCatchup(payload);
        return null; // Catchup messages merged directly — no single chat message

      case 'SessionCapabilities':
        _sessionCapabilities = SessionCapabilities.fromJson(payload);
        // Trigger rebuild so widgets watching capabilities can update.
        state = [...state];
        return null; // Capabilities metadata — no chat message

      case 'ConfigSync':
        final model = payload['model'] as String?;
        final permMode = payload['permission_mode'] as String?;
        if (model != null) {
          _claudeConfigNotifier.setModelFromId(model);
        }
        if (permMode != null) {
          _claudeConfigNotifier.setPermissionModeFromCli(permMode);
        }
        // Store per-session
        if (_activeSessionId != null) {
          _sessionConfigs[_activeSessionId!] = _claudeConfigNotifier.state;
        }
        return null; // Config sync — no chat message

      case 'PermissionRulesSync':
        final allow = (payload['allow'] as List?)?.map((e) => e.toString()).toList() ?? [];
        final deny = (payload['deny'] as List?)?.map((e) => e.toString()).toList() ?? [];
        _claudeConfigNotifier.setPermissionRules(allow, deny);
        // Store per-session
        if (_activeSessionId != null) {
          _sessionConfigs[_activeSessionId!] = _claudeConfigNotifier.state;
        }
        return null; // Rules sync — no chat message

      case 'HandoffActive':
        _handedOff = true;
        _addSystemMessage('Session handed off to computer. You can observe activity here.');
        return null;

      case 'HandoffEnded':
        _handedOff = false;
        _addSystemMessage('Session back on phone.');
        return null;

      case 'HandoffMessage':
        final msgData = payload['message'];
        if (msgData is Map) {
          final m = _convertToStringDynamicMap(msgData);
          final role = m['role'] as String? ?? 'assistant';
          final content = m['content'] as String? ?? '';
          if (content.isNotEmpty) {
            _addObserverMessage(role, content);
          }
        }
        return null;

      default:
        // Unknown type — show as text, clean ANSI codes
        final content = payload['content'] as String? ?? payload.toString();
        return Message(
          id: id,
          type: MessageType.text,
          sender: MessageSender.claude,
          content: _cleanAnsiCodes(content),
          timestamp: now,
        );
    }
  }

  /// Remove ANSI escape codes from terminal output while preserving structure.
  String _cleanAnsiCodes(String text) {
    // Remove ANSI escape sequences (colors, cursor movement, etc.)
    var cleaned = text.replaceAll(_ansiEscapeRe, '');

    // Remove OSC sequences (operating system commands)
    cleaned = cleaned.replaceAll(_ansiOscRe, '');

    // Remove other control characters but keep unicode box drawing
    cleaned = cleaned.replaceAll(_controlCharsRe, '');

    // Keep box-drawing characters (─│┌┐└┘├┤┬┴┼) - they look nice in terminal
    // Only replace if they cause rendering issues

    // Remove excess whitespace but preserve structure
    final lines = cleaned.split('\n');
    final cleanedLines = <String>[];
    for (final line in lines) {
      final trimmed = line.trimRight();
      if (trimmed.isNotEmpty || cleanedLines.isNotEmpty) {
        cleanedLines.add(trimmed);
      }
    }

    // Remove trailing empty lines
    while (cleanedLines.isNotEmpty && cleanedLines.last.isEmpty) {
      cleanedLines.removeLast();
    }

    return cleanedLines.join('\n');
  }

  DiffType _parseDiffType(String? type) {
    switch (type) {
      case 'Add':
        return DiffType.add;
      case 'Remove':
        return DiffType.remove;
      default:
        return DiffType.context;
    }
  }

  void _addSystemMessage(String text) {
    final msg = Message(
      id: 'sys_${DateTime.now().millisecondsSinceEpoch}_${_msgIdCounter++}',
      type: MessageType.system,
      sender: MessageSender.system,
      content: text,
      timestamp: DateTime.now(),
    );
    _appendMessage(msg);
  }

  /// Add a read-only observer message during handoff (from transcript watcher).
  void _addObserverMessage(String role, String content) {
    final sender = role == 'user' ? MessageSender.user : MessageSender.claude;
    final type = role == 'user' ? MessageType.text : MessageType.claudeResponse;
    final msg = Message(
      id: 'observer_${DateTime.now().millisecondsSinceEpoch}_${_msgIdCounter++}',
      type: type,
      sender: sender,
      content: _cleanAnsiCodes(content),
      timestamp: DateTime.now(),
    );
    _appendMessage(msg);
  }

  /// Add a user-visible message confirming a file was sent to the computer.
  void addFileSentMessage(String fileName) {
    final msg = Message(
      id: 'file_sent_${DateTime.now().millisecondsSinceEpoch}_${_msgIdCounter++}',
      type: MessageType.system,
      sender: MessageSender.user,
      content: 'Sent file: $fileName',
      timestamp: DateTime.now(),
    );
    _appendMessage(msg);
  }

  // -------------------------------------------------------------------------
  // Outgoing
  // -------------------------------------------------------------------------

  /// Append a message to the active session's list and sync state.
  void _appendMessage(Message msg) {
    if (_activeSessionId != null) {
      final messages =
          _sessionMessages.putIfAbsent(_activeSessionId!, () => []);
      messages.add(msg);
      _syncState();
    } else {
      state = [...state, msg];
    }
  }

  /// Request handoff to computer.
  Future<void> sendHandoff() async {
    try {
      await _security.sendMessage('handoff');
    } on PlatformException catch (e) {
      debugPrint('[Chat] sendHandoff error: ${e.code} - ${e.message}');
    }
  }

  /// Request take-back from computer.
  Future<void> sendTakeBack() async {
    try {
      await _security.sendMessage('takeback');
    } on PlatformException catch (e) {
      debugPrint('[Chat] sendTakeBack error: ${e.code} - ${e.message}');
    }
  }

  /// Send a user text message (with automatic Enter at the end).
  ///
  /// The message is added to the local list immediately for optimistic UI,
  /// then sent through the native encrypted channel.
  Future<void> sendMessage(String content) async {
    // Allow empty content to just send Enter
    final userMessage = Message(
      id: 'usr_${DateTime.now().millisecondsSinceEpoch}_${_msgIdCounter++}',
      type: MessageType.text,
      sender: MessageSender.user,
      content: content.isEmpty ? '⏎' : content,
      timestamp: DateTime.now(),
    );
    if (!_peerConnected && _activeSessionId != null) {
      _queuedMessageIds.putIfAbsent(_activeSessionId!, () => {}).add(userMessage.id);
    }
    _appendMessage(userMessage);

    try {
      final success = await _security.sendMessage(content);
      if (!success) {
        _addSystemMessage('Failed to send message');
      }
    } on PlatformException catch (e) {
      debugPrint('[Chat] sendMessage error: ${e.code} - ${e.message}');
      _addSystemMessage('Failed to send — computer is offline');
    }
  }

  /// Send a special key press (Enter, Escape, Arrow keys, etc.)
  Future<void> sendKey(String key) async {
    final keyMessage = Message(
      id: 'key_${DateTime.now().millisecondsSinceEpoch}_${_msgIdCounter++}',
      type: MessageType.text,
      sender: MessageSender.user,
      content: '\u2328\uFE0F $key',
      timestamp: DateTime.now(),
    );
    if (!_peerConnected && _activeSessionId != null) {
      _queuedMessageIds.putIfAbsent(_activeSessionId!, () => {}).add(keyMessage.id);
    }
    _appendMessage(keyMessage);

    try {
      final success = await _security.sendKey(key);
      if (!success) {
        _addSystemMessage('Failed to send key');
      }
    } on PlatformException catch (e) {
      debugPrint('[Chat] sendKey error: ${e.code} - ${e.message}');
      _addSystemMessage('Failed to send key — computer is offline');
    }
  }

  /// Send raw input without automatic newline.
  Future<void> sendRawInput(String content) async {
    if (content.isEmpty) return;

    try {
      final success = await _security.sendRawInput(content);
      if (!success) {
        _addSystemMessage('Failed to send input');
      }
    } on PlatformException catch (e) {
      debugPrint('[Chat] sendRawInput error: ${e.code} - ${e.message}');
    }
  }

  /// Respond to a pending action (e.g. allow / deny).
  ///
  /// The local action state is updated immediately, and the response is
  /// forwarded to the native layer.
  Future<void> respondToAction(String actionId, String response) async {
    // Update local state first for instant feedback.
    if (_activeSessionId != null) {
      final messages = _sessionMessages[_activeSessionId!];
      if (messages != null) {
        for (int i = 0; i < messages.length; i++) {
          if (messages[i].action?.id == actionId) {
            messages[i] = messages[i].copyWith(
              action: messages[i].action!.copyWith(
                responded: true,
                response: response,
              ),
            );
          }
        }
        _syncState();
      }
    }

    try {
      final success = await _security.sendActionResponse(
        actionId: actionId,
        response: response,
      );
      if (!success) {
        _addSystemMessage('Failed to send action response');
      }
    } on PlatformException catch (e) {
      debugPrint('[Chat] respondToAction error: ${e.code} - ${e.message}');
      _addSystemMessage('Failed to send response — computer is offline');
    }
  }

  /// Send a Claude Code slash command (e.g., /help, /clear, /model).
  ///
  /// Commands are displayed in the chat as user messages for visibility.
  Future<void> sendCommand(String command, {String? args}) async {
    // Display the command in chat
    final displayText = args != null ? '/$command $args' : '/$command';
    final userMessage = Message(
      id: 'cmd_${DateTime.now().millisecondsSinceEpoch}_${_msgIdCounter++}',
      type: MessageType.text,
      sender: MessageSender.user,
      content: displayText,
      timestamp: DateTime.now(),
    );
    if (!_peerConnected && _activeSessionId != null) {
      _queuedMessageIds.putIfAbsent(_activeSessionId!, () => {}).add(userMessage.id);
    }
    _appendMessage(userMessage);

    try {
      final success = await _security.sendCommand(command, args: args);
      if (!success) {
        _addSystemMessage('Failed to send command');
      }
    } on PlatformException catch (e) {
      debugPrint('[Chat] sendCommand error: ${e.code} - ${e.message}');
      _addSystemMessage('Failed to send command — computer is offline');
    }
  }

  /// Send a command to the bridge without displaying it in chat.
  /// Used for internal operations (rule management, data fetching).
  Future<void> sendCommandSilent(String command, {String? args}) async {
    try {
      final success = await _security.sendCommand(command, args: args);
      if (!success) {
        _addSystemMessage('Failed to send command');
      }
    } on PlatformException catch (e) {
      debugPrint('[Chat] sendCommandSilent error: ${e.code} - ${e.message}');
    }
  }

  /// Request plugins, skills, and rules from the bridge.
  /// The bridge reads from disk and sends back PluginList/SkillList/RulesList.
  Future<void> requestExtensions() async {
    await sendCommandSilent('plugins');
    await sendCommandSilent('skills');
    await sendCommandSilent('rules');
    await sendCommandSilent('permission-rules');
  }

  /// Request project memory (CLAUDE.md files) from the bridge.
  Future<void> requestMemory() async {
    try {
      await _security.sendCommand('memory');
    } on PlatformException catch (e) {
      debugPrint('[Chat] requestMemory error: ${e.code} - ${e.message}');
      _addSystemMessage('Failed to request memory — computer is offline');
    }
  }

  /// Request the list of resumable sessions from the bridge.
  /// The bridge reads sessions-index.json and sends back a SessionList message.
  Future<void> requestSessions() async {
    try {
      final success = await _security.sendCommand('resume');
      if (!success) {
        _addSystemMessage('Failed to request sessions');
      }
    } on PlatformException catch (e) {
      debugPrint('[Chat] requestSessions error: ${e.code} - ${e.message}');
      _addSystemMessage('Failed to request sessions — computer is offline');
    }
  }

  /// Resume a specific Claude Code session by ID.
  Future<void> resumeSession(String sessionId) async {
    final userMessage = Message(
      id: 'cmd_${DateTime.now().millisecondsSinceEpoch}_${_msgIdCounter++}',
      type: MessageType.text,
      sender: MessageSender.user,
      content: 'Resuming session...',
      timestamp: DateTime.now(),
    );
    _appendMessage(userMessage);

    try {
      final success = await _security.sendCommand('resume', args: sessionId);
      if (!success) {
        _addSystemMessage('Failed to resume session');
      }
    } on PlatformException catch (e) {
      debugPrint('[Chat] resumeSession error: ${e.code} - ${e.message}');
      _addSystemMessage('Failed to resume session — computer is offline');
    }
  }

  /// Set the Claude Code model.
  Future<void> setModel(String model) async {
    final userMessage = Message(
      id: 'model_${DateTime.now().millisecondsSinceEpoch}_${_msgIdCounter++}',
      type: MessageType.text,
      sender: MessageSender.user,
      content: '/model $model',
      timestamp: DateTime.now(),
    );
    _appendMessage(userMessage);

    try {
      final success = await _security.setModel(model);
      if (!success) {
        _addSystemMessage('Failed to set model');
      }
    } on PlatformException catch (e) {
      debugPrint('[Chat] setModel error: ${e.code} - ${e.message}');
      _addSystemMessage('Failed to set model — computer is offline');
    }
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  /// Get last meaningful message preview for a session (for session list).
  /// Checks in-memory first, then SharedPreferences.
  Future<String?> getLastPreview(String sessionId) async {
    // Check in-memory first
    final inMemory = _sessionMessages[sessionId];
    if (inMemory != null && inMemory.isNotEmpty) {
      for (int i = inMemory.length - 1; i >= 0; i--) {
        final preview = _previewText(inMemory[i]);
        if (preview != null) return preview;
      }
    }

    // Load from SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList('$_msgPrefix$sessionId');
      if (raw == null || raw.isEmpty) return null;

      for (int i = raw.length - 1; i >= 0; i--) {
        try {
          final json = jsonDecode(raw[i]) as Map<String, dynamic>;
          final msg = Message.fromJson(json);
          final preview = _previewText(msg);
          if (preview != null) return preview;
        } catch (_) {
          continue;
        }
      }
    } catch (_) {}

    return null;
  }

  /// Build a short preview string for a message (returns null to skip).
  /// Mirrors smart mode filter: skip terminal-parsed text/code/diff from Claude.
  String? _previewText(Message msg) {
    // Skip noise: system messages, thinking, terminal-parsed output from Claude
    if (msg.type == MessageType.system ||
        msg.type == MessageType.thinking) {
      return null;
    }
    // Skip terminal-parsed types from Claude (text, code, diff) — same as smart mode
    if (msg.sender == MessageSender.claude &&
        (msg.type == MessageType.text ||
         msg.type == MessageType.code ||
         msg.type == MessageType.diff)) {
      return null;
    }

    switch (msg.type) {
      case MessageType.toolUse:
        return '${msg.toolName ?? "Tool"}: ${msg.content}';
      case MessageType.action:
        return msg.content;
      case MessageType.askQuestion:
        return msg.content;
      case MessageType.claudeResponse:
        final text = msg.content.replaceAll('\n', ' ').trim();
        if (text.isEmpty) return null;
        return text.length > 80 ? '${text.substring(0, 77)}...' : text;
      case MessageType.text:
        // Only user text reaches here (Claude text is filtered above)
        final text = msg.content.replaceAll('\n', ' ').trim();
        if (text.isEmpty) return null;
        return text.length > 80 ? '${text.substring(0, 77)}...' : text;
      default:
        return null;
    }
  }

  /// Clear all messages for the active session.
  void clearMessages() {
    _persistTimer?.cancel();
    _thinkingIndex = -1;
    if (_activeSessionId != null) {
      _sessionMessages[_activeSessionId!] = [];
      _lastMessageTimes.remove(_activeSessionId);
      _persistMessages(_activeSessionId!);
    }
    state = [];
  }

  /// Remove all stored messages and config for a session (e.g. on disconnect).
  Future<void> removeSession(String sessionId) async {
    _sessionMessages.remove(sessionId);
    _lastMessageTimes.remove(sessionId);
    _fileReceives.remove(sessionId);
    _sessionConfigs.remove(sessionId);
    _sessionExtensions.remove(sessionId);
    _sessionMemory.remove(sessionId);
    // Cancel and remove background persist timer to prevent unbounded growth
    _bgPersistTimers[sessionId]?.cancel();
    _bgPersistTimers.remove(sessionId);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_msgPrefix$sessionId');
    } catch (_) {}
  }

}
