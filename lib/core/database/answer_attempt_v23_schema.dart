library;

import 'sqflite_runtime.dart';

const int answerAttemptSchemaVersion = 23;

const String answerAttemptsTableDdl = '''
CREATE TABLE answer_attempts (
  attempt_id TEXT PRIMARY KEY NOT NULL,

  question_id TEXT NOT NULL,

  session_kind TEXT NOT NULL
    CHECK(session_kind IN (
      'normal',
      'focused',
      'exam'
    )),

  modality TEXT NOT NULL
    CHECK(modality IN (
      'choice',
      'text'
    )),

  answer_payload_json TEXT NOT NULL
    CHECK(length(answer_payload_json) > 0),

  correctness INTEGER
    CHECK(correctness IS NULL OR correctness IN (0, 1)),

  answered_at INTEGER NOT NULL
    CHECK(answered_at >= 0),

  duration_ms INTEGER
    CHECK(duration_ms IS NULL OR duration_ms >= 0)
);
''';

const String answerAttemptsQuestionAnsweredIndexDdl = '''
CREATE INDEX idx_answer_attempts_question_answered ON answer_attempts(question_id, answered_at);
''';

const String answerAttemptsCorrectnessAnsweredIndexDdl = '''
CREATE INDEX idx_answer_attempts_correctness_answered ON answer_attempts(correctness, answered_at);
''';

Future<void> createAnswerAttemptV23Schema(DatabaseExecutor db) async {
  await db.execute(answerAttemptsTableDdl.replaceFirst(
    'CREATE TABLE ',
    'CREATE TABLE IF NOT EXISTS ',
  ));
  await db.execute(answerAttemptsQuestionAnsweredIndexDdl.replaceFirst(
    'CREATE INDEX ',
    'CREATE INDEX IF NOT EXISTS ',
  ));
  await db.execute(answerAttemptsCorrectnessAnsweredIndexDdl.replaceFirst(
    'CREATE INDEX ',
    'CREATE INDEX IF NOT EXISTS ',
  ));
}

Future<void> validateAnswerAttemptV23Schema(DatabaseExecutor db) async {
  final rows = await db.rawQuery(
    "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name = 'answer_attempts'",
  );
  if (rows.isEmpty) {
    throw const AnswerAttemptSchemaException(
        AnswerAttemptSchemaFailure.malformedSchema);
  }
  final storedSql = rows.single['sql'] as String?;
  if (storedSql == null ||
      _canonicalizeSql(storedSql) != _canonicalizeSql(answerAttemptsTableDdl)) {
    throw const AnswerAttemptSchemaException(
        AnswerAttemptSchemaFailure.malformedSchema);
  }

  final columns = await db.rawQuery('PRAGMA table_info(answer_attempts)');
  const expectedColumns = <(String, String, int, int)>[
    ('attempt_id', 'TEXT', 1, 1),
    ('question_id', 'TEXT', 1, 0),
    ('session_kind', 'TEXT', 1, 0),
    ('modality', 'TEXT', 1, 0),
    ('answer_payload_json', 'TEXT', 1, 0),
    ('correctness', 'INTEGER', 0, 0),
    ('answered_at', 'INTEGER', 1, 0),
    ('duration_ms', 'INTEGER', 0, 0),
  ];
  if (columns.length != expectedColumns.length) {
    throw const AnswerAttemptSchemaException(
        AnswerAttemptSchemaFailure.malformedSchema);
  }
  for (var i = 0; i < expectedColumns.length; i++) {
    final col = columns[i];
    final (name, affinity, notNull, pk) = expectedColumns[i];
    if (col['name'] != name ||
        _columnAffinity(col['type'] as String? ?? '') != affinity ||
        col['notnull'] != notNull ||
        col['pk'] != pk) {
      throw const AnswerAttemptSchemaException(
          AnswerAttemptSchemaFailure.malformedSchema);
    }
  }

  final foreignKeys =
      await db.rawQuery('PRAGMA foreign_key_list(answer_attempts)');
  if (foreignKeys.isNotEmpty) {
    throw const AnswerAttemptSchemaException(
        AnswerAttemptSchemaFailure.malformedSchema);
  }

  final foreignKeyIssues = await db.rawQuery('PRAGMA foreign_key_check');
  if (foreignKeyIssues.isNotEmpty) {
    throw const AnswerAttemptSchemaException(
        AnswerAttemptSchemaFailure.malformedSchema);
  }
}

String _canonicalizeSql(String sql) => sql
    .replaceAll(RegExp(r'\bIF\s+NOT\s+EXISTS\b', caseSensitive: false), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'\s*([(),=])\s*'), r'$1')
    .replaceAll(RegExp(r';\s*$'), '')
    .trim()
    .toLowerCase();

String _columnAffinity(String rawType) {
  final upper = rawType.toUpperCase();
  if (upper.contains('INT')) return 'INTEGER';
  if (upper.contains('CHAR') ||
      upper.contains('CLOB') ||
      upper.contains('TEXT')) {
    return 'TEXT';
  }
  if (upper.contains('BLOB') || upper.isEmpty) return 'BLOB';
  if (upper.contains('REAL') ||
      upper.contains('FLOA') ||
      upper.contains('DOUB')) {
    return 'REAL';
  }
  return 'NUMERIC';
}

enum AnswerAttemptSchemaFailure { malformedSchema }

final class AnswerAttemptSchemaException implements Exception {
  const AnswerAttemptSchemaException(this.failure);

  final AnswerAttemptSchemaFailure failure;

  @override
  String toString() => 'AnswerAttemptSchemaException(${failure.name}): '
      'The answer_attempts table does not match the frozen v23 definition.';
}
