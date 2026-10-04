import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/study_activity/study_activity_time.dart';

import '../../support/study_activity_time_fakes.dart';

Map<String, int> _days(List<StudyActivitySegmentDraft> segments) {
  final sums = <String, int>{};
  for (final segment in segments) {
    sums.update(segment.localDate, (v) => v + segment.durationMs,
        ifAbsent: () => segment.durationMs);
  }
  return sums;
}

void _exact(
    List<StudyActivitySegmentDraft> drafts, int duration, int sequence) {
  expect(drafts.fold<int>(0, (s, d) => s + d.durationMs), duration);
  for (var i = 0; i < drafts.length; i++) {
    expect(drafts[i].sequence, sequence + i);
    expect(drafts[i].durationMs, greaterThan(0));
    if (i > 0) expect(drafts[i].startUtcMs, drafts[i - 1].endUtcMs);
  }
  expect(() => drafts.clear(), throwsUnsupportedError);
}

void main() {
  test('local midnight splits exactly 10s/20s, never by UTC date', () {
    final start = utcMs('2026-10-04T15:59:50Z');
    final drafts = splitStudyActivityElapsed(
        startUtcMs: start,
        durationMs: 30000,
        firstSequence: 7,
        mapping: FakeActivityMapping(480));
    expect(_days(drafts), {'2026-10-04': 10000, '2026-10-05': 20000});
    expect(drafts.map((d) => d.utcOffsetMinutes), [480, 480]);
    expect(drafts.first.startUtcMs, start);
    expect(drafts.last.endUtcMs, start + 30000);
    _exact(drafts, 30000, 7);
  });

  test('Friday 23:59 to Sunday 00:01 crosses all real local midnights', () {
    final duration = const Duration(days: 1, minutes: 2).inMilliseconds;
    final drafts = splitStudyActivityElapsed(
        startUtcMs: utcMs('2026-10-02T15:59:00Z'),
        durationMs: duration,
        firstSequence: 1,
        mapping: FakeActivityMapping(480));
    expect(_days(drafts),
        {'2026-10-02': 60000, '2026-10-03': 86400000, '2026-10-04': 60000});
    _exact(drafts, duration, 1);
  });

  for (final offset in [480, 330, -420]) {
    test('offset $offset attributes its observed local date', () {
      final local = utcMs('2026-10-04T23:59:59.999Z');
      final drafts = splitStudyActivityElapsed(
          startUtcMs: local - offset * 60000,
          durationMs: 2,
          firstSequence: 1,
          mapping: FakeActivityMapping(offset));
      expect(drafts.map((d) => d.localDate), ['2026-10-04', '2026-10-05']);
      expect(drafts.map((d) => d.utcOffsetMinutes), [offset, offset]);
      expect(drafts.map((d) => d.durationMs), [1, 1]);
    });
  }

  for (final spring in [true, false]) {
    test(
        'DST ${spring ? 23 : 25}-hour day uses real bounds and offset transition',
        () {
      final start =
          utcMs(spring ? '2026-03-08T05:00:00Z' : '2026-11-01T04:00:00Z');
      final end =
          utcMs(spring ? '2026-03-09T04:00:00Z' : '2026-11-02T05:00:00Z');
      final mapping = FakeActivityMapping(spring ? -300 : -240, [
        (
          utcMs:
              utcMs(spring ? '2026-03-08T07:00:00Z' : '2026-11-01T06:00:00Z'),
          offset: spring ? -240 : -300
        )
      ]);
      final drafts = splitStudyActivityElapsed(
          startUtcMs: start,
          durationMs: end - start,
          firstSequence: 1,
          mapping: mapping);
      expect(
          _days(drafts), {spring ? '2026-03-08' : '2026-11-01': end - start});
      expect(drafts, hasLength(2));
      expect(drafts.map((d) => d.utcOffsetMinutes),
          spring ? [-300, -240] : [-240, -300]);
      expect(end - start, Duration(hours: spring ? 23 : 25).inMilliseconds);
      _exact(drafts, end - start, 1);
      final crossing = splitStudyActivityElapsed(
          startUtcMs: start - 1,
          durationMs: end - start + 2,
          firstSequence: 1,
          mapping: mapping);
      expect(_days(crossing).values, [1, end - start, 1]);
      _exact(crossing, end - start + 2, 1);
    });
  }

  for (final duration in [0, 1, 999, 59999, 60000]) {
    test('integer precision $duration ms, zero makes no learning day', () {
      final drafts = splitStudyActivityElapsed(
          startUtcMs: utcMs('2026-10-04T10:00:00Z'),
          durationMs: duration,
          firstSequence: 1,
          mapping: FakeActivityMapping(0));
      expect(drafts.length, duration == 0 ? 0 : 1);
      _exact(drafts, duration, 1);
    });
  }

  test('incomplete/invalid mapping fails closed, even after a valid prefix',
      () {
    final start = utcMs('2026-10-04T23:59:59Z');
    final good = FakeActivityMapping(0);
    final failure = BrokenActivityMapping((utc) {
      if (utc > start) throw StateError('synthetic rejected calendar details');
      return good.intervalAt(utc);
    });
    expect(
        () => splitStudyActivityElapsed(
            startUtcMs: start,
            durationMs: 2000,
            firstSequence: 1,
            mapping: failure),
        throwsA(isA<FormatException>()
            .having((e) => e.source, 'safe source', isNull)
            .having((e) => e.message, 'safe error',
                'Unavailable StudyActivity time attribution.')));
    for (final interval in [
      StudyActivityLocalInterval(
          localDate: '2026-10-04',
          utcOffsetMinutes: 0,
          startUtcMs: start + 1,
          endUtcMs: start + 2),
      StudyActivityLocalInterval(
          localDate: '2026-10-03',
          utcOffsetMinutes: 0,
          startUtcMs: start - 1,
          endUtcMs: start + 2),
      StudyActivityLocalInterval(
          localDate: '2026-10-04',
          utcOffsetMinutes: 0,
          startUtcMs: start - 1,
          endUtcMs: start + 2000),
    ]) {
      expect(
          () => splitStudyActivityElapsed(
              startUtcMs: start,
              durationMs: 2000,
              firstSequence: 1,
              mapping: BrokenActivityMapping((_) => interval)),
          throwsFormatException);
    }
  });

  test('segment/date/interval inputs validate without echoing values', () {
    for (final date in ['2026-02-30', '2026-13-01', 'bad', '2026-1-01']) {
      expect(isStudyActivityLocalDate(date), isFalse);
      expect(
          () => StudyActivitySegmentDraft(
              sequence: 1,
              localDate: date,
              utcOffsetMinutes: 0,
              startUtcMs: 0,
              endUtcMs: 1,
              durationMs: 1),
          throwsFormatException);
    }
    expect(isStudyActivityLocalDate('2024-02-29'), isTrue);
    for (final (sequence, start, end, duration) in [
      (0, 0, 1, 1),
      (1, -1, 1, 1),
      (1, 2, 1, 1),
      (1, 0, 1, -1)
    ]) {
      expect(
          () => StudyActivitySegmentDraft(
              sequence: sequence,
              localDate: '2026-10-04',
              utcOffsetMinutes: 0,
              startUtcMs: start,
              endUtcMs: end,
              durationMs: duration),
          throwsFormatException);
    }
  });
}
