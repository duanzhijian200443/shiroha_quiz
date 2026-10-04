import 'dart:convert';

import '../../application/backup/backup_restore_gate.dart';
import '../../application/home_training_result.dart';
import '../../application/study_activity/study_activity_contracts.dart';
import '../../application/study_activity/study_activity_persistence.dart';
import '../../application/study_activity/study_activity_transition_engine.dart';
import '../../core/database/database_helper.dart';
import '../../core/database/sqflite_runtime.dart';
import '../../core/database/study_activity_v30_schema.dart';
import '../../domain/study_activity/study_activity_time.dart';
import '../../domain/study_activity/study_activity_values.dart';
import '../../domain/training/category_key.dart';

/// One gated short transaction per live mutation. Immutable exact proposals
/// may replay; clocks are never read or recalculated by persistence.
final class StudyActivityRepository implements StudyActivityPersistence {
  StudyActivityRepository(
      {Future<Database> Function()? database,
      BackupRestoreMutationGateState? mutationGate})
      : _database = database ?? (() => DatabaseHelper.instance.database),
        _gate = mutationGate ?? BackupRestoreMutationGate.instance;
  final Future<Database> Function() _database;
  final BackupRestoreMutationGateState _gate;

  Future<HomeTrainingResult<T>> _read<T>(
      Future<T> Function(DatabaseExecutor) action,
      {bool mutation = false}) async {
    Future<T> execute() async => (await _database()).transaction(action);
    try {
      return HomeTrainingSuccess(
          await (mutation ? _gate.runMutation(execute) : execute()));
    } on _ActivityFailure catch (e) {
      return HomeTrainingFailed(e.code);
    } catch (_) {
      return const HomeTrainingFailed(HomeTrainingFailure.unavailable);
    }
  }

  Map<String, Object?> _session(StudyActivityRuntimeState state) => {
        'session_id': state.snapshot.sessionId,
        'scene': state.snapshot.scene.name,
        'lifecycle_status': state.snapshot.lifecycle.status.name,
        'started_at_utc_ms': state.startedAtUtcMs,
        'last_checkpoint_at_utc_ms': state.snapshot.lastCheckpointAtUtcMs,
        'ended_at_utc_ms': state.snapshot.lifecycle.endedAtUtcMs,
        'end_reason': state.snapshot.lifecycle.endReason?.name,
        'checkpoint_sequence': state.snapshot.checkpointSequence,
        'revision': state.snapshot.revision,
        'category_key': state.context.categoryKey == null
            ? null
            : const CategoryKeyCodec().encodeString(state.context.categoryKey!),
        'content_id': state.context.contentId,
        'bank_name': state.context.bankName,
        'plan_id': state.context.planId,
        'paper_id': state.context.paperId,
      };
  Map<String, Object?> _segment(String id, StudyActivitySegmentDraft draft) => {
        'segment_id': jsonEncode([id, draft.sequence]),
        'session_id': id,
        'sequence': draft.sequence,
        'local_date': draft.localDate,
        'utc_offset_minutes': draft.utcOffsetMinutes,
        'start_utc_ms': draft.startUtcMs,
        'end_utc_ms': draft.endUtcMs,
        'duration_ms': draft.durationMs,
      };
  bool _equal(Map<String, Object?> a, Map<String, Object?> b) =>
      a.length == b.length && a.keys.every((key) => a[key] == b[key]);
  Never _fail(HomeTrainingFailure code) => throw _ActivityFailure(code);

  @override
  Future<HomeTrainingResult<StudyActivitySnapshot>> createSession(
          StudyActivityTransition proposal) =>
      _read((db) async {
        final state = proposal.state;
        final values = _session(state);
        decodeStudyActivitySession(values);
        if (state.owner == null ||
            state.snapshot.lifecycle.status !=
                StudyActivityLifecycleStatus.active ||
            state.snapshot.revision != 1 ||
            state.snapshot.checkpointSequence != 0 ||
            state.nextSegmentSequence != 1 ||
            proposal.segments.isNotEmpty) {
          _fail(HomeTrainingFailure.invalidInput);
        }
        if ((await db.query(studyActivitySessionsTable,
                where: 'session_id=?', whereArgs: [state.snapshot.sessionId]))
            .isNotEmpty) {
          _fail(HomeTrainingFailure.conflict);
        }
        await db.insert(studyActivitySessionsTable, values);
        final actual = (await db.query(studyActivitySessionsTable,
                where: 'session_id=?', whereArgs: [state.snapshot.sessionId]))
            .single;
        if (!_equal(actual, values)) _fail(HomeTrainingFailure.unavailable);
        return state.snapshot;
      }, mutation: true);

