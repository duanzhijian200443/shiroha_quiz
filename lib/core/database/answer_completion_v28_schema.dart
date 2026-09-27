/// Additive v28 durable schema for Answer Completion question sets.
///
/// This module owns only the database-side shape and relationship
/// invariants of `ImportedQuestionSet` / ordered membership. It never writes
/// learning data, never backfills historical questions, and is not a second
/// Question deletion authority: membership lifecycle runs on SQLite relation
/// semantics plus the schema-owned triggers below.
library;

import 'sqflite_runtime.dart';

const int answerCompletionSchemaVersion = 28;

const String importedQuestionSetsTable = 'imported_question_sets';
const String importedQuestionSetItemsTable = 'imported_question_set_items';
const String importedQuestionSetBankIndex =
    'idx_imported_question_sets_bank_name';

/// Fixed trigger failure strings. They never include ids, banks, or paths.
const String answerCompletionCrossBankMembershipFailure =
    'answer_completion_cross_bank_membership';
const String answerCompletionSetBankImmutableFailure =
    'answer_completion_set_bank_immutable';

const String answerCompletionMemberInsertBankTrigger =
    'trg_answer_completion_member_insert_bank';
const String answerCompletionMemberUpdateBankTrigger =
    'trg_answer_completion_member_update_bank';
const String answerCompletionQuestionBankDetachTrigger =
    'trg_answer_completion_question_bank_detach';
const String answerCompletionMemberDeleteCleanupTrigger =
    'trg_answer_completion_member_delete_cleanup';
const String answerCompletionMemberMoveCleanupTrigger =
    'trg_answer_completion_member_move_cleanup';
const String answerCompletionSetBankImmutableTrigger =
    'trg_answer_completion_set_bank_immutable';

/// `source_file_id` stays a soft provenance column: no foreign key, no
/// uniqueness, no lifecycle ownership.
const String importedQuestionSetsTableDdl = '''
CREATE TABLE imported_question_sets (
  set_id TEXT PRIMARY KEY NOT NULL,
  bank_name TEXT NOT NULL,
  display_name TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  source_file_id TEXT
);
''';

const String importedQuestionSetItemsTableDdl = '''
CREATE TABLE imported_question_set_items (
  set_id TEXT NOT NULL,
  question_storage_id TEXT NOT NULL,
  position INTEGER NOT NULL CHECK(position >= 0),
  PRIMARY KEY(set_id, question_storage_id),
  UNIQUE(question_storage_id),
  UNIQUE(set_id, position),
  FOREIGN KEY(set_id)
    REFERENCES imported_question_sets(set_id)
    ON DELETE CASCADE,
  FOREIGN KEY(question_storage_id)
    REFERENCES questions(id)
    ON DELETE CASCADE
);
''';

const String importedQuestionSetBankIndexDdl = '''
CREATE INDEX idx_imported_question_sets_bank_name
ON imported_question_sets(bank_name);
''';

/// Rejects a membership whose set and question exist with different banks.
///
/// Missing set or question rows stay classified by their foreign keys; the
/// trigger only fires when both rows exist and the banks are observed to
/// differ, and a question without a bank can never satisfy a set's bank.
const String answerCompletionMemberInsertBankTriggerDdl = '''
CREATE TRIGGER trg_answer_completion_member_insert_bank
AFTER INSERT ON imported_question_set_items
WHEN EXISTS (
  SELECT 1 FROM imported_question_sets s WHERE s.set_id = NEW.set_id
) AND EXISTS (
  SELECT 1 FROM questions q WHERE q.id = NEW.question_storage_id
) AND (
  SELECT s.bank_name FROM imported_question_sets s WHERE s.set_id = NEW.set_id
) IS NOT (
  SELECT q.bank_name FROM questions q WHERE q.id = NEW.question_storage_id
)
BEGIN
  SELECT RAISE(ABORT, 'answer_completion_cross_bank_membership');
END;
''';

/// Update-path counterpart of the INSERT guard so a rewritten relation can
/// never bypass the insert-time cross-bank rejection.
const String answerCompletionMemberUpdateBankTriggerDdl = '''
CREATE TRIGGER trg_answer_completion_member_update_bank
AFTER UPDATE OF set_id, question_storage_id ON imported_question_set_items
WHEN EXISTS (
  SELECT 1 FROM imported_question_sets s WHERE s.set_id = NEW.set_id
) AND EXISTS (
  SELECT 1 FROM questions q WHERE q.id = NEW.question_storage_id
) AND (
  SELECT s.bank_name FROM imported_question_sets s WHERE s.set_id = NEW.set_id
) IS NOT (
  SELECT q.bank_name FROM questions q WHERE q.id = NEW.question_storage_id
)
BEGIN
  SELECT RAISE(ABORT, 'answer_completion_cross_bank_membership');
END;
''';

