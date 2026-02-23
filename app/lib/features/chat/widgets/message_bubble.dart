import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/platform/security_channel.dart';
import '../../../models/message.dart';
import '../../../shared/extensions.dart';
import '../../../shared/responsive.dart';
import '../../../shared/theme.dart';
import 'code_block.dart';
import 'diff_view.dart';
import 'ask_question_card.dart';
import 'file_transfer_card.dart';
import 'tool_use_card.dart';

/// Renders a single chat message bubble.
///
/// Layout varies by [MessageSender]:
///  - **claude**: left-aligned, dark surface background.
///  - **user**: right-aligned, blue background.
///  - **system**: centered, muted style.
///
/// Content rendering varies by [MessageType]:
///  - **text**: Markdown.
///  - **code**: Syntax-highlighted code block.
///  - **diff**: Unified diff viewer.
///  - **action**: Prompt text (the buttons are in [ActionButtonsBar]).
///  - **system**: Plain text, smaller.
class MessageBubble extends StatelessWidget {
  final Message message;
  final bool smartMode;
  final bool isQueued;
  final void Function(String text)? onSendMessage;

  const MessageBubble({super.key, required this.message, this.smartMode = true, this.isQueued = false, this.onSendMessage});

  @override
  Widget build(BuildContext context) {
    if (message.type == MessageType.system) {
      return _SystemBubble(message: message, smartMode: smartMode);
    }

    // File transfer messages render as a dedicated card, not a chat bubble.
    if (message.type == MessageType.fileOffer ||
        message.type == MessageType.fileProgress ||
        message.type == MessageType.fileComplete) {
      return FileTransferCard(
        message: message,
        onAccept: message.transferId != null
            ? () {
                debugPrint('[FileTransfer] Accept: ${message.transferId}');
                SecurityChannel().acceptFileTransfer(message.transferId!);
              }
            : null,
        onDecline: message.transferId != null
            ? () {
                debugPrint('[FileTransfer] Decline: ${message.transferId}');
                SecurityChannel().cancelFileTransfer(message.transferId!);
              }
            : null,
        onOpen: message.localFilePath != null
            ? () {
                debugPrint('[FileTransfer] Open: ${message.localFilePath}');
                final type = lookupMimeType(message.localFilePath!) ?? 'application/octet-stream';
                OpenFilex.open(message.localFilePath!, type: type);
              }
            : null,
        onShare: message.localFilePath != null
            ? () {
                debugPrint('[FileTransfer] Share: ${message.localFilePath}');
                final file = XFile(message.localFilePath!);
                SharePlus.instance.share(ShareParams(files: [file]));
              }
            : null,
      );
    }

    final isUser = message.sender == MessageSender.user;

    // ── Terminal mode: no bubbles, full-width, left-aligned, rich content ──
    if (!smartMode) {
      return GestureDetector(
        onLongPress: () {
          Clipboard.setData(ClipboardData(text: message.content));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Copied to clipboard'),
              duration: Duration(seconds: 1),
            ),
          );
        },
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: context.rSpacing * 0.5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Section label based on message type
              if (_terminalLabel != null)
                Padding(
                  padding: EdgeInsets.only(bottom: context.rSpacing * 0.25),
                  child: Row(
                    children: [
                      Icon(
                        _terminalIcon,
                        size: context.rValue(mobile: 13.0, tablet: 15.0),
                        color: _terminalLabelColor,
                      ),
                      SizedBox(width: context.rSpacing * 0.5),
                      Text(
                        _terminalLabel!,
                        style: TextStyle(
                          fontSize: context.captionFontSize,
                          fontWeight: FontWeight.w600,
                          color: _terminalLabelColor,
                        ),
                      ),
                    ],
                  ),
                ),
              _buildContent(context),
              SizedBox(height: context.rSpacing * 0.25),
              _Timestamp(time: message.timestamp, isQueued: isUser && isQueued),
            ],
          ),
        ),
      );
    }

    // ── Smart mode: original bubble layout (terminal labels not used here) ──
    final alignment = isUser ? Alignment.centerRight : Alignment.centerLeft;
    final bubbleColor = isUser ? AppTheme.userBubble : AppTheme.claudeBubble;
    final borderRadius = BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomLeft: Radius.circular(isUser ? 16 : 4),
      bottomRight: Radius.circular(isUser ? 4 : 16),
    );

    return GestureDetector(
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: message.content));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Copied to clipboard'),
            duration: Duration(seconds: 1),
          ),
        );
      },
      child: Align(
        alignment: alignment,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: context.rChatBubbleMaxWidth,
          ),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: context.rHorizontalPadding * 1.15,
              vertical: context.rSpacing * 1.25,
            ),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: borderRadius,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildContent(context),
                SizedBox(height: context.rSpacing * 0.5),
                _Timestamp(time: message.timestamp, isQueued: isUser && isQueued),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Terminal mode label for this message (null = no label).
  String? get _terminalLabel {
    if (message.sender == MessageSender.user) return 'You';
    if (message.sender == MessageSender.system) return null; // system bubble handles itself
    // Claude messages
    switch (message.type) {
      case MessageType.claudeResponse:
        return 'Claude';
      case MessageType.text:
        return message.id.startsWith('progress_') ? null : 'Output';
      case MessageType.thinking:
        return 'Thinking';
      case MessageType.toolUse:
        return null; // ToolUseCard has its own header
      case MessageType.code:
        return 'Code';
      case MessageType.diff:
        return 'Changes';
      case MessageType.action:
        return 'Permission Required';
      case MessageType.askQuestion:
        return 'Question';
      case MessageType.subagentEvent:
        return 'Agent';
      default:
        return null;
    }
  }

  /// Terminal mode icon for the label.
  IconData get _terminalIcon {
    if (message.sender == MessageSender.user) return Icons.person_rounded;
    switch (message.type) {
      case MessageType.claudeResponse:
        return Icons.smart_toy_rounded;
      case MessageType.text:
        return Icons.notes_rounded;
      case MessageType.thinking:
        return Icons.psychology_rounded;
      case MessageType.code:
        return Icons.code_rounded;
      case MessageType.diff:
        return Icons.compare_arrows_rounded;
      case MessageType.action:
        return Icons.security_rounded;
      case MessageType.askQuestion:
        return Icons.help_outline_rounded;
      case MessageType.subagentEvent:
        return Icons.hub_rounded;
      default:
        return Icons.info_outline_rounded;
    }
  }

  /// Terminal mode label color.
  Color get _terminalLabelColor {
    if (message.sender == MessageSender.user) return AppTheme.primary;
    switch (message.type) {
      case MessageType.claudeResponse:
        return AppTheme.accent;
      case MessageType.thinking:
        return AppTheme.textMuted;
      case MessageType.action:
        return AppTheme.warning;
      case MessageType.code:
      case MessageType.diff:
        return AppTheme.brandCyan;
      case MessageType.askQuestion:
        return AppTheme.primary;
      case MessageType.subagentEvent:
        return AppTheme.brandPurple;
      default:
        return AppTheme.textSecondary;
    }
  }

  Widget _buildContent(BuildContext context) {
    switch (message.type) {
      case MessageType.code:
        return CodeBlock(
          code: message.content,
          language: message.language,
        );

      case MessageType.diff:
        if (message.diffLines != null && message.diffLines!.isNotEmpty) {
          return DiffView(lines: message.diffLines!);
        }
        // Fallback: render raw diff text.
        return _MarkdownContent(content: '```diff\n${message.content}\n```');

      case MessageType.action:
        return Text(
          message.content,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: AppTheme.textPrimary,
              ),
        );

      case MessageType.toolUse:
        return ToolUseCard(message: message, onSendMessage: onSendMessage);

      case MessageType.askQuestion:
        if (message.questions != null && message.questions!.isNotEmpty) {
          return AskQuestionCard(
            questions: message.questions!,
            onAnswer: (answer) => onSendMessage?.call(answer),
          );
        }
        return _MarkdownContent(content: message.content);

      case MessageType.thinking:
        return _ThinkingIndicator(status: message.content);

      // Progress text during thinking — compact single line
      case MessageType.text when message.id.startsWith('progress_'):
        final lines = message.content.split('\n');
        final lastLine = lines.lastWhere(
          (l) => l.trim().isNotEmpty,
          orElse: () => lines.last,
        );
        final truncated = lastLine.length > 80
            ? '${lastLine.substring(0, 77)}...'
            : lastLine;
        return Text(
          truncated,
          style: TextStyle(
            fontSize: context.rFontSize(mobile: 13, tablet: 15),
            color: AppTheme.textMuted,
            fontStyle: FontStyle.italic,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );

      case MessageType.claudeResponse:
      case MessageType.text:
      case MessageType.system:
      case MessageType.subagentEvent:
      case MessageType.fileOffer:
      case MessageType.fileProgress:
      case MessageType.fileComplete:
      case MessageType.sessionList:
        return _MarkdownContent(content: message.content);
    }
  }
}

