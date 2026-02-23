import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/quick_actions.dart';
import '../../../shared/responsive.dart';
import '../../../shared/theme.dart';

/// Simple, WhatsApp-style input bar.
///
/// Clean text input with send button. Advanced controls accessible via
/// the "+" button which opens a bottom sheet.
///
/// The bar above the input adapts to the current mode:
/// - **Smart mode**: scrollable quick-action chips (Commit, Review, etc.)
/// - **Terminal mode**: minimal terminal keys (Enter, Esc, Stop)
class InputBar extends StatefulWidget {
  /// Called when user sends text
  final void Function(String text) onSendText;

  /// Called when user presses a special key
  final void Function(String key) onSendKey;

  /// Called when user selects a slash command
  final void Function(String command, String? args)? onCommand;

  /// Called when user wants to pick a photo
  final VoidCallback? onPickPhoto;

  /// Called when user wants to pick a file
  final VoidCallback? onPickFile;

  /// Called when user taps the + button (opens settings).
  final VoidCallback? onSettings;

  /// Whether the chat is in smart mode (rich cards) vs terminal mode.
  final bool smartMode;

  /// Whether Claude is currently thinking/processing.
  final bool isThinking;

  /// Whether the session is handed off to the computer.
  final bool isHandedOff;

  /// Whether keyboard is currently visible — hides action bar to save space.
  final bool keyboardVisible;

  /// Called when user requests handoff to computer.
  final VoidCallback? onHandoff;

