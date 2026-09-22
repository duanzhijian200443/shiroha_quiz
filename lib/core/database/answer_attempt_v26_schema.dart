import 'answer_attempt_v23_schema.dart';
import 'sqflite_runtime.dart';

const int photoAnswerSchemaVersion = 26;

final String answerAttemptsV26TableDdl =
    answerAttemptsTableDdl.replaceFirst("'text'", "'text',\n      'image'");

Future<void> createAnswerAttemptV26Schema(DatabaseExecutor db) async {
  await db.execute(answerAttemptsV26TableDdl);
  await db.execute(answerAttemptsQuestionAnsweredIndexDdl);
  await db.execute(answerAttemptsCorrectnessAnsweredIndexDdl);
}

Future<void> validateAnswerAttemptV26Schema(DatabaseExecutor db) =>
    validateAnswerAttemptSchema(db,
        expectedTableDdl: answerAttemptsV26TableDdl);

/// Runs inside the caller's SQLite upgrade transaction. Any failure rolls
/// back the table rebuild, old rows, indexes, and user_version together.
Future<void> migrateAnswerAttemptsToV26(DatabaseExecutor db) async {
  // Tests and staged restores may reset user_version on a current schema.
  final table = await db.rawQuery(
    "SELECT sql FROM sqlite_master WHERE type='table' AND name='answer_attempts'",
  );
  if (table.isNotEmpty && (table.single['sql'] as String).contains("'image'")) {
    await validateAnswerAttemptV26Schema(db);
    return;
  }
  await validateAnswerAttemptV23Schema(db);
  await db.execute(answerAttemptsV26TableDdl.replaceFirst(
    'CREATE TABLE answer_attempts',
    'CREATE TABLE answer_attempts_v26',
  ));
  await db
      .execute('INSERT INTO answer_attempts_v26 SELECT * FROM answer_attempts');
  // Compare every column in both directions before removing the old table.
  for (final pair in [
    ('answer_attempts', 'answer_attempts_v26'),
    ('answer_attempts_v26', 'answer_attempts'),
  ]) {
    final difference = await db.rawQuery(
      'SELECT * FROM ${pair.$1} EXCEPT SELECT * FROM ${pair.$2} LIMIT 1',
    );
    if (difference.isNotEmpty) {
      throw const AnswerAttemptSchemaException(
          AnswerAttemptSchemaFailure.malformedSchema);
    }
  }
  await db.execute('DROP TABLE answer_attempts');
  await db.execute('ALTER TABLE answer_attempts_v26 RENAME TO answer_attempts');
  await db.execute(answerAttemptsQuestionAnsweredIndexDdl);
  await db.execute(answerAttemptsCorrectnessAnsweredIndexDdl);
  await validateAnswerAttemptV26Schema(db);
}