/// Renders markdown text inside a bubble.
class _MarkdownContent extends StatelessWidget {
  final String content;

  const _MarkdownContent({required this.content});

  @override
  Widget build(BuildContext context) {
    // Check if content looks like terminal output (has multiple lines with specific patterns)
    final isTerminalOutput = _isTerminalOutput(content);

    if (isTerminalOutput) {
      return _TerminalOutput(content: content);
    }

    return MarkdownBody(
      data: content,
      selectable: false, // Disabled to avoid flutter_markdown bug
      styleSheet: MarkdownStyleSheet(
        p: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: AppTheme.textPrimary,
              height: 1.4,
            ),
        code: TextStyle(
          fontFamily: 'monospace',
          fontSize: context.codeFontSize,
          color: AppTheme.primaryLight,
          backgroundColor: AppTheme.surfaceLight,
        ),
        codeblockDecoration: BoxDecoration(
          color: AppTheme.surfaceLight,
          borderRadius: BorderRadius.circular(8),
        ),
        a: const TextStyle(
          color: AppTheme.accent,
          decoration: TextDecoration.underline,
        ),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: AppTheme.textMuted.withValues(alpha: 0.4),
              width: 3,
            ),
          ),
        ),
      ),
    );
  }

  bool _isTerminalOutput(String text) {
    // Detect terminal-like output
    final patterns = [
      '---',
      '>>>',
      '> ',
      '❯',
      'Enter to confirm',
      'Esc to cancel',
      'Accessing workspace',
      'Claude Code',
      'Task(',
      'Read(',
      'Edit(',
      'Write(',
      'Bash(',
      'Grep(',
      'Glob(',
      '✓',
      '✗',
      '⏳',
      'Working on',
      'Thinking',
      'Completed',
      '│',
      '├',
      '└',
    ];

    for (final pattern in patterns) {
      if (text.contains(pattern)) {
        return true;
      }
    }

    // Also detect if it has multiple lines with consistent indentation
    final lines = text.split('\n');
    if (lines.length > 3) {
      final leadingSpaces = lines.where((l) => l.startsWith('  ')).length;
      if (leadingSpaces > lines.length / 2) {
        return true;
      }
    }

    return false;
  }
}

