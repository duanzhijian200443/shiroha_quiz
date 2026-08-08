/// IANA timezone seam for the T0 read-only study query layer.
///
/// The project has no timezone database dependency, so the default resolver
/// embeds a bounded, frozen set of common IANA zones: fixed-offset zones
/// (UTC, major Asian zones) and rule-based DST zones (US/Canada, EU, and
/// Australia). Any other syntactically valid IANA name is rejected as an
/// invalid request rather than silently using a wrong offset. A full tz
/// database remains a deferred concern outside T0.
library;

import 'study_query_dtos.dart';
import 'study_query_error.dart';

/// Resolves UTC instants to local calendar dates for an IANA zone.
abstract interface class StudyQueryTimeZone {
  /// Local calendar date of [utcInstant] in [ianaName].
  StudyLocalDate localDateOf(DateTime utcInstant, String ianaName);

  /// UTC instant of local midnight of [date] in [ianaName].
  DateTime utcInstantOfLocalMidnight(StudyLocalDate date, String ianaName);
}

/// Embedded bounded IANA resolver (see library comment for the supported
/// set and its documented limits).
final class EmbeddedIanaTimeZoneResolver implements StudyQueryTimeZone {
  const EmbeddedIanaTimeZoneResolver();

  static final RegExp _ianaNamePattern =
      RegExp(r'^[A-Za-z0-9_+\-]+(?:/[A-Za-z0-9_+\-]+)*$');
  static const int _maxNameLength = 64;

  static const Map<String, Duration> _fixedOffsets = <String, Duration>{
    'UTC': Duration.zero,
    'Etc/UTC': Duration.zero,
    'Etc/GMT': Duration.zero,
    'Asia/Shanghai': Duration(hours: 8),
    'Asia/Hong_Kong': Duration(hours: 8),
    'Asia/Taipei': Duration(hours: 8),
    'Asia/Singapore': Duration(hours: 8),
    'Asia/Tokyo': Duration(hours: 9),
    'Asia/Seoul': Duration(hours: 9),
    'Asia/Kolkata': Duration(hours: 5, minutes: 30),
    'Asia/Dubai': Duration(hours: 4),
    'Australia/Perth': Duration(hours: 8),
  };

  static const Map<String, _DstZone> _dstZones = <String, _DstZone>{
    'America/New_York': _DstZone(
      standard: Duration(hours: -5),
      daylight: Duration(hours: -4),
      start: _DstRule(month: 3, occurrence: 2, weekday: DateTime.sunday),
      end: _DstRule(month: 11, occurrence: 1, weekday: DateTime.sunday),
    ),
    'America/Toronto': _DstZone(
      standard: Duration(hours: -5),
      daylight: Duration(hours: -4),
      start: _DstRule(month: 3, occurrence: 2, weekday: DateTime.sunday),
      end: _DstRule(month: 11, occurrence: 1, weekday: DateTime.sunday),
    ),
    'America/Chicago': _DstZone(
      standard: Duration(hours: -6),
      daylight: Duration(hours: -5),
      start: _DstRule(month: 3, occurrence: 2, weekday: DateTime.sunday),
      end: _DstRule(month: 11, occurrence: 1, weekday: DateTime.sunday),
    ),
    'America/Denver': _DstZone(
      standard: Duration(hours: -7),
      daylight: Duration(hours: -6),
      start: _DstRule(month: 3, occurrence: 2, weekday: DateTime.sunday),
      end: _DstRule(month: 11, occurrence: 1, weekday: DateTime.sunday),
    ),
    'America/Los_Angeles': _DstZone(
      standard: Duration(hours: -8),
      daylight: Duration(hours: -7),
      start: _DstRule(month: 3, occurrence: 2, weekday: DateTime.sunday),
      end: _DstRule(month: 11, occurrence: 1, weekday: DateTime.sunday),
    ),
    'America/Vancouver': _DstZone(
      standard: Duration(hours: -8),
      daylight: Duration(hours: -7),
      start: _DstRule(month: 3, occurrence: 2, weekday: DateTime.sunday),
      end: _DstRule(month: 11, occurrence: 1, weekday: DateTime.sunday),
    ),
    'Europe/London': _DstZone(
      standard: Duration.zero,
      daylight: Duration(hours: 1),
      start: _DstRule(
        month: 3,
        occurrence: -1,
        weekday: DateTime.sunday,
        atUtc: Duration(hours: 1),
      ),
      end: _DstRule(
        month: 10,
        occurrence: -1,
        weekday: DateTime.sunday,
        atUtc: Duration(hours: 1),
      ),
    ),
    'Europe/Paris': _DstZone(
      standard: Duration(hours: 1),
      daylight: Duration(hours: 2),
      start: _DstRule(
        month: 3,
        occurrence: -1,
        weekday: DateTime.sunday,
        atUtc: Duration(hours: 1),
      ),
      end: _DstRule(
        month: 10,
        occurrence: -1,
        weekday: DateTime.sunday,
        atUtc: Duration(hours: 1),
      ),
    ),
    'Europe/Berlin': _DstZone(
      standard: Duration(hours: 1),
      daylight: Duration(hours: 2),
      start: _DstRule(
        month: 3,
        occurrence: -1,
        weekday: DateTime.sunday,
        atUtc: Duration(hours: 1),
      ),
      end: _DstRule(
        month: 10,
        occurrence: -1,
        weekday: DateTime.sunday,
        atUtc: Duration(hours: 1),
      ),
    ),
    'Europe/Madrid': _DstZone(
      standard: Duration(hours: 1),
      daylight: Duration(hours: 2),
      start: _DstRule(
        month: 3,
        occurrence: -1,
        weekday: DateTime.sunday,
        atUtc: Duration(hours: 1),
      ),
      end: _DstRule(
        month: 10,
        occurrence: -1,
        weekday: DateTime.sunday,
        atUtc: Duration(hours: 1),
      ),
    ),
    'Europe/Rome': _DstZone(
      standard: Duration(hours: 1),
      daylight: Duration(hours: 2),
      start: _DstRule(
        month: 3,
        occurrence: -1,
        weekday: DateTime.sunday,
        atUtc: Duration(hours: 1),
      ),
      end: _DstRule(
        month: 10,
        occurrence: -1,
        weekday: DateTime.sunday,
        atUtc: Duration(hours: 1),
      ),
    ),
    'Australia/Sydney': _DstZone(
      standard: Duration(hours: 10),
      daylight: Duration(hours: 11),
      start: _DstRule(month: 10, occurrence: 1, weekday: DateTime.sunday),
      end: _DstRule(month: 4, occurrence: 1, weekday: DateTime.sunday),
    ),
    'Australia/Melbourne': _DstZone(
      standard: Duration(hours: 10),
      daylight: Duration(hours: 11),
      start: _DstRule(month: 10, occurrence: 1, weekday: DateTime.sunday),
      end: _DstRule(month: 4, occurrence: 1, weekday: DateTime.sunday),
    ),
  };

