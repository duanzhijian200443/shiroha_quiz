import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/study_activity/study_activity_contracts.dart';
import 'package:shiroha_quiz/application/study_activity/study_activity_persistence.dart';
import 'package:shiroha_quiz/application/study_activity/study_activity_service_impl.dart';
import 'package:shiroha_quiz/application/study_activity/study_activity_transition_engine.dart';
import 'package:shiroha_quiz/domain/study_activity/study_activity_values.dart';
import '../../support/study_activity_time_fakes.dart';

final class _Port implements StudyActivityPersistence {
  final committed = <StudyActivityTransition>[];
  final entered = Completer<void>();
  Completer<HomeTrainingResult<StudyActivitySnapshot>>? hold;
  bool throwsCommit = false;
  int recoveries = 0;
  String? monday;
  @override
  Future<HomeTrainingResult<StudyActivitySnapshot>> createSession(
          StudyActivityTransition t) async =>
      HomeTrainingSuccess(t.snapshot);
  @override
  Future<HomeTrainingResult<StudyActivitySnapshot>> commitTransition(
      StudyActivityRuntimeState old, StudyActivityTransition t) async {
    committed.add(t);
    if (!entered.isCompleted) entered.complete();
    if (throwsCommit) throw StateError('synthetic port failure');
    final waiting = hold;
    hold = null;
    return waiting == null
        ? HomeTrainingSuccess(t.snapshot)
        : await waiting.future;
  }

  @override
  Future<HomeTrainingResult<int>> recoverInterruptedSessions() async {
    recoveries++;
    return const HomeTrainingSuccess(0);
  }

  @override
  Future<HomeTrainingResult<StudyActivityWeekSnapshot>> readWeek(
      String date) async {
    monday = date;
    final start = DateTime.parse('${date}T00:00:00Z');
    return HomeTrainingSuccess(StudyActivityWeekSnapshot(
        mondayLocalDate: date,
        days: [
          for (var i = 0; i < 7; i++)
            StudyActivityDaySummary(
                localDate: start
                    .add(Duration(days: i))
                    .toIso8601String()
                    .substring(0, 10),
                durationMs: 0)
        ],
        recordingQuality: StudyActivityRecordingQuality.recordedOnly));
  }
}

