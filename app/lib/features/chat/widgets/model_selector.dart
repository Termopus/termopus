import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/chat_provider.dart';
import '../../../core/providers/claude_config_provider.dart';
import '../../../shared/responsive.dart';
import '../../../shared/theme.dart';

/// Model selector dropdown for the chat AppBar.
///
/// Displays the currently selected model with a colored indicator dot,
/// and allows users to switch between Opus, Sonnet, and Haiku models.
class ModelSelector extends ConsumerWidget {
  const ModelSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(claudeConfigProvider);

    return PopupMenuButton<ClaudeModel>(
      onSelected: (model) {
        ref.read(claudeConfigProvider.notifier).setModel(model);
        ref.read(chatProvider.notifier).setModel(model.id);
      },
      offset: Offset(0, context.rValue(mobile: 40.0, tablet: 48.0)),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      color: AppTheme.surface,
      itemBuilder: (context) => ClaudeModel.values.map((model) {
        final isSelected = model == config.selectedModel;
        return PopupMenuItem<ClaudeModel>(
          value: model,
          child: _ModelMenuItem(
            model: model,
            isSelected: isSelected,
          ),
        );
      }).toList(),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: context.rSpacing * 1.25, vertical: context.rSpacing * 0.75),
        decoration: BoxDecoration(
          color: AppTheme.surfaceLight,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Color(config.selectedModel.colorValue).withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: context.rValue(mobile: 8.0, tablet: 10.0),
              height: context.rValue(mobile: 8.0, tablet: 10.0),
              decoration: BoxDecoration(
                color: Color(config.selectedModel.colorValue),
                shape: BoxShape.circle,
              ),
            ),
            SizedBox(width: context.rSpacing * 0.75),
            Text(
              config.selectedModel.displayName,
              style: TextStyle(
                fontSize: context.captionFontSize,
                fontWeight: FontWeight.w500,
              ),
            ),
            SizedBox(width: context.rSpacing * 0.5),
            Icon(
              Icons.keyboard_arrow_down,
              size: context.rValue(mobile: 16.0, tablet: 18.0),
              color: AppTheme.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelMenuItem extends StatelessWidget {
  final ClaudeModel model;
  final bool isSelected;

  const _ModelMenuItem({
    required this.model,
    required this.isSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: context.rValue(mobile: 10.0, tablet: 12.0),
          height: context.rValue(mobile: 10.0, tablet: 12.0),
          decoration: BoxDecoration(
            color: Color(model.colorValue),
            shape: BoxShape.circle,
          ),
        ),
        SizedBox(width: context.rSpacing * 1.25),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                model.displayName,
                style: TextStyle(
                  fontSize: context.bodyFontSize,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              Text(
                model.description,
                style: TextStyle(
                  fontSize: context.rFontSize(mobile: 11, tablet: 13),
                  color: AppTheme.textMuted,
                ),
              ),
            ],
          ),
        ),
        if (isSelected)
          Icon(
            Icons.check,
            size: context.rValue(mobile: 18.0, tablet: 20.0),
            color: AppTheme.primary,
          ),
      ],
    );
  }
}
