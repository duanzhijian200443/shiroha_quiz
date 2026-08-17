import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/study_plan_v22_schema.dart';
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
    tempDir = await Directory.systemTemp.createTemp('study_plan_v22_');
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
      'A. fresh DB creates study_plans singleton table, version 22, and validates',
      () async {
    final db =
        await DatabaseHelper.instance.openPathForTesting(inMemoryDatabasePath);
    try {
      final versionRows = await db.rawQuery('PRAGMA user_version');
      expect(
          versionRows.single['user_version'], DatabaseHelper.databaseVersion);

      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'study_plans'",
      );
      expect(tables, hasLength(1));

      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);

      // Verify schema helper validates cleanly without throwing
      await expectLater(validateStudyPlanV22Schema(db), completes);
    } finally {
      await db.close();
    }
  });

  test('B. v21 to v22 is additive and preserves representative existing data',
      () async {
    final path = p.join(tempDir.path, 'upgrade_v21_v22.db');
    final created = await DatabaseHelper.instance.openPathForTesting(path);

    // Seed representative existing data across multiple domains
    await created.insert('questions', <String, Object?>{
      'id': 'q-v21',
      'type': 0,
      'content': 'Question 1',
      'options': '["A","B"]',
      'standard_answer': 'A',
      'explanation': 'Exp',
      'created_at': 1000,
      'bank_name': 'Math',
    });

    await created.insert('review_states', <String, Object?>{
      'question_id': 'q-v21',
      'state': 1,
      'next_review_time': 2000,
      'lapses': 1,
      'difficulty': 5.0,
      'stability': 2.0,
      'reps': 3,
      'last_lapse_time': 1500,
      'last_review_time': 1800,
    });

    await created.insert('projects', <String, Object?>{
      'project_id': 'proj-1',
      'display_name': 'Project One',
      'created_at': 1000,
    });

    await created.insert('project_banks', <String, Object?>{
      'project_id': 'proj-1',
      'bank_name': 'Math',
    });

    await created.insert('conversations', <String, Object?>{
      'conversation_id': 'conv-1',
      'scope_kind': 'learning_space',
      'project_id': 'proj-1',
      'title': 'Test Conv',
      'created_at': 1000,
      'updated_at': 1000,
    });

    await created.insert('conversation_messages', <String, Object?>{
      'message_id': 'msg-1',
      'conversation_id': 'conv-1',
      'sequence': 1,
      'role': 'user',
      'content': 'Help me plan',
      'created_at': 1000,
    });

    // Simulate v21 database without study_plans table
    await created.execute('DROP TABLE study_plans');
    await created.execute('PRAGMA user_version = 21');
    await created.close();

    // Reopen using current DatabaseHelper (upgrades 21 -> 22)
    final upgraded = await DatabaseHelper.instance.openPathForTesting(path);
    try {
      final versionRows = await upgraded.rawQuery('PRAGMA user_version');
      expect(
          versionRows.single['user_version'], DatabaseHelper.databaseVersion);

      // Verify old data is intact
      final questions = await upgraded.query('questions');
      expect(questions, hasLength(1));
      expect(questions.first['id'], 'q-v21');

      final reviewStates = await upgraded.query('review_states');
      expect(reviewStates, hasLength(1));
      expect(reviewStates.first['question_id'], 'q-v21');

      final conversations = await upgraded.query('conversations');
      expect(conversations, hasLength(1));
      expect(conversations.first['conversation_id'], 'conv-1');

      final messages = await upgraded.query('conversation_messages');
      expect(messages, hasLength(1));
      expect(messages.first['message_id'], 'msg-1');

      // Verify study_plans table exists and is empty
      final plans = await upgraded.query('study_plans');
      expect(plans, isEmpty);

      // Verify schema is valid
      await expectLater(validateStudyPlanV22Schema(upgraded), completes);
      expect(await upgraded.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      await upgraded.close();
    }
  });

  test('C. malformed pre-existing study_plans fails atomically and leaves v21',
      () async {
    final path = p.join(tempDir.path, 'malformed_v22.db');
    final created = await DatabaseHelper.instance.openPathForTesting(path);

    await created.insert('questions', <String, Object?>{
      'id': 'q-pre',
      'type': 0,
      'content': 'Preexisting question',
      'options': '[]',
      'standard_answer': 'A',
      'created_at': 1000,
      'bank_name': 'Default',
    });

    // Create malformed study_plans table and set user_version = 21
    await created.execute('DROP TABLE study_plans');
    await created.execute(
      'CREATE TABLE study_plans (plan_id TEXT PRIMARY KEY, malformed_col TEXT)',
    );
    await created.execute('PRAGMA user_version = 21');
    await created.close();

    // Opening with DatabaseHelper must fail with StudyPlanSchemaException
    await expectLater(
      DatabaseHelper.instance.openPathForTesting(path),
      throwsA(isA<StudyPlanSchemaException>().having(
        (e) => e.failure,
        'failure',
        StudyPlanSchemaFailure.malformedSchema,
      )),
    );

    // Read-only probe: user_version must remain 21, and existing rows intact
    final probe = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      final versionRows = await probe.rawQuery('PRAGMA user_version');
      expect(versionRows.single['user_version'], 21);

      final questions = await probe.query('questions');
      expect(questions, hasLength(1));
      expect(questions.first['id'], 'q-pre');
    } finally {
      await probe.close();
    }
  });

  group('D. SQLite DDL CHECK constraints on study_plans', () {
    test('enforces singleton_key uniqueness', () async {
      final db = await DatabaseHelper.instance
          .openPathForTesting(inMemoryDatabasePath);
      try {
        await db.insert('study_plans', <String, Object?>{
          'plan_id': 'plan-1',
          'singleton_key': 1,
          'bank_name': 'Math',
          'goal': 'Master calculus',
          'daily_target': 30,
          'priority': 'balanced',
          'horizon_days': 14,
          'adopted_at': 1000,
        });

        expect(
          () => db.insert('study_plans', <String, Object?>{
            'plan_id': 'plan-2',
            'singleton_key': 1,
            'bank_name': 'Physics',
            'daily_target': 20,
            'priority': 'due_first',
            'adopted_at': 2000,
          }),
          throwsA(isA<DatabaseException>()),
        );
      } finally {
        await db.close();
      }
    });

    test('rejects daily_target out of bounds (0 or 201)', () async {
      final db = await DatabaseHelper.instance
          .openPathForTesting(inMemoryDatabasePath);
      try {
        expect(
          () => db.insert('study_plans', <String, Object?>{
            'plan_id': 'plan-invalid-target-0',
            'singleton_key': 1,
            'bank_name': 'Math',
            'daily_target': 0,
            'priority': 'balanced',
            'adopted_at': 1000,
          }),
          throwsA(isA<DatabaseException>()),
        );

        expect(
          () => db.insert('study_plans', <String, Object?>{
            'plan_id': 'plan-invalid-target-201',
            'singleton_key': 1,
            'bank_name': 'Math',
            'daily_target': 201,
            'priority': 'balanced',
            'adopted_at': 1000,
          }),
          throwsA(isA<DatabaseException>()),
        );
      } finally {
        await db.close();
      }
    });

    test('rejects unknown priority', () async {
      final db = await DatabaseHelper.instance
          .openPathForTesting(inMemoryDatabasePath);
      try {
        expect(
          () => db.insert('study_plans', <String, Object?>{
            'plan_id': 'plan-invalid-priority',
            'singleton_key': 1,
            'bank_name': 'Math',
            'daily_target': 30,
            'priority': 'random_unknown',
            'adopted_at': 1000,
          }),
          throwsA(isA<DatabaseException>()),
        );
      } finally {
        await db.close();
      }
    });

    test('rejects horizon_days out of bounds (0 or 91)', () async {
      final db = await DatabaseHelper.instance
          .openPathForTesting(inMemoryDatabasePath);
      try {
        expect(
          () => db.insert('study_plans', <String, Object?>{
            'plan_id': 'plan-invalid-horizon-0',
            'singleton_key': 1,
            'bank_name': 'Math',
            'daily_target': 30,
            'priority': 'balanced',
            'horizon_days': 0,
            'adopted_at': 1000,
          }),
          throwsA(isA<DatabaseException>()),
        );

        expect(
          () => db.insert('study_plans', <String, Object?>{
            'plan_id': 'plan-invalid-horizon-91',
            'singleton_key': 1,
            'bank_name': 'Math',
            'daily_target': 30,
            'priority': 'balanced',
            'horizon_days': 91,
            'adopted_at': 1000,
          }),
          throwsA(isA<DatabaseException>()),
        );
      } finally {
        await db.close();
      }
    });

    test('rejects untrimmed or empty bank_name', () async {
      final db = await DatabaseHelper.instance
          .openPathForTesting(inMemoryDatabasePath);
      try {
        expect(
          () => db.insert('study_plans', <String, Object?>{
            'plan_id': 'plan-untrimmed-bank',
            'singleton_key': 1,
            'bank_name': ' Math ',
            'daily_target': 30,
            'priority': 'balanced',
            'adopted_at': 1000,
          }),
          throwsA(isA<DatabaseException>()),
        );
      } finally {
        await db.close();
      }
    });
  });
}
