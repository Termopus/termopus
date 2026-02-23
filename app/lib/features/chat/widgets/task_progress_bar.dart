import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/active_tasks_provider.dart';
import '../../../shared/responsive.dart';
import '../../../shared/theme.dart';

/// Compact progress bar showing Claude's task list progress.
///
/// Collapses to zero height when no tasks exist.
/// Tapping opens a bottom sheet with the full live checklist.
class TaskProgressBar extends ConsumerWidget {
  const TaskProgressBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(activeTasksProvider);

    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      child: tasks.isEmpty
          ? const SizedBox.shrink()
          : GestureDetector(
              onTap: () => _showTaskSheet(context, tasks),
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(vertical: context.rSpacing, horizontal: context.rHorizontalPadding),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  border: Border(
                    top: BorderSide(color: Colors.white.withValues(alpha: 0.04)),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.checklist_rounded,
                      size: context.rValue(mobile: 16.0, tablet: 18.0),
                      color: _barColor(tasks),
                    ),
                    SizedBox(width: context.rSpacing * 1.25),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _summaryText(tasks),
                            style: TextStyle(
                              fontSize: context.rFontSize(mobile: 13, tablet: 15),
                              color: AppTheme.textSecondary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          SizedBox(height: context.rSpacing * 0.5),
                          _ProgressIndicator(tasks: tasks),
                        ],
                      ),
                    ),
                    SizedBox(width: context.rSpacing),
                    Icon(
                      Icons.expand_more_rounded,
                      size: context.rValue(mobile: 18.0, tablet: 20.0),
                      color: AppTheme.textMuted,
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Color _barColor(List<TrackedTask> tasks) {
    final completed = tasks.where((t) => t.status == 'completed').length;
    if (completed == tasks.length) return Colors.green.shade400;
    if (tasks.any((t) => t.status == 'in_progress')) return const Color(0xFF4DD0E1);
    return AppTheme.textMuted;
  }

  String _summaryText(List<TrackedTask> tasks) {
    final completed = tasks.where((t) => t.status == 'completed').length;
    final inProgress = tasks.where((t) => t.status == 'in_progress').length;

    if (completed == tasks.length) {
      return 'All ${tasks.length} tasks completed';
    }

    final parts = <String>[];
    parts.add('$completed/${tasks.length} done');
    if (inProgress > 0) {
      parts.add('$inProgress in progress');
    }
    return parts.join(' · ');
  }

  void _showTaskSheet(BuildContext context, List<TrackedTask> tasks) {
    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _TaskListSheet(tasks: tasks),
    );
  }
}

/// Slim progress bar showing completed/total ratio.
class _ProgressIndicator extends StatelessWidget {
  final List<TrackedTask> tasks;

  const _ProgressIndicator({required this.tasks});

  @override
  Widget build(BuildContext context) {
    final total = tasks.length;
    final completed = tasks.where((t) => t.status == 'completed').length;
    final progress = total > 0 ? completed / total : 0.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 3,
        child: LinearProgressIndicator(
          value: progress,
          backgroundColor: Colors.white.withValues(alpha: 0.08),
          color: progress >= 1.0 ? Colors.green.shade400 : const Color(0xFF4DD0E1),
        ),
      ),
    );
  }
}

/// Bottom sheet with full task checklist.
class _TaskListSheet extends StatelessWidget {
  final List<TrackedTask> tasks;

  const _TaskListSheet({required this.tasks});

  @override
  Widget build(BuildContext context) {
    final completed = tasks.where((t) => t.status == 'completed').length;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.6,
      ),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              margin: EdgeInsets.only(top: context.rSpacing * 1.5, bottom: context.rSpacing),
              width: context.rValue(mobile: 40.0, tablet: 48.0),
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.textMuted.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 2, vertical: context.rSpacing),
              child: Row(
                children: [
                  Text(
                    'Task List',
                    style: TextStyle(
                      fontSize: context.rFontSize(mobile: 16, tablet: 18),
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: context.rSpacing, vertical: 2),
                    decoration: BoxDecoration(
                      color: (completed == tasks.length
                              ? Colors.green
                              : const Color(0xFF4DD0E1))
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$completed/${tasks.length}',
                      style: TextStyle(
                        fontSize: context.rFontSize(mobile: 13, tablet: 15),
                        fontWeight: FontWeight.w600,
                        color: completed == tasks.length
                            ? Colors.green.shade400
                            : const Color(0xFF4DD0E1),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: context.rSpacing * 0.5),
            // Task list
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.only(bottom: context.rSpacing * 2),
                itemCount: tasks.length,
                itemBuilder: (context, index) => _TaskTile(
                  task: tasks[index],
                  index: index + 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Single task row in the checklist.
class _TaskTile extends StatelessWidget {
  final TrackedTask task;
  final int index;

  const _TaskTile({required this.task, required this.index});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 2, vertical: context.rSpacing * 0.75),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: context.rSpacing * 0.25),
            child: _statusIcon(task.status, context),
          ),
          SizedBox(width: context.rSpacing * 1.25),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.subject,
                  style: TextStyle(
                    color: task.status == 'completed'
                        ? AppTheme.textMuted
                        : AppTheme.textPrimary,
                    fontSize: context.bodyFontSize,
                    fontWeight: FontWeight.w500,
                    decoration: task.status == 'completed'
                        ? TextDecoration.lineThrough
                        : null,
                    decorationColor: AppTheme.textMuted,
                  ),
                ),
                if (task.description.isNotEmpty) ...[
                  SizedBox(height: context.rSpacing * 0.25),
                  Text(
                    task.description.length > 100
                        ? '${task.description.substring(0, 97)}...'
                        : task.description,
                    style: TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: context.captionFontSize,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (task.status == 'in_progress')
            SizedBox(
              width: context.rValue(mobile: 14.0, tablet: 16.0),
              height: context.rValue(mobile: 14.0, tablet: 16.0),
              child: const CircularProgressIndicator(
                strokeWidth: 1.5,
                color: Color(0xFF4DD0E1),
              ),
            ),
        ],
      ),
    );
  }

  Widget _statusIcon(String status, BuildContext context) {
    switch (status) {
      case 'completed':
        return Icon(Icons.check_circle, size: context.rIconSize, color: Colors.green.shade400);
      case 'in_progress':
        return Icon(Icons.play_circle_outline, size: context.rIconSize, color: const Color(0xFF4DD0E1));
      default:
        return Icon(Icons.radio_button_unchecked, size: context.rIconSize, color: AppTheme.textMuted);
    }
  }
}