/// Renders terminal output in a styled container with smart formatting.
///
/// Uses a single [SelectableText.rich] with styled [TextSpan] children instead
/// of a Column of per-line widgets, reducing the widget count from ~5N to 1.
class _TerminalOutput extends StatelessWidget {
  final String content;

  const _TerminalOutput({required this.content});

  @override
  Widget build(BuildContext context) {
    final lines = content.split('\n');

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.rSpacing * 1.5),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.1),
          width: 1,
        ),
      ),
      child: SelectableText.rich(
        TextSpan(
          children: _buildSpans(context, lines),
        ),
      ),
    );
  }

  List<TextSpan> _buildSpans(BuildContext context, List<String> lines) {
    final spans = <TextSpan>[];
    for (int i = 0; i < lines.length; i++) {
      if (i > 0) spans.add(const TextSpan(text: '\n'));
      spans.add(_buildSpan(context, lines[i]));
    }
    return spans;
  }

  TextSpan _buildSpan(BuildContext context, String line) {
    final trimmed = line.trim();

    // Separator lines (---)
    if (trimmed.startsWith('---') || trimmed.startsWith('───')) {
      return TextSpan(
        text: '────────────────────',
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: context.captionFontSize,
          color: Colors.white.withValues(alpha: 0.15),
          height: 1.5,
        ),
      );
    }

    // Prompt lines (> or ❯)
    if (trimmed.startsWith('>') || trimmed.startsWith('❯')) {
      return TextSpan(
        children: [
          TextSpan(
            text: '❯ ',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: context.codeFontSize,
              color: AppTheme.primary,
              fontWeight: FontWeight.bold,
              height: 1.5,
            ),
          ),
          TextSpan(
            text: trimmed.substring(1).trim(),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: context.codeFontSize,
              color: AppTheme.textPrimary,
              height: 1.5,
            ),
          ),
        ],
      );
    }

    // Action hints (Esc, Enter, etc.)
    if (trimmed.contains('Esc to') || trimmed.contains('Enter to') ||
        trimmed.contains('to confirm') || trimmed.contains('to cancel')) {
      return TextSpan(
        text: '\u2328 $trimmed',
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: context.rFontSize(mobile: 11, tablet: 13),
          color: AppTheme.textMuted,
          fontStyle: FontStyle.italic,
          height: 1.5,
        ),
      );
    }

    // Status messages (✓, ✗, ●, etc.)
    Color? statusColor;
    if (trimmed.contains('✓') || trimmed.contains('success') || trimmed.contains('done')) {
      statusColor = Colors.green;
    } else if (trimmed.contains('✗') || trimmed.contains('error') || trimmed.contains('failed')) {
      statusColor = AppTheme.error;
    } else if (trimmed.contains('⏳') || trimmed.contains('...') || trimmed.contains('loading')) {
      statusColor = AppTheme.accent;
    }

    // Regular line (including status-colored lines)
    return TextSpan(
      text: line,
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: context.captionFontSize,
        color: statusColor ?? AppTheme.textPrimary,
        height: 1.5,
      ),
    );
  }
}

