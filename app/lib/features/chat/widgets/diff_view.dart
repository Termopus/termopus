import 'package:flutter/material.dart';

import '../../../models/message.dart';
import '../../../shared/responsive.dart';
import '../../../shared/theme.dart';

/// Displays a git-style unified diff with green (add), red (remove),
/// and gray (context) lines, each prefixed with a line number.
class DiffView extends StatelessWidget {
  final List<DiffLine> lines;

  const DiffView({super.key, required this.lines});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.divider),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---- Header ----
            Container(
              padding: EdgeInsets.symmetric(horizontal: context.rSpacing * 1.5, vertical: context.rSpacing * 0.75),
              color: Colors.white.withValues(alpha: 0.04),
              child: Text(
                'Changes',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.textMuted,
                      fontFamily: 'monospace',
                    ),
              ),
            ),

            // ---- Diff lines ----
            ...lines.map((line) => _DiffLineRow(line: line)),
          ],
        ),
      ),
    );
  }
}

class _DiffLineRow extends StatelessWidget {
  final DiffLine line;

  const _DiffLineRow({required this.line});

  Color get _background {
    return switch (line.type) {
      DiffType.add => AppTheme.diffAdd.withValues(alpha: 0.25),
      DiffType.remove => AppTheme.diffRemove.withValues(alpha: 0.25),
      DiffType.context => Colors.transparent,
    };
  }

  Color get _prefixColor {
    return switch (line.type) {
      DiffType.add => AppTheme.primary,
      DiffType.remove => AppTheme.error,
      DiffType.context => AppTheme.textMuted,
    };
  }

  String get _prefix {
    return switch (line.type) {
      DiffType.add => '+',
      DiffType.remove => '-',
      DiffType.context => ' ',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _background,
      padding: EdgeInsets.symmetric(horizontal: context.rSpacing, vertical: 1),
      child: Row(
        children: [
          // ---- Line number ----
          SizedBox(
            width: context.rValue(mobile: 36.0, tablet: 42.0),
            child: Text(
              '${line.lineNumber}',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: context.rFontSize(mobile: 11, tablet: 13),
                color: AppTheme.textMuted.withValues(alpha: 0.6),
              ),
              textAlign: TextAlign.right,
            ),
          ),
          SizedBox(width: context.rSpacing),

          // ---- Prefix (+, -, space) ----
          Text(
            _prefix,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: context.codeFontSize,
              color: _prefixColor,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(width: context.rSpacing * 0.75),

          // ---- Content ----
          Expanded(
            child: Text(
              line.content,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: context.codeFontSize,
                color: AppTheme.textPrimary.withValues(alpha: 0.9),
                height: 1.5,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
