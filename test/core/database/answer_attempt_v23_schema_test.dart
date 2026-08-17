import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/answer_attempt_v23_schema.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    tempDir = await Directory.systemTemp.createTemp('answer_attempt_v23_');
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  test('S1: fresh DB creates answer_attempts table, version 23, and validates',
      () async {
    final db =
        await DatabaseHelper.instance.openPathForTesting(inMemoryDatabasePath);
    try {
      final versionRows = await db.rawQuery('PRAGMA user_version');
      expect(versionRows.single['user_version'], 23);

      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'answer_attempts'",
      );
      expect(tables, hasLength(1));

      final indexes = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'answer_attempts' ORDER BY name",
      );
      final indexNames = indexes.map((row) => row['name'] as String).toSet();
      expect(
        indexNames,
        containsAll(<String>{
          'idx_answer_attempts_question_answered',
          'idx_answer_attempts_correctness_answered',
        }),
      );

      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);

      // Verify schema helper validates cleanly without throwing
      await expectLater(validateAnswerAttemptV23Schema(db), completes);
    } finally {
      await db.close();
    }
  });

  test('S2: v22 to v23 is additive and preserves existing data', () async {
    final path = p.join(tempDir.path, 'upgrade_v22_v23.db');
    final created = await DatabaseHelper.instance.openPathForTesting(path);

    // Seed representative existing data across multiple domains
    await created.insert('questions', <String, Object?>{
      'id': 'q-v22',
      'type': 0,
      'content': 'Stem V22',
      'options': '["A. opt1", "B. opt2"]',
      'standard_answer': 'A',
      'created_at': 1700000000,
      'bank_name': 'Default Bank',
    });
    await created.insert('review_states', <String, Object?>{
      'question_id': 'q-v22',
      'state': 1,
      'difficulty': 5.0,
      'stability': 2.0,
      'reps': 3,
      'lapses': 1,
      'last_review_time': 1700001000,
      'next_review_time': 1700005000,
      'last_lapse_time': 1700001000,
    });
    await created.insert('study_plans', <String, Object?>{
      'plan_id': 'plan-1',
      'singleton_key': 1,
      'bank_name': 'Default Bank',
      'goal': 'Master Flutter',
      'daily_target': 20,
      'priority': 'balanced',
      'adopted_at': 1700000000,
    });

    // Simulate v22 database without answer_attempts table
    await created
        .execute('DROP INDEX IF EXISTS idx_answer_attempts_question_answered');
    await created.execute(
        'DROP INDEX IF EXISTS idx_answer_attempts_correctness_answered');
    await created.execute('DROP TABLE answer_attempts');
    await created.execute('PRAGMA user_version = 22');
    await created.close();

    // Reopen using current DatabaseHelper (upgrades 22 -> 23)
    final upgraded = await DatabaseHelper.instance.openPathForTesting(path);
    try {
      final versionRows = await upgraded.rawQuery('PRAGMA user_version');
      expect(versionRows.single['user_version'], 23);

      // Verify old data is intact
      final questions = await upgraded.query('questions');
      expect(questions, hasLength(1));
      expect(questions.first['id'], 'q-v22');

      final reviewStates = await upgraded.query('review_states');
      expect(reviewStates, hasLength(1));
      expect(reviewStates.first['question_id'], 'q-v22');

      final studyPlans = await upgraded.query('study_plans');
      expect(studyPlans, hasLength(1));
      expect(studyPlans.first['plan_id'], 'plan-1');

      // Verify answer_attempts table exists and is empty
      final attempts = await upgraded.query('answer_attempts');
      expect(attempts, isEmpty);

      // Verify schema validates cleanly
      await expectLater(validateAnswerAttemptV23Schema(upgraded), completes);
    } finally {
      await upgraded.close();
    }
  });

  test('S3: validateAnswerAttemptV23Schema detects malformed tables', () async {
    final db = await openDatabase(inMemoryDatabasePath);
    try {
      // Table missing entirely
      expect(
        () => validateAnswerAttemptV23Schema(db),
        throwsA(isA<AnswerAttemptSchemaException>()),
      );

      // Table created with incorrect column type
      await db.execute('''
        CREATE TABLE answer_attempts (
          attempt_id TEXT PRIMARY KEY NOT NULL,
          question_id INTEGER NOT NULL,
          session_kind TEXT NOT NULL,
          modality TEXT NOT NULL,
          answer_payload_json TEXT NOT NULL,
          correctness INTEGER,
          answered_at INTEGER NOT NULL,
          duration_ms INTEGER
        );
      ''');

      expect(
        () => validateAnswerAttemptV23Schema(db),
        throwsA(isA<AnswerAttemptSchemaException>()),
      );
    } finally {
      await db.close();
    }
  });

  test('S4: append-only multiple attempts for the same question coexist',
      () async {
    final db =
        await DatabaseHelper.instance.openPathForTesting(inMemoryDatabasePath);
    try {
      await db.insert('answer_attempts', <String, Object?>{
        'attempt_id': 'att-1',
        'question_id': 'q-1',
        'session_kind': 'normal',
        'modality': 'choice',
        'answer_payload_json':
            '{"version":1,"kind":"choice","option_ids":["opt_a"]}',
        'correctness': 0,
        'answered_at': 1700000100,
        'duration_ms': 5000,
      });

      await db.insert('answer_attempts', <String, Object?>{
        'attempt_id': 'att-2',
        'question_id': 'q-1',
        'session_kind': 'normal',
        'modality': 'choice',
        'answer_payload_json':
            '{"version":1,"kind":"choice","option_ids":["opt_b"]}',
        'correctness': 1,
        'answered_at': 1700000200,
        'duration_ms': 3000,
      });

      final rows = await db.query(
        'answer_attempts',
        where: 'question_id = ?',
        whereArgs: <Object?>['q-1'],
        orderBy: 'answered_at ASC',
      );
      expect(rows, hasLength(2));
      expect(rows[0]['attempt_id'], 'att-1');
      expect(rows[0]['correctness'], 0);
      expect(rows[1]['attempt_id'], 'att-2');
      expect(rows[1]['correctness'], 1);
    } finally {
      await db.close();
    }
  });

  test('S5: CHECK constraints enforce invariants', () async {
    final db =
        await DatabaseHelper.instance.openPathForTesting(inMemoryDatabasePath);
    try {
      // Invalid session_kind
      expect(
        () => db.insert('answer_attempts', <String, Object?>{
          'attempt_id': 'att-bad-session',
          'question_id': 'q-1',
          'session_kind': 'invalid_session',
          'modality': 'choice',
          'answer_payload_json': '{"version":1}',
          'correctness': 1,
          'answered_at': 1700000100,
        }),
        throwsA(isA<DatabaseException>()),
      );

      // Invalid modality
      expect(
        () => db.insert('answer_attempts', <String, Object?>{
          'attempt_id': 'att-bad-modality',
          'question_id': 'q-1',
          'session_kind': 'normal',
          'modality': 'voice',
          'answer_payload_json': '{"version":1}',
          'correctness': 1,
          'answered_at': 1700000100,
        }),
        throwsA(isA<DatabaseException>()),
      );

      // Invalid correctness
      expect(
        () => db.insert('answer_attempts', <String, Object?>{
          'attempt_id': 'att-bad-correctness',
          'question_id': 'q-1',
          'session_kind': 'normal',
          'modality': 'choice',
          'answer_payload_json': '{"version":1}',
          'correctness': 2,
          'answered_at': 1700000100,
        }),
        throwsA(isA<DatabaseException>()),
      );

      // Empty payload
      expect(
        () => db.insert('answer_attempts', <String, Object?>{
          'attempt_id': 'att-empty-payload',
          'question_id': 'q-1',
          'session_kind': 'normal',
          'modality': 'choice',
          'answer_payload_json': '',
          'correctness': 1,
          'answered_at': 1700000100,
        }),
        throwsA(isA<DatabaseException>()),
      );

      // Negative duration
      expect(
        () => db.insert('answer_attempts', <String, Object?>{
          'attempt_id': 'att-neg-duration',
          'question_id': 'q-1',
          'session_kind': 'normal',
          'modality': 'choice',
          'answer_payload_json': '{"version":1}',
          'correctness': 1,
          'answered_at': 1700000100,
          'duration_ms': -100,
        }),
        throwsA(isA<DatabaseException>()),
      );
    } finally {
      await db.close();
    }
  });
}
