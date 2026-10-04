import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/study_activity/study_activity_contracts.dart';
import 'package:shiroha_quiz/application/study_activity/study_activity_service_impl.dart';
import 'package:shiroha_quiz/application/study_activity/study_activity_transition_engine.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/study_activity_v30_schema.dart';
import 'package:shiroha_quiz/data/repositories/study_activity_repository.dart';
import 'package:shiroha_quiz/domain/study_activity/study_activity_time.dart';
import 'package:shiroha_quiz/domain/study_activity/study_activity_values.dart';

import '../../support/study_activity_time_fakes.dart';

T _ok<T>(HomeTrainingResult<T> result) {
  expect(result, isA<HomeTrainingSuccess<T>>());
  return (result as HomeTrainingSuccess<T>).value;
}

void _failed<T>(HomeTrainingResult<T> result, HomeTrainingFailure code) =>
    expect((result as HomeTrainingFailed<T>).failure, code);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late Directory temp;
  late StudyActivityRepository repo;
  late BackupRestoreMutationGateState gate;
  late FakeActivityTimeSource time;
  late StudyActivityTransitionEngine engine;
  var ids = 0;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    temp = await Directory.systemTemp.createTemp('activity_repo_');
    db = await DatabaseHelper.instance
        .openPathForTesting(p.join(temp.path, 'repo.db'));
    gate = BackupRestoreMutationGateState();
    repo =
        StudyActivityRepository(database: () async => db, mutationGate: gate);
    ids = 0;
    time = FakeActivityTimeSource(StudyActivityTimeSample(
        monotonicMs: 0,
        utcMs: utcMs('2026-10-05T23:59:50Z'),
        mapping: FakeActivityMapping(0)));
    engine = StudyActivityTransitionEngine(
        timeSource: time, sessionIdFactory: () => 's-${++ids}');
  });
  tearDown(() async {
    if (db.isOpen) await db.close();
    await DatabaseHelper.resetRuntimeProfileForTesting();
    await temp.delete(recursive: true);
  });
  Future<StudyActivityTransition> begin() async {
    final t = _ok(engine.begin(
        null,
        StudyActivityBeginRequest(
            scene: StudyActivityScene.ordinaryPractice,
            ownerToken: 'route',
            context: const StudyActivityContext(
                contentId: 'deleted',
                bankName: 'deleted',
                planId: 'stopped',
                paperId: 'deleted'))));
    _ok(await repo.createSession(t));
    return t;
  }

  Future<Object> rows() async => [
        await db.query(studyActivitySessionsTable),
        await db.query(studyActivitySegmentsTable,
            orderBy: 'session_id, sequence')
      ];

  test(
      'begin stores facts only, duplicate conflicts, no learning/config mutation',
      () async {
    final t = await begin();
    expect(await db.query('questions'), isEmpty);
    expect(await db.query('review_states'), isEmpty);
    expect(await db.query('training_contents'), isEmpty);
    final row = (await db.query(studyActivitySessionsTable)).single;
    expect(row['content_id'], 'deleted');
    expect(row['started_at_utc_ms'], time.current.utcMs);
    expect(row.containsKey('ownerToken'), isFalse);
    expect(row.containsKey('recordingQuality'), isFalse);
    expect(await db.query(studyActivitySegmentsTable), isEmpty);
    final before = await rows();
    _failed(await repo.createSession(t), HomeTrainingFailure.conflict);
    expect(await rows(), before);
    expect(gate.activeMutationCount, 0);
  });

  test(
      'multi-day checkpoint exceeds checkpoint sequence, replay once, conflict immutable',
      () async {
    final initial = await begin();
    time.advance(const Duration(days: 2, seconds: 30).inMilliseconds);
    final t = _ok(engine.checkpoint(initial.state, initial.state.owner!));
    expect(t.segments, hasLength(4));
    _ok(await repo.commitTransition(initial.state, t));
    final before = await rows();
    for (var i = 0; i < 3; i++) {
      _ok(await repo.commitTransition(initial.state, t));
    }
    expect(await rows(), before);
    final stored = (await db.query(studyActivitySessionsTable)).single;
    expect(stored['revision'], 2);
    expect(stored['checkpoint_sequence'], 1);
    final old = t.segments.first;
    final changed = StudyActivitySegmentDraft(
        sequence: old.sequence,
        localDate: old.localDate,
        utcOffsetMinutes: old.utcOffsetMinutes,
        startUtcMs: old.startUtcMs,
        endUtcMs: old.endUtcMs,
        durationMs: old.durationMs + 1);
    _failed(
        await repo.commitTransition(initial.state,
            StudyActivityTransition(t.state, [changed, ...t.segments.skip(1)])),
        HomeTrainingFailure.conflict);
    expect(await rows(), before);
    await validateStudyActivityV30Data(db);
  });

  test(
      'stale checkpoint/pause/end zero mutation and terminal exact replay only',
      () async {
    final initial = await begin();
    final owner = initial.state.owner!;
    time.advance(1000);
    final cp = _ok(engine.checkpoint(initial.state, owner));
    _ok(await repo.commitTransition(initial.state, cp));
    time.advance(1000);
    final terminal = _ok(engine.end(
        cp.state,
        StudyActivityEndRequest(
            owner: owner, reason: StudyActivityEndReason.exited)));
    _ok(await repo.commitTransition(cp.state, terminal));
    final before = await rows();
    _ok(await repo.commitTransition(cp.state, terminal));
    for (final t in [
      _ok(engine.checkpoint(initial.state, owner)),
      _ok(engine.pause(initial.state, owner)),
      _ok(engine.end(
          initial.state,
          StudyActivityEndRequest(
              owner: owner, reason: StudyActivityEndReason.queueFinished)))
    ]) {
      _failed(await repo.commitTransition(initial.state, t),
          HomeTrainingFailure.stale);
      expect(await rows(), before);
    }
  });

  test('segment/update write failures roll back the entire proposal', () async {
    final initial = await begin();
    time.advance(30000);
    final t = _ok(engine.checkpoint(initial.state, initial.state.owner!));
    final before = await rows();
    await db.execute(
        "CREATE TRIGGER fail_segment BEFORE INSERT ON study_activity_segments WHEN NEW.sequence=2 BEGIN SELECT RAISE(ABORT,'synthetic'); END");
    _failed(await repo.commitTransition(initial.state, t),
        HomeTrainingFailure.unavailable);
    expect(await rows(), before);
    await db.execute('DROP TRIGGER fail_segment');
    await db.execute(
        "CREATE TRIGGER fail_session BEFORE UPDATE ON study_activity_sessions BEGIN SELECT RAISE(ABORT,'synthetic'); END");
    _failed(await repo.commitTransition(initial.state, t),
        HomeTrainingFailure.unavailable);
    expect(await rows(), before);
    await db.execute('DROP TRIGGER fail_session');
    _ok(await repo.commitTransition(initial.state, t));
    expect(await db.query(studyActivitySegmentsTable), hasLength(2));
  });

  test(
      'mutation gate blocks begin/checkpoint/recovery, read queries never recover',
      () async {
    final initial = await begin();
    time.advance(1000);
    final t = _ok(engine.checkpoint(initial.state, initial.state.owner!));
    final before = await rows();
    gate.tryEnterQuiescence();
    _failed(await repo.commitTransition(initial.state, t),
        HomeTrainingFailure.unavailable);
    _failed(await repo.recoverInterruptedSessions(),
        HomeTrainingFailure.unavailable);
    final newer = _ok(engine.begin(
        null,
        StudyActivityBeginRequest(
            scene: StudyActivityScene.mockExam,
            ownerToken: 'other',
            context: const StudyActivityContext())));
    _failed(await repo.createSession(newer), HomeTrainingFailure.unavailable);
    final week = _ok(await repo.readWeek('2026-10-05'));
    expect(week.totalDurationMs, 0);
    expect(await rows(), before);
    gate.exitQuiescence();
    expect(gate.activeMutationCount, 0);
  });

  test(
      'recovery closes active/paused at last checkpoint with revision only, idempotent',
      () async {
    final active = await begin();
    final another = await begin();
    time.advance(1000);
    final paused = _ok(engine.pause(another.state, another.state.owner!));
    _ok(await repo.commitTransition(another.state, paused));
    final segments = await db.query(studyActivitySegmentsTable);
    expect(_ok(await repo.recoverInterruptedSessions()), 2);
    final saved = await rows();
    expect(_ok(await repo.recoverInterruptedSessions()), 0);
    expect(await rows(), saved);
    for (final row in await db.query(studyActivitySessionsTable)) {
      expect(row['lifecycle_status'], 'interrupted');
      expect(row['end_reason'], 'processInterrupted');
      expect(row['ended_at_utc_ms'], row['last_checkpoint_at_utc_ms']);
      expect(row['checkpoint_sequence'],
          row['session_id'] == active.snapshot.sessionId ? 0 : 1);
      expect(row['revision'],
          row['session_id'] == active.snapshot.sessionId ? 2 : 3);
    }
    expect(await db.query(studyActivitySegmentsTable), segments);
  });

  test(
      'zero-segment replay and missing replay fact fail closed; recovery rollback',
      () async {
    final initial = await begin();
    final zero = _ok(engine.checkpoint(initial.state, initial.state.owner!));
    expect(zero.segments, isEmpty);
    _ok(await repo.commitTransition(initial.state, zero));
    final zeroRows = await rows();
    _ok(await repo.commitTransition(initial.state, zero));
    expect(await rows(), zeroRows);
    time.advance(1000);
    final cp = _ok(engine.checkpoint(zero.state, zero.state.owner!));
    _ok(await repo.commitTransition(zero.state, cp));
    await db.delete(studyActivitySegmentsTable);
    final missing = await rows();
    _failed(await repo.commitTransition(zero.state, cp),
        HomeTrainingFailure.conflict);
    expect(await rows(), missing);
    await db.execute(
        "CREATE TRIGGER failed_recovery BEFORE UPDATE ON study_activity_sessions BEGIN SELECT RAISE(ABORT,'synthetic'); END");
    _failed(await repo.recoverInterruptedSessions(),
        HomeTrainingFailure.unavailable);
    expect(await rows(), missing);
    await db.execute('DROP TRIGGER failed_recovery');
    _ok(await repo.recoverInterruptedSessions());
    final interrupted = await rows();
    time.advance(1000);
    _failed(
        await repo.commitTransition(
            cp.state, _ok(engine.checkpoint(cp.state, cp.state.owner!))),
        HomeTrainingFailure.stale);
    expect(await rows(), interrupted);
  });

  test(
      'weekly SUM facts/7 days/zero vs failure; wall/offset history never normalized',
      () async {
    final initial = await begin();
    time.advance(30000);
    final first = _ok(engine.checkpoint(initial.state, initial.state.owner!));
    _ok(await repo.commitTransition(initial.state, first));
    time.advance(900, utc: utcMs('2026-10-06T00:00:01Z'), changed: true);
    final second = _ok(engine.end(
        first.state,
        StudyActivityEndRequest(
            owner: initial.state.owner!,
            reason: StudyActivityEndReason.exited)));
    _ok(await repo.commitTransition(first.state, second));
    // Sequence/monotonic facts allow UTC overlap and duration != boundary width.
    await db.update(studyActivitySegmentsTable,
        {'duration_ms': 999, 'utc_offset_minutes': 330},
        where: 'sequence=3');
    final week = _ok(await repo.readWeek('2026-10-05'));
    expect(week.days, hasLength(7));
    expect(week.totalDurationMs, 30999);
    expect(week.learningDayCount, 2);
    expect(week.days[0].durationMs, 10000);
    expect(week.days[1].durationMs, 20999);
    expect(_ok(await repo.readWeek('2026-10-12')).totalDurationMs, 0);
    final plan = await db.rawQuery(
        'EXPLAIN QUERY PLAN SELECT local_date, SUM(duration_ms) FROM study_activity_segments WHERE local_date >= ? AND local_date <= ? GROUP BY local_date',
        ['2026-10-05', '2026-10-11']);
    expect(plan.map((r) => r['detail']).join(' '),
        contains('idx_study_activity_local_date'));
    await db.close();
    _failed(await repo.readWeek('2026-10-05'), HomeTrainingFailure.unavailable);
  });

  test(
      'real service serial terminal race records once and stops after failed pause',
      () async {
    final service = PersistentStudyActivityService(
        engine: engine,
        persistence: repo,
        currentLocalDate: () => '2026-10-05');
    _ok(await service.recoverAtStartup());
    final owner = _ok(await service.begin(StudyActivityBeginRequest(
        scene: StudyActivityScene.mockExam,
        ownerToken: 'route',
        context: const StudyActivityContext())));
    time.advance(1000);
    final results = await Future.wait([
      service.checkpoint(owner),
      service.end(StudyActivityEndRequest(
          owner: owner, reason: StudyActivityEndReason.submitted)),
      service.end(StudyActivityEndRequest(
          owner: owner, reason: StudyActivityEndReason.exited))
    ]);
    expect(results[0], isA<HomeTrainingSuccess<StudyActivitySnapshot>>());
    expect(results[1], isA<HomeTrainingSuccess<StudyActivitySnapshot>>());
    _failed(results[2], HomeTrainingFailure.stale);
    expect(_ok(await service.readCurrentWeek()).totalDurationMs, 1000);
    final next = _ok(await service.begin(StudyActivityBeginRequest(
        scene: StudyActivityScene.ordinaryPractice,
        ownerToken: 'next',
        context: const StudyActivityContext())));
    await db.execute(
        "CREATE TRIGGER failed_pause BEFORE UPDATE ON study_activity_sessions BEGIN SELECT RAISE(ABORT,'synthetic'); END");
    time.advance(1000);
    _failed(await service.pause(next), HomeTrainingFailure.unavailable);
    await db.execute('DROP TRIGGER failed_pause');
    final before = await rows();
    final samples = time.samples;
    time.advance(7200000);
    _failed(await service.resume(next), HomeTrainingFailure.unavailable);
    _failed(await service.checkpoint(next), HomeTrainingFailure.unavailable);
    _failed(
        await service.end(StudyActivityEndRequest(
            owner: next, reason: StudyActivityEndReason.exited)),
        HomeTrainingFailure.unavailable);
    expect(time.samples, samples);
    expect(await rows(), before);
    expect(_ok(await service.readCurrentWeek()).recordingQuality,
        StudyActivityRecordingQuality.partial);
    // Exit failure does not retain the released runtime owner.
    expect(
        await service.begin(StudyActivityBeginRequest(
            scene: StudyActivityScene.categoryReview,
            ownerToken: 'new-route',
            context: const StudyActivityContext())),
        isA<HomeTrainingSuccess<StudyActivityOwner>>());
  });
}