T _ok<T>(HomeTrainingResult<T> r) => (r as HomeTrainingSuccess<T>).value;
void main() {
  late _Port port;
  late FakeActivityTimeSource time;
  late PersistentStudyActivityService service;
  var ids = 0;
  StudyActivityBeginRequest request() => StudyActivityBeginRequest(
      scene: StudyActivityScene.ordinaryPractice,
      ownerToken: 'route',
      context: const StudyActivityContext());
  setUp(() {
    port = _Port();
    ids = 0;
    time = FakeActivityTimeSource(StudyActivityTimeSample(
        monotonicMs: 0,
        utcMs: utcMs('2026-10-05T10:00:00Z'),
        mapping: FakeActivityMapping(0)));
    service = PersistentStudyActivityService(
        engine: StudyActivityTransitionEngine(
            timeSource: time, sessionIdFactory: () => 's-${++ids}'),
        persistence: port,
        currentLocalDate: () => '2026-10-11');
  });
  test('startup explicit, query does not recover; Sunday maps to Monday',
      () async {
    expect(await service.begin(request()),
        isA<HomeTrainingFailed<StudyActivityOwner>>());
    _ok(await service.readCurrentWeek());
    expect(port.recoveries, 0);
    expect(port.monday, '2026-10-05');
    _ok(await service.recoverAtStartup());
    _ok(await service.recoverAtStartup());
    expect(port.recoveries, 1);
    _ok(await service.begin(request()));
    expect(await service.recoverAtStartup(), isA<HomeTrainingFailed<int>>());
  });
  test('occupied owner remains conflict even when clock source fails',
      () async {
    _ok(await service.recoverAtStartup());
    _ok(await service.begin(request()));
    time.failure = StateError('synthetic unavailable clock');
    expect((await service.begin(request()) as HomeTrainingFailed).failure,
        HomeTrainingFailure.conflict);
  });

  test('injected local week crosses month/year with seven calendar dates',
      () async {
    for (final fixture in [
      ('2026-01-01', '2025-12-29', '2026-01-04'),
      ('2026-03-01', '2026-02-23', '2026-03-01')
    ]) {
      var reads = 0;
      final query = PersistentStudyActivityService(
          engine: StudyActivityTransitionEngine(
              timeSource: time, sessionIdFactory: () => 'unused'),
          persistence: port,
          currentLocalDate: () {
            reads++;
            return fixture.$1;
          });
      final week = _ok(await query.readCurrentWeek());
      expect(reads, 1);
      expect(week.mondayLocalDate, fixture.$2);
      expect(week.days, hasLength(7));
      expect(week.days.last.localDate, fixture.$3);
      expect(port.recoveries, 0);
    }
  });

  test('pause racing exit commits elapsed once and releases owner', () async {
    _ok(await service.recoverAtStartup());
    final owner = _ok(await service.begin(request()));
    time.advance(1000);
    final results = await Future.wait([
      service.pause(owner),
      service.end(StudyActivityEndRequest(
          owner: owner, reason: StudyActivityEndReason.exited))
    ]);
    expect(results,
        everyElement(isA<HomeTrainingSuccess<StudyActivitySnapshot>>()));
    expect(
        port.committed
            .expand((p) => p.segments)
            .fold<int>(0, (sum, s) => sum + s.durationMs),
        1000);
    expect(await service.checkpoint(owner),
        isA<HomeTrainingFailed<StudyActivitySnapshot>>());
    expect(await service.begin(request()),
        isA<HomeTrainingSuccess<StudyActivityOwner>>());
  });

  test('queued pause freezes clock at ingress rather than after slow DB write',
      () async {
    _ok(await service.recoverAtStartup());
    final owner = _ok(await service.begin(request()));
    time.advance(1000);
    final held = Completer<HomeTrainingResult<StudyActivitySnapshot>>();
    port.hold = held;
    final checkpoint = service.checkpoint(owner);
    await port.entered.future;
    final pause = service.pause(owner);
    time.advance(7200000);
    held.complete(HomeTrainingSuccess(port.committed.first.snapshot));
    _ok(await checkpoint);
    _ok(await pause);
    expect(
        port.committed
            .expand((p) => p.segments)
            .fold<int>(0, (sum, s) => sum + s.durationMs),
        1000);
    _ok(await service.resume(owner));
    time.advance(5000);
    _ok(await service.end(StudyActivityEndRequest(
        owner: owner, reason: StudyActivityEndReason.exited)));
    expect(
        port.committed
            .expand((p) => p.segments)
            .fold<int>(0, (sum, s) => sum + s.durationMs),
        6000);
  });
  test('throwing end port releases owner and marks partial', () async {
    _ok(await service.recoverAtStartup());
    final owner = _ok(await service.begin(request()));
    time.advance(1000);
    port.throwsCommit = true;
    expect(
        await service.end(StudyActivityEndRequest(
            owner: owner, reason: StudyActivityEndReason.exited)),
        isA<HomeTrainingFailed<StudyActivitySnapshot>>());
    port.throwsCommit = false;
    expect(await service.begin(request()),
        isA<HomeTrainingSuccess<StudyActivityOwner>>());
    expect(_ok(await service.readCurrentWeek()).recordingQuality,
        StudyActivityRecordingQuality.partial);
  });
  test('racing terminal reasons commit once, later callback stale', () async {
    _ok(await service.recoverAtStartup());
    final owner = _ok(await service.begin(request()));
    time.advance(1000);
    final results = await Future.wait([
      service.end(StudyActivityEndRequest(
          owner: owner, reason: StudyActivityEndReason.queueFinished)),
      service.end(StudyActivityEndRequest(
          owner: owner, reason: StudyActivityEndReason.exited))
    ]);
    expect(results.first, isA<HomeTrainingSuccess<StudyActivitySnapshot>>());
    expect((results.last as HomeTrainingFailed).failure,
        HomeTrainingFailure.stale);
    expect(port.committed, hasLength(1));
  });
  test('failed checkpoint stops new attribution/clock reads for same session',
      () async {
    _ok(await service.recoverAtStartup());
    final owner = _ok(await service.begin(request()));
    time.advance(1000);
    final held = Completer<HomeTrainingResult<StudyActivitySnapshot>>();
    port.hold = held;
    final checkpoint = service.checkpoint(owner);
    await port.entered.future;
    held.complete(const HomeTrainingFailed(HomeTrainingFailure.unavailable));
    await checkpoint;
    final samples = time.samples;
    time.advance(7200000);
    await service.pause(owner);
    await service.resume(owner);
    await service.checkpoint(owner);
    expect(port.committed, hasLength(1));
    expect(time.samples, samples);
    expect(_ok(await service.readCurrentWeek()).recordingQuality,
        StudyActivityRecordingQuality.partial);
  });
}
