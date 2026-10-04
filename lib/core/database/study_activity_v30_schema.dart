import '../../application/study_activity/study_activity_contracts.dart';
import '../../domain/study_activity/study_activity_time.dart';
import '../../domain/study_activity/study_activity_values.dart';
import '../../domain/training/category_key.dart';
import 'sqflite_runtime.dart';

const studyActivitySchemaVersion = 30;
const studyActivitySessionsTable = 'study_activity_sessions';
const studyActivitySegmentsTable = 'study_activity_segments';
const studyActivitySessionsDdl = '''
CREATE TABLE study_activity_sessions (
  session_id TEXT PRIMARY KEY NOT NULL CHECK(length(trim(session_id)) > 0),
  scene TEXT NOT NULL CHECK(scene IN ('ordinaryPractice','categoryReview','studyPlanPractice','mockExam')),
  lifecycle_status TEXT NOT NULL CHECK(lifecycle_status IN ('active','paused','ended','interrupted')),
  started_at_utc_ms INTEGER NOT NULL CHECK(typeof(started_at_utc_ms) = 'integer' AND started_at_utc_ms >= 0),
  last_checkpoint_at_utc_ms INTEGER NOT NULL CHECK(typeof(last_checkpoint_at_utc_ms) = 'integer' AND last_checkpoint_at_utc_ms >= 0),
  ended_at_utc_ms INTEGER CHECK(ended_at_utc_ms IS NULL OR (typeof(ended_at_utc_ms) = 'integer' AND ended_at_utc_ms >= last_checkpoint_at_utc_ms)),
  end_reason TEXT,
  checkpoint_sequence INTEGER NOT NULL CHECK(typeof(checkpoint_sequence) = 'integer' AND checkpoint_sequence >= 0),
  revision INTEGER NOT NULL CHECK(typeof(revision) = 'integer' AND revision > 0),
  category_key TEXT,
  content_id TEXT,
  bank_name TEXT,
  plan_id TEXT,
  paper_id TEXT,
  CHECK((lifecycle_status IN ('active','paused') AND ended_at_utc_ms IS NULL AND end_reason IS NULL)
    OR (lifecycle_status = 'ended' AND ended_at_utc_ms IS NOT NULL AND end_reason IS NOT NULL AND end_reason IN ('exited','queueFinished','submitted'))
    OR (lifecycle_status = 'interrupted' AND ended_at_utc_ms IS NOT NULL AND end_reason IS NOT NULL AND end_reason IN ('processInterrupted','snapshotInterrupted')))
);
''';
const studyActivitySegmentsDdl = '''
CREATE TABLE study_activity_segments (
  segment_id TEXT PRIMARY KEY NOT NULL CHECK(length(trim(segment_id)) > 0),
  session_id TEXT NOT NULL,
  sequence INTEGER NOT NULL CHECK(typeof(sequence) = 'integer' AND sequence > 0),
  local_date TEXT NOT NULL,
  utc_offset_minutes INTEGER NOT NULL CHECK(typeof(utc_offset_minutes) = 'integer'),
  start_utc_ms INTEGER NOT NULL CHECK(typeof(start_utc_ms) = 'integer' AND start_utc_ms >= 0),
  end_utc_ms INTEGER NOT NULL CHECK(typeof(end_utc_ms) = 'integer' AND end_utc_ms >= start_utc_ms),
  duration_ms INTEGER NOT NULL CHECK(typeof(duration_ms) = 'integer' AND duration_ms >= 0),
  UNIQUE(session_id, sequence),
  FOREIGN KEY(session_id) REFERENCES study_activity_sessions(session_id) ON DELETE CASCADE
);
''';
const _objects = {
  studyActivitySessionsTable: studyActivitySessionsDdl,
  studyActivitySegmentsTable: studyActivitySegmentsDdl,
  'idx_study_activity_local_date':
      'CREATE INDEX idx_study_activity_local_date ON study_activity_segments(local_date);',
  'idx_study_activity_lifecycle':
      'CREATE INDEX idx_study_activity_lifecycle ON study_activity_sessions(lifecycle_status);',
};

final class StudyActivitySchemaException implements Exception {
  const StudyActivitySchemaException();
  @override
  String toString() => 'StudyActivitySchemaException(malformedState)';
}

Future<void> createStudyActivityV30Schema(DatabaseExecutor db) async {
  for (final ddl in _objects.values) {
    await db.execute(ddl
        .replaceFirst('CREATE TABLE ', 'CREATE TABLE IF NOT EXISTS ')
        .replaceFirst('CREATE INDEX ', 'CREATE INDEX IF NOT EXISTS '));
  }
}

Future<void> migrateStudyActivityToV30(DatabaseExecutor db) async {
  await createStudyActivityV30Schema(db);
  await validateStudyActivityV30Schema(db);
  for (final table in [
    studyActivitySessionsTable,
    studyActivitySegmentsTable
  ]) {
    if ((await db.query(table, limit: 1)).isNotEmpty) {
      throw const StudyActivitySchemaException();
    }
  }
}

