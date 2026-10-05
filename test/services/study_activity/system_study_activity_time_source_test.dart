import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/study_activity/study_activity_time.dart';
import 'package:shiroha_quiz/services/study_activity/system_study_activity_time_source.dart';

void main() {
  for (final offset in [480, -300]) {
    test('injected system mapping $offset splits actual local midnight', () {
      final utc = DateTime.utc(2026, 10, 5, 23, 59, 50).millisecondsSinceEpoch -
          offset * 60000;
      var mono = 5;
      var wall = utc;
      StudyActivityLocalObservation localAt(int instant) => (
            localDate: DateTime.fromMillisecondsSinceEpoch(
                    instant + offset * 60000,
                    isUtc: true)
                .toIso8601String()
                .substring(0, 10),
            offsetMinutes: offset
          );
      final source = SystemStudyActivityTimeSource(
          monotonicMs: () => mono,
          utcNow: () => DateTime.fromMillisecondsSinceEpoch(wall, isUtc: true),
          localAt: localAt);
      final first = source.sample();
      mono += 30000;
      wall += 30000;
      final second = source.sample();
      expect(second.monotonicMs - first.monotonicMs, 30000);
      expect(second.mappingRevision, first.mappingRevision);
      expect(source.currentLocalDate(), '2026-10-06');
      final split = splitStudyActivityElapsed(
          startUtcMs: utc,
          durationMs: 30000,
          firstSequence: 1,
          mapping: first.mapping);
      expect(split.map((s) => s.durationMs), [10000, 20000]);
      expect(split.map((s) => s.localDate), ['2026-10-05', '2026-10-06']);
      expect(split.map((s) => s.utcOffsetMinutes), [offset, offset]);
    });
  }

  test(
      'wall/zone observation changes revision; previous mapping stays immutable',
      () {
    var utc = DateTime.utc(2026, 10, 5, 12).millisecondsSinceEpoch;
    var mono = 0;
    var offset = 0;
    final source = SystemStudyActivityTimeSource(
        monotonicMs: () => mono,
        utcNow: () => DateTime.fromMillisecondsSinceEpoch(utc, isUtc: true),
        localAt: (instant) => (
              localDate: DateTime.fromMillisecondsSinceEpoch(
                      instant + offset * 60000,
                      isUtc: true)
                  .toIso8601String()
                  .substring(0, 10),
              offsetMinutes: offset
            ));
    final initial = source.sample();
    mono = 30000;
    utc += 3600000;
    final jumped = source.sample();
    expect(jumped.monotonicMs, 30000);
    expect(jumped.utcMs - initial.utcMs, 3600000);
    expect(jumped.mappingRevision, greaterThan(initial.mappingRevision));
    offset = -300;
    final zoned = source.sample();
    expect(zoned.mappingRevision, greaterThan(jumped.mappingRevision));
    expect(initial.mapping.intervalAt(utc).utcOffsetMinutes, 0);
    expect(zoned.mapping.intervalAt(utc).utcOffsetMinutes, -300);
  });

  test('captured system offset transition is a real boundary', () {
    final transition = DateTime.utc(2026, 3, 8, 7).millisecondsSinceEpoch;
    final source = SystemStudyActivityTimeSource(
        monotonicMs: () => 0,
        utcNow: () => DateTime.fromMillisecondsSinceEpoch(transition - 10000,
            isUtc: true),
        localAt: (instant) {
          final offset = instant < transition ? -300 : -240;
          return (
            localDate: DateTime.fromMillisecondsSinceEpoch(
                    instant + offset * 60000,
                    isUtc: true)
                .toIso8601String()
                .substring(0, 10),
            offsetMinutes: offset
          );
        });
    final mapping = source.sample().mapping;
    expect(mapping.intervalAt(transition - 1).endUtcMs, transition);
    expect(mapping.intervalAt(transition).utcOffsetMinutes, -240);
  });
}
