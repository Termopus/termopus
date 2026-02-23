import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A task being tracked by Claude Code's task management.
class TrackedTask {
  final String id;
  final String subject;
  final String description;
  final String status; // "pending", "in_progress", "completed", "deleted"
  final DateTime createdAt;
  final DateTime updatedAt;

  const TrackedTask({
    required this.id,
    required this.subject,
    this.description = '',
    this.status = 'pending',
    required this.createdAt,
    required this.updatedAt,
  });

  TrackedTask copyWith({
    String? subject,
    String? description,
    String? status,
    DateTime? updatedAt,
  }) {
    return TrackedTask(
      id: id,
      subject: subject ?? this.subject,
      description: description ?? this.description,
      status: status ?? this.status,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// Riverpod provider for tracking Claude's task list.
final activeTasksProvider =
    NotifierProvider<ActiveTasksNotifier, List<TrackedTask>>(
  ActiveTasksNotifier.new,
);

/// Aggregates TaskCreate/TaskUpdate events into a live task list.
class ActiveTasksNotifier extends Notifier<List<TrackedTask>> {
  @override
  List<TrackedTask> build() => [];

  /// Add a new task (from PostToolUse of TaskCreate).
  void taskCreated(String id, String subject, String description) {
    // Dedup by id
    if (state.any((t) => t.id == id)) return;
    final now = DateTime.now();
    state = [
      ...state,
      TrackedTask(
        id: id,
        subject: subject,
        description: description,
        createdAt: now,
        updatedAt: now,
      ),
    ];
  }

  /// Update a task's status (from PostToolUse of TaskUpdate).
  void taskUpdated(String id, {String? status, String? subject}) {
    state = state.map((t) {
      if (t.id != id) return t;
      return t.copyWith(
        status: status,
        subject: subject,
        updatedAt: DateTime.now(),
      );
    }).toList();

    // Remove deleted tasks
    if (status == 'deleted') {
      state = state.where((t) => t.id != id).toList();
    }
  }

  /// Bulk replace from a TaskList result.
  void setFromTaskList(List<TrackedTask> tasks) {
    state = tasks;
  }

  /// Clear all tasks (on disconnect / session switch).
  void clear() {
    state = [];
  }

  /// Computed: number of completed tasks.
  int get completedCount => state.where((t) => t.status == 'completed').length;

  /// Computed: total tasks (excluding deleted).
  int get totalCount => state.length;
}
