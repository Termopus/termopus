import 'package:intl/intl.dart';

/// Extensions on [DateTime] for common formatting patterns.
extension DateTimeFormatting on DateTime {
  /// e.g. "2:34 PM"
  String get timeString => DateFormat.jm().format(this);

  /// e.g. "Jan 5, 2025"
  String get dateString => DateFormat.yMMMd().format(this);

  /// e.g. "Jan 5, 2025 2:34 PM"
  String get dateTimeString => DateFormat.yMMMd().add_jm().format(this);

  /// Returns a human-friendly relative time string:
  /// "just now", "5m ago", "2h ago", "yesterday", or the date.
  String get relativeString {
    final now = DateTime.now();
    final diff = now.difference(this);

    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return dateString;
  }

  /// Whether this [DateTime] is the same calendar day as [other].
  bool isSameDayAs(DateTime other) {
    return year == other.year && month == other.month && day == other.day;
  }
}

/// Extensions on [String] for convenience.
extension StringHelpers on String {
  /// Truncate to [maxLength] with ellipsis.
  String truncate(int maxLength) {
    if (length <= maxLength) return this;
    return '${substring(0, maxLength - 1)}\u2026';
  }

  /// Capitalise the first letter.
  String get capitalised {
    if (isEmpty) return this;
    return '${this[0].toUpperCase()}${substring(1)}';
  }
}

/// Extensions on [Duration].
extension DurationFormatting on Duration {
  /// e.g. "15 min", "1 hr 30 min".
  String get friendlyString {
    if (inMinutes < 60) return '${inMinutes} min';
    final hours = inHours;
    final minutes = inMinutes.remainder(60);
    if (minutes == 0) return '$hours hr';
    return '$hours hr $minutes min';
  }
}
