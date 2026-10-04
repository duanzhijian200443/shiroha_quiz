import 'package:shiroha_quiz/application/study_activity/study_activity_transition_engine.dart';
import 'package:shiroha_quiz/domain/study_activity/study_activity_time.dart';

int utcMs(String instant) => DateTime.parse(instant).millisecondsSinceEpoch;

/// Synthetic immutable rules: no host timezone, IANA data or system clock.
final class FakeActivityMapping implements StudyActivityLocalTimeMapping {
  FakeActivityMapping(this.initialOffset,
      [Iterable<({int utcMs, int offset})> changes = const []])
      : changes = List.unmodifiable(changes);
  final int initialOffset;
  final List<({int utcMs, int offset})> changes;

  int _offsetAt(int utc) {
    var offset = initialOffset;
    for (final change in changes) {
      if (utc < change.utcMs) break;
      offset = change.offset;
    }
    return offset;
  }

  int _midnight(DateTime date) {
    for (final offset in {initialOffset, ...changes.map((c) => c.offset)}) {
      final candidate = date.millisecondsSinceEpoch - offset * 60000;
      if (_offsetAt(candidate) == offset) return candidate;
    }
    throw StateError('Unsupported synthetic midnight');
  }

  @override
  StudyActivityLocalInterval intervalAt(int utc) {
    final offset = _offsetAt(utc);
    final local =
        DateTime.fromMillisecondsSinceEpoch(utc + offset * 60000, isUtc: true);
    var start = _midnight(DateTime.utc(local.year, local.month, local.day));
    var end = _midnight(DateTime.utc(local.year, local.month, local.day + 1));
    for (final change in changes) {
      if (change.utcMs <= utc && change.utcMs > start) start = change.utcMs;
      if (change.utcMs > utc && change.utcMs < end) end = change.utcMs;
    }
    return StudyActivityLocalInterval(
        localDate: '${local.year.toString().padLeft(4, '0')}-'
            '${local.month.toString().padLeft(2, '0')}-'
            '${local.day.toString().padLeft(2, '0')}',
        utcOffsetMinutes: offset,
        startUtcMs: start,
        endUtcMs: end);
  }
}

final class FakeActivityTimeSource implements StudyActivityTimeSource {
  FakeActivityTimeSource(this.current);
  StudyActivityTimeSample current;
  Object? failure;
  int samples = 0;
  @override
  StudyActivityTimeSample sample() {
    samples++;
    if (failure != null) throw failure!;
    return current;
  }

  void advance(int elapsedMs,
      {int? utc,
      StudyActivityLocalTimeMapping? mapping,
      bool changed = false}) {
    current = StudyActivityTimeSample(
        monotonicMs: current.monotonicMs + elapsedMs,
        utcMs: utc ?? current.utcMs + elapsedMs,
        mapping: mapping ?? current.mapping,
        mappingRevision: current.mappingRevision + (changed ? 1 : 0));
  }
}

final class BrokenActivityMapping implements StudyActivityLocalTimeMapping {
  const BrokenActivityMapping(this.read);
  final StudyActivityLocalInterval Function(int) read;
  @override
  StudyActivityLocalInterval intervalAt(int utcMs) => read(utcMs);
}
