import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/monokai-sublime.dart';
import '../../../models/message.dart';
import '../../../shared/responsive.dart';
import '../../../shared/theme.dart';

/// Rich tool use card matching the reference design.
/// Shows file edits with diffs, bash commands with output,
/// code files with syntax highlighting, etc.
class ToolUseCard extends StatefulWidget {
  final Message message;
  final void Function(String text)? onSendMessage;

  const ToolUseCard({super.key, required this.message, this.onSendMessage});

  @override
  State<ToolUseCard> createState() => _ToolUseCardState();
}

class _ToolUseCardState extends State<ToolUseCard> {
  bool _expanded = false;

  Message get message => widget.message;

  @override
  Widget build(BuildContext context) {
    final isError = message.toolStatus == 'error';

    return Container(
      margin: EdgeInsets.symmetric(vertical: context.rSpacing * 0.5),
      decoration: BoxDecoration(
        color: const Color(0xFF161825),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isError
              ? Colors.red.withValues(alpha: 0.4)
              : _toolColor.withValues(alpha: 0.15),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context, isError),
          if (_expanded) _buildBody(context),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, bool isError) {
    final color = isError ? Colors.red : _toolColor;
    final subtitle = _headerSubtitle;

    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: context.rSpacing * 1.75, vertical: context.rSpacing * 1.25),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: _expanded
              ? const BorderRadius.vertical(top: Radius.circular(12))
              : BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            // Tool icon in a rounded rect
            Container(
              width: context.rValue(mobile: 28.0, tablet: 34.0),
              height: context.rValue(mobile: 28.0, tablet: 34.0),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(_toolIcon, size: context.rValue(mobile: 16.0, tablet: 22.0), color: color),
            ),
            SizedBox(width: context.rSpacing),
            // Title + subtitle
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _headerTitle,
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: context.captionFontSize,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null) ...[
                    SizedBox(height: context.rSpacing * 0.25),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: context.rFontSize(mobile: 11, tablet: 13),
                        fontFamily: 'monospace',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            // Status icon
            if (isError)
              Icon(Icons.error_outline, size: context.rValue(mobile: 18.0, tablet: 22.0), color: Colors.red)
            else if (message.toolStatus == 'success')
              Icon(Icons.check_circle, size: context.rValue(mobile: 18.0, tablet: 22.0), color: Colors.green.shade400),
            SizedBox(width: context.rSpacing * 0.75),
            // Expand/collapse chevron
            Icon(
              _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              size: context.rValue(mobile: 18.0, tablet: 22.0),
              color: AppTheme.textMuted,
            ),
          ],
        ),
      ),
    );
  }

  String get _headerTitle {
    switch (message.toolName) {
      case 'Edit':
        return 'Edit File';
      case 'Write':
        return 'Create File';
      case 'Bash':
        return 'Terminal';
      case 'Read':
        return 'Read File';
      case 'Glob':
        return 'Find Files';
      case 'Grep':
        return 'Search Code';
      case 'TaskCreate':
        return 'Create Task';
      case 'TaskUpdate':
        return 'Update Task';
      case 'TaskList':
        return 'Task List';
      case 'TaskGet':
        return 'Get Task';
      default:
        return message.toolName ?? 'Tool';
    }
  }

  String? get _headerSubtitle {
    final input = message.toolInput ?? {};
    switch (message.toolName) {
      case 'Edit':
      case 'Write':
      case 'Read':
        final path = input['file_path'] as String? ?? '';
        if (path.isEmpty) return null;
        return path.split('/').last;
      case 'Bash':
        final cmd = input['command'] as String? ?? '';
        if (cmd.isEmpty) return null;
        return cmd.length > 50 ? '${cmd.substring(0, 47)}...' : cmd;
      case 'Glob':
        return input['pattern'] as String?;
      case 'Grep':
        return input['pattern'] as String?;
      case 'TaskCreate':
        return input['subject'] as String?;
      case 'TaskUpdate':
        final status = input['status'] as String?;
        final subject = input['subject'] as String?;
        if (subject != null && status != null) return '$subject → $status';
        return status ?? subject;
      case 'TaskList':
        return null;
      case 'TaskGet':
        return 'Task #${input['taskId'] ?? '?'}';
      default:
        return null;
    }
  }

  Widget _buildBody(BuildContext context) {
    switch (message.toolName) {
      case 'Edit':
        return _EditBody(message: message);
      case 'Write':
        return _WriteBody(message: message);
      case 'Bash':
        return _BashBody(message: message);
      case 'Read':
        return _ReadBody(message: message);
      case 'TaskCreate':
      case 'TaskUpdate':
      case 'TaskList':
      case 'TaskGet':
        return _TaskBody(message: message);
      default:
        return _GenericBody(message: message);
    }
  }

  IconData get _toolIcon {
    switch (message.toolName) {
      case 'Edit':
        return Icons.edit_note_rounded;
      case 'Write':
        return Icons.note_add_rounded;
      case 'Bash':
        return Icons.terminal_rounded;
      case 'Read':
        return Icons.description_rounded;
      case 'Glob':
        return Icons.folder_open_rounded;
      case 'Grep':
        return Icons.manage_search_rounded;
      case 'TaskCreate':
      case 'TaskUpdate':
      case 'TaskList':
      case 'TaskGet':
        return Icons.checklist_rounded;
      default:
        return Icons.build_rounded;
    }
  }

  Color get _toolColor {
    switch (message.toolName) {
      case 'Edit':
        return Colors.orange;
      case 'Write':
        return const Color(0xFF4FC3F7);
      case 'Bash':
        return Colors.green;
      case 'Read':
        return Colors.cyan;
      case 'Glob':
        return Colors.purple;
      case 'Grep':
        return Colors.amber;
      case 'TaskCreate':
      case 'TaskUpdate':
      case 'TaskList':
      case 'TaskGet':
        return const Color(0xFF4DD0E1); // teal
      default:
        return AppTheme.primary;
    }
  }
}

