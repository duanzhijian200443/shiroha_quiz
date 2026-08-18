import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/questions/question_bank_mutation_command.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/data/repositories/settings_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _targetBank = 'd1c_target_bank';
const _otherBank = 'd1c_other_bank';
const _targetQuestionId = 'd1c_target_question';
const _otherQuestionId = 'd1c_other_question';
const _projectId = 'd1c_project';
const _fileId = 'd1c_file';

Future<Database> _database() => DatabaseHelper.instance.database;

Future<void> _insertQuestion(
  Database db, {
  required String id,
  required String bankName,
}) async {
  await db.insert('questions', <String, Object?>{
    'id': id,
    'type': 0,
    'content': 'D1C question $id',
    'options': '["A. option", "B. option"]',
    'standard_answer': 'A',
    'explanation': 'D1C explanation',
    'raw_explanation': 'D1C raw explanation',
    'created_at': 1700000000,
    'bank_name': bankName,
  });
  await db.insert('question_v2_payloads', <String, Object?>{
    'question_id': id,
    'payload_schema_version': 2,
    'payload_json': '{"schemaVersion":2,"questionId":"$id"}',
  });
  await db.insert('review_states', <String, Object?>{
    'question_id': id,
    'state': 0,
    'next_review_time': 1700000000,
    'lapses': 1,
    'difficulty': 5.0,
    'stability': 1.0,
    'reps': 1,
    'last_lapse_time': 1700000000,
    'last_review_time': 1700000000,
  });
  await db.insert('review_logs', <String, Object?>{
    'id': 'review-log-$id',
    'question_id': id,
    'grade': 1,
    'llm_score': null,
    'review_time': 1700000000,
    'duration_ms': 1000,
    'user_answer': 'A',
    'ai_evaluation': null,
  });
}

Future<void> _insertTargetAttempt(Database db) async {
  await db.insert('answer_attempts', <String, Object?>{
    'attempt_id': 'answer-attempt-$_targetQuestionId',
    'question_id': _targetQuestionId,
    'session_kind': 'normal',
    'modality': 'choice',
    'answer_payload_json': '{"version":1,"kind":"choice","option_ids":["A"]}',
    'correctness': 0,
    'answered_at': 1700000000,
    'duration_ms': 1000,
  });
}

Future<void> _insertLibraryAsset(Database db) async {
  final sourceHash = 'a' * 64;
  await db.insert('library_files', <String, Object?>{
    'file_id': _fileId,
    'display_name': 'd1c-source.txt',
    'mime_type': 'text/plain',
    'size_bytes': 4,
    'sha256': sourceHash,
    'storage_key': 'library/$_fileId',
    'created_at': 1,
  });
  await db.insert('parsed_artifact_heads', <String, Object?>{
    'file_id': _fileId,
    'last_revision': 1,
  });
  await db.insert('parsed_artifacts', <String, Object?>{
    'file_id': _fileId,
    'artifact_id': 'd1c_artifact',
    'revision': 1,
    'source_sha256': sourceHash,
    'cache_key_version': 1,
    'cache_fingerprint': 'd1c-fingerprint',
    'parser_route': 'txt',
    'parser_version': '1',
    'options_schema_version': 1,
    'payload_schema_version': 1,
    'storage_key': 'artifacts/d1c_artifact',
    'payload_sha256': 'b' * 64,
    'size_bytes': 4,
    'published_at': 1,
  });
}

Future<void> _seedBank(
  Database db, {
  bool includeOtherBank = false,
}) async {
  await _insertQuestion(
    db,
    id: _targetQuestionId,
    bankName: _targetBank,
  );
  await _insertTargetAttempt(db);
  await db.insert('bank_folders', <String, Object?>{
    'bank_name': _targetBank,
    'folder_name': 'D1C folder',
  });
  await db.insert('projects', <String, Object?>{
    'project_id': _projectId,
    'display_name': 'D1C project',
    'created_at': 1,
  });
  await db.insert('project_banks', <String, Object?>{
    'project_id': _projectId,
    'bank_name': _targetBank,
  });
  await _insertLibraryAsset(db);

  if (includeOtherBank) {
    await _insertQuestion(
      db,
      id: _otherQuestionId,
      bankName: _otherBank,
    );
    await db.insert('bank_folders', <String, Object?>{
      'bank_name': _otherBank,
      'folder_name': 'Other folder',
    });
    await db.insert('project_banks', <String, Object?>{
      'project_id': _projectId,
      'bank_name': _otherBank,
    });
  }
}

Future<void> _deleteTargetBank() {
  return QuestionBankMutationCommand(QuestionRepository())
      .deleteQuestionBank(_targetBank);
}

