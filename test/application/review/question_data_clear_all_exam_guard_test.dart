import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/review/question_data_clear_all.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/review_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _seedQuestionData(dynamic db, String questionId) async {
  await db.insert('questions', <String, Object?>{
    'id': questionId,
    'type': 0,
    'content': 'Synthetic question $questionId',
    'options': null,
    'standard_answer': 'A',
    'explanation': null,
    'raw_explanation': null,
    'created_at': 1700000000,
    'bank_name': 'Synthetic clear-all bank',
  });
  await db.insert('question_v2_payloads', <String, Object?>{
    'question_id': questionId,
    'payload_schema_version': 2,
    'payload_json': '{"kind":"synthetic","version":2}',
  });
  await db.insert('review_states', <String, Object?>{
    'question_id': questionId,
    'state': 0,
    'next_review_time': 1700000000,
    'lapses': 0,
    'difficulty': 5.0,
    'stability': 0.0,
    'reps': 0,
    'last_lapse_time': null,
    'last_review_time': null,
  });
  await db.insert('review_logs', <String, Object?>{
    'id': 'log-$questionId',
    'question_id': questionId,
    'grade': 1,
    'review_time': 1700000000,
    'duration_ms': 1000,
    'user_answer': null,
    'ai_evaluation': null,
  });
  await db.insert('answer_attempts', <String, Object?>{
    'attempt_id': 'attempt-$questionId',
    'question_id': questionId,
    'session_kind': 'normal',
    'modality': 'choice',
    'answer_payload_json':
        '{"version":1,"kind":"choice","option_ids":["opt_a"]}',
    'correctness': 0,
    'answered_at': 1700000000,
    'duration_ms': 1000,
  });
}

Future<void> _createExamTables(dynamic db) async {
  await db.execute('''
    CREATE TABLE exam_papers (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      source_type INTEGER NOT NULL,
      status INTEGER NOT NULL DEFAULT 0,
      score REAL DEFAULT 0.0,
      total_score REAL DEFAULT 0.0,
      created_at INTEGER NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE paper_questions (
      paper_id TEXT NOT NULL,
      question_id TEXT NOT NULL,
      user_answer TEXT,
      is_correct INTEGER DEFAULT 0,
      order_index INTEGER NOT NULL,
      PRIMARY KEY (paper_id, question_id)
    )
  ''');
}

Future<void> _installQuestionFts(dynamic db) async {
  await db.execute(
    'CREATE VIRTUAL TABLE IF NOT EXISTS questions_fts '
    'USING fts5(id UNINDEXED, content, options, explanation)',
  );
  await db.execute('''
    CREATE TRIGGER IF NOT EXISTS q_ai AFTER INSERT ON questions
    BEGIN
      INSERT INTO questions_fts(id, content, options, explanation)
      VALUES (new.id, new.content, new.options, new.explanation);
    END;
  ''');
  await db.execute('''
    CREATE TRIGGER IF NOT EXISTS q_ad AFTER DELETE ON questions
    BEGIN
      DELETE FROM questions_fts WHERE id = old.id;
    END;
  ''');
  await db.execute('''
    CREATE TRIGGER IF NOT EXISTS q_au AFTER UPDATE ON questions
    BEGIN
      DELETE FROM questions_fts WHERE id = old.id;
      INSERT INTO questions_fts(id, content, options, explanation)
      VALUES (new.id, new.content, new.options, new.explanation);
    END;
  ''');
}

Future<void> _expectQuestionDataPresent(
  dynamic db,
  List<String> questionIds,
) async {
  expect(
    (await db.query('questions')).map((row) => row['id']),
    unorderedEquals(questionIds),
  );
  expect(
    (await db.query('question_v2_payloads')).map((row) => row['question_id']),
    unorderedEquals(questionIds),
  );
  expect(
    (await db.query('review_states')).map((row) => row['question_id']),
    unorderedEquals(questionIds),
  );
  expect(
    (await db.query('review_logs')).map((row) => row['question_id']),
    unorderedEquals(questionIds),
  );
  expect(
    (await db.query('answer_attempts')).map((row) => row['question_id']),
    unorderedEquals(questionIds),
  );
  expect(
    (await db.rawQuery('SELECT id FROM questions_fts')).map((row) => row['id']),
    unorderedEquals(questionIds),
  );
}

