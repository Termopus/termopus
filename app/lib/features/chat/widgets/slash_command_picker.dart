import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/models/session_capabilities.dart';
import '../../../shared/claude_commands.dart';
import '../../../shared/responsive.dart';
import '../../../shared/theme.dart';

/// Opens a full-height bottom sheet for browsing and searching all Claude Code
/// slash commands, grouped by category.
///
/// When [capabilities] is provided (stream-json mode), the picker shows
/// the live command list from the session instead of the hardcoded fallback.
///
/// Returns `void`; command selection is communicated via [onCommand].
void showSlashCommandPicker({
  required BuildContext context,
  required void Function(String command, String? args) onCommand,
  SessionCapabilities? capabilities,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _SlashCommandPicker(
      onCommand: onCommand,
      capabilities: capabilities,
    ),
  );
}

// =============================================================================
// Root picker widget
// =============================================================================

class _SlashCommandPicker extends StatefulWidget {
  final void Function(String command, String? args) onCommand;
  final SessionCapabilities? capabilities;

  const _SlashCommandPicker({
    required this.onCommand,
    this.capabilities,
  });

  @override
  State<_SlashCommandPicker> createState() => _SlashCommandPickerState();
}

class _SlashCommandPickerState extends State<_SlashCommandPicker> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';

  /// Commands list: dynamic from capabilities or hardcoded fallback.
  late final List<ClaudeCommand> _commands =
      ClaudeCommands.fromCapabilities(widget.capabilities);
  late final List<String> _categories =
      ClaudeCommands.categoriesFrom(_commands);

  /// When non-null the user is entering arguments for this command.
  ClaudeCommand? _argsTarget;
  final _argsController = TextEditingController();
  final _argsFocus = FocusNode();

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    _argsController.dispose();
    _argsFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Handlers
  // ---------------------------------------------------------------------------

  void _onSearchChanged(String value) {
    setState(() => _query = value.trim());
  }

  void _onCommandTapped(ClaudeCommand cmd) {
    HapticFeedback.lightImpact();

    if (cmd.needsArgs) {
      setState(() {
        _argsTarget = cmd;
        _argsController.clear();
      });
      // Focus the args field after the frame renders.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _argsFocus.requestFocus();
      });
    } else {
      widget.onCommand(cmd.command, null);
      Navigator.of(context).pop();
    }
  }

  void _submitArgs() {
    final cmd = _argsTarget;
    if (cmd == null) return;
    HapticFeedback.lightImpact();
    final args = _argsController.text.trim();
    widget.onCommand(cmd.command, args.isEmpty ? null : args);
    Navigator.of(context).pop();
  }

  void _cancelArgs() {
    setState(() {
      _argsTarget = null;
      _argsController.clear();
    });
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.75;

    return Container(
      height: height,
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(24),
        ),
      ),
      child: Column(
        children: [
          // Drag handle
          const _DragHandle(),

          // Search bar
          _buildSearchBar(),

          // Args input (overlays list when active)
          if (_argsTarget != null) _buildArgsInput(),

          // Command list
          if (_argsTarget == null)
            Expanded(
              child: _query.isEmpty ? _buildCategoryList() : _buildFilteredList(),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Search bar
  // ---------------------------------------------------------------------------

  Widget _buildSearchBar() {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding, vertical: context.rSpacing),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocus,
        onChanged: _onSearchChanged,
        style: TextStyle(
          color: AppTheme.textPrimary,
          fontSize: context.bodyFontSize,
        ),
        decoration: InputDecoration(
          hintText: 'Search commands...',
          hintStyle: TextStyle(color: AppTheme.textMuted, fontSize: context.bodyFontSize),
          prefixIcon: Icon(Icons.search, color: AppTheme.textMuted, size: context.rIconSize),
          suffixIcon: _query.isNotEmpty
              ? IconButton(
                  icon: Icon(Icons.close, color: AppTheme.textMuted, size: context.rValue(mobile: 18.0, tablet: 20.0)),
                  onPressed: () {
                    _searchController.clear();
                    _onSearchChanged('');
                  },
                )
              : null,
          filled: true,
          fillColor: AppTheme.surfaceLight,
          contentPadding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding, vertical: context.rSpacing * 1.5),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppTheme.primary, width: 1),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Args input row
  // ---------------------------------------------------------------------------

  Widget _buildArgsInput() {
    final cmd = _argsTarget!;
    return Expanded(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding, vertical: context.rSpacing),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Command label
            Row(
              children: [
                Icon(cmd.icon, color: AppTheme.primary, size: context.rValue(mobile: 18.0, tablet: 20.0)),
                SizedBox(width: context.rSpacing),
                Text(
                  '/',
                  style: TextStyle(
                    color: AppTheme.primary,
                    fontSize: context.rFontSize(mobile: 16, tablet: 18),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  cmd.command,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: context.rFontSize(mobile: 16, tablet: 18),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.close, color: AppTheme.textMuted, size: context.rIconSize),
                  onPressed: _cancelArgs,
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(minWidth: context.rValue(mobile: 32.0, tablet: 38.0), minHeight: context.rValue(mobile: 32.0, tablet: 38.0)),
                ),
              ],
            ),
            SizedBox(height: context.rSpacing * 1.5),
            // Text field + send button
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _argsController,
                    focusNode: _argsFocus,
                    onSubmitted: (_) => _submitArgs(),
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: context.bodyFontSize,
                    ),
                    decoration: InputDecoration(
                      hintText: cmd.argsHint ?? 'Enter arguments...',
                      hintStyle: TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: context.bodyFontSize,
                      ),
                      filled: true,
                      fillColor: AppTheme.surfaceLight,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: context.rSpacing * 2,
                        vertical: context.rSpacing * 1.5,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: AppTheme.primary,
                          width: 1,
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: context.rSpacing),
                Material(
                  color: AppTheme.primary,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    onTap: _submitArgs,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: EdgeInsets.all(context.rSpacing * 1.5),
                      child: Icon(
                        Icons.send,
                        color: AppTheme.background,
                        size: context.rIconSize,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Category-grouped list (default view)
  // ---------------------------------------------------------------------------

  Widget _buildCategoryList() {
    return ListView.builder(
      padding: EdgeInsets.only(bottom: context.rSpacing * 3),
      itemCount: _categories.length,
      itemBuilder: (context, index) {
        final category = _categories[index];
        final commands = ClaudeCommands.byCategoryFrom(category, _commands);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(title: category),
            for (final cmd in commands)
              _CommandRow(
                command: cmd,
                onTap: () => _onCommandTapped(cmd),
              ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Flat filtered list (search view)
  // ---------------------------------------------------------------------------

  Widget _buildFilteredList() {
    final results = ClaudeCommands.searchIn(_query, _commands);

    if (results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, color: AppTheme.textMuted, size: context.rValue(mobile: 40.0, tablet: 48.0)),
            SizedBox(height: context.rSpacing * 1.5),
            Text(
              'No commands match "$_query"',
              style: TextStyle(color: AppTheme.textMuted, fontSize: context.bodyFontSize),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.only(bottom: context.rSpacing * 3),
      itemCount: results.length,
      itemBuilder: (context, index) {
        final cmd = results[index];
        return _CommandRow(
          command: cmd,
          onTap: () => _onCommandTapped(cmd),
        );
      },
    );
  }
}

// =============================================================================
// Drag handle
// =============================================================================

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: EdgeInsets.only(top: context.rSpacing * 1.5, bottom: context.rSpacing * 0.5),
        width: context.rValue(mobile: 40.0, tablet: 48.0),
        height: 4,
        decoration: BoxDecoration(
          color: AppTheme.textMuted.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

// =============================================================================
// Section header
// =============================================================================

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(context.rHorizontalPadding, context.rSpacing * 2, context.rHorizontalPadding, context.rSpacing * 0.5),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: AppTheme.textMuted,
          fontSize: context.captionFontSize,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// =============================================================================
// Command row
// =============================================================================

class _CommandRow extends StatelessWidget {
  final ClaudeCommand command;
  final VoidCallback onTap;

  const _CommandRow({
    required this.command,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding, vertical: context.rSpacing * 1.25),
          child: Row(
            children: [
              // Icon
              Container(
                width: context.rValue(mobile: 36.0, tablet: 44.0),
                height: context.rValue(mobile: 36.0, tablet: 44.0),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceLight,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  command.icon,
                  color: AppTheme.primary,
                  size: context.rValue(mobile: 18.0, tablet: 20.0),
                ),
              ),
              SizedBox(width: context.rSpacing * 1.5),

              // Command name + description
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '/',
                          style: TextStyle(
                            color: AppTheme.primary,
                            fontSize: context.bodyFontSize,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          command.command,
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: context.bodyFontSize,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: context.rSpacing * 0.25),
                    Text(
                      command.description,
                      style: TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: context.captionFontSize,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),

              // Chevron for commands that need args
              if (command.needsArgs)
                Padding(
                  padding: EdgeInsets.only(left: context.rSpacing * 0.5),
                  child: Icon(
                    Icons.chevron_right,
                    color: AppTheme.textMuted,
                    size: context.rIconSize,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