  @override
  StudyLocalDate localDateOf(DateTime utcInstant, String ianaName) {
    final normalized = _requireKnownZone(ianaName);
    final utc = utcInstant.toUtc();
    final offset = _offsetAt(utc, normalized);
    final local = utc.add(offset);
    return StudyLocalDate(
      year: local.year,
      month: local.month,
      day: local.day,
    );
  }

  @override
  DateTime utcInstantOfLocalMidnight(
    StudyLocalDate date,
    String ianaName,
  ) {
    final normalized = _requireKnownZone(ianaName);
    final localMidnight = DateTime.utc(date.year, date.month, date.day);
    final offset = _offsetAt(
      localMidnight.subtract(_standardOffset(normalized)),
      normalized,
    );
    return localMidnight.subtract(offset);
  }

  String _requireKnownZone(String ianaName) {
    final trimmed = ianaName.trim();
    if (trimmed.isEmpty ||
        trimmed.length > _maxNameLength ||
        !_ianaNamePattern.hasMatch(trimmed)) {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
    if (!_fixedOffsets.containsKey(trimmed) &&
        !_dstZones.containsKey(trimmed)) {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
    return trimmed;
  }

  Duration _standardOffset(String zone) {
    final fixed = _fixedOffsets[zone];
    if (fixed != null) return fixed;
    return _dstZones[zone]!.standard;
  }

  Duration _offsetAt(DateTime utcInstant, String zone) {
    final fixed = _fixedOffsets[zone];
    if (fixed != null) return fixed;
    final dstZone = _dstZones[zone]!;
    return _isDst(utcInstant, dstZone) ? dstZone.daylight : dstZone.standard;
  }

  bool _isDst(DateTime utcInstant, _DstZone zone) {
    final utc = utcInstant.toUtc();
    final year = utc.year;
    final start = _transitionUtc(year, zone.start, zone);
    final end = _transitionUtc(year, zone.end, zone);
    if (zone.start.month < zone.end.month) {
      return !utc.isBefore(start) && utc.isBefore(end);
    }
    // Southern-hemisphere DST crosses the year boundary.
    return !utc.isBefore(start) || utc.isBefore(end);
  }

  DateTime _transitionUtc(int year, _DstRule rule, _DstZone zone) {
    final localDate = rule.occurrence < 0
        ? _lastWeekday(year, rule.month, rule.weekday)
        : _nthWeekday(year, rule.month, rule.weekday, rule.occurrence);
    final wallClock = localDate.add(rule.atUtc);
    if (rule.atUtc != Duration.zero) return wallClock;
    final isStart = identical(rule, zone.start);
    return wallClock.subtract(isStart ? zone.standard : zone.daylight);
  }
}

/// Nth-weekday DST rule. Negative [occurrence] means the last such weekday
/// of the month. [atUtc] anchors EU-style transitions at a UTC wall time.
final class _DstRule {
  const _DstRule({
    required this.month,
    required this.occurrence,
    required this.weekday,
    this.atUtc = Duration.zero,
  });

  final int month;
  final int occurrence;
  final int weekday;
  final Duration atUtc;
}

final class _DstZone {
  const _DstZone({
    required this.standard,
    required this.daylight,
    required this.start,
    required this.end,
  });

  final Duration standard;
  final Duration daylight;
  final _DstRule start;
  final _DstRule end;
}

DateTime _nthWeekday(int year, int month, int weekday, int occurrence) {
  final first = DateTime.utc(year, month, 1);
  final offset = (weekday - first.weekday) % 7;
  return DateTime.utc(year, month, 1 + offset + (occurrence - 1) * 7);
}

DateTime _lastWeekday(int year, int month, int weekday) {
  final last = DateTime.utc(year, month + 1, 0);
  final offset = (last.weekday - weekday) % 7;
  return DateTime.utc(year, month, last.day - offset);
}