String _sql(String value) => value
    .replaceAll(RegExp(r'\bIF\s+NOT\s+EXISTS\b'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'\s*([(),=])\s*'), r'$1')
    .replaceAll(RegExp(r';\s*$'), '')
    .trim();

/// Shared strict shape authority for open/migration and B0, with no repairs.
Future<void> validateStudyActivityV30Schema(DatabaseExecutor db) async {
  try {
    for (final object in _objects.entries) {
      final rows = await db.rawQuery(
          'SELECT sql FROM sqlite_master WHERE name = ?', [object.key]);
      if (rows.length != 1 ||
          _sql(rows.single['sql'] as String) != _sql(object.value)) {
        throw const StudyActivitySchemaException();
      }
    }
    for (final table in [
      studyActivitySessionsTable,
      studyActivitySegmentsTable
    ]) {
      if ((await db.rawQuery(
                  "SELECT 1 FROM sqlite_master WHERE type='trigger' AND tbl_name=?",
                  [
                table
              ]))
              .isNotEmpty ||
          (await db.rawQuery('PRAGMA index_list($table)'))
              .any((r) => r['origin'] == 'c' && r['unique'] == 1)) {
        throw const StudyActivitySchemaException();
      }
    }
    if ((await db.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
      throw const StudyActivitySchemaException();
    }
  } catch (_) {
    throw const StudyActivitySchemaException();
  }
}

/// Read-only Domain validation; clocks/current timezone never reinterpret facts.
StudyActivitySnapshot decodeStudyActivitySession(Map<String, Object?> row) {
  try {
    final scene = StudyActivityScene.values.byName(row['scene'] as String);
    if (scene == StudyActivityScene.singleQuestionStudy ||
        (row['started_at_utc_ms'] as int) < 0) {
      throw const StudyActivitySchemaException();
    }
    final category = row['category_key'];
    if (category != null) {
      const codec = CategoryKeyCodec();
      if (codec.encodeString(codec.decodeString(category as String)) !=
          category) {
        throw const StudyActivitySchemaException();
      }
    }
    for (final key in ['content_id', 'bank_name', 'plan_id', 'paper_id']) {
      if (row[key] != null && row[key] is! String) {
        throw const StudyActivitySchemaException();
      }
    }
    return StudyActivitySnapshot(
      sessionId: row['session_id'] as String,
      scene: scene,
      lifecycle: StudyActivityLifecycle(
          status: StudyActivityLifecycleStatus.values
              .byName(row['lifecycle_status'] as String),
          endedAtUtcMs: row['ended_at_utc_ms'] as int?,
          endReason: row['end_reason'] == null
              ? null
              : StudyActivityEndReason.values
                  .byName(row['end_reason'] as String)),
      lastCheckpointAtUtcMs: row['last_checkpoint_at_utc_ms'] as int,
      checkpointSequence: row['checkpoint_sequence'] as int,
      revision: row['revision'] as int,
      recordingQuality: StudyActivityRecordingQuality.recordedOnly,
    );
  } catch (_) {
    throw const StudyActivitySchemaException();
  }
}

StudyActivitySegmentDraft decodeStudyActivitySegment(Map<String, Object?> row) {
  try {
    if ((row['segment_id'] as String).trim().isEmpty) {
      throw const StudyActivitySchemaException();
    }
    return StudyActivitySegmentDraft(
        sequence: row['sequence'] as int,
        localDate: row['local_date'] as String,
        utcOffsetMinutes: row['utc_offset_minutes'] as int,
        startUtcMs: row['start_utc_ms'] as int,
        endUtcMs: row['end_utc_ms'] as int,
        durationMs: row['duration_ms'] as int);
  } catch (_) {
    throw const StudyActivitySchemaException();
  }
}

Future<void> validateStudyActivityV30Data(DatabaseExecutor db) async {
  try {
    final sessions = <String>{};
    for (final row in await db.query(studyActivitySessionsTable)) {
      final session = decodeStudyActivitySession(row);
      if (!sessions.add(session.sessionId)) {
        throw const StudyActivitySchemaException();
      }
    }
    final sequences = <(String, int)>{};
    for (final row in await db.query(studyActivitySegmentsTable)) {
      final segment = decodeStudyActivitySegment(row);
      final session = row['session_id'] as String;
      if (!sessions.contains(session) ||
          !sequences.add((session, segment.sequence))) {
        throw const StudyActivitySchemaException();
      }
    }
  } catch (_) {
    throw const StudyActivitySchemaException();
  }
}

/// Caller-owned transaction/copy only. No elapsed, owner or queue is recovered.
Future<int> interruptStudyActivitySessions(
    DatabaseExecutor db, StudyActivityEndReason reason) async {
  if (reason != StudyActivityEndReason.processInterrupted &&
      reason != StudyActivityEndReason.snapshotInterrupted) {
    throw const StudyActivitySchemaException();
  }
  await validateStudyActivityV30Data(db);
  return db.rawUpdate('''UPDATE study_activity_sessions
      SET lifecycle_status='interrupted', end_reason=?,
          ended_at_utc_ms=last_checkpoint_at_utc_ms, revision=revision+1
      WHERE lifecycle_status IN ('active','paused')''', [reason.name]);
}
