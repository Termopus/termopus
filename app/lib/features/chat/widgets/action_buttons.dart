import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/message.dart';
import '../../../shared/responsive.dart';
import '../../../shared/theme.dart';

/// Compact action buttons for permission prompts.
///
/// Displays when Claude needs user approval (Allow/Deny/Always).
/// Matches the visual style of ToolUseCard and AskQuestionCard —
/// flat surface, subtle border, lightweight shadow.
class ActionButtonsBar extends StatelessWidget {
  final PendingAction action;
  final void Function(String response) onResponse;

  const ActionButtonsBar({
    super.key,
    required this.action,
    required this.onResponse,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.symmetric(vertical: context.rSpacing * 0.5),
      padding: EdgeInsets.all(context.rSpacing * 1.75),
      decoration: BoxDecoration(
        color: AppTheme.surfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppTheme.accent.withValues(alpha: 0.25),
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
        mainAxisSize: MainAxisSize.min,
        children: [
          // Prompt icon and text
          Row(
            children: [
              Container(
                width: context.rValue(mobile: 32.0, tablet: 40.0),
                height: context.rValue(mobile: 32.0, tablet: 40.0),
                decoration: BoxDecoration(
                  color: AppTheme.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.shield_outlined,
                  color: AppTheme.accent,
                  size: context.rValue(mobile: 18.0, tablet: 22.0),
                ),
              ),
              SizedBox(width: context.rSpacing * 1.25),
              Expanded(
                child: Text(
                  action.prompt,
                  style: TextStyle(
                    fontSize: context.bodyFontSize,
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.w500,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: context.rSpacing * 1.75),

          // Action buttons
          Row(
            children: action.options.asMap().entries.map((entry) {
              final index = entry.key;
              final option = entry.value;
              final isPrimary = _isPrimaryOption(option);
              final isLast = index == action.options.length - 1;

              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: isLast ? 0 : context.rSpacing),
                  child: _ActionButton(
                    label: option,
                    isPrimary: isPrimary,
                    onTap: () {
                      HapticFeedback.mediumImpact();
                      onResponse(option.toLowerCase());
                    },
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  bool _isPrimaryOption(String option) {
    final lower = option.toLowerCase();
    return lower == 'allow' ||
        lower == 'always' ||
        lower == 'yes' ||
        lower == 'approve' ||
        lower == 'accept' ||
        lower == 'ok' ||
        lower == 'confirm';
  }
}

/// Individual action button with press feedback.
class _ActionButton extends StatefulWidget {
  final String label;
  final bool isPrimary;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.isPrimary,
    required this.onTap,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  bool _isPressed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.96).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails details) {
    setState(() => _isPressed = true);
    _controller.forward();
  }

  void _handleTapUp(TapUpDetails details) {
    setState(() => _isPressed = false);
    _controller.reverse();
    widget.onTap();
  }

  void _handleTapCancel() {
    setState(() => _isPressed = false);
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    final Color bgColor;
    final Color fgColor;
    final Color borderColor;

    final isAlways = widget.label.toLowerCase() == 'always';

    if (isAlways) {
      icon = Icons.verified_user_rounded;
      bgColor = _isPressed
          ? const Color(0xFF1976D2)
          : const Color(0xFF2196F3).withValues(alpha: 0.15);
      fgColor = _isPressed ? Colors.white : const Color(0xFF64B5F6);
      borderColor = const Color(0xFF2196F3).withValues(alpha: 0.4);
    } else if (widget.isPrimary) {
      icon = Icons.check_rounded;
      bgColor = _isPressed
          ? AppTheme.success.withValues(alpha: 0.8)
          : AppTheme.success.withValues(alpha: 0.12);
      fgColor = _isPressed ? Colors.white : AppTheme.success;
      borderColor = AppTheme.success.withValues(alpha: 0.35);
    } else {
      icon = Icons.close_rounded;
      bgColor = _isPressed
          ? AppTheme.surfaceLight
          : Colors.white.withValues(alpha: 0.04);
      fgColor = AppTheme.textSecondary;
      borderColor = Colors.white.withValues(alpha: 0.1);
    }

    return GestureDetector(
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: EdgeInsets.symmetric(vertical: context.rSpacing * 1.5),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: borderColor, width: 1),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: fgColor, size: context.rValue(mobile: 18.0, tablet: 22.0)),
                  SizedBox(width: context.rSpacing * 0.75),
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: context.buttonFontSize,
                      fontWeight: FontWeight.w600,
                      color: fgColor,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