/// Animated thinking/processing indicator.
class _ThinkingIndicator extends StatelessWidget {
  final String status;

  const _ThinkingIndicator({required this.status});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: context.rValue(mobile: 16.0, tablet: 18.0),
          height: context.rValue(mobile: 16.0, tablet: 18.0),
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppTheme.primary,
          ),
        ),
        SizedBox(width: context.rSpacing * 1.25),
        Flexible(
          child: Text(
            status.isEmpty ? 'Thinking...' : status,
            style: TextStyle(
              fontSize: context.bodyFontSize,
              color: AppTheme.textMuted,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      ],
    );
  }
}

/// System messages are displayed as centered, muted text (smart mode)
/// or as dim monospace with `-- ` prefix (terminal mode).
class _SystemBubble extends StatelessWidget {
  final Message message;
  final bool smartMode;

  const _SystemBubble({required this.message, this.smartMode = true});

  @override
  Widget build(BuildContext context) {
    // ── Terminal mode: left-aligned, no bubble container ──
    if (!smartMode) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: context.rSpacing * 0.5),
        child: Text(
          message.content,
          style: TextStyle(
            fontSize: context.captionFontSize,
            color: AppTheme.textMuted,
          ),
        ),
      );
    }

    // ── Smart mode: original centered bubble ──
    return Center(
      child: Container(
        margin: EdgeInsets.symmetric(vertical: context.rSpacing),
        padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding, vertical: context.rSpacing * 0.75),
        decoration: BoxDecoration(
          color: AppTheme.systemBubble.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          message.content,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppTheme.textMuted,
              ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

/// Displays a small timestamp below the message content, with optional send status.
class _Timestamp extends StatelessWidget {
  final DateTime time;
  final bool isQueued;

  const _Timestamp({required this.time, this.isQueued = false});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: AppTheme.textMuted,
          fontSize: context.rFontSize(mobile: 10, tablet: 12),
        );
    final iconSize = context.rFontSize(mobile: 12, tablet: 14);

    return Align(
      alignment: Alignment.bottomRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(time.timeString, style: style),
          if (isQueued) ...[
            SizedBox(width: context.rSpacing * 0.3),
            Icon(Icons.schedule_rounded, size: iconSize, color: AppTheme.warning),
          ],
        ],
      ),
    );
  }
}
