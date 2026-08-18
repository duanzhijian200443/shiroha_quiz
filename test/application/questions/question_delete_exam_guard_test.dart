import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/questions/question_mutation_command.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/exam_repository.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _questionId = 'question-delete-guard';

Future<Database> _database() => DatabaseHelper.instance.database;

Future<void> _seedQuestionWithReviewData(Database db) async {
  await db.insert('questions', <String, Object?>{
    'id': _questionId,
    'type': 0,
    'content': 'Question delete guard',
    'options': '["A. option"]',
    'standard_answer': 'A',
    'explanation': 'Explanation',
    'raw_explanation': 'Raw explanation',
    'created_at': 1700000000,
    'bank_name': 'Delete guard bank',
  });
  await db.insert('question_v2_payloads', <String, Object?>{
    'question_id': _questionId,
    'payload_schema_version': 2,
    'payload_json': '{"schemaVersion":2}',
  });
  await db.insert('review_states', <String, Object?>{
    'question_id': _questionId,
    'state': 0,
    'next_review_time': 1700000000,
    'lapses': 1,
    'difficulty': 5.0,
    'stability': 0.0,
    'reps': 1,
    'last_lapse_time': 1700000000,
    'last_review_time': 1700000000,
  });
  await db.insert('review_logs', <String, Object?>{
    'id': 'review-log-delete-guard',
    'question_id': _questionId,
    'grade': 1,
    'review_time': 1700000000,
    'duration_ms': 1000,
    'user_answer': 'A',
    'ai_evaluation': null,
  });
  await db.insert('answer_attempts', <String, Object?>{
    'attempt_id': 'answer-attempt-delete-guard',
    'question_id': _questionId,
    'session_kind': 'normal',
    'modality': 'choice',
    'answer_payload_json': '{"version":1,"kind":"choice","option_ids":["A"]}',
    'correctness': 0,
    'answered_at': 1700000000,
    'duration_ms': 1000,
  });
}

Future<void> _deleteQuestion() {
  return QuestionMutationCommand(QuestionRepository()).deleteQuestion(
    _questionId,
  );
}

Future<void> _expectQuestionAndHistoryToRemain(Database db) async {
  expect(await db.query('questions'), hasLength(1));
  expect(await db.query('question_v2_payloads'), hasLength(1));
  expect(await db.query('review_states'), hasLength(1));
  expect(await db.query('review_logs'), hasLength(1));
  expect(await db.query('answer_attempts'), hasLength(1));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    BackupRestoreMutationGate.resetForTesting();
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  tearDown(() async {
    BackupRestoreMutationGate.resetForTesting();
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  test('deletes an unreferenced question and preserves AnswerAttempt',
      () async {
    final db = await _database();
    await _seedQuestionWithReviewData(db);
    await ExamRepository().getAllExamPapers();

    expect(await db.query('questions_fts'), hasLength(1));
    await _deleteQuestion();

    expect(await db.query('questions'), isEmpty);
    expect(await db.query('question_v2_payloads'), isEmpty);
    expect(await db.query('review_states'), isEmpty);
    expect(await db.query('review_logs'), isEmpty);
    expect(await db.query('questions_fts'), isEmpty);
    expect(await db.query('answer_attempts'), hasLength(1));
  });

  test('deletes a legacy question when exam tables are absent', () async {
    final db = await _database();
    await _seedQuestionWithReviewData(db);

    expect(
      await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE name = 'paper_questions'",
      ),
      isEmpty,
    );
    await _deleteQuestion();

    expect(await db.query('questions'), isEmpty);
    expect(await db.query('question_v2_payloads'), isEmpty);
    expect(await db.query('review_states'), isEmpty);
    expect(await db.query('review_logs'), isEmpty);
    expect(await db.query('answer_attempts'), hasLength(1));
  });

  test('blocks deletion when an exam references the question', () async {
    final db = await _database();
    await _seedQuestionWithReviewData(db);
    await ExamRepository().createExamPaper(
      'Delete guard exam',
      0,
      <Map<String, dynamic>>[
        <String, dynamic>{'id': _questionId},
      ],
    );

    await expectLater(
      _deleteQuestion(),
      throwsA(
        isA<QuestionDeleteException>().having(
          (error) => error.failure,
          'failure',
          QuestionDeleteFailure.examReferenced,
        ),
      ),
    );

    await _expectQuestionAndHistoryToRemain(db);
    expect(await db.query('questions_fts'), hasLength(1));
    expect(await db.query('paper_questions'), hasLength(1));
  });

  test('fails closed when the exam reference check cannot query its table',
      () async {
    final db = await _database();
    await _seedQuestionWithReviewData(db);
    await db.execute('''
      CREATE TABLE paper_questions (
        paper_id TEXT NOT NULL
      )
    ''');

    await expectLater(
      _deleteQuestion(),
      throwsA(
        isA<QuestionDeleteException>().having(
          (error) => error.failure,
          'failure',
          QuestionDeleteFailure.unavailable,
        ),
      ),
    );

    await _expectQuestionAndHistoryToRemain(db);
  });

  test('maps a delete transaction failure to a fixed typed failure', () async {
    final db = await _database();
    await _seedQuestionWithReviewData(db);
    await db.execute('''
      CREATE TRIGGER d1b_block_review_log_delete
      BEFORE DELETE ON review_logs
      BEGIN
        SELECT RAISE(ABORT, 'd1b_synthetic_delete_failure');
      END;
    ''');

    await expectLater(
      _deleteQuestion(),
      throwsA(
        isA<QuestionDeleteException>().having(
          (error) => error.failure,
          'failure',
          QuestionDeleteFailure.transactionFailed,
        ),
      ),
    );

    await _expectQuestionAndHistoryToRemain(db);
  });
}
