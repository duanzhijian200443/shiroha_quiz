import '../../application/study_activity/study_activity_transition_engine.dart';
import '../../domain/study_activity/study_activity_time.dart';

typedef StudyActivityLocalObservation = ({String localDate, int offsetMinutes});

/// System clocks with immutable calendar observations. Duration still comes
/// exclusively from Stopwatch. Calendar snapshots fail closed outside their
/// captured horizon, rather than consulting a possibly changed system zone.
final class SystemStudyActivityTimeSource implements StudyActivityTimeSource {
  SystemStudyActivityTimeSource({
    int Function()? monotonicMs,
    DateTime Function()? utcNow,
    StudyActivityLocalObservation Function(int)? localAt,
  })  : _monotonicMs = monotonicMs ?? _startClock(),
        _utcNow = utcNow ?? DateTime.now,
        _localAt = localAt ?? _systemLocalAt;

  final int Function() _monotonicMs;
  final DateTime Function() _utcNow;
  final StudyActivityLocalObservation Function(int) _localAt;
  StudyActivityTimeSample? _last;
  _CapturedCalendar? _calendar;
  int _revision = 0;

  static int Function() _startClock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsedMilliseconds;
  }

  static StudyActivityLocalObservation _systemLocalAt(int utcMs) {
    final local =
        DateTime.fromMillisecondsSinceEpoch(utcMs, isUtc: true).toLocal();
    return (
      localDate: _date(local),
      offsetMinutes: local.timeZoneOffset.inMinutes
    );
  }

  static String _date(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  String currentLocalDate() =>
      _localAt(_utcNow().millisecondsSinceEpoch).localDate;

  @override
  StudyActivityTimeSample sample() {
    final monotonic = _monotonicMs();
    final utc = _utcNow().millisecondsSinceEpoch;
    final local = _localAt(utc);
    final last = _last;
    final predicted =
        last == null ? utc : last.utcMs + monotonic - last.monotonicMs;
    final calendar = _calendar;
    // Millisecond sampling jitter does not imply a manual wall-clock change.
    final wallChanged = (utc - predicted).abs() > 1000;
    final zoneChanged = calendar != null &&
        calendar.contains(utc) &&
        calendar.observationAt(utc) != local;
    // Re-observe tomorrow's offset as well: a zone change can keep today's
    // offset but change the future DST rules. Old samples retain old facts.
    final futureChanged = calendar != null &&
        calendar.contains(utc + Duration.millisecondsPerDay) &&
        calendar.observationAt(utc + Duration.millisecondsPerDay) !=
            _localAt(utc + Duration.millisecondsPerDay);
    if (calendar == null ||
        wallChanged ||
        zoneChanged ||
        futureChanged ||
        !calendar.contains(utc + 2 * Duration.millisecondsPerDay)) {
      _calendar = _CapturedCalendar.capture(utc, _localAt);
      if (last != null) _revision++;
    }
    final observation = StudyActivityTimeSample(
        monotonicMs: monotonic,
        utcMs: utc,
        mapping: _calendar!,
        mappingRevision: _revision);
    _last = observation;
    return observation;
  }
}

final class _CapturedCalendar implements StudyActivityLocalTimeMapping {
  _CapturedCalendar(List<StudyActivityLocalInterval> intervals)
      : _intervals = List.unmodifiable(intervals);
  final List<StudyActivityLocalInterval> _intervals;

  // Observe real local-date/offset boundaries in UTC and capture their facts.
  // Advancing the probe in UTC is not advancing a local midnight by 24 hours.
  // A 370-day horizon captures a complete system DST cycle; an unobserved
  // longer interval becomes unavailable instead of inventing calendar facts.
  factory _CapturedCalendar.capture(
      int utc, StudyActivityLocalObservation Function(int) localAt) {
    final start = (utc - 2 * Duration.millisecondsPerDay).clamp(0, utc);
    final end = utc + 370 * Duration.millisecondsPerDay;
    final intervals = <StudyActivityLocalInterval>[];
    var cursor = start;
    var intervalStart = start;
    var observation = localAt(cursor);
    while (cursor < end) {
      final probe = (cursor + Duration.millisecondsPerHour).clamp(cursor, end);
      if (localAt(probe) != observation) {
        var low = cursor;
        var high = probe;
        while (high - low > 1) {
          final middle = low + (high - low) ~/ 2;
          if (localAt(middle) == observation) {
            low = middle;
          } else {
            high = middle;
          }
        }
        intervals.add(StudyActivityLocalInterval(
            localDate: observation.localDate,
            utcOffsetMinutes: observation.offsetMinutes,
            startUtcMs: intervalStart,
            endUtcMs: high));
        cursor = high;
        intervalStart = high;
        observation = localAt(cursor);
      } else {
        cursor = probe;
      }
    }
    if (intervalStart < end) {
      intervals.add(StudyActivityLocalInterval(
          localDate: observation.localDate,
          utcOffsetMinutes: observation.offsetMinutes,
          startUtcMs: intervalStart,
          endUtcMs: end));
    }
    return _CapturedCalendar(intervals);
  }

  bool contains(int utc) =>
      utc >= _intervals.first.startUtcMs && utc < _intervals.last.endUtcMs;
  StudyActivityLocalObservation observationAt(int utc) {
    final interval = intervalAt(utc);
    return (
      localDate: interval.localDate,
      offsetMinutes: interval.utcOffsetMinutes
    );
  }

  @override
  StudyActivityLocalInterval intervalAt(int utcMs) {
    var low = 0;
    var high = _intervals.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_intervals[middle].endUtcMs <= utcMs) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low == _intervals.length || utcMs < _intervals[low].startUtcMs) {
      throw const FormatException('Unavailable StudyActivity calendar.');
    }
    return _intervals[low];
  }
}
