import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/study_activity/study_activity_contracts.dart';
import 'package:shiroha_quiz/application/study_activity/study_activity_transition_engine.dart';
import 'package:shiroha_quiz/domain/study_activity/study_activity_values.dart';
import 'package:shiroha_quiz/domain/training/category_key.dart';

import '../../support/study_activity_time_fakes.dart';

StudyActivityTransition _ok(
    HomeTrainingResult<StudyActivityTransition> result) {
  expect(result, isA<HomeTrainingSuccess<StudyActivityTransition>>());
  return (result as HomeTrainingSuccess<StudyActivityTransition>).value;
}

void _failed(HomeTrainingResult<StudyActivityTransition> result,
    HomeTrainingFailure code) {
  expect(result, isA<HomeTrainingFailed<StudyActivityTransition>>());
  expect((result as HomeTrainingFailed<StudyActivityTransition>).failure, code);
}

int _duration(StudyActivityTransition transition) => transition.segments
    .fold<int>(0, (sum, segment) => sum + segment.durationMs);

void main() {
  late FakeActivityTimeSource time;
  late StudyActivityTransitionEngine engine;
  int identities = 0;
  final context = StudyActivityContext(
      categoryKey: FolderCategoryKey('Math'),
      contentId: 'deleted-content',
      bankName: 'deleted-bank',
      planId: 'stopped-plan',
      paperId: 'deleted-paper');

  setUp(() {
    identities = 0;
    time = FakeActivityTimeSource(StudyActivityTimeSample(
        monotonicMs: 0,
        utcMs: utcMs('2026-10-04T10:00:00Z'),
        mapping: FakeActivityMapping(480)));
    engine = StudyActivityTransitionEngine(
        timeSource: time, sessionIdFactory: () => 'session-${++identities}');
  });

  StudyActivityTransition begin(
          [StudyActivityScene scene = StudyActivityScene.ordinaryPractice]) =>
      _ok(engine.begin(
          null,
          StudyActivityBeginRequest(
              scene: scene, ownerToken: 'route', context: context)));

  for (final scene in StudyActivityScene.values
      .where((s) => s != StudyActivityScene.singleQuestionStudy)) {
    test('$scene begins one active owner with explicit scene and soft context',
        () {
      final transition = begin(scene);
      final state = transition.state;
      expect(state.owner!.sessionId, 'session-1');
      expect(state.owner!.ownerToken, 'route');
      expect(state.snapshot.scene, scene);
      expect(state.context, same(context));
      expect(state.startedAtUtcMs, time.current.utcMs);
      expect(state.activeAnchor, same(time.current));
      expect(
          state.snapshot.lifecycle.status, StudyActivityLifecycleStatus.active);
      expect(state.snapshot.recordingQuality,
          StudyActivityRecordingQuality.recordedOnly);
      expect(state.snapshot.checkpointSequence, 0);
      expect(state.snapshot.revision, 1);
      expect(state.nextSegmentSequence, 1);
      expect(transition.segments, isEmpty);
      final sampled = time.samples;
      _failed(
          engine.begin(
              state,
              StudyActivityBeginRequest(
                  scene: scene,
                  ownerToken: 'second-route',
                  context: const StudyActivityContext())),
          HomeTrainingFailure.conflict);
      expect(time.samples, sampled);
      expect(identities, 1);
      expect(state.owner!.ownerToken, 'route');
    });
  }

  test('fifth scene and recovery reasons remain definition-only at runtime',
      () {
    expect(
        () => StudyActivityBeginRequest(
            scene: StudyActivityScene.singleQuestionStudy,
            ownerToken: 'route',
            context: context),
        throwsA(isA<HomeTrainingContractException>().having(
            (e) => e.failure, 'safe code', HomeTrainingFailure.invalidInput)));
    final owner = begin().state.owner!;
    for (final reason in [
      StudyActivityEndReason.processInterrupted,
      StudyActivityEndReason.snapshotInterrupted
    ]) {
      expect(() => StudyActivityEndRequest(owner: owner, reason: reason),
          throwsA(isA<HomeTrainingContractException>()));
    }
  });

  test('pause/resume repetitions are no-ops, wrong session/token are stale',
      () {
    final initial = begin().state;
    final owner = initial.owner!;
    time.advance(1000);
    final paused = _ok(engine.pause(initial, owner));
    expect(_duration(paused), 1000);
    expect(paused.state.activeAnchor, isNull);
    final calls = time.samples;
    time.advance(7200000);
    final repeatedPause = _ok(engine.pause(paused.state, owner));
    expect(repeatedPause.state, same(paused.state));
    expect(repeatedPause.segments, isEmpty);
    expect(time.samples, calls);
    for (final wrong in [
      StudyActivityOwner(sessionId: owner.sessionId, ownerToken: 'wrong'),
      StudyActivityOwner(sessionId: 'wrong', ownerToken: 'route')
    ]) {
      _failed(engine.resume(paused.state, wrong), HomeTrainingFailure.stale);
      _failed(engine.pause(initial, wrong), HomeTrainingFailure.stale);
      _failed(engine.checkpoint(initial, wrong), HomeTrainingFailure.stale);
      _failed(
          engine.end(
              initial,
              StudyActivityEndRequest(
                  owner: wrong, reason: StudyActivityEndReason.exited)),
          HomeTrainingFailure.stale);
    }
    expect(time.samples, calls);
    // Value-equivalent owner handles are accepted only with both identities.
    final resumed = _ok(engine.resume(
        paused.state,
        StudyActivityOwner(
            sessionId: owner.sessionId, ownerToken: owner.ownerToken)));
    expect(resumed.segments, isEmpty);
    expect(
        resumed.snapshot.lifecycle.status, StudyActivityLifecycleStatus.active);
    final beforeRepeat = time.samples;
    time.advance(500);
    final repeatedResume = _ok(engine.resume(resumed.state, owner));
    expect(repeatedResume.state, same(resumed.state));
    expect(repeatedResume.segments, isEmpty);
    expect(time.samples, beforeRepeat);
  });

  for (final paused in [false, true]) {
    for (final reason in [
      StudyActivityEndReason.exited,
      StudyActivityEndReason.queueFinished,
      StudyActivityEndReason.submitted
    ]) {
      test(
          '${paused ? 'paused' : 'active'} ends/$reason and rejects all late events',
          () {
        var state = begin(StudyActivityScene.mockExam).state;
        final owner = state.owner!;
        time.advance(1000);
        if (paused) state = _ok(engine.pause(state, owner)).state;
        time.advance(1000);
        final terminal = _ok(engine.end(
            state, StudyActivityEndRequest(owner: owner, reason: reason)));
        expect(_duration(terminal), paused ? 0 : 2000);
        expect(terminal.snapshot.lifecycle.status,
            StudyActivityLifecycleStatus.ended);
        expect(terminal.snapshot.lifecycle.endReason, reason);
        expect(terminal.snapshot.lifecycle.endedAtUtcMs, time.current.utcMs);
        expect(terminal.state.owner, isNull);
        expect(terminal.state.activeAnchor, isNull);
        final sampled = time.samples;
        time.advance(1000);
        for (final result in [
          engine.pause(terminal.state, owner),
          engine.resume(terminal.state, owner),
          engine.checkpoint(terminal.state, owner),
          engine.end(terminal.state,
              StudyActivityEndRequest(owner: owner, reason: reason))
        ]) {
          _failed(result, HomeTrainingFailure.stale);
        }
        expect(time.samples, sampled);
        final next = _ok(engine.begin(
            terminal.state,
            StudyActivityBeginRequest(
                scene: StudyActivityScene.categoryReview,
                ownerToken: 'new-route',
                context: const StudyActivityContext())));
        expect(next.state.owner!.sessionId, 'session-2');
        expect(next.state.nextSegmentSequence, 1);
        _failed(
            engine.checkpoint(next.state, owner), HomeTrainingFailure.stale);
      });
    }
  }

  test(
      '0/1000/3500 monotonic accumulation yields 1000 + 2500, deterministic sequences',
      () {
    final started = begin().state;
    final owner = started.owner!;
    time.advance(1000);
    final first = _ok(engine.checkpoint(started, owner));
    time.advance(2500);
    final second = _ok(engine.checkpoint(first.state, owner));
    expect([_duration(first), _duration(second)], [1000, 2500]);
    expect([first.segments.single.sequence, second.segments.single.sequence],
        [1, 2]);
    expect(second.state.nextSegmentSequence, 3);
    expect(second.snapshot.checkpointSequence, 2);
    expect(second.snapshot.revision, 3);
    expect(started.snapshot.checkpointSequence, 0);
    expect(() => first.segments.clear(), throwsUnsupportedError);
  });

  test(
      'pause through midnight and 2h checkpoint adds nothing; resume/end adds only active',
      () {
    time.current = StudyActivityTimeSample(
        monotonicMs: 0,
        utcMs: utcMs('2026-10-04T15:59:45Z'),
        mapping: time.current.mapping);
    final initial = begin().state;
    final owner = initial.owner!;
    time.advance(10000);
    final pause = _ok(engine.pause(initial, owner));
    time.advance(7200000);
    final checkpoint = _ok(engine.checkpoint(pause.state, owner));
    expect(checkpoint.segments, isEmpty);
    expect(checkpoint.state.nextSegmentSequence, 2);
    final resume = _ok(engine.resume(checkpoint.state, owner));
    expect(resume.segments, isEmpty);
    time.advance(5000);
    final ended = _ok(engine.end(
        resume.state,
        StudyActivityEndRequest(
            owner: owner, reason: StudyActivityEndReason.exited)));
    expect(_duration(pause) + _duration(ended), 15000);
    expect(pause.segments.single.localDate, '2026-10-04');
    expect(ended.segments.single.localDate, '2026-10-05');
    expect(ended.state.context, same(context));
  });

  for (final jump in [-3600000, 86400000]) {
    test('wall jump $jump cannot change duration or invalidate terminal matrix',
        () {
      final initial = begin().state;
      final owner = initial.owner!;
      time.advance(1000);
      final checkpoint = _ok(engine.checkpoint(initial, owner));
      final oldWall = time.current.utcMs;
      time.advance(30000, utc: oldWall + jump, changed: true);
      final ended = _ok(engine.end(
          checkpoint.state,
          StudyActivityEndRequest(
              owner: owner, reason: StudyActivityEndReason.exited)));
      expect(_duration(ended), 30000);
      expect(ended.segments.single.startUtcMs, oldWall);
      expect(ended.segments.single.endUtcMs, oldWall + 30000);
      expect(ended.snapshot.lastCheckpointAtUtcMs, oldWall + jump);
      expect(ended.snapshot.lifecycle.endedAtUtcMs, oldWall + jump);
      expect(ended.state.startedAtUtcMs, initial.startedAtUtcMs);
    });
  }

  test('observed zone change keeps 20s on old mapping, next 10s on new mapping',
      () {
    time.current = StudyActivityTimeSample(
        monotonicMs: 0,
        utcMs: utcMs('2026-10-04T20:00:00Z'),
        mapping: FakeActivityMapping(0));
    final initial = begin().state;
    final owner = initial.owner!;
    time.advance(20000, mapping: FakeActivityMapping(480), changed: true);
    final detection = _ok(engine.checkpoint(initial, owner));
    expect(detection.segments.single.localDate, '2026-10-04');
    expect(detection.segments.single.utcOffsetMinutes, 0);
    expect(_duration(detection), 20000);
    time.advance(10000);
    final next = _ok(engine.checkpoint(detection.state, owner));
    expect(next.segments.single.localDate, '2026-10-05');
    expect(next.segments.single.utcOffsetMinutes, 480);
    expect(_duration(next), 10000);
    expect(detection.segments.single.utcOffsetMinutes, 0);
    expect(detection.segments.single.endUtcMs, next.segments.single.startUtcMs);
  });

  test(
      'wall mapping switch uses old anchor until observation and new one afterwards',
      () {
    final initial = begin().state;
    final owner = initial.owner!;
    final oldUtc = time.current.utcMs;
    time.advance(20000, utc: oldUtc + 3600000, changed: true);
    final detection = _ok(engine.checkpoint(initial, owner));
    time.advance(10000);
    final next = _ok(engine.checkpoint(detection.state, owner));
    expect(detection.segments.single.endUtcMs, oldUtc + 20000);
    expect(next.segments.single.startUtcMs, oldUtc + 3600000);
    expect(_duration(detection) + _duration(next), 30000);
  });

  test(
      'backward monotonic, unannounced mapping/wall drift and source errors do not advance state',
      () {
    final initial = begin().state;
    final owner = initial.owner!;
    time.advance(1000);
    final confirmed = _ok(engine.checkpoint(initial, owner)).state;
    final previous = time.current;
    for (final sample in [
      StudyActivityTimeSample(
          monotonicMs: 999,
          utcMs: previous.utcMs,
          mapping: previous.mapping,
          mappingRevision: 1),
      StudyActivityTimeSample(
          monotonicMs: 2000,
          utcMs: previous.utcMs + 999,
          mapping: previous.mapping),
      StudyActivityTimeSample(
          monotonicMs: 2000,
          utcMs: previous.utcMs + 1000,
          mapping: FakeActivityMapping(0)),
    ]) {
      time.current = sample;
      _failed(
          engine.checkpoint(confirmed, owner), HomeTrainingFailure.unavailable);
      expect(confirmed.lastSample, same(previous));
      expect(confirmed.snapshot.checkpointSequence, 1);
      expect(confirmed.snapshot.revision, 2);
      expect(confirmed.nextSegmentSequence, 2);
    }
    time.failure = StateError('synthetic source details');
    _failed(engine.pause(confirmed, owner), HomeTrainingFailure.unavailable);
    expect(confirmed.snapshot.lifecycle.status,
        StudyActivityLifecycleStatus.active);
    time.failure = null;
    time.current = previous;
    time.advance(2500);
    final recovered = _ok(engine.checkpoint(confirmed, owner));
    expect(_duration(recovered), 2500);
    expect(recovered.segments.single.sequence, 2);
  });

  test(
      'split failure after a valid prefix publishes no state or partial drafts',
      () {
    final start = utcMs('2026-10-04T23:59:59Z');
    final good = FakeActivityMapping(0);
    final broken = BrokenActivityMapping((utc) {
      if (utc == utcMs('2026-10-05T00:00:00Z')) {
        throw StateError('synthetic bad midpoint');
      }
      return good.intervalAt(utc);
    });
    time.current =
        StudyActivityTimeSample(monotonicMs: 0, utcMs: start, mapping: broken);
    final initial = begin().state;
    time.advance(2000);
    _failed(engine.checkpoint(initial, initial.owner!),
        HomeTrainingFailure.unavailable);
    expect(initial.activeAnchor!.utcMs, start);
    expect(initial.snapshot.revision, 1);
    expect(initial.nextSegmentSequence, 1);
    // The accepted state still contains the entire unconfirmed interval.
    time.advance(1000, mapping: good, changed: true);
    // The old immutable mapping is still required to attribute that interval;
    // a new observation cannot repair or erase its failed historical prefix.
    _failed(engine.checkpoint(initial, initial.owner!),
        HomeTrainingFailure.unavailable);
  });

  for (final elapsed in [0, 1, 999, 59999, 60000]) {
    test('checkpoint $elapsed ms preserves precision without zero facts', () {
      final initial = begin().state;
      time.advance(elapsed);
      final result = _ok(engine.checkpoint(initial, initial.owner!));
      expect(_duration(result), elapsed);
      expect(result.segments.length, elapsed == 0 ? 0 : 1);
      expect(result.state.nextSegmentSequence, elapsed == 0 ? 1 : 2);
      expect(result.snapshot.checkpointSequence, 1);
    });
  }

  test('reused terminal session identity cannot reactivate an old owner handle',
      () {
    final initial = begin().state;
    final ended = _ok(engine.end(
            initial,
            StudyActivityEndRequest(
                owner: initial.owner!, reason: StudyActivityEndReason.exited)))
        .state;
    final reused = StudyActivityTransitionEngine(
        timeSource: time, sessionIdFactory: () => initial.owner!.sessionId);
    _failed(
        reused.begin(
            ended,
            StudyActivityBeginRequest(
                scene: StudyActivityScene.ordinaryPractice,
                ownerToken: 'route',
                context: context)),
        HomeTrainingFailure.unavailable);
    expect(ended.owner, isNull);
    _failed(engine.resume(ended, initial.owner!), HomeTrainingFailure.stale);
  });

  test(
      'bad source/identity factories and invalid samples have no owner proposal',
      () {
    for (final factory in [
      () => '',
      () => throw StateError('synthetic ID failure')
    ]) {
      final bad = StudyActivityTransitionEngine(
          timeSource: time, sessionIdFactory: factory);
      _failed(
          bad.begin(
              null,
              StudyActivityBeginRequest(
                  scene: StudyActivityScene.mockExam,
                  ownerToken: 'route',
                  context: context)),
          HomeTrainingFailure.unavailable);
    }
    time.failure = StateError('synthetic time failure');
    _failed(
        engine.begin(
            null,
            StudyActivityBeginRequest(
                scene: StudyActivityScene.mockExam,
                ownerToken: 'route',
                context: context)),
        HomeTrainingFailure.unavailable);
    expect(identities, 0);
    for (final (mono, wall, revision) in [(-1, 0, 0), (0, -1, 0), (0, 0, -1)]) {
      expect(
          () => StudyActivityTimeSample(
              monotonicMs: mono,
              utcMs: wall,
              mapping: FakeActivityMapping(0),
              mappingRevision: revision),
          throwsA(isA<HomeTrainingContractException>()));
    }
  });
}