Future<void> _expectTargetBankToRemain(Database db) async {
  expect(
    await db.query(
      'questions',
      where: 'bank_name = ?',
      whereArgs: <Object?>[_targetBank],
    ),
    hasLength(1),
  );
  expect(
    await db.query(
      'question_v2_payloads',
      where: 'question_id = ?',
      whereArgs: <Object?>[_targetQuestionId],
    ),
    hasLength(1),
  );
  expect(
    await db.query(
      'review_states',
      where: 'question_id = ?',
      whereArgs: <Object?>[_targetQuestionId],
    ),
    hasLength(1),
  );
  expect(
    await db.query(
      'review_logs',
      where: 'question_id = ?',
      whereArgs: <Object?>[_targetQuestionId],
    ),
    hasLength(1),
  );
  expect(
    await db.query(
      'answer_attempts',
      where: 'question_id = ?',
      whereArgs: <Object?>[_targetQuestionId],
    ),
    hasLength(1),
  );
  expect(
    await db.query(
      'bank_folders',
      where: 'bank_name = ?',
      whereArgs: <Object?>[_targetBank],
    ),
    hasLength(1),
  );
  expect(
    await db.query(
      'project_banks',
      where: 'bank_name = ?',
      whereArgs: <Object?>[_targetBank],
    ),
    hasLength(1),
  );
  expect(await db.query('library_files'), hasLength(1));
  expect(await db.query('parsed_artifact_heads'), hasLength(1));
  expect(await db.query('parsed_artifacts'), hasLength(1));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    BackupRestoreMutationGate.resetForTesting();
    SettingsRepository.instance.clearCache();
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  tearDown(() async {
    BackupRestoreMutationGate.resetForTesting();
    SettingsRepository.instance.clearCache();
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  test(
      'deletes bank-owned data and relations while preserving independent data',
      () async {
    final db = await _database();
    await _seedBank(db, includeOtherBank: true);
    await SettingsRepository.instance.setCurrentBank(_targetBank);
    final paperId = await DatabaseHelper.instance.createExamPaper(
      'D1C preserved exam',
      0,
      <Map<String, dynamic>>[
        <String, dynamic>{'id': _otherQuestionId},
      ],
    );

    expect(
      await db.query(
        'questions_fts',
        where: 'id = ?',
        whereArgs: <Object?>[_targetQuestionId],
      ),
      hasLength(1),
    );

    await _deleteTargetBank();

    expect(
      await db.query(
        'questions',
        where: 'bank_name = ?',
        whereArgs: <Object?>[_targetBank],
      ),
      isEmpty,
    );
    expect(
      await db.query(
        'question_v2_payloads',
        where: 'question_id = ?',
        whereArgs: <Object?>[_targetQuestionId],
      ),
      isEmpty,
    );
    expect(
      await db.query(
        'review_states',
        where: 'question_id = ?',
        whereArgs: <Object?>[_targetQuestionId],
      ),
      isEmpty,
    );
    expect(
      await db.query(
        'review_logs',
        where: 'question_id = ?',
        whereArgs: <Object?>[_targetQuestionId],
      ),
      isEmpty,
    );
    expect(
      await db.query(
        'questions_fts',
        where: 'id = ?',
        whereArgs: <Object?>[_targetQuestionId],
      ),
      isEmpty,
    );
    expect(
      await db.query(
        'answer_attempts',
        where: 'question_id = ?',
        whereArgs: <Object?>[_targetQuestionId],
      ),
      hasLength(1),
    );
    expect(
      await db.query(
        'bank_folders',
        where: 'bank_name = ?',
        whereArgs: <Object?>[_targetBank],
      ),
      isEmpty,
    );
    expect(
      await db.query(
        'project_banks',
        where: 'bank_name = ?',
        whereArgs: <Object?>[_targetBank],
      ),
      isEmpty,
    );

    expect(
      await db.query(
        'questions',
        where: 'id = ?',
        whereArgs: <Object?>[_otherQuestionId],
      ),
      hasLength(1),
    );
    expect(
      await db.query(
        'question_v2_payloads',
        where: 'question_id = ?',
        whereArgs: <Object?>[_otherQuestionId],
      ),
      hasLength(1),
    );
    expect(
      await db.query(
        'questions_fts',
        where: 'id = ?',
        whereArgs: <Object?>[_otherQuestionId],
      ),
      hasLength(1),
    );
    expect(
      await db.query(
        'bank_folders',
        where: 'bank_name = ?',
        whereArgs: <Object?>[_otherBank],
      ),
      hasLength(1),
    );
    expect(
      await db.query(
        'project_banks',
        where: 'bank_name = ?',
        whereArgs: <Object?>[_otherBank],
      ),
      hasLength(1),
    );
    expect(await db.query('library_files'), hasLength(1));
    expect(await db.query('parsed_artifact_heads'), hasLength(1));
    expect(await db.query('parsed_artifacts'), hasLength(1));
    expect(
      await db.query(
        'exam_papers',
        where: 'id = ?',
        whereArgs: <Object?>[paperId],
      ),
      hasLength(1),
    );
    expect(
      await db.query(
        'paper_questions',
        where: 'paper_id = ?',
        whereArgs: <Object?>[paperId],
      ),
      hasLength(1),
    );
    expect(
      await SettingsRepository.instance.getCurrentBank(),
      '点击修改选择题库',
    );
  });

  test('deletes a legacy bank when the exam reference table is absent',
      () async {
    final db = await _database();
    await _seedBank(db);

    expect(
      await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE name = 'paper_questions'",
      ),
      isEmpty,
    );

    await _deleteTargetBank();

    expect(
      await db.query(
        'questions',
        where: 'bank_name = ?',
        whereArgs: <Object?>[_targetBank],
      ),
      isEmpty,
    );
    expect(
      await db.query(
        'bank_folders',
        where: 'bank_name = ?',
        whereArgs: <Object?>[_targetBank],
      ),
      isEmpty,
    );
    expect(
      await db.query(
        'project_banks',
        where: 'bank_name = ?',
        whereArgs: <Object?>[_targetBank],
      ),
      isEmpty,
    );
    expect(await db.query('answer_attempts'), hasLength(1));
    expect(await db.query('library_files'), hasLength(1));
    expect(await db.query('parsed_artifacts'), hasLength(1));
  });

  test('blocks bank deletion when an exam references one of its questions',
      () async {
    final db = await _database();
    await _seedBank(db);
    final paperId = await DatabaseHelper.instance.createExamPaper(
      'D1C blocking exam',
      0,
      <Map<String, dynamic>>[
        <String, dynamic>{'id': _targetQuestionId},
      ],
    );

    await expectLater(
      _deleteTargetBank(),
      throwsA(
        isA<QuestionBankDeleteException>().having(
          (error) => error.failure,
          'failure',
          QuestionBankDeleteFailure.examReferenced,
        ),
      ),
    );

    await _expectTargetBankToRemain(db);
    expect(
      await db.query(
        'questions_fts',
        where: 'id = ?',
        whereArgs: <Object?>[_targetQuestionId],
      ),
      hasLength(1),
    );
    expect(
      await db.query(
        'exam_papers',
        where: 'id = ?',
        whereArgs: <Object?>[paperId],
      ),
      hasLength(1),
    );
    expect(
      await db.query(
        'paper_questions',
        where: 'paper_id = ?',
        whereArgs: <Object?>[paperId],
      ),
      hasLength(1),
    );
  });

  test('fails closed when the exam reference table cannot be queried',
      () async {
    final db = await _database();
    await _seedBank(db);
    await db.execute('''
      CREATE TABLE paper_questions (
        paper_id TEXT NOT NULL
      )
    ''');

    await expectLater(
      _deleteTargetBank(),
      throwsA(
        isA<QuestionBankDeleteException>().having(
          (error) => error.failure,
          'failure',
          QuestionBankDeleteFailure.unavailable,
        ),
      ),
    );

    await _expectTargetBankToRemain(db);
  });

  test('rolls back every bank delete when a later delete fails', () async {
    final db = await _database();
    await _seedBank(db);
    await db.execute('''
      CREATE TRIGGER d1c_block_project_bank_delete
      BEFORE DELETE ON project_banks
      BEGIN
        SELECT RAISE(ABORT, 'd1c_synthetic_relation_delete_failure');
      END;
    ''');

    await expectLater(
      _deleteTargetBank(),
      throwsA(
        isA<QuestionBankDeleteException>().having(
          (error) => error.failure,
          'failure',
          QuestionBankDeleteFailure.transactionFailed,
        ),
      ),
    );

    await _expectTargetBankToRemain(db);
  });

  test('rolls back bank deletion when current-bank update fails', () async {
    final db = await _database();
    await _seedBank(db);
    await SettingsRepository.instance.setCurrentBank(_targetBank);
    await db.execute('''
      CREATE TRIGGER d1c_block_current_bank_update
      BEFORE UPDATE OF value ON app_settings
      WHEN OLD.key = 'current_bank' AND OLD.value = 'd1c_target_bank'
      BEGIN
        SELECT RAISE(ABORT, 'd1c_synthetic_current_bank_failure');
      END;
    ''');

    await expectLater(
      _deleteTargetBank(),
      throwsA(
        isA<QuestionBankDeleteException>().having(
          (error) => error.failure,
          'failure',
          QuestionBankDeleteFailure.transactionFailed,
        ),
      ),
    );

    await _expectTargetBankToRemain(db);
    expect(
      await db.query(
        'app_settings',
        where: 'key = ?',
        whereArgs: <Object?>['current_bank'],
      ),
      hasLength(1),
    );
    expect(
      (await db.query(
        'app_settings',
        where: 'key = ?',
        whereArgs: <Object?>['current_bank'],
      ))
          .single['value'],
      _targetBank,
    );
    expect(
      await SettingsRepository.instance.getCurrentBank(),
      _targetBank,
    );
  });
}
