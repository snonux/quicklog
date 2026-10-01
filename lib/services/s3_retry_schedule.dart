/// Daily retry times in the device's local time zone. Empty disables retries.
class S3RetrySchedule {
  S3RetrySchedule(Iterable<int> minutes)
    : minutes = List.unmodifiable(minutes.toSet().toList()..sort()) {
    if (this.minutes.any((minute) => minute < 0 || minute >= 24 * 60)) {
      throw const FormatException(
        'Retry times must be between 00:00 and 23:59.',
      );
    }
  }

  factory S3RetrySchedule.parse(Iterable<String> times) {
    return S3RetrySchedule(
      times.map((time) {
        if (!RegExp(r'^\d{2}:\d{2}$').hasMatch(time)) {
          throw const FormatException('Retry times must use HH:mm.');
        }
        final hour = int.parse(time.substring(0, 2));
        final minute = int.parse(time.substring(3));
        if (hour > 23 || minute > 59) {
          throw const FormatException(
            'Retry times must be between 00:00 and 23:59.',
          );
        }
        return hour * 60 + minute;
      }),
    );
  }

  final List<int> minutes;
  bool get enabled => minutes.isNotEmpty;
  List<String> get times => minutes.map(formatMinute).toList();

  static String formatMinute(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:'
      '${(minute % 60).toString().padLeft(2, '0')}';

  /// The next future slot, constructed by calendar day so DST cannot drift
  /// tomorrow's selected clock time by an hour.
  DateTime? nextAfter(DateTime now) {
    if (!enabled) return null;
    DateTime at(int day, int minute) => now.isUtc
        ? DateTime.utc(now.year, now.month, day, minute ~/ 60, minute % 60)
        : DateTime(now.year, now.month, day, minute ~/ 60, minute % 60);
    for (final minute in minutes) {
      final candidate = at(now.day, minute);
      if (candidate.isAfter(now)) return candidate;
    }
    return at(now.day + 1, minutes.first);
  }
}
