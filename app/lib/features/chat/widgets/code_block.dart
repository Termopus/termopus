import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/monokai-sublime.dart';

import '../../../shared/constants.dart';
import '../../../shared/responsive.dart';
import '../../../shared/theme.dart';

/// Syntax-highlighted code block widget.
///
/// Shows a language label in the top-right corner and a copy button.
class CodeBlock extends StatelessWidget {
  final String code;
  final String? language;

  const CodeBlock({
    super.key,
    required this.code,
    this.language,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF23241F), // Monokai background
        borderRadius: BorderRadius.circular(AppConstants.codeBlockBorderRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ---- Header: language label + copy button ----
          Container(
            padding: EdgeInsets.symmetric(horizontal: context.rSpacing * 1.5, vertical: context.rSpacing * 0.75),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.only(
                topLeft:
                    Radius.circular(AppConstants.codeBlockBorderRadius),
                topRight:
                    Radius.circular(AppConstants.codeBlockBorderRadius),
              ),
            ),
            child: Row(
              children: [
                if (language != null && language!.isNotEmpty)
                  Text(
                    language!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.textMuted,
                          fontFamily: 'monospace',
                          fontSize: context.rFontSize(mobile: 11, tablet: 13),
                        ),
                  ),
                const Spacer(),
                _CopyButton(text: code),
              ],
            ),
          ),

          // ---- Code body ----
          Padding(
            padding: EdgeInsets.only(bottom: context.rSpacing * 0.5),
            child: HighlightView(
              code,
              language: language ?? 'plaintext',
              theme: monokaiSublimeTheme,
              padding: EdgeInsets.all(context.rSpacing * 1.5),
              textStyle: TextStyle(
                fontFamily: 'monospace',
                fontSize: context.codeFontSize,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyButton extends StatefulWidget {
  final String text;

  const _CopyButton({required this.text});

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _copy,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: context.rSpacing * 0.75, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _copied ? Icons.check : Icons.copy,
              size: context.rValue(mobile: 14.0, tablet: 16.0),
              color: _copied ? AppTheme.primary : AppTheme.textMuted,
            ),
            SizedBox(width: context.rSpacing * 0.5),
            Text(
              _copied ? 'Copied' : 'Copy',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: _copied ? AppTheme.primary : AppTheme.textMuted,
                    fontSize: context.rFontSize(mobile: 11, tablet: 13),
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
