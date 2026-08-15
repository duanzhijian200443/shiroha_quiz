library;

import 'sqflite_runtime.dart';

const int studyPlanSchemaVersion = 22;

const String studyPlansTableDdl = '''
CREATE TABLE study_plans (
  plan_id TEXT PRIMARY KEY NOT NULL
    CHECK(length(plan_id) BETWEEN 1 AND 128),

  singleton_key INTEGER NOT NULL DEFAULT 1 UNIQUE
    CHECK(singleton_key = 1),

  bank_name TEXT NOT NULL
    CHECK(bank_name = trim(bank_name))
    CHECK(length(bank_name) BETWEEN 1 AND 200),

  goal TEXT
    CHECK(
      goal IS NULL OR (
        goal = trim(goal)
        AND length(goal) BETWEEN 1 AND 120
      )
    ),

  daily_target INTEGER NOT NULL
    CHECK(daily_target BETWEEN 1 AND 200),

  priority TEXT NOT NULL
    CHECK(priority IN (
      'balanced',
      'due_first',
      'weak_first',
      'new_first'
    )),

  horizon_days INTEGER
    CHECK(
      horizon_days IS NULL
      OR horizon_days BETWEEN 1 AND 90
    ),

  source_conversation_id TEXT
    CHECK(
      source_conversation_id IS NULL
      OR length(source_conversation_id) BETWEEN 1 AND 128
    ),

  source_user_message_id TEXT
    CHECK(
      source_user_message_id IS NULL
      OR length(source_user_message_id) BETWEEN 1 AND 128
    ),

  adopted_at INTEGER NOT NULL
    CHECK(adopted_at >= 0)
);
''';

Future<void> createStudyPlanV22Schema(DatabaseExecutor db) async {
  await db.execute(studyPlansTableDdl.replaceFirst(
    'CREATE TABLE ',
    'CREATE TABLE IF NOT EXISTS ',
  ));
}

Future<void> validateStudyPlanV22Schema(DatabaseExecutor db) async {
  final rows = await db.rawQuery(
    "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name = 'study_plans'",
  );
  if (rows.isEmpty) {
    throw const StudyPlanSchemaException(
        StudyPlanSchemaFailure.malformedSchema);
  }
  final storedSql = rows.single['sql'] as String?;
  if (storedSql == null ||
      _canonicalizeSql(storedSql) != _canonicalizeSql(studyPlansTableDdl)) {
    throw const StudyPlanSchemaException(
        StudyPlanSchemaFailure.malformedSchema);
  }

  final columns = await db.rawQuery('PRAGMA table_info(study_plans)');
  const expectedColumns = <(String, String, int, int)>[
    ('plan_id', 'TEXT', 1, 1),
    ('singleton_key', 'INTEGER', 1, 0),
    ('bank_name', 'TEXT', 1, 0),
    ('goal', 'TEXT', 0, 0),
    ('daily_target', 'INTEGER', 1, 0),
    ('priority', 'TEXT', 1, 0),
    ('horizon_days', 'INTEGER', 0, 0),
    ('source_conversation_id', 'TEXT', 0, 0),
    ('source_user_message_id', 'TEXT', 0, 0),
    ('adopted_at', 'INTEGER', 1, 0),
  ];
  if (columns.length != expectedColumns.length) {
    throw const StudyPlanSchemaException(
        StudyPlanSchemaFailure.malformedSchema);
  }
  for (var i = 0; i < expectedColumns.length; i++) {
    final col = columns[i];
    final (name, affinity, notNull, pk) = expectedColumns[i];
    if (col['name'] != name ||
        _columnAffinity(col['type'] as String? ?? '') != affinity ||
        col['notnull'] != notNull ||
        col['pk'] != pk) {
      throw const StudyPlanSchemaException(
          StudyPlanSchemaFailure.malformedSchema);
    }
  }

  final foreignKeys = await db.rawQuery('PRAGMA foreign_key_list(study_plans)');
  if (foreignKeys.isNotEmpty) {
    throw const StudyPlanSchemaException(
        StudyPlanSchemaFailure.malformedSchema);
  }

  final foreignKeyIssues = await db.rawQuery('PRAGMA foreign_key_check');
  if (foreignKeyIssues.isNotEmpty) {
    throw const StudyPlanSchemaException(
        StudyPlanSchemaFailure.malformedSchema);
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

enum StudyPlanSchemaFailure { malformedSchema }

final class StudyPlanSchemaException implements Exception {
  const StudyPlanSchemaException(this.failure);

  final StudyPlanSchemaFailure failure;

  @override
  String toString() => 'StudyPlanSchemaException(${failure.name}): '
      'The study_plans table does not match the frozen v22 definition.';
}
