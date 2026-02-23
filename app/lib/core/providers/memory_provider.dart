import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A project memory entry (from CLAUDE.md files).
class MemoryEntry {
  final String filename;
  final String content;
  final String scope;

  const MemoryEntry({
    required this.filename,
    required this.content,
    required this.scope,
  });

  factory MemoryEntry.fromMap(Map<String, dynamic> m) {
    return MemoryEntry(
      filename: m['filename'] as String? ?? '',
      content: m['content'] as String? ?? '',
      scope: m['scope'] as String? ?? 'global',
    );
  }

  String get scopeLabel {
    if (scope == 'project') return 'This Project';
    return 'Global';
  }
}

/// Manages project memory (CLAUDE.md) data from the bridge.
class MemoryNotifier extends Notifier<List<MemoryEntry>> {
  @override
  List<MemoryEntry> build() => [];

  void setEntries(List<MemoryEntry> entries) {
    state = entries;
  }

  void clear() {
    state = [];
  }
}

final memoryProvider =
    NotifierProvider<MemoryNotifier, List<MemoryEntry>>(
  MemoryNotifier.new,
);
