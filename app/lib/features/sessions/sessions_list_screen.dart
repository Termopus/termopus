
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/chat_provider.dart';
import '../../core/providers/connection_provider.dart';
import '../../core/providers/live_state_provider.dart';
import '../../core/providers/session_provider.dart';
import '../../models/connection_state.dart';
import '../../models/session.dart';
import '../../models/session_live_state.dart';
import '../../shared/extensions.dart';
import '../../shared/responsive.dart';
import '../../shared/theme.dart';
/// Home screen — branded Termopus header with WhatsApp/Telegram-style session list.
class SessionsListScreen extends ConsumerStatefulWidget {
  const SessionsListScreen({super.key});

  @override
  ConsumerState<SessionsListScreen> createState() => _SessionsListScreenState();
}

class _SessionsListScreenState extends ConsumerState<SessionsListScreen>
    with WidgetsBindingObserver {
  // ── Multi-select state (Task 5) ──
  bool _isSelectionMode = false;
  final Set<String> _selectedIds = {};


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }






  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(sessionProvider);
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;

    return PopScope(
      canPop: !_isSelectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isSelectionMode) {
          setState(() {
            _isSelectionMode = false;
            _selectedIds.clear();
          });
        }
      },
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            // ── Branded header ──
            SliverToBoxAdapter(
              child: _isSelectionMode
                  ? _SelectionHeader(
                      selectedCount: _selectedIds.length,
                      totalCount: sessions.length,
                      onCancel: () => setState(() {
                        _isSelectionMode = false;
                        _selectedIds.clear();
                      }),
                      onSelectAll: () => setState(() {
                        if (_selectedIds.length == sessions.length) {
                          _selectedIds.clear();
                        } else {
                          _selectedIds.addAll(sessions.map((s) => s.id));
                        }
                      }),
                    )
                  : _BrandHeader(
                      onSettings: () => context.push('/app-settings'),
                    ),
            ),

            // ── Content ──
            if (sessions.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyState(onPair: () => context.push('/pair')),
              )
            else ...[
              // Section label
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(context.rHorizontalPadding * 1.25, context.rSpacing, context.rHorizontalPadding * 1.25, context.rSpacing * 1.5),
                  child: Text(
                    _isSelectionMode ? 'SELECT SESSIONS' : 'DEVICES',
                    style: TextStyle(
                      fontSize: context.rFontSize(mobile: 11, tablet: 13),
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textMuted,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ),

              // Session list
              SliverPadding(
                padding: EdgeInsets.fromLTRB(context.rSpacing * 2, 0, context.rSpacing * 2, (_isSelectionMode ? 140 : 80) + bottomPadding),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final session = sessions[index];
                      final isSelected = _selectedIds.contains(session.id);

                      final tile = Padding(
                        padding: EdgeInsets.only(bottom: context.rSpacing * 0.25),
                        child: Row(
                          children: [
                            // Checkbox in selection mode
                            if (_isSelectionMode) ...[
                              Checkbox(
                                value: isSelected,
                                onChanged: (_) => _toggleSelection(session.id),
                                activeColor: AppTheme.primary,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ],
                            Expanded(
                              child: _SessionTileWithPreview(
                                session: session,
                                chatNotifier: ref.read(chatProvider.notifier),
                                onTap: _isSelectionMode
                                    ? () => _toggleSelection(session.id)
                                    : () => _connectAndOpen(session),
                                onDelete: () => _confirmDelete(session),
                                onRename: () => _showRename(session),
                                onLongPress: _isSelectionMode
                                    ? null
                                    : () => _enterSelectionMode(session.id),
                              ),
                            ),
                          ],
                        ),
                      );

                      // Swipe-to-delete (disabled during selection mode)
                      if (_isSelectionMode) return tile;

                      return Dismissible(
                        key: Key('session-dismiss-${session.id}'),
                        direction: DismissDirection.endToStart,
                        confirmDismiss: (_) => _confirmDeleteDialog(session),
                        onDismissed: (_) => _performDelete(session),
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: EdgeInsets.only(right: context.rSpacing * 2),
                          decoration: BoxDecoration(
                            color: AppTheme.error,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            Icons.delete_outline_rounded,
                            color: Colors.white,
                            size: context.rIconSize,
                          ),
                        ),
                        child: tile,
                      );
                    },
                    childCount: sessions.length,
                  ),
                ),
              ),
            ],
          ],
        ),

        // ── Bottom bar (selection mode) or Pair FAB ──
        bottomSheet: _isSelectionMode
            ? _SelectionBottomBar(
                selectedCount: _selectedIds.length,
                onCancel: () => setState(() {
                  _isSelectionMode = false;
                  _selectedIds.clear();
                }),
                onDelete: _selectedIds.isEmpty ? null : _deleteSelected,
              )
            : null,
        floatingActionButton: _isSelectionMode
            ? null
            : Padding(
                padding: EdgeInsets.only(bottom: context.rSpacing),
                child: FloatingActionButton.extended(
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    context.push('/pair');
                  },
                  backgroundColor: AppTheme.primary,
                  foregroundColor: AppTheme.background,
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  icon: Icon(
                    Icons.add_rounded,
                    size: context.rIconSize,
                  ),
                  label: Text(
                    'New Session',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: context.bodyFontSize),
                  ),
                ),
              ),
      ),
    );
  }

  // ── Selection mode ──

  void _enterSelectionMode(String firstId) {
    HapticFeedback.mediumImpact();
    setState(() {
      _isSelectionMode = true;
      _selectedIds.add(firstId);
    });
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedIds.add(id);
      }
    });
  }

  Future<void> _deleteSelected() async {
    final sessions = ref.read(sessionProvider);
    final selected = sessions.where((s) => _selectedIds.contains(s.id)).toList();
    if (selected.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Remove Sessions'),
        content: Text(
          'Remove ${selected.length} session${selected.length > 1 ? 's' : ''} from your paired devices?\n'
          'You will need to scan new QR codes to reconnect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final currentId = ref.read(connectionProvider.notifier).currentSessionId;

      // Send delete commands to bridge FIRST (while WS is still connected)
      for (final session in selected) {
        ref.read(chatProvider.notifier).removeSession(session.id);
        await ref.read(sessionProvider.notifier).removeSession(session.id);
      }

      // Disconnect after bridge has been notified
      if (currentId != null && _selectedIds.contains(currentId)) {
        ref.read(connectionProvider.notifier).disconnect();
      }

      setState(() {
        _isSelectionMode = false;
        _selectedIds.clear();
      });
    }
  }

  // ── Actions ──

  Future<void> _connectAndOpen(Session session) async {
    HapticFeedback.lightImpact();
    await ref
        .read(connectionProvider.notifier)
        .connect(session.id, relay: session.relay);
    final status = ref.read(connectionProvider);
    if (status == ConnectionStatus.sessionExpired) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Session expired. Please pair again by scanning a new QR code.'),
          ),
        );
      }
      return;
    }
    if (mounted) {
      context.push('/chat/${session.id}');
    }
  }

  /// Show confirmation dialog and return whether delete was confirmed.
  Future<bool> _confirmDeleteDialog(Session session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Remove Session'),
        content: Text(
          'Remove "${session.name}" from your paired devices?\n'
          'You will need to scan a new QR code to reconnect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _confirmDelete(Session session) async {
    if (await _confirmDeleteDialog(session)) {
      _performDelete(session);
    }
  }

  Future<void> _performDelete(Session session) async {
    // Send delete command to bridge FIRST (while WS is still connected),
    // then disconnect and clean up locally.
    ref.read(chatProvider.notifier).removeSession(session.id);
    await ref.read(sessionProvider.notifier).removeSession(session.id);
    // Disconnect after bridge has been notified
    final currentId = ref.read(connectionProvider.notifier).currentSessionId;
    if (currentId == session.id) {
      ref.read(connectionProvider.notifier).disconnect();
    }
  }

  Future<void> _showRename(Session session) async {
    final controller = TextEditingController(text: session.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Rename Session'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Session name'),
          onSubmitted: (value) => Navigator.of(ctx).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty && newName != session.name) {
      ref.read(sessionProvider.notifier).renameSession(session.id, newName);
    }
  }
}

