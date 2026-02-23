import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A resumable Claude Code session entry.
class ResumableSession {
  final String sessionId;
  final String summary;
  final String firstPrompt;
  final int messageCount;
  final DateTime created;
  final DateTime modified;
  final String? gitBranch;
  final String project;

  const ResumableSession({
    required this.sessionId,
    required this.summary,
    required this.firstPrompt,
    required this.messageCount,
    required this.created,
    required this.modified,
    this.gitBranch,
    required this.project,
  });

  factory ResumableSession.fromMap(Map<String, dynamic> map) {
    return ResumableSession(
      sessionId: map['session_id'] as String? ?? '',
      summary: map['summary'] as String? ?? 'Untitled',
      firstPrompt: map['first_prompt'] as String? ?? '',
      messageCount: (map['message_count'] as num?)?.toInt() ?? 0,
      created: DateTime.tryParse(map['created'] as String? ?? '') ?? DateTime.now(),
      modified: DateTime.tryParse(map['modified'] as String? ?? '') ?? DateTime.now(),
      gitBranch: map['git_branch'] as String?,
      project: map['project'] as String? ?? 'Unknown',
    );
  }

  String get timeAgo {
    final diff = DateTime.now().difference(modified);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${(diff.inDays / 7).floor()}w ago';
  }
}

/// Holds the list of resumable sessions received from the bridge.
class SessionPickerNotifier extends Notifier<List<ResumableSession>> {
  @override
  List<ResumableSession> build() => [];

  void setSessions(List<ResumableSession> sessions) {
    state = sessions;
  }

  void clear() {
    state = [];
  }
}

final sessionPickerProvider =
    NotifierProvider<SessionPickerNotifier, List<ResumableSession>>(
  SessionPickerNotifier.new,
);