class _EditBody extends StatelessWidget {
  final Message message;
  const _EditBody({required this.message});

  @override
  Widget build(BuildContext context) {
    final input = message.toolInput ?? {};
    final filePath = input['file_path'] as String? ?? '';
    final oldStr = input['old_string'] as String? ?? '';
    final newStr = input['new_string'] as String? ?? '';

    if (oldStr.isEmpty && newStr.isEmpty) return const SizedBox.shrink();

    final truncOld = oldStr.length > 3000 ? '${oldStr.substring(0, 3000)}\n...(truncated)' : oldStr;
    final truncNew = newStr.length > 3000 ? '${newStr.substring(0, 3000)}\n...(truncated)' : newStr;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // File path bar
        if (filePath.isNotEmpty)
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(horizontal: context.rSpacing * 1.75, vertical: context.rSpacing * 0.75),
            color: Colors.black.withValues(alpha: 0.2),
            child: Row(
              children: [
                Icon(Icons.insert_drive_file_outlined, size: context.rValue(mobile: 14.0, tablet: 16.0), color: AppTheme.textMuted),
                SizedBox(width: context.rSpacing * 0.75),
                Expanded(
                  child: Text(
                    filePath,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: context.rFontSize(mobile: 11, tablet: 13),
                      color: AppTheme.textMuted,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _CopyIconButton(text: truncNew.isNotEmpty ? truncNew : truncOld),
              ],
            ),
          ),
        // Diff content
        Padding(
          padding: EdgeInsets.all(context.rSpacing * 1.25),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (oldStr.isNotEmpty)
                _DiffBlock(
                  content: truncOld,
                  isAddition: false,
                ),
              if (oldStr.isNotEmpty && newStr.isNotEmpty)
                SizedBox(height: context.rSpacing * 0.5),
              if (newStr.isNotEmpty)
                _DiffBlock(
                  content: truncNew,
                  isAddition: true,
                ),
            ],
          ),
        ),
        // Action row
        _ActionRow(
          actions: [
            _ActionChip(label: 'Explain', icon: Icons.lightbulb_outline, onTap: () {
              final filePath = input['file_path'] as String? ?? 'this file';
              context.findAncestorStateOfType<_ToolUseCardState>()?.widget.onSendMessage?.call(
                'Explain the changes you just made to $filePath',
              );
            }),
            _ActionChip(label: 'Copy', icon: Icons.copy_rounded, onTap: () {
              Clipboard.setData(ClipboardData(text: truncNew.isNotEmpty ? truncNew : truncOld));
            }),
          ],
        ),
      ],
    );
  }
}