Future<void> _expectQuestionDataPurged(dynamic db) async {
  expect(await db.query('questions'), isEmpty);
  expect(await db.query('question_v2_payloads'), isEmpty);
  expect(await db.query('review_states'), isEmpty);
  expect(await db.query('review_logs'), isEmpty);
  expect(await db.query('answer_attempts'), isEmpty);
  expect(await db.rawQuery('SELECT id FROM questions_fts'), isEmpty);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    final db = await DatabaseHelper.instance.database;
    await _installQuestionFts(db);
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  test('legacy clear-all succeeds when paper_questions is absent', () async {
    final db = await DatabaseHelper.instance.database;
    await _seedQuestionData(db, 'question-legacy');

    final examTables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name = 'paper_questions'",
    );
    expect(examTables, isEmpty);

    await ReviewRepository().clearAllData();

    await _expectQuestionDataPurged(db);
  });

  test('clear-all succeeds when Exam tables exist without a reference',
      () async {
    final db = await DatabaseHelper.instance.database;
    await _seedQuestionData(db, 'question-unreferenced');
    await _createExamTables(db);

    await ReviewRepository().clearAllData();

    await _expectQuestionDataPurged(db);
    expect(await db.query('exam_papers'), isEmpty);
    expect(await db.query('paper_questions'), isEmpty);
  });

  test('one completed Exam reference blocks the entire clear-all', () async {
    final db = await DatabaseHelper.instance.database;
    await _seedQuestionData(db, 'question-referenced');
    await _seedQuestionData(db, 'question-unreferenced');
    await _createExamTables(db);
    await db.insert('exam_papers', <String, Object?>{
      'id': 'completed-paper',
      'title': 'Synthetic completed paper',
      'source_type': 0,
      'status': 2,
      'score': 1.0,
      'total_score': 1.0,
      'created_at': 1700000000,
    });
    await db.insert('paper_questions', <String, Object?>{
      'paper_id': 'completed-paper',
      'question_id': 'question-referenced',
      'user_answer': 'A',
      'is_correct': 1,
      'order_index': 0,
    });

    await expectLater(
      ReviewRepository().clearAllData(),
      throwsA(
        isA<QuestionDataClearAllException>().having(
          (error) => error.failure,
          'failure',
          QuestionDataClearAllFailure.examReferenced,
        ),
      ),
    );

    expect(
      const QuestionDataClearAllException(
        QuestionDataClearAllFailure.examReferenced,
      ).toString(),
      'QuestionDataClearAllException(examReferenced)',
    );
    await _expectQuestionDataPresent(
      db,
      <String>['question-referenced', 'question-unreferenced'],
    );
    expect(await db.query('exam_papers'), hasLength(1));
    expect(await db.query('paper_questions'), hasLength(1));
  });

  test('unavailable Exam reference schema fails closed before clear-all',
      () async {
    final db = await DatabaseHelper.instance.database;
    await _seedQuestionData(db, 'question-unavailable');
    await db.execute('''
      CREATE TABLE paper_questions (
        paper_id TEXT PRIMARY KEY NOT NULL
      )
    ''');
    await db.insert('paper_questions', <String, Object?>{
      'paper_id': 'malformed-paper',
    });

    await expectLater(
      ReviewRepository().clearAllData(),
      throwsA(
        isA<QuestionDataClearAllException>().having(
          (error) => error.failure,
          'failure',
          QuestionDataClearAllFailure.unavailable,
        ),
      ),
    );

    await _expectQuestionDataPresent(db, <String>['question-unavailable']);
    expect(await db.query('paper_questions'), hasLength(1));
  });

  test('transaction start failure is unavailable before guard completion',
      () async {
    final db = await DatabaseHelper.instance.database;
    await _seedQuestionData(db, 'question-transaction-start');
    await db.execute('BEGIN EXCLUSIVE');

    await expectLater(
      ReviewRepository().clearAllData(),
      throwsA(
        isA<QuestionDataClearAllException>().having(
          (error) => error.failure,
          'failure',
          QuestionDataClearAllFailure.unavailable,
        ),
      ),
    );

    await db.execute('ROLLBACK');
    await _expectQuestionDataPresent(
        db, <String>['question-transaction-start']);
  });

  test('post-guard delete failure rolls back every clear-all table', () async {
    final db = await DatabaseHelper.instance.database;
    await _seedQuestionData(db, 'question-rollback');
    await _createExamTables(db);
    await db.execute('''
      CREATE TRIGGER fail_clear_all_review_logs
      BEFORE DELETE ON review_logs
      BEGIN
        SELECT RAISE(ABORT, 'synthetic clear-all failure');
      END;
    ''');

    await expectLater(
      ReviewRepository().clearAllData(),
      throwsA(
        isA<QuestionDataClearAllException>().having(
          (error) => error.failure,
          'failure',
          QuestionDataClearAllFailure.transactionFailed,
        ),
      ),
    );

    await _expectQuestionDataPresent(db, <String>['question-rollback']);
    expect(await db.query('exam_papers'), isEmpty);
    expect(await db.query('paper_questions'), isEmpty);
  });
}