  @override
  Future<HomeTrainingResult<StudyActivitySnapshot>> commitTransition(
          StudyActivityRuntimeState previous,
          StudyActivityTransition proposal) =>
      _read((db) async {
        final next = proposal.state;
        final oldRow = _session(previous);
        final nextRow = _session(next);
        decodeStudyActivitySession(oldRow);
        decodeStudyActivitySession(nextRow);
        if (previous.snapshot.lifecycle.isTerminal ||
            next.snapshot.lifecycle.status ==
                StudyActivityLifecycleStatus.interrupted ||
            next.snapshot.revision != previous.snapshot.revision + 1 ||
            next.snapshot.checkpointSequence !=
                previous.snapshot.checkpointSequence + 1 ||
            next.nextSegmentSequence !=
                previous.nextSegmentSequence + proposal.segments.length ||
            [
              'session_id',
              'scene',
              'started_at_utc_ms',
              'category_key',
              'content_id',
              'bank_name',
              'plan_id',
              'paper_id'
            ].any((key) => oldRow[key] != nextRow[key])) {
          _fail(HomeTrainingFailure.invalidInput);
        }
        final id = previous.snapshot.sessionId;
        for (var i = 0; i < proposal.segments.length; i++) {
          if (proposal.segments[i].sequence !=
              previous.nextSegmentSequence + i) {
            _fail(HomeTrainingFailure.invalidInput);
          }
        }
        final rows = await db.query(studyActivitySessionsTable,
            where: 'session_id=?', whereArgs: [id]);
        if (rows.isEmpty) _fail(HomeTrainingFailure.stale);
        final current = rows.single;
        final snapshot = decodeStudyActivitySession(current);
        final replay = _equal(current, nextRow);
        if (!replay &&
            (snapshot.lifecycle.isTerminal || !_equal(current, oldRow))) {
          _fail(HomeTrainingFailure.stale);
        }
        final existing = await db.query(studyActivitySegmentsTable,
            where: 'session_id=?', whereArgs: [id], orderBy: 'sequence');
        for (final row in existing) {
          decodeStudyActivitySegment(row);
        }
        final max = existing.isEmpty ? 0 : existing.last['sequence'] as int;
        if (max != (replay ? next : previous).nextSegmentSequence - 1) {
          _fail(HomeTrainingFailure.conflict);
        }
        for (final draft in proposal.segments) {
          final values = _segment(id, draft);
          decodeStudyActivitySegment(values);
          final matching = existing
              .where((row) => row['sequence'] == draft.sequence)
              .toList();
          if (matching.isNotEmpty) {
            if (!_equal(matching.single, values)) {
              _fail(HomeTrainingFailure.conflict);
            }
          } else {
            if (replay) _fail(HomeTrainingFailure.conflict);
            await db.insert(studyActivitySegmentsTable, values);
          }
        }
        if (replay) return snapshot;
        final changed = await db.update(studyActivitySessionsTable, nextRow,
            where: 'session_id=? AND revision=?',
            whereArgs: [id, previous.snapshot.revision]);
        if (changed != 1) _fail(HomeTrainingFailure.stale);
        final actual = (await db.query(studyActivitySessionsTable,
                where: 'session_id=?', whereArgs: [id]))
            .single;
        if (!_equal(actual, nextRow)) _fail(HomeTrainingFailure.unavailable);
        final committed = await db.query(studyActivitySegmentsTable,
            where: 'session_id=?', whereArgs: [id], orderBy: 'sequence');
        if (committed.length != existing.length + proposal.segments.length ||
            proposal.segments.any(
                (d) => !committed.any((r) => _equal(r, _segment(id, d))))) {
          _fail(HomeTrainingFailure.unavailable);
        }
        return next.snapshot;
      }, mutation: true);

  @override
  Future<HomeTrainingResult<int>> recoverInterruptedSessions() => _read(
      (db) => interruptStudyActivitySessions(
          db, StudyActivityEndReason.processInterrupted),
      mutation: true);

  @override
  Future<HomeTrainingResult<StudyActivityWeekSnapshot>> readWeek(
          String mondayLocalDate) =>
      _read((db) async {
        if (!isStudyActivityLocalDate(mondayLocalDate)) {
          _fail(HomeTrainingFailure.invalidInput);
        }
        final monday = DateTime.parse('${mondayLocalDate}T00:00:00Z');
        if (monday.weekday != DateTime.monday) {
          _fail(HomeTrainingFailure.invalidInput);
        }
        await validateStudyActivityV30Data(db);
        String date(int offset) =>
            DateTime.utc(monday.year, monday.month, monday.day + offset)
                .toIso8601String()
                .substring(0, 10);
        final totals = {
          for (final row in await db.rawQuery(
              '''SELECT local_date, SUM(duration_ms) AS duration
      FROM study_activity_segments WHERE local_date >= ? AND local_date <= ? GROUP BY local_date''',
              [mondayLocalDate, date(6)]))
            row['local_date'] as String: row['duration'] as int
        };
        return StudyActivityWeekSnapshot(
            mondayLocalDate: mondayLocalDate,
            days: [
              for (var i = 0; i < 7; i++)
                StudyActivityDaySummary(
                    localDate: date(i), durationMs: totals[date(i)] ?? 0)
            ],
            recordingQuality: StudyActivityRecordingQuality.recordedOnly);
      });
}

final class _ActivityFailure implements Exception {
  const _ActivityFailure(this.code);
  final HomeTrainingFailure code;
}