class _BashBody extends StatelessWidget {
  final Message message;
  const _BashBody({required this.message});

  @override
  Widget build(BuildContext context) {
    final input = message.toolInput ?? {};
    final command = input['command'] as String? ?? '';
    final result = message.toolResult;
    final error = message.toolError;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Command display
        if (command.isNotEmpty)
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(horizontal: context.rSpacing * 1.75, vertical: context.rSpacing * 1.25),
            color: Colors.black.withValues(alpha: 0.3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '\$ ',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: context.captionFontSize,
                    color: Colors.green.shade300,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Expanded(
                  child: SelectableText(
                    command,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: context.captionFontSize,
                      color: Colors.green.shade200,
                    ),
                  ),
                ),
              ],
            ),
          ),
        // Output
        if (result != null && result.isNotEmpty)
          Container(
            width: double.infinity,
            constraints: BoxConstraints(maxHeight: context.rValue(mobile: 300.0, tablet: 400.0)),
            color: Colors.black.withValues(alpha: 0.15),
            child: SingleChildScrollView(
              child: HighlightView(
                result.length > 5000 ? '${result.substring(0, 5000)}\n...(truncated)' : result,
                language: 'bash',
                theme: monokaiSublimeTheme,
                padding: EdgeInsets.all(context.rSpacing * 1.25),
                textStyle: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: context.rFontSize(mobile: 11, tablet: 13),
                  height: 1.4,
                ),
              ),
            ),
          ),
        // Error
        if (error != null && error.isNotEmpty)
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(context.rSpacing * 1.25),
            color: Colors.red.withValues(alpha: 0.08),
            child: SelectableText(
              error,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: context.rFontSize(mobile: 11, tablet: 13),
                color: Colors.redAccent,
                height: 1.4,
              ),
            ),
          ),
        // Actions
        _ActionRow(
          actions: [
            _ActionChip(label: 'Explain', icon: Icons.lightbulb_outline, onTap: () {
              context.findAncestorStateOfType<_ToolUseCardState>()?.widget.onSendMessage?.call(
                'Explain what this command does: $command',
              );
            }),
            _ActionChip(label: 'Copy', icon: Icons.copy_rounded, onTap: () {
              Clipboard.setData(ClipboardData(text: command));
            }),
            if (result != null && result.isNotEmpty)
              _ActionChip(label: 'Copy Output', icon: Icons.content_copy_rounded, onTap: () {
                Clipboard.setData(ClipboardData(text: result));
              }),
          ],
        ),
      ],
    );
  }
}

class _WriteBody extends StatelessWidget {
  final Message message;
  const _WriteBody({required this.message});

