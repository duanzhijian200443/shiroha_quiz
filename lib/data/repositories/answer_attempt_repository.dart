import 'package:sqflite/sqflite.dart';

import '../../application/practice/record_answer_attempt_command.dart';
import '../../core/database/database_helper.dart';
import '../../domain/attempt/answer_attempt.dart';

/// Concrete SQLite repository for [AnswerAttempt] facts.
///
/// Implements [AnswerAttemptPersistencePort] for the Application layer.
/// All writes are append-only.
final class AnswerAttemptRepository implements AnswerAttemptPersistencePort {
  AnswerAttemptRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  static final AnswerAttemptRepository instance = AnswerAttemptRepository();

  final DatabaseHelper _databaseHelper;

  Future<Database> get _db => _databaseHelper.database;

  @override
  Future<void> recordAttempt(AnswerAttempt attempt) async {
    AnswerAttemptPayload.validateForModality(
      attempt.modality,
      attempt.answerPayloadJson,
    );
    final db = await _db;
    await db.insert(
      'answer_attempts',
      attempt.toMap(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  /// Returns all attempts for a given [questionId] ordered by `answered_at ASC`.
  Future<List<AnswerAttempt>> getAttemptsForQuestion(String questionId) async {
    final db = await _db;
    final rows = await db.query(
      'answer_attempts',
      where: 'question_id = ?',
      whereArgs: <Object?>[questionId],
      orderBy: 'answered_at ASC',
    );
    return rows.map(AnswerAttempt.fromMap).toList(growable: false);
  }

  /// Counts distinct questions that have at least one incorrect attempt (`correctness = 0`).
  Future<int> countIncorrectQuestions() async {
    final db = await _db;
    final rows = await db.rawQuery(
      'SELECT COUNT(DISTINCT question_id) AS count FROM answer_attempts WHERE correctness = 0',
    );
    return (rows.first['count'] as num?)?.toInt() ?? 0;
  }

  /// Clears all answer attempt data. Used exclusively by [clearAllData].
  Future<void> clearAllData() async {
    final db = await _db;
    await db.delete('answer_attempts');
  }
}