  const InputBar({
    super.key,
    required this.onSendText,
    required this.onSendKey,
    this.onCommand,
    this.onPickPhoto,
    this.onPickFile,
    this.onSettings,
    this.smartMode = true,
    this.isThinking = false,
    this.isHandedOff = false,
    this.keyboardVisible = false,
    this.onHandoff,
  });

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> with SingleTickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _hasText = false;
  late AnimationController _sendButtonController;
  late Animation<double> _sendButtonScale;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);

    _sendButtonController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _sendButtonScale = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _sendButtonController, curve: Curves.easeOut),
    );
  }

  void _onTextChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText != _hasText) {
      setState(() => _hasText = hasText);
      if (hasText) {
        _sendButtonController.forward();
      } else {
        _sendButtonController.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _sendButtonController.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    widget.onSendText(text);
    _controller.clear();
  }

  void _showFilePicker(BuildContext context) {
    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(context.rHorizontalPadding * 2, context.rSpacing * 2, context.rHorizontalPadding * 2, context.rSpacing * 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: context.rValue(mobile: 40.0, tablet: 48.0), height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.textMuted.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                SizedBox(height: context.rSpacing * 2.5),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _FilePickerOption(
                      icon: Icons.photo_camera_rounded,
                      label: 'Photo',
                      color: Colors.blue,
                      onTap: () {
                        Navigator.pop(context);
                        widget.onPickPhoto?.call();
                      },
                    ),
                    _FilePickerOption(
                      icon: Icons.insert_drive_file_rounded,
                      label: 'File',
                      color: AppTheme.brandCyan,
                      onTap: () {
                        Navigator.pop(context);
                        widget.onPickFile?.call();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(0, 0, 0, bottomPadding),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(
          top: BorderSide(
            color: AppTheme.divider.withValues(alpha: 0.3),
            width: 0.5,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Context-aware action bar — hidden when keyboard is open
          if (!widget.keyboardVisible) ...[
            if (widget.smartMode)
              _SmartActionBar(
                onSendText: widget.onSendText,
                onSendKey: widget.onSendKey,
                isThinking: widget.isThinking,
                isHandedOff: widget.isHandedOff,
                onHandoff: widget.onHandoff,
              )
            else
              _TerminalKeyBar(
                onSendKey: widget.onSendKey,
              ),
          ],

          // Text input row
          Padding(
            padding: EdgeInsets.fromLTRB(context.rSpacing * 1.5, context.rSpacing, context.rSpacing * 1.5, context.rSpacing * 1.5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Settings button
                _PlusButton(onTap: () {
                  HapticFeedback.selectionClick();
                  widget.onSettings?.call();
                }),
                SizedBox(width: context.rSpacing * 1.25),

                // Text input
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: widget.isHandedOff
                          ? AppTheme.surfaceLight.withValues(alpha: 0.5)
                          : AppTheme.surfaceLight,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      enabled: !widget.isHandedOff,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      maxLines: 4,
                      minLines: 1,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: context.bodyFontSize,
                      ),
                      decoration: InputDecoration(
                        hintText: widget.isHandedOff
                            ? 'Observing session on computer...'
                            : 'Message',
                        hintStyle: const TextStyle(color: AppTheme.textMuted),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: context.rSpacing * 2.25,
                          vertical: context.rSpacing * 1.5,
                        ),
                        suffixIcon: widget.isHandedOff
                            ? null
                            : GestureDetector(
                                onTap: () => _showFilePicker(context),
                                child: Padding(
                                  padding: EdgeInsets.only(right: context.rSpacing),
                                  child: Icon(
                                    Icons.attach_file_rounded,
                                    color: AppTheme.textMuted,
                                    size: context.rValue(mobile: 22.0, tablet: 26.0),
                                  ),
                                ),
                              ),
                        suffixIconConstraints: widget.isHandedOff
                            ? null
                            : BoxConstraints(
                                minWidth: context.rValue(mobile: 36.0, tablet: 42.0),
                                minHeight: context.rValue(mobile: 36.0, tablet: 42.0),
                              ),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: context.rSpacing * 1.25),

                // Send button (hidden during handoff)
                if (!widget.isHandedOff)
                  AnimatedBuilder(
                    animation: _sendButtonController,
                    builder: (context, child) {
                      return Transform.scale(
                        scale: _hasText ? _sendButtonScale.value : 0.8,
                        child: _SendButton(
                          onTap: _send,
                          isActive: _hasText,
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Circular plus button for accessing advanced controls.
class _PlusButton extends StatelessWidget {
  final VoidCallback onTap;

  const _PlusButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final size = context.rValue(mobile: 42.0, tablet: 48.0);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: AppTheme.surfaceLight,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.add_rounded,
          color: AppTheme.textSecondary,
          size: context.rValue(mobile: 24.0, tablet: 30.0),
        ),
      ),
    );
  }
}

/// Animated send button.
class _SendButton extends StatelessWidget {
  final VoidCallback onTap;
  final bool isActive;

  const _SendButton({
    required this.onTap,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    final size = context.rValue(mobile: 42.0, tablet: 48.0);
    return GestureDetector(
      onTap: isActive ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: isActive ? AppTheme.primaryGradient : null,
          color: isActive ? null : AppTheme.surfaceLight,
          shape: BoxShape.circle,
          boxShadow: isActive ? AppTheme.glowShadow : null,
        ),
        child: Icon(
          Icons.arrow_upward_rounded,
          color: isActive ? Colors.white : AppTheme.textMuted,
          size: context.rValue(mobile: 24.0, tablet: 28.0),
        ),
      ),
    );
  }
}

/// Smart mode action bar — category dropdown chips.
///
/// Shows [Stop] [Code ▼] [GitHub ▼] [Continue].
/// Tapping a category opens a bottom sheet with all actions in that group.
class _SmartActionBar extends StatelessWidget {
  final void Function(String text) onSendText;
  final void Function(String key) onSendKey;
  final bool isThinking;
  final bool isHandedOff;
  final VoidCallback? onHandoff;

  const _SmartActionBar({
    required this.onSendText,
    required this.onSendKey,
    required this.isThinking,
    this.isHandedOff = false,
    this.onHandoff,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(minHeight: context.rValue(mobile: 44.0, tablet: 52.0)),
      padding: EdgeInsets.symmetric(horizontal: context.rSpacing),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(
          bottom: BorderSide(
            color: AppTheme.divider.withValues(alpha: 0.2),
            width: 0.5,
          ),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // Stop button — always visible, highlighted when thinking
            GestureDetector(
              onTap: () {
                HapticFeedback.heavyImpact();
                onSendKey('Escape');
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: EdgeInsets.only(left: context.rValue(mobile: 2.0, tablet: 10.0)),
                padding: EdgeInsets.symmetric(horizontal: context.rValue(mobile: 8.0, tablet: 10.0), vertical: context.rSpacing * 0.75),
                decoration: BoxDecoration(
                  color: isThinking
                      ? AppTheme.error.withValues(alpha: 0.15)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isThinking
                        ? AppTheme.error.withValues(alpha: 0.5)
                        : AppTheme.divider.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.stop_rounded,
                      size: context.rValue(mobile: 16.0, tablet: 18.0),
                      color: isThinking ? AppTheme.error : AppTheme.textMuted,
                    ),
                    SizedBox(width: context.rSpacing * 0.5),
                    Text(
                      'Stop',
                      style: TextStyle(
                        fontSize: context.captionFontSize,
                        fontWeight: FontWeight.w600,
                        color: isThinking ? AppTheme.error : AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(width: context.rValue(mobile: 4.0, tablet: 8.0)),

            // Continue chip (always visible — most used)
            _SmartChip(
              label: 'Continue',
              icon: Icons.play_arrow_rounded,
              color: const Color(0xFF60A5FA),
              onTap: () {
                HapticFeedback.mediumImpact();
                onSendText('continue');
              },
            ),
            SizedBox(width: context.rValue(mobile: 4.0, tablet: 6.0)),

            // Code category dropdown
            _CategoryChip(
              label: 'Code',
              icon: Icons.code_rounded,
              color: const Color(0xFF7DD3FC),
              onTap: () => _showCategory(context, 'Code', QuickActions.code),
            ),
            SizedBox(width: context.rValue(mobile: 4.0, tablet: 6.0)),

            // GitHub category dropdown
            _CategoryChip(
              label: 'GitHub',
              icon: Icons.merge_rounded,
              color: const Color(0xFF4ADE80),
              onTap: () => _showCategory(context, 'GitHub', QuickActions.git),
            ),

            // Handoff to computer chip (hidden during handoff)
            if (!isHandedOff && onHandoff != null) ...[
              SizedBox(width: context.rValue(mobile: 4.0, tablet: 6.0)),
              _SmartChip(
                label: 'Computer',
                icon: Icons.computer_rounded,
                color: const Color(0xFFA78BFA),
                onTap: () {
                  HapticFeedback.mediumImpact();
                  onHandoff!();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showCategory(BuildContext context, String title, List<QuickAction> actions) {
    HapticFeedback.selectionClick();
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  margin: EdgeInsets.only(top: ctx.rSpacing * 1.5, bottom: ctx.rSpacing * 2),
                  width: ctx.rValue(mobile: 40.0, tablet: 48.0),
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.textMuted.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: ctx.rHorizontalPadding),
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: ctx.rFontSize(mobile: 16, tablet: 18),
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
              SizedBox(height: ctx.rSpacing * 1.5),
              Padding(
                padding: EdgeInsets.fromLTRB(ctx.rHorizontalPadding, 0, ctx.rHorizontalPadding, ctx.rHorizontalPadding),
                child: Wrap(
                  spacing: ctx.rSpacing,
                  runSpacing: ctx.rSpacing,
                  children: [
                    for (final action in actions)
                      _ActionSheetChip(
                        label: action.label,
                        icon: action.icon,
                        color: action.color,
                        onTap: () {
                          Navigator.pop(ctx);
                          HapticFeedback.mediumImpact();
                          onSendText(action.prompt);
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Category dropdown chip for the smart action bar.
class _CategoryChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _CategoryChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: context.rValue(mobile: 8.0, tablet: 10.0), vertical: context.rSpacing * 0.75),
        margin: EdgeInsets.symmetric(vertical: context.rSpacing * 0.75),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: context.rValue(mobile: 14.0, tablet: 16.0), color: color),
            SizedBox(width: context.rValue(mobile: 3.0, tablet: 4.0)),
            Text(
              label,
              style: TextStyle(
                fontSize: context.captionFontSize,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
            SizedBox(width: context.rValue(mobile: 2.0, tablet: 2.0)),
            Icon(Icons.expand_more_rounded, size: context.rValue(mobile: 14.0, tablet: 16.0), color: color.withValues(alpha: 0.6)),
          ],
        ),
      ),
    );
  }
}

/// Action chip inside the category bottom sheet.
class _ActionSheetChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ActionSheetChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: context.rSpacing * 1.75, vertical: context.rSpacing * 1.25),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: context.rValue(mobile: 18.0, tablet: 20.0), color: color),
              SizedBox(width: context.rSpacing),
              Text(
                label,
                style: TextStyle(
                  fontSize: context.bodyFontSize,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A compact chip for the smart action bar.
class _SmartChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _SmartChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: context.rValue(mobile: 8.0, tablet: 10.0), vertical: context.rSpacing * 0.75),
        margin: EdgeInsets.symmetric(vertical: context.rSpacing * 0.75),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: context.rValue(mobile: 14.0, tablet: 16.0), color: color),
            SizedBox(width: context.rValue(mobile: 3.0, tablet: 4.0)),
            Text(
              label,
              style: TextStyle(
                fontSize: context.captionFontSize,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Terminal mode key bar — minimal controls: Enter | Esc | Stop.
class _TerminalKeyBar extends StatelessWidget {
  final void Function(String key) onSendKey;

  const _TerminalKeyBar({
    required this.onSendKey,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: context.rValue(mobile: 40.0, tablet: 48.0),
      padding: EdgeInsets.symmetric(horizontal: context.rSpacing * 1.5),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(
          bottom: BorderSide(
            color: AppTheme.divider.withValues(alpha: 0.2),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _DevKey(
            label: 'Enter',
            icon: Icons.keyboard_return_rounded,
            onTap: () {
              HapticFeedback.lightImpact();
              onSendKey('Enter');
            },
          ),
          const _DevKeySeparator(),
          _DevKey(
            label: 'Esc',
            icon: Icons.close_rounded,
            onTap: () {
              HapticFeedback.lightImpact();
              onSendKey('Escape');
            },
          ),
          const _DevKeySeparator(),
          _DevKey(
            label: 'Stop',
            icon: Icons.stop_circle_outlined,
            color: AppTheme.error,
            onTap: () {
              HapticFeedback.heavyImpact();
              onSendKey('C-c');
            },
          ),
        ],
      ),
    );
  }
}

/// Single key in the developer keyboard bar.
class _DevKey extends StatelessWidget {
  final String? label;
  final IconData icon;
  final Color? color;
  final VoidCallback onTap;

  const _DevKey({
    this.label,
    required this.icon,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final keyColor = color ?? AppTheme.textSecondary;

    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: context.rValue(mobile: 44.0, tablet: 52.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: context.rValue(mobile: 18.0, tablet: 20.0), color: keyColor),
              if (label != null)
                Text(
                  label!,
                  style: TextStyle(
                    fontSize: context.rFontSize(mobile: 9, tablet: 11),
                    fontWeight: FontWeight.w600,
                    color: keyColor,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Thin vertical separator between key groups.
class _DevKeySeparator extends StatelessWidget {
  const _DevKeySeparator();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: context.rValue(mobile: 24.0, tablet: 28.0),
      margin: EdgeInsets.symmetric(horizontal: context.rSpacing * 0.5),
      color: AppTheme.divider.withValues(alpha: 0.3),
    );
  }
}

/// Circular icon button for the file picker bottom sheet.
class _FilePickerOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _FilePickerOption({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: context.rValue(mobile: 56.0, tablet: 64.0),
            height: context.rValue(mobile: 56.0, tablet: 64.0),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: context.rValue(mobile: 28.0, tablet: 32.0)),
          ),
          SizedBox(height: context.rSpacing),
          Text(
            label,
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: context.rFontSize(mobile: 13, tablet: 15),
            ),
          ),
        ],
      ),
    );
  }
}

