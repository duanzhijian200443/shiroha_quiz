import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/study_activity/study_activity_values.dart';

void main() {
  test('all status x reason x endedAt combinations follow the frozen matrix',
      () {
    const allowedRows = {
      (StudyActivityLifecycleStatus.active, null, false),
      (StudyActivityLifecycleStatus.paused, null, false),
      (StudyActivityLifecycleStatus.ended, StudyActivityEndReason.exited, true),
      (
        StudyActivityLifecycleStatus.ended,
        StudyActivityEndReason.queueFinished,
        true
      ),
      (
        StudyActivityLifecycleStatus.ended,
        StudyActivityEndReason.submitted,
        true
      ),
      (
        StudyActivityLifecycleStatus.interrupted,
        StudyActivityEndReason.processInterrupted,
        true
      ),
      (
        StudyActivityLifecycleStatus.interrupted,
        StudyActivityEndReason.snapshotInterrupted,
        true
      ),
    };
    for (final status in StudyActivityLifecycleStatus.values) {
      for (final reason in <StudyActivityEndReason?>[
        null,
        ...StudyActivityEndReason.values
      ]) {
        for (final endedAt in <int?>[null, 0, 1000]) {
          final terminal = [
            StudyActivityLifecycleStatus.ended,
            StudyActivityLifecycleStatus.interrupted
          ].contains(status);
          final allowed =
              allowedRows.contains((status, reason, endedAt != null));
          StudyActivityLifecycle construct() => StudyActivityLifecycle(
              status: status, endedAtUtcMs: endedAt, endReason: reason);
          if (allowed) {
            final lifecycle = construct();
            expect(lifecycle.isTerminal, terminal);
            expect(lifecycle.endReason, reason);
          } else {
            expect(construct, throwsFormatException);
          }
        }
      }
    }
  });

  test('negative terminal timestamp fails with a fixed safe error', () {
    expect(
        () => StudyActivityLifecycle(
            status: StudyActivityLifecycleStatus.ended,
            endedAtUtcMs: -1,
            endReason: StudyActivityEndReason.exited),
        throwsA(isA<FormatException>()
            .having((error) => error.source, 'source', isNull)));
    expect(StudyActivityScene.values,
        contains(StudyActivityScene.singleQuestionStudy));
    expect(StudyActivityScene.values, hasLength(5));
  });
}