/// A question leaving its bank leaves its set; it is never re-attached and no
/// destination set is guessed.
const String answerCompletionQuestionBankDetachTriggerDdl = '''
CREATE TRIGGER trg_answer_completion_question_bank_detach
AFTER UPDATE OF bank_name ON questions
WHEN OLD.bank_name IS NOT NEW.bank_name
BEGIN
  DELETE FROM imported_question_set_items
  WHERE question_storage_id = NEW.id;
END;
''';

/// The last membership removal clears its now-empty set in the same
/// statement, including removals caused by foreign-key cascades.
const String answerCompletionMemberDeleteCleanupTriggerDdl = '''
CREATE TRIGGER trg_answer_completion_member_delete_cleanup
AFTER DELETE ON imported_question_set_items
WHEN NOT EXISTS (
  SELECT 1 FROM imported_question_set_items WHERE set_id = OLD.set_id
)
BEGIN
  DELETE FROM imported_question_sets WHERE set_id = OLD.set_id;
END;
''';

/// A membership moved to another set clears its former set, so an UPDATE can
/// never strand a durable empty set.
const String answerCompletionMemberMoveCleanupTriggerDdl = '''
CREATE TRIGGER trg_answer_completion_member_move_cleanup
AFTER UPDATE OF set_id ON imported_question_set_items
WHEN OLD.set_id IS NOT NEW.set_id AND NOT EXISTS (
  SELECT 1 FROM imported_question_set_items WHERE set_id = OLD.set_id
)
BEGIN
  DELETE FROM imported_question_sets WHERE set_id = OLD.set_id;
END;
''';

/// `bank_name` is immutable once a set exists; a same-value update stays legal.
const String answerCompletionSetBankImmutableTriggerDdl = '''
CREATE TRIGGER trg_answer_completion_set_bank_immutable
BEFORE UPDATE OF bank_name ON imported_question_sets
WHEN OLD.bank_name IS NOT NEW.bank_name
BEGIN
  SELECT RAISE(ABORT, 'answer_completion_set_bank_immutable');
END;
''';

/// Creates the v28 objects idempotently.
///
/// A pre-existing object is accepted only when the strict validator below
/// confirms its exact expected shape.
Future<void> createAnswerCompletionV28Schema(DatabaseExecutor db) async {
  await db.execute(_createIfNotExists(importedQuestionSetsTableDdl));
  await db.execute(_createIfNotExists(importedQuestionSetItemsTableDdl));
  await db.execute(_createIfNotExists(importedQuestionSetBankIndexDdl));
  for (final ddl in <String>[
    answerCompletionMemberInsertBankTriggerDdl,
    answerCompletionMemberUpdateBankTriggerDdl,
    answerCompletionQuestionBankDetachTriggerDdl,
    answerCompletionMemberDeleteCleanupTriggerDdl,
    answerCompletionMemberMoveCleanupTriggerDdl,
    answerCompletionSetBankImmutableTriggerDdl,
  ]) {
    await db.execute(_createIfNotExists(ddl));
  }
}

/// Additive v27 -> v28 step running inside the caller's open transaction.
///
/// Historical questions stay ungrouped: this migration never scans, derives,
/// or backfills sets, and it never rewrites existing rows.
Future<void> migrateAnswerCompletionToV28(DatabaseExecutor db) async {
  await createAnswerCompletionV28Schema(db);
  await validateAnswerCompletionV28Schema(db);
}