// =============================================================================
// Branded header with logo + title
// =============================================================================

class _BrandHeader extends StatelessWidget {
  final VoidCallback onSettings;

  const _BrandHeader({required this.onSettings});

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).viewPadding.top;

    return Container(
      padding: EdgeInsets.fromLTRB(context.rHorizontalPadding * 1.25, topPadding + context.rSpacing * 2, context.rHorizontalPadding, context.rHorizontalPadding * 1.25),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF151528), AppTheme.background],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Row(
        children: [
          // Octopus logo
          Container(
            width: context.rValue(mobile: 44.0, tablet: 52.0),
            height: context.rValue(mobile: 44.0, tablet: 52.0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primary.withValues(alpha:0.2),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Image.asset(
              'assets/images/app_icon.png',
              fit: BoxFit.cover,
            ),
          ),
          SizedBox(width: context.rSpacing * 1.75),

          // Brand text — inverted logo image (dark text on white → light on dark)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: context.rValue(mobile: 22.0, tablet: 26.0),
                  child: ColorFiltered(
                    colorFilter: const ColorFilter.matrix(<double>[
                      -1, 0, 0, 0, 255,
                       0,-1, 0, 0, 255,
                       0, 0,-1, 0, 255,
                       0, 0, 0, 1,   0,
                    ]),
                    child: Image.asset(
                      'assets/images/termopus_wordmark.png',
                      fit: BoxFit.contain,
                      alignment: Alignment.centerLeft,
                    ),
                  ),
                ),
                SizedBox(height: context.rSpacing * 0.5),
                Text(
                  'Claude Code Remote',
                  style: TextStyle(
                    fontSize: context.captionFontSize,
                    color: AppTheme.textMuted,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),

          // Settings button
          IconButton(
            onPressed: onSettings,
            icon: Icon(Icons.settings_outlined, size: context.rIconSize),
            color: AppTheme.textSecondary,
            style: IconButton.styleFrom(
              backgroundColor: AppTheme.surfaceLight.withValues(alpha:0.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Empty state — friendly CTA
// =============================================================================

class _EmptyState extends StatelessWidget {
  final VoidCallback onPair;

  const _EmptyState({required this.onPair});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Octopus avatar with glow
            Container(
              width: context.rValue(mobile: 96.0, tablet: 120.0),
              height: context.rValue(mobile: 96.0, tablet: 120.0),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primary.withValues(alpha:0.15),
                    blurRadius: 32,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.asset(
                'assets/images/app_icon.png',
                fit: BoxFit.cover,
              ),
            ),
            SizedBox(height: context.rSpacing * 4),

            Text(
              'Welcome to Termopus',
              style: TextStyle(
                fontSize: context.titleFontSize,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
            SizedBox(height: context.rSpacing * 1.5),
            Text(
              'Control Claude Code from your phone.\nPair with your computer to get started.',
              style: TextStyle(
                fontSize: context.bodyFontSize,
                color: AppTheme.textMuted,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: context.rSpacing * 4),

            // Pair button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  HapticFeedback.lightImpact();
                  onPair();
                },
                icon: Icon(Icons.qr_code_scanner_rounded, size: context.rIconSize),
                label: const Text('Scan QR Code to Pair'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: AppTheme.background,
                  padding: EdgeInsets.symmetric(vertical: context.rSpacing * 2),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  textStyle: TextStyle(
                    fontSize: context.buttonFontSize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


// =============================================================================
// Session tile — WhatsApp/Telegram-style conversation item
// =============================================================================

class _SessionTileWithPreview extends ConsumerStatefulWidget {
  final Session session;
  final ChatNotifier chatNotifier;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback? onRename;
  final VoidCallback? onLongPress;

  const _SessionTileWithPreview({
    required this.session,
    required this.chatNotifier,
    required this.onTap,
    required this.onDelete,
    this.onRename,
    this.onLongPress,
  });

  @override
  ConsumerState<_SessionTileWithPreview> createState() =>
      _SessionTileWithPreviewState();
}

class _SessionTileWithPreviewState extends ConsumerState<_SessionTileWithPreview> {
  String? _preview;

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  Future<void> _loadPreview() async {
    final preview =
        await widget.chatNotifier.getLastPreview(widget.session.id);
    if (mounted && preview != _preview) {
      setState(() => _preview = preview);
    }
  }

  @override
  Widget build(BuildContext context) {
    final liveStates = ref.watch(liveStateProvider);
    final liveState = liveStates[widget.session.id];
    return _SessionTile(
      session: widget.session,
      preview: _preview,
      liveState: liveState,
      onTap: widget.onTap,
      onDelete: widget.onDelete,
      onRename: widget.onRename,
      onLongPress: widget.onLongPress,
    );
  }
}

class _SessionTile extends StatelessWidget {
  final Session session;
  final String? preview;
  final SessionLiveState? liveState;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback? onRename;
  final VoidCallback? onLongPress;

  const _SessionTile({
    required this.session,
    this.preview,
    this.liveState,
    required this.onTap,
    required this.onDelete,
    this.onRename,
    this.onLongPress,
  });

  /// Shorten common computer hostnames for display.
  /// "MacBook-Air-sl-nwr" → "MacBook Air"
  /// "Johns-MacBook-Pro.local" → "Johns MacBook Pro"
  /// Short names pass through unchanged.
  String get _displayName {
    var name = session.name;
    // Remove .local suffix
    name = name.replaceAll('.local', '');
    // Replace hyphens/underscores with spaces
    name = name.replaceAll(RegExp(r'[-_]'), ' ');
    // Remove trailing random suffixes (e.g. "sl nwr", "2 local")
    // Keep only known meaningful words
    final words = name.split(RegExp(r'\s+'));
    final meaningful = <String>[];
    for (final word in words) {
      // Keep known words, skip short random suffixes
      if (word.length <= 3 &&
          meaningful.isNotEmpty &&
          !RegExp(r'^(Pro|Air|Max|Mini|iMac)$', caseSensitive: false)
              .hasMatch(word)) {
        continue;
      }
      meaningful.add(word);
    }
    final result = meaningful.join(' ').trim();
    return result.isEmpty ? session.name : result;
  }

  @override
  Widget build(BuildContext context) {
    final isOnline = session.isConnected;
    final isBusy = liveState != null && liveState!.isBusy;
    final isHandedOff = liveState != null && liveState!.isHandedOff;
    final subtitle = (liveState != null && !liveState!.isIdle && isOnline)
        ? liveState!.statusLabel
        : preview ?? (isOnline ? 'Online' : 'Offline');

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress ?? () => _showActions(context),
        borderRadius: BorderRadius.circular(14),
        splashColor: AppTheme.primary.withValues(alpha:0.08),
        highlightColor: AppTheme.primary.withValues(alpha:0.04),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.rSpacing, vertical: context.rSpacing * 1.75),
          child: Row(
            children: [
              // ── Avatar with status indicator ──
              Stack(
                children: [
                  Container(
                    width: context.rValue(mobile: 52.0, tablet: 60.0),
                    height: context.rValue(mobile: 52.0, tablet: 60.0),
                    decoration: BoxDecoration(
                      color: isOnline
                          ? AppTheme.primary.withValues(alpha:0.12)
                          : AppTheme.surfaceLight,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.laptop_mac_rounded,
                      size: context.rValue(mobile: 22.0, tablet: 28.0),
                      color: isOnline ? AppTheme.primary : AppTheme.textMuted,
                    ),
                  ),
                  // Online/activity indicator dot
                  Positioned(
                    right: 1,
                    bottom: 1,
                    child: Container(
                      width: context.rValue(mobile: 14.0, tablet: 18.0),
                      height: context.rValue(mobile: 14.0, tablet: 18.0),
                      decoration: BoxDecoration(
                        color: isHandedOff
                            ? const Color(0xFFA78BFA)
                            : isBusy
                                ? AppTheme.primary
                                : isOnline
                                    ? AppTheme.statusOnline
                                    : AppTheme.statusOffline,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppTheme.background,
                          width: 2.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(width: context.rSpacing * 1.75),

              // ── Text content ──
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Name + time row
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _displayName,
                            style: TextStyle(
                              fontSize: context.bodyFontSize,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (session.lastConnected != null)
                          Text(
                            session.lastConnected!.relativeString,
                            style: TextStyle(
                              fontSize: context.rFontSize(mobile: 11, tablet: 13),
                              color: isOnline
                                  ? AppTheme.primary
                                  : AppTheme.textMuted,
                            ),
                          ),
                      ],
                    ),
                    SizedBox(height: context.rSpacing * 0.5),

                    // Last message preview or status
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: context.captionFontSize,
                        color: isHandedOff
                            ? const Color(0xFFA78BFA)
                            : isBusy
                                ? AppTheme.primary
                                : preview != null
                                    ? AppTheme.textSecondary
                                    : AppTheme.textMuted,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),

              // ── Chevron ──
              SizedBox(width: context.rSpacing),
              Icon(
                Icons.chevron_right_rounded,
                size: context.rIconSize,
                color: AppTheme.textMuted.withValues(alpha:0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showActions(BuildContext context) {
    HapticFeedback.mediumImpact();
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
                margin: EdgeInsets.only(top: context.rSpacing * 1.5, bottom: 4),
                width: context.rValue(mobile: 40.0, tablet: 48.0),
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.textMuted.withValues(alpha:0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Session name header
              Padding(
                padding: EdgeInsets.fromLTRB(context.rSpacing * 2.5, context.rSpacing * 1.5, context.rSpacing * 2.5, context.rSpacing),
                child: Row(
                  children: [
                    Container(
                      width: context.rValue(mobile: 36.0, tablet: 44.0),
                      height: context.rValue(mobile: 36.0, tablet: 44.0),
                      decoration: BoxDecoration(
                        color: AppTheme.surfaceLight,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.laptop_mac_rounded,
                        size: context.rValue(mobile: 18.0, tablet: 24.0),
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    SizedBox(width: context.rSpacing * 1.5),
                    Expanded(
                      child: Text(
                        session.name,
                        style: TextStyle(
                          fontSize: context.bodyFontSize,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, indent: context.rHorizontalPadding, endIndent: context.rHorizontalPadding),

              _ActionTile(
                icon: Icons.edit_outlined,
                label: 'Rename',
                onTap: () {
                  Navigator.pop(ctx);
                  onRename?.call();
                },
              ),
              _ActionTile(
                icon: Icons.delete_outline_rounded,
                label: 'Remove',
                color: AppTheme.error,
                onTap: () {
                  Navigator.pop(ctx);
                  onDelete();
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

// =============================================================================
// Selection mode header
// =============================================================================

class _SelectionHeader extends StatelessWidget {
  final int selectedCount;
  final int totalCount;
  final VoidCallback onCancel;
  final VoidCallback onSelectAll;

  const _SelectionHeader({
    required this.selectedCount,
    required this.totalCount,
    required this.onCancel,
    required this.onSelectAll,
  });

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).viewPadding.top;
    final allSelected = selectedCount == totalCount;

    return Container(
      padding: EdgeInsets.fromLTRB(context.rSpacing, topPadding + context.rSpacing, context.rSpacing, context.rSpacing * 1.5),
      color: AppTheme.background,
      child: Row(
        children: [
          IconButton(
            onPressed: onCancel,
            icon: Icon(Icons.close, size: context.rIconSize),
            color: AppTheme.textPrimary,
          ),
          SizedBox(width: context.rSpacing),
          Expanded(
            child: Text(
              '$selectedCount selected',
              style: TextStyle(
                fontSize: context.titleFontSize,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
          TextButton(
            onPressed: onSelectAll,
            child: Text(
              allSelected ? 'Deselect All' : 'Select All',
              style: TextStyle(
                color: AppTheme.primary,
                fontSize: context.bodyFontSize,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Selection mode bottom bar
// =============================================================================

class _SelectionBottomBar extends StatelessWidget {
  final int selectedCount;
  final VoidCallback onCancel;
  final VoidCallback? onDelete;

  const _SelectionBottomBar({
    required this.selectedCount,
    required this.onCancel,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(context.rSpacing * 2, context.rSpacing * 1.5, context.rSpacing * 2, context.rSpacing * 1.5 + bottomPadding),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(
          top: BorderSide(
            color: AppTheme.surfaceLight.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Row(
        children: [
          TextButton(
            onPressed: onCancel,
            child: Text(
              'Cancel',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: context.bodyFontSize,
              ),
            ),
          ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: onDelete,
            icon: Icon(Icons.delete_outline_rounded, size: context.rIconSize * 0.85),
            label: Text('Delete${selectedCount > 0 ? ' ($selectedCount)' : ''}'),
            style: ElevatedButton.styleFrom(
              backgroundColor: onDelete != null ? AppTheme.error : AppTheme.surfaceLight,
              foregroundColor: onDelete != null ? Colors.white : AppTheme.textMuted,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: EdgeInsets.symmetric(
                horizontal: context.rSpacing * 2,
                vertical: context.rSpacing * 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.label,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppTheme.textPrimary;
    return ListTile(
      leading: Icon(icon, color: c, size: context.rIconSize),
      title: Text(label, style: TextStyle(color: c, fontSize: context.bodyFontSize)),
      onTap: onTap,
      contentPadding: EdgeInsets.symmetric(horizontal: context.rSpacing * 2.5),
    );
  }
}

