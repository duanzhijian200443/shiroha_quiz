import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/study_activity/study_activity_contracts.dart';
import 'package:shiroha_quiz/domain/study_activity/study_activity_values.dart';

final class _ActivityFake implements StudyActivityService {
  StudyActivityOwner? seenOwner;
  StudyActivityEndRequest? seenEnd;
  @override
  Future<HomeTrainingResult<StudyActivityOwner>> begin(
          StudyActivityBeginRequest request) async =>
      HomeTrainingSuccess(StudyActivityOwner(
          sessionId: 'session-a', ownerToken: request.ownerToken));
  @override
  Future<HomeTrainingResult<StudyActivitySnapshot>> pause(
          StudyActivityOwner owner) async =>
      _capture(owner);
  @override
  Future<HomeTrainingResult<StudyActivitySnapshot>> resume(
          StudyActivityOwner owner) async =>
      _capture(owner);
  @override
  Future<HomeTrainingResult<StudyActivitySnapshot>> checkpoint(
          StudyActivityOwner owner) async =>
      _capture(owner);
  @override
  Future<HomeTrainingResult<StudyActivitySnapshot>> end(
      StudyActivityEndRequest request) async {
    seenEnd = request;
    return _capture(request.owner);
  }

  HomeTrainingResult<StudyActivitySnapshot> _capture(StudyActivityOwner owner) {
    seenOwner = owner;
    return const HomeTrainingFailed(HomeTrainingFailure.stale);
  }
}

void main() {
  test(
      'begin rejects the definition-only fifth scene; lifecycle calls bind the owner',
      () async {
    final fake = _ActivityFake();
    final result = await fake.begin(StudyActivityBeginRequest(
        scene: StudyActivityScene.ordinaryPractice,
        ownerToken: 'route-owner-1',
        context: const StudyActivityContext(
            contentId: 'deleted-content-soft-reference')));
    final owner = (result as HomeTrainingSuccess<StudyActivityOwner>).value;
    expect(owner.ownerToken, 'route-owner-1');
    await fake.pause(owner);
    await fake.resume(owner);
    final checkpoint = await fake.checkpoint(owner);
    expect(fake.seenOwner, same(owner));
    expect((checkpoint as HomeTrainingFailed<StudyActivitySnapshot>).failure,
        HomeTrainingFailure.stale);
    final end = StudyActivityEndRequest(
        owner: owner, reason: StudyActivityEndReason.exited);
    await fake.end(end);
    expect(fake.seenEnd, same(end));
    expect(
        () => StudyActivityBeginRequest(
            scene: StudyActivityScene.singleQuestionStudy,
            ownerToken: 'owner',
            context: const StudyActivityContext()),
        throwsA(isA<HomeTrainingContractException>()));
  });

  test('runtime end cannot claim recovery/snapshot interruption reasons', () {
    final owner = StudyActivityOwner(sessionId: 's', ownerToken: 'o');
    for (final reason in [
      StudyActivityEndReason.exited,
      StudyActivityEndReason.queueFinished,
      StudyActivityEndReason.submitted
    ]) {
      expect(
          StudyActivityEndRequest(owner: owner, reason: reason).reason, reason);
    }
    for (final reason in [
      StudyActivityEndReason.processInterrupted,
      StudyActivityEndReason.snapshotInterrupted
    ]) {
      expect(() => StudyActivityEndRequest(owner: owner, reason: reason),
          throwsA(isA<HomeTrainingContractException>()));
    }
  });

  test(
      'recorded week is immutable and distinguishes zero, partial and unavailable',
      () {
    final days = [
      for (var day = 5; day <= 11; day++)
        StudyActivityDaySummary(
            localDate: '2026-10-${day.toString().padLeft(2, '0')}',
            durationMs: day == 5 ? 59999 : 0)
    ];
    final week = StudyActivityWeekSnapshot(
        mondayLocalDate: '2026-10-05',
        days: days,
        recordingQuality: StudyActivityRecordingQuality.partial);
    days.clear();
    expect(week.days, hasLength(7));
    expect(week.totalDurationMs, 59999);
    expect(week.learningDayCount, 1);
    expect(week.recordingQuality, StudyActivityRecordingQuality.partial);
    expect(() => week.days.clear(), throwsUnsupportedError);
    final empty = StudyActivityWeekSnapshot(
        mondayLocalDate: '2026-10-05',
        days: [
          for (final day in week.days)
            StudyActivityDaySummary(localDate: day.localDate, durationMs: 0)
        ],
        recordingQuality: StudyActivityRecordingQuality.recordedOnly);
    expect(empty.totalDurationMs, 0);
    expect(empty.learningDayCount, 0);
    expect(
        const HomeTrainingFailed<StudyActivityWeekSnapshot>(
            HomeTrainingFailure.unavailable),
        isNot(isA<HomeTrainingSuccess<StudyActivityWeekSnapshot>>()));
    expect(
        () => StudyActivityDaySummary(localDate: '2026-02-30', durationMs: 0),
        throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => StudyActivityDaySummary(localDate: '2026-10-05', durationMs: -1),
        throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => StudyActivityWeekSnapshot(
            mondayLocalDate: '2026-10-06',
            days: week.days,
            recordingQuality: StudyActivityRecordingQuality.recordedOnly),
        throwsA(isA<HomeTrainingContractException>()));
  });

  test(
      'safe lifecycle snapshot keeps owner identity separate from durable facts',
      () {
    final snapshot = StudyActivitySnapshot(
        sessionId: 's',
        scene: StudyActivityScene.mockExam,
        lifecycle: StudyActivityLifecycle(
            status: StudyActivityLifecycleStatus.interrupted,
            endedAtUtcMs: 1000,
            endReason: StudyActivityEndReason.processInterrupted),
        lastCheckpointAtUtcMs: 1000,
        checkpointSequence: 2,
        revision: 3,
        recordingQuality: StudyActivityRecordingQuality.recordedOnly);
    expect(snapshot.lifecycle.isTerminal, isTrue);
    expect(snapshot.lastCheckpointAtUtcMs, 1000);
    expect(snapshot.checkpointSequence, 2);
    expect(
        () => StudyActivitySnapshot(
            sessionId: 's',
            scene: StudyActivityScene.mockExam,
            lifecycle: snapshot.lifecycle,
            lastCheckpointAtUtcMs: 1001,
            checkpointSequence: 2,
            revision: 3,
            recordingQuality: StudyActivityRecordingQuality.recordedOnly),
        throwsA(isA<HomeTrainingContractException>()));
  });
}