/// Validates the exact v28 shape: tables, columns, constraints, foreign key
/// actions, bank lookup index, and every required trigger.
Future<void> validateAnswerCompletionV28Schema(DatabaseExecutor db) async {
  await _requireExactTable(
    db,
    table: importedQuestionSetsTable,
    expectedDdl: importedQuestionSetsTableDdl,
    expectedColumns: const <(String, String, int, int)>[
      ('set_id', 'TEXT', 1, 1),
      ('bank_name', 'TEXT', 1, 0),
      ('display_name', 'TEXT', 1, 0),
      ('created_at', 'INTEGER', 1, 0),
      ('source_file_id', 'TEXT', 0, 0),
    ],
  );
  await _requireExactTable(
    db,
    table: importedQuestionSetItemsTable,
    expectedDdl: importedQuestionSetItemsTableDdl,
    expectedColumns: const <(String, String, int, int)>[
      ('set_id', 'TEXT', 1, 1),
      ('question_storage_id', 'TEXT', 1, 2),
      ('position', 'INTEGER', 1, 0),
    ],
  );
  await _requireBankIndex(db);
  await _requireItemKeyShapes(db);
  await _requireItemForeignKeys(db);
  final setsForeignKeys = await db.rawQuery(
    'PRAGMA foreign_key_list($importedQuestionSetsTable)',
  );
  if (setsForeignKeys.isNotEmpty) {
    throw const AnswerCompletionSchemaException(
      AnswerCompletionSchemaFailure.malformedSchema,
    );
  }
  for (final trigger in _requiredTriggers) {
    await _requireExactTrigger(
      db,
      name: trigger.$1,
      targetTable: trigger.$2,
      expectedDdl: trigger.$3,
    );
  }
  final foreignKeyIssues = await db.rawQuery('PRAGMA foreign_key_check');
  if (foreignKeyIssues.isNotEmpty) {
    throw const AnswerCompletionSchemaException(
      AnswerCompletionSchemaFailure.malformedSchema,
    );
  }
}

const List<(String, String, String)> _requiredTriggers =
    <(String, String, String)>[
  (
    answerCompletionMemberInsertBankTrigger,
    importedQuestionSetItemsTable,
    answerCompletionMemberInsertBankTriggerDdl,
  ),
  (
    answerCompletionMemberUpdateBankTrigger,
    importedQuestionSetItemsTable,
    answerCompletionMemberUpdateBankTriggerDdl,
  ),
  (
    answerCompletionQuestionBankDetachTrigger,
    'questions',
    answerCompletionQuestionBankDetachTriggerDdl,
  ),
  (
    answerCompletionMemberDeleteCleanupTrigger,
    importedQuestionSetItemsTable,
    answerCompletionMemberDeleteCleanupTriggerDdl,
  ),
  (
    answerCompletionMemberMoveCleanupTrigger,
    importedQuestionSetItemsTable,
    answerCompletionMemberMoveCleanupTriggerDdl,
  ),
  (
    answerCompletionSetBankImmutableTrigger,
    importedQuestionSetsTable,
    answerCompletionSetBankImmutableTriggerDdl,
  ),
];

String _createIfNotExists(String ddl) {
  if (ddl.startsWith('CREATE TABLE ')) {
    return ddl.replaceFirst('CREATE TABLE ', 'CREATE TABLE IF NOT EXISTS ');
  }
  if (ddl.startsWith('CREATE INDEX ')) {
    return ddl.replaceFirst('CREATE INDEX ', 'CREATE INDEX IF NOT EXISTS ');
  }
  if (ddl.startsWith('CREATE TRIGGER ')) {
    return ddl.replaceFirst('CREATE TRIGGER ', 'CREATE TRIGGER IF NOT EXISTS ');
  }
  throw const AnswerCompletionSchemaException(
    AnswerCompletionSchemaFailure.malformedSchema,
  );
}

Future<void> _requireExactTable(
  DatabaseExecutor db, {
  required String table,
  required String expectedDdl,
  required List<(String, String, int, int)> expectedColumns,
}) async {
  final rows = await db.rawQuery(
    "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
    <Object?>[table],
  );
  final storedSql = rows.length == 1 ? rows.single['sql'] as String? : null;
  if (storedSql == null ||
      _canonicalizeSql(storedSql) != _canonicalizeSql(expectedDdl)) {
    throw const AnswerCompletionSchemaException(
      AnswerCompletionSchemaFailure.malformedSchema,
    );
  }
  final columns = await db.rawQuery('PRAGMA table_info($table)');
  if (columns.length != expectedColumns.length) {
    throw const AnswerCompletionSchemaException(
      AnswerCompletionSchemaFailure.malformedSchema,
    );
  }
  for (var index = 0; index < expectedColumns.length; index++) {
    final column = columns[index];
    final (name, affinity, notNull, primaryKey) = expectedColumns[index];
    if (column['name'] != name ||
        _columnAffinity(column['type'] as String? ?? '') != affinity ||
        column['notnull'] != notNull ||
        column['pk'] != primaryKey) {
      throw const AnswerCompletionSchemaException(
        AnswerCompletionSchemaFailure.malformedSchema,
      );
    }
  }
}

