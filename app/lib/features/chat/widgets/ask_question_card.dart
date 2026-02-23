import 'package:flutter/material.dart';

import '../../../shared/responsive.dart';
import '../../../shared/theme.dart';

/// Interactive multi-choice card rendered when Claude sends an AskUserQuestion.
///
/// Users select one option per question (radio buttons), then press Submit
/// to send all answers at once. The card locks after submission.
class AskQuestionCard extends StatefulWidget {
  /// The list of question maps from the bridge payload.
  ///
  /// Each map may contain:
  ///   - `question` (String): The question text.
  ///   - `header` (String?): Optional header badge.
  ///   - `options` (List): Each with `label` and optional `description`.
  ///   - `multi_select` (bool): Reserved for future use.
  final List<Map<String, dynamic>> questions;

  /// Called when the user submits all answers. Combined answer string is passed.
  final void Function(String answer)? onAnswer;

  const AskQuestionCard({
    super.key,
    required this.questions,
    this.onAnswer,
  });

  @override
  State<AskQuestionCard> createState() => _AskQuestionCardState();
}

class _AskQuestionCardState extends State<AskQuestionCard> {
  /// Tracks the selected option index per question index.
  final Map<int, int> _selections = {};

  /// Whether the user has submitted their answers.
  bool _submitted = false;

  bool get _allAnswered => _selections.length == widget.questions.length;

  void _submit() {
    if (!_allAnswered || _submitted) return;

    setState(() => _submitted = true);

    // Build combined answer string
    final parts = <String>[];
    for (int qi = 0; qi < widget.questions.length; qi++) {
      final q = widget.questions[qi];
      final options = q['options'] as List<dynamic>? ?? [];
      final selectedIdx = _selections[qi]!;
      final option = options[selectedIdx];
      final label = option is Map
          ? (option['label'] as String?) ?? 'Option ${selectedIdx + 1}'
          : option.toString();

      if (widget.questions.length == 1) {
        // Single question: just send the label
        parts.add(label);
      } else {
        // Multiple questions: include question context
        final header = q['header'] as String?;
        final prefix = (header != null && header.isNotEmpty) ? header : 'Q${qi + 1}';
        parts.add('$prefix: $label');
      }
    }

    widget.onAnswer?.call(parts.join('\n'));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.symmetric(vertical: context.rSpacing * 0.5),
      decoration: BoxDecoration(
        color: AppTheme.surfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppTheme.accent.withValues(alpha: 0.3),
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
          for (int qi = 0; qi < widget.questions.length; qi++) ...[
            if (qi > 0)
              Divider(
                height: 1,
                color: Colors.white.withValues(alpha: 0.06),
              ),
            _buildQuestion(qi, widget.questions[qi]),
          ],
          // Submit button
          Padding(
            padding: EdgeInsets.fromLTRB(
              context.rSpacing * 1.75,
              0,
              context.rSpacing * 1.75,
              context.rSpacing * 1.75,
            ),
            child: SizedBox(
              width: double.infinity,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: _submitted ? 0.5 : 1.0,
                child: ElevatedButton(
                  onPressed: (_allAnswered && !_submitted) ? _submit : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _allAnswered
                        ? AppTheme.accent
                        : AppTheme.accent.withValues(alpha: 0.3),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: _submitted
                        ? AppTheme.accent.withValues(alpha: 0.4)
                        : AppTheme.accent.withValues(alpha: 0.15),
                    disabledForegroundColor: Colors.white.withValues(alpha: 0.5),
                    padding: EdgeInsets.symmetric(vertical: context.rSpacing * 1.25),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    _submitted
                        ? 'Submitted'
                        : _allAnswered
                            ? 'Submit'
                            : 'Select all answers to submit',
                    style: TextStyle(
                      fontSize: context.bodyFontSize,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuestion(int questionIndex, Map<String, dynamic> q) {
    final header = q['header'] as String?;
    final questionText = q['question'] as String? ?? '';
    final rawOptions = q['options'] as List<dynamic>? ?? [];
    final selectedIndex = _selections[questionIndex];

    return Padding(
      padding: EdgeInsets.all(context.rSpacing * 1.75),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Optional header badge
          if (header != null && header.isNotEmpty) ...[
            Container(
              padding: EdgeInsets.symmetric(horizontal: context.rSpacing * 1.25, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.accent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                header,
                style: TextStyle(
                  color: AppTheme.accent,
                  fontSize: context.rFontSize(mobile: 11, tablet: 13),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            SizedBox(height: context.rSpacing * 1.25),
          ],

          // Question text with help icon
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.help_outline_rounded,
                size: context.rValue(mobile: 18.0, tablet: 20.0),
                color: AppTheme.accent.withValues(alpha: 0.7),
              ),
              SizedBox(width: context.rSpacing),
              Expanded(
                child: Text(
                  questionText,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: context.bodyFontSize,
                    fontWeight: FontWeight.w500,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: context.rSpacing * 1.5),

          // Options (radio buttons — tappable until submitted)
          for (int oi = 0; oi < rawOptions.length; oi++)
            _buildOption(
              questionIndex: questionIndex,
              optionIndex: oi,
              option: rawOptions[oi],
              isSelected: selectedIndex == oi,
            ),
        ],
      ),
    );
  }

  Widget _buildOption({
    required int questionIndex,
    required int optionIndex,
    required dynamic option,
    required bool isSelected,
  }) {
    String label;
    String? description;

    if (option is Map) {
      label = (option['label'] as String?) ?? 'Option ${optionIndex + 1}';
      description = option['description'] as String?;
    } else {
      label = option.toString();
    }

    return GestureDetector(
      onTap: _submitted
          ? null
          : () {
              setState(() {
                _selections[questionIndex] = optionIndex;
              });
            },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: EdgeInsets.only(bottom: context.rSpacing * 0.75),
        padding: EdgeInsets.symmetric(horizontal: context.rSpacing * 1.5, vertical: context.rSpacing * 1.25),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.accent.withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? AppTheme.accent.withValues(alpha: 0.5)
                : Colors.white.withValues(alpha: 0.1),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            // Radio circle
            Container(
              width: context.rValue(mobile: 20.0, tablet: 24.0),
              height: context.rValue(mobile: 20.0, tablet: 24.0),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelected
                    ? AppTheme.accent
                    : Colors.transparent,
                border: Border.all(
                  color: isSelected
                      ? AppTheme.accent
                      : _submitted
                          ? AppTheme.textMuted.withValues(alpha: 0.3)
                          : AppTheme.textMuted,
                  width: 2,
                ),
              ),
              child: isSelected
                  ? Icon(
                      Icons.check,
                      size: context.rValue(mobile: 14.0, tablet: 16.0),
                      color: Colors.white,
                    )
                  : null,
            ),
            SizedBox(width: context.rSpacing * 1.5),
            // Label + description
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: _submitted && !isSelected
                          ? AppTheme.textMuted.withValues(alpha: 0.5)
                          : AppTheme.textPrimary,
                      fontSize: context.bodyFontSize,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (description != null && description.isNotEmpty) ...[
                    SizedBox(height: context.rSpacing * 0.25),
                    Text(
                      description,
                      style: TextStyle(
                        color: _submitted && !isSelected
                            ? AppTheme.textMuted.withValues(alpha: 0.3)
                            : AppTheme.textMuted,
                        fontSize: context.captionFontSize,
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
