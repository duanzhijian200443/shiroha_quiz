import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/review_engine_service.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _questionId = 'd1d-reset-question';

Future<void> _seedReviewStateHistory(Database db) async {
  await db.insert('questions', <String, Object?>{
    'id': _questionId,
    'type': 0,
    'content': 'D1D reset question',
    'options': '["A. option", "B. option"]',
    'standard_answer': 'A',
    'explanation': 'D1D explanation',
    'raw_explanation': null,
    'created_at': 1700000000,
    'bank_name': 'D1D bank',
  });
  await db.insert('review_states', <String, Object?>{
    'question_id': _questionId,
    'state': 3,
    'next_review_time': 1700003600,
    'lapses': 4,
    'difficulty': 2.5,
    'stability': 42.0,
    'reps': 8,
    'last_lapse_time': 1700001000,
    'last_review_time': 1700002000,
  });
  await db.insert('review_logs', <String, Object?>{
    'id': 'd1d-review-log',
    'question_id': _questionId,
    'grade': 4,
    'llm_score': 0.9,
    'review_time': 1700002000,
    'duration_ms': 1200,
    'user_answer': 'A',
    'ai_evaluation': 'D1D review history',
  });
  await db.insert('answer_attempts', <String, Object?>{
    'attempt_id': 'd1d-answer-attempt',
    'question_id': _questionId,
    'session_kind': 'normal',
    'modality': 'choice',
    'answer_payload_json': '{"version":1,"kind":"choice","option_ids":["A"]}',
    'correctness': 1,
    'answered_at': 1700002000,
    'duration_ms': 1200,
  });
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

  test('resetReviewState resets scheduling only and preserves both histories',
      () async {
    final db = await DatabaseHelper.instance.database;
    await _seedReviewStateHistory(db);

    await ReviewEngineService().resetReviewState(_questionId);

    final state = (await db.query(
      'review_states',
      where: 'question_id = ?',
      whereArgs: <Object?>[_questionId],
    ))
        .single;
    expect(state['state'], 0);
    expect(state['next_review_time'], 0);
    expect(state['lapses'], 0);
    expect(state['difficulty'], 5.0);
    expect(state['stability'], 0.0);
    expect(state['reps'], 0);
    expect(state['last_lapse_time'], 0);
    expect(state['last_review_time'], 0);

    expect(await db.query('questions'), hasLength(1));
    expect(await db.query('review_logs'), hasLength(1));
    expect(await db.query('answer_attempts'), hasLength(1));
    expect(
      (await db.query('review_logs')).single['id'],
      'd1d-review-log',
    );
    expect(
      (await db.query('answer_attempts')).single['attempt_id'],
      'd1d-answer-attempt',
    );
  });

  test('resetReviewState is blocked during backup restore maintenance',
      () async {
    final db = await DatabaseHelper.instance.database;
    await _seedReviewStateHistory(db);
    await BackupRestoreMutationGate.instance.enterQuiescence();

    await expectLater(
      ReviewEngineService().resetReviewState(_questionId),
      throwsA(isA<BackupException>()),
    );

    BackupRestoreMutationGate.instance.exitQuiescence();
    final state = (await db.query('review_states')).single;
    expect(state['state'], 3);
    expect((await db.query('review_logs')), hasLength(1));
    expect((await db.query('answer_attempts')), hasLength(1));
  });
}