Future<void> _requireBankIndex(DatabaseExecutor db) async {
  final rows = await db.rawQuery(
    "SELECT tbl_name, sql FROM sqlite_master WHERE type = 'index' AND name = ?",
    <Object?>[importedQuestionSetBankIndex],
  );
  if (rows.length != 1 ||
      rows.single['tbl_name'] != importedQuestionSetsTable ||
      _canonicalizeSql(rows.single['sql'] as String? ?? '') !=
          _canonicalizeSql(importedQuestionSetBankIndexDdl)) {
    throw const AnswerCompletionSchemaException(
      AnswerCompletionSchemaFailure.malformedSchema,
    );
  }
  final indexed = await db.rawQuery(
    'PRAGMA index_info($importedQuestionSetBankIndex)',
  );
  if (indexed.length != 1 || indexed.single['name'] != 'bank_name') {
    throw const AnswerCompletionSchemaException(
      AnswerCompletionSchemaFailure.malformedSchema,
    );
  }
}

/// Requires exactly `PRIMARY KEY(set_id, question_storage_id)`,
/// `UNIQUE(question_storage_id)`, and `UNIQUE(set_id, position)`.
Future<void> _requireItemKeyShapes(DatabaseExecutor db) async {
  final uniqueShapes = <String>[];
  final primaryKeyShapes = <String>[];
  final indexes = await db.rawQuery(
    'PRAGMA index_list($importedQuestionSetItemsTable)',
  );
  for (final index in indexes) {
    final name = index['name'] as String? ?? '';
    final indexed = await db.rawQuery('PRAGMA index_info($name)');
    final shape = indexed.map((row) => row['name'] as String? ?? '').join(',');
    switch (index['origin']) {
      case 'u':
        if (index['unique'] != 1) {
          throw const AnswerCompletionSchemaException(
            AnswerCompletionSchemaFailure.malformedSchema,
          );
        }
        uniqueShapes.add(shape);
      case 'pk':
        primaryKeyShapes.add(shape);
      case 'c':
        // A named index adds no key semantics; the frozen shapes are checked
        // through the unique and primary-key entries above.
        break;
      default:
        throw const AnswerCompletionSchemaException(
          AnswerCompletionSchemaFailure.malformedSchema,
        );
    }
  }
  uniqueShapes.sort();
  if (!_sameShapes(uniqueShapes, <String>[
    'question_storage_id',
    'set_id,position',
  ])) {
    throw const AnswerCompletionSchemaException(
      AnswerCompletionSchemaFailure.malformedSchema,
    );
  }
  if (!_sameShapes(primaryKeyShapes, <String>['set_id,question_storage_id'])) {
    throw const AnswerCompletionSchemaException(
      AnswerCompletionSchemaFailure.malformedSchema,
    );
  }
}

bool _sameShapes(List<String> actual, List<String> expected) {
  if (actual.length != expected.length) return false;
  final expectedSorted = <String>[...expected]..sort();
  for (var index = 0; index < actual.length; index++) {
    if (actual[index] != expectedSorted[index]) return false;
  }
  return true;
}

Future<void> _requireItemForeignKeys(DatabaseExecutor db) async {
  final rows = await db.rawQuery(
    'PRAGMA foreign_key_list($importedQuestionSetItemsTable)',
  );
  final shapes = rows
      .map((row) => '${row['from']}->${row['table']}.${row['to']}'
          ':${row['on_update']}:${row['on_delete']}')
      .toList()
    ..sort();
  final expected = <String>[
    'question_storage_id->questions.id:NO ACTION:CASCADE',
    'set_id->imported_question_sets.set_id:NO ACTION:CASCADE',
  ]..sort();
  if (!_sameShapes(shapes, expected)) {
    throw const AnswerCompletionSchemaException(
      AnswerCompletionSchemaFailure.malformedSchema,
    );
  }
}

Future<void> _requireExactTrigger(
  DatabaseExecutor db, {
  required String name,
  required String targetTable,
  required String expectedDdl,
}) async {
  final rows = await db.rawQuery(
    "SELECT tbl_name, sql FROM sqlite_master WHERE type = 'trigger' AND name = ?",
    <Object?>[name],
  );
  if (rows.length != 1 ||
      rows.single['tbl_name'] != targetTable ||
      _canonicalizeSql(rows.single['sql'] as String? ?? '') !=
          _canonicalizeSql(expectedDdl)) {
    throw const AnswerCompletionSchemaException(
      AnswerCompletionSchemaFailure.malformedSchema,
    );
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

enum AnswerCompletionSchemaFailure { malformedSchema }

/// Fixed safe failure. It never carries ids, banks, display names, source
/// file references, rows, paths, or raw exceptions.
final class AnswerCompletionSchemaException implements Exception {
  const AnswerCompletionSchemaException(this.failure);

  final AnswerCompletionSchemaFailure failure;

  @override
  String toString() => 'AnswerCompletionSchemaException(${failure.name})';
}