  @override
  Widget build(BuildContext context) {
    final input = message.toolInput ?? {};
    final filePath = input['file_path'] as String? ?? '';
    final content = input['content'] as String? ?? '';
    final language = _languageFromPath(filePath);

    if (content.isEmpty) return const SizedBox.shrink();

    final truncated = content.length > 5000
        ? '${content.substring(0, 5000)}\n...(truncated)'
        : content;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (filePath.isNotEmpty)
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(horizontal: context.rSpacing * 1.75, vertical: context.rSpacing * 0.75),
            color: Colors.black.withValues(alpha: 0.2),
            child: Row(
              children: [
                Icon(Icons.insert_drive_file_outlined, size: context.rValue(mobile: 14.0, tablet: 16.0), color: AppTheme.textMuted),
                SizedBox(width: context.rSpacing * 0.75),
                Expanded(
                  child: Text(
                    filePath,
                    style: TextStyle(fontFamily: 'monospace', fontSize: context.rFontSize(mobile: 11, tablet: 13), color: AppTheme.textMuted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (language != null)
                  Padding(
                    padding: EdgeInsets.only(right: context.rSpacing),
                    child: Text(
                      language,
                      style: TextStyle(fontSize: context.rFontSize(mobile: 10, tablet: 12), color: AppTheme.textMuted.withValues(alpha: 0.6)),
                    ),
                  ),
                _CopyIconButton(text: content),
              ],
            ),
          ),
        Container(
          width: double.infinity,
          constraints: BoxConstraints(maxHeight: context.rValue(mobile: 300.0, tablet: 400.0)),
          color: const Color(0xFF23241F),
          child: SingleChildScrollView(
            child: HighlightView(
              truncated,
              language: language ?? 'plaintext',
              theme: monokaiSublimeTheme,
              padding: EdgeInsets.all(context.rSpacing * 1.25),
              textStyle: TextStyle(
                fontFamily: 'monospace',
                fontSize: context.rFontSize(mobile: 11, tablet: 13),
                height: 1.4,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ReadBody extends StatelessWidget {
  final Message message;
  const _ReadBody({required this.message});

  @override
  Widget build(BuildContext context) {
    final input = message.toolInput ?? {};
    final filePath = input['file_path'] as String? ?? '';
    final result = message.toolResult;

    if (result == null || result.isEmpty) return const SizedBox.shrink();

    final truncated = result.length > 5000
        ? '${result.substring(0, 5000)}\n...(truncated)'
        : result;
    final language = _languageFromPath(filePath);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (filePath.isNotEmpty)
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(horizontal: context.rSpacing * 1.75, vertical: context.rSpacing * 0.75),
            color: Colors.black.withValues(alpha: 0.2),
            child: Row(
              children: [
                Icon(Icons.insert_drive_file_outlined, size: context.rValue(mobile: 14.0, tablet: 16.0), color: AppTheme.textMuted),
                SizedBox(width: context.rSpacing * 0.75),
                Expanded(
                  child: Text(
                    filePath,
                    style: TextStyle(fontFamily: 'monospace', fontSize: context.rFontSize(mobile: 11, tablet: 13), color: AppTheme.textMuted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (language != null)
                  Padding(
                    padding: EdgeInsets.only(right: context.rSpacing),
                    child: Text(
                      language,
                      style: TextStyle(fontSize: context.rFontSize(mobile: 10, tablet: 12), color: AppTheme.textMuted.withValues(alpha: 0.6)),
                    ),
                  ),
                _CopyIconButton(text: result),
              ],
            ),
          ),
        Container(
          width: double.infinity,
          constraints: BoxConstraints(maxHeight: context.rValue(mobile: 300.0, tablet: 400.0)),
          color: const Color(0xFF23241F),
          child: SingleChildScrollView(
            child: HighlightView(
              truncated,
              language: language ?? 'plaintext',
              theme: monokaiSublimeTheme,
              padding: EdgeInsets.all(context.rSpacing * 1.25),
              textStyle: TextStyle(
                fontFamily: 'monospace',
                fontSize: context.rFontSize(mobile: 11, tablet: 13),
                height: 1.4,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TaskBody extends StatelessWidget {
  final Message message;
  const _TaskBody({required this.message});

  @override
  Widget build(BuildContext context) {
    switch (message.toolName) {
      case 'TaskCreate':
        return _buildTaskCreate(context);
      case 'TaskUpdate':
        return _buildTaskUpdate(context);
      case 'TaskList':
        return _buildTaskList(context);
      case 'TaskGet':
        return _buildTaskGet(context);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildTaskCreate(BuildContext context) {
    final input = message.toolInput ?? {};
    final subject = input['subject'] as String? ?? '';
    final description = input['description'] as String? ?? '';

    return Padding(
      padding: EdgeInsets.all(context.rSpacing * 1.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: context.rSpacing * 0.25),
            child: Icon(Icons.radio_button_unchecked, size: context.rValue(mobile: 18.0, tablet: 20.0), color: AppTheme.textMuted),
          ),
          SizedBox(width: context.rSpacing * 1.25),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  subject,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: context.rFontSize(mobile: 13, tablet: 15),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (description.isNotEmpty) ...[
                  SizedBox(height: context.rSpacing * 0.5),
                  Text(
                    description.length > 200 ? '${description.substring(0, 197)}...' : description,
                    style: TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: context.captionFontSize,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskUpdate(BuildContext context) {
    final input = message.toolInput ?? {};
    final taskId = input['taskId'] as String? ?? '?';
    final status = input['status'] as String?;
    final subject = input['subject'] as String?;

    return Padding(
      padding: EdgeInsets.all(context.rSpacing * 1.5),
      child: Row(
        children: [
          _statusIcon(status, context),
          SizedBox(width: context.rSpacing * 1.25),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  subject ?? 'Task #$taskId',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: context.rFontSize(mobile: 13, tablet: 15),
                    fontWeight: FontWeight.w500,
                    decoration: status == 'completed' ? TextDecoration.lineThrough : null,
                    decorationColor: AppTheme.textMuted,
                  ),
                ),
                if (status != null) ...[
                  SizedBox(height: context.rSpacing * 0.25),
                  Text(
                    status,
                    style: TextStyle(
                      color: _statusColor(status),
                      fontSize: context.rFontSize(mobile: 11, tablet: 13),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskList(BuildContext context) {
    final result = message.toolResult;
    if (result == null || result.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(context.rSpacing * 1.5),
        child: Text('No tasks', style: TextStyle(color: AppTheme.textMuted, fontSize: context.captionFontSize)),
      );
    }

    // TaskList result is text like "#1. [completed] Fix bug\n#2. [in_progress] Add feature"
    final lines = result.split('\n').where((l) => l.trim().isNotEmpty).toList();

    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.rSpacing, horizontal: context.rSpacing * 1.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: lines.map((line) => _buildTaskLine(line, context)).toList(),
      ),
    );
  }

  Widget _buildTaskLine(String line, BuildContext context) {
    // Parse lines like "#1. [completed] Fix bug" or "#2. [in_progress] Add feature"
    final statusMatch = RegExp(r'\[([\w_]+)\]').firstMatch(line);
    final status = statusMatch?.group(1);

    // Extract the text after the status bracket
    final textStart = statusMatch != null ? statusMatch.end : 0;
    final subject = line.substring(textStart).trim();

    // Extract task ID
    final idMatch = RegExp(r'#(\d+)').firstMatch(line);
    final taskId = idMatch?.group(1) ?? '';

    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.rSpacing * 0.375),
      child: Row(
        children: [
          _statusIcon(status, context),
          SizedBox(width: context.rSpacing),
          if (taskId.isNotEmpty) ...[
            Text(
              '#$taskId',
              style: TextStyle(
                color: AppTheme.textMuted,
                fontSize: context.rFontSize(mobile: 11, tablet: 13),
                fontFamily: 'monospace',
              ),
            ),
            SizedBox(width: context.rSpacing * 0.75),
          ],
          Expanded(
            child: Text(
              subject,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: context.captionFontSize,
                decoration: status == 'completed' ? TextDecoration.lineThrough : null,
                decorationColor: AppTheme.textMuted,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskGet(BuildContext context) {
    final result = message.toolResult;
    if (result == null || result.isEmpty) return const SizedBox.shrink();

    // TaskGet returns task details as text
    return Padding(
      padding: EdgeInsets.all(context.rSpacing * 1.5),
      child: Text(
        result.length > 500 ? '${result.substring(0, 497)}...' : result,
        style: TextStyle(
          color: AppTheme.textSecondary,
          fontSize: context.captionFontSize,
          height: 1.4,
        ),
      ),
    );
  }

  Widget _statusIcon(String? status, BuildContext context) {
    final iconSize = context.rValue(mobile: 18.0, tablet: 20.0);
    switch (status) {
      case 'completed':
        return Icon(Icons.check_circle, size: iconSize, color: Colors.green.shade400);
      case 'in_progress':
        return SizedBox(
          width: iconSize,
          height: iconSize,
          child: const CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF4DD0E1)),
        );
      case 'deleted':
        return Icon(Icons.remove_circle_outline, size: iconSize, color: AppTheme.textMuted);
      default: // pending
        return Icon(Icons.radio_button_unchecked, size: iconSize, color: AppTheme.textMuted);
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'completed':
        return Colors.green.shade400;
      case 'in_progress':
        return const Color(0xFF4DD0E1);
      case 'deleted':
        return AppTheme.textMuted;
      default:
        return AppTheme.textSecondary;
    }
  }
}

class _GenericBody extends StatelessWidget {
  final Message message;
  const _GenericBody({required this.message});

  @override
  Widget build(BuildContext context) {
    final text = message.toolError ?? message.toolResult;
    if (text == null || text.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.all(context.rSpacing * 1.25),
      child: SelectableText(
        text.length > 3000 ? '${text.substring(0, 3000)}\n...(truncated)' : text,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: context.captionFontSize,
          color: message.toolError != null ? Colors.redAccent : AppTheme.textSecondary,
          height: 1.4,
        ),
      ),
    );
  }
}

/// Diff block with colored background and line-by-line display
class _DiffBlock extends StatelessWidget {
  final String content;
  final bool isAddition;

  const _DiffBlock({required this.content, required this.isAddition});

  @override
  Widget build(BuildContext context) {
    final color = isAddition ? Colors.green : Colors.red;
    final prefix = isAddition ? '+' : '-';
    final lines = content.split('\n');

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.rSpacing),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border(
          left: BorderSide(color: color.withValues(alpha: 0.6), width: 3),
        ),
      ),
      child: SelectableText(
        lines.map((line) => '$prefix $line').join('\n'),
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: context.captionFontSize,
          color: color.withValues(alpha: 0.9),
          height: 1.5,
        ),
      ),
    );
  }
}

/// Row of action chips at the bottom of a card
class _ActionRow extends StatelessWidget {
  final List<Widget> actions;
  const _ActionRow({required this.actions});

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(horizontal: context.rSpacing * 1.25, vertical: context.rSpacing),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: Wrap(
        spacing: context.rSpacing,
        runSpacing: context.rSpacing * 0.5,
        children: actions,
      ),
    );
  }
}

/// Small action chip button (Explain, Copy, etc.)
class _ActionChip extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _ActionChip({required this.label, required this.icon, required this.onTap});

  @override
  State<_ActionChip> createState() => _ActionChipState();
}

class _ActionChipState extends State<_ActionChip> {
  bool _tapped = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        widget.onTap();
        setState(() => _tapped = true);
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => _tapped = false);
        });
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: context.rSpacing * 1.25, vertical: context.rSpacing * 0.625),
        decoration: BoxDecoration(
          color: _tapped
              ? Colors.green.withValues(alpha: 0.15)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _tapped
                ? Colors.green.withValues(alpha: 0.3)
                : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _tapped ? Icons.check : widget.icon,
              size: context.rValue(mobile: 13.0, tablet: 15.0),
              color: _tapped ? Colors.green : AppTheme.textMuted,
            ),
            SizedBox(width: context.rSpacing * 0.5),
            Text(
              _tapped ? 'Done' : widget.label,
              style: TextStyle(
                fontSize: context.rFontSize(mobile: 11, tablet: 13),
                color: _tapped ? Colors.green : AppTheme.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small copy icon button for file path rows
class _CopyIconButton extends StatefulWidget {
  final String text;
  const _CopyIconButton({required this.text});

  @override
  State<_CopyIconButton> createState() => _CopyIconButtonState();
}

class _CopyIconButtonState extends State<_CopyIconButton> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Clipboard.setData(ClipboardData(text: widget.text));
        setState(() => _copied = true);
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => _copied = false);
        });
      },
      child: Icon(
        _copied ? Icons.check : Icons.copy_rounded,
        size: context.rValue(mobile: 14.0, tablet: 16.0),
        color: _copied ? Colors.green : AppTheme.textMuted,
      ),
    );
  }
}

/// Detect programming language from file path extension.
String? _languageFromPath(String path) {
  if (path.isEmpty) return null;
  final ext = path.split('.').last.toLowerCase();
  switch (ext) {
    case 'dart': return 'dart';
    case 'rs': return 'rust';
    case 'py': return 'python';
    case 'js': return 'javascript';
    case 'ts': return 'typescript';
    case 'jsx': case 'tsx': return 'typescript';
    case 'json': return 'json';
    case 'yaml': case 'yml': return 'yaml';
    case 'toml': return 'toml';
    case 'html': return 'html';
    case 'css': return 'css';
    case 'md': return 'markdown';
    case 'sh': case 'bash': case 'zsh': return 'bash';
    case 'sql': return 'sql';
    case 'xml': return 'xml';
    case 'java': return 'java';
    case 'kt': case 'kts': return 'kotlin';
    case 'swift': return 'swift';
    case 'go': return 'go';
    case 'c': case 'h': return 'c';
    case 'cpp': case 'hpp': case 'cc': return 'cpp';
    case 'rb': return 'ruby';
    case 'php': return 'php';
    case 'r': return 'r';
    case 'scala': return 'scala';
    case 'lua': return 'lua';
    case 'groovy': return 'groovy';
    case 'tf': return 'hcl';
    case 'dockerfile': return 'dockerfile';
    case 'makefile': return 'makefile';
    default: return null;
  }
}
