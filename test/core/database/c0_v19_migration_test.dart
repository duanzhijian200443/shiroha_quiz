import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _c0Objects = <String>{
  'conversations',
  'conversation_messages',
  'conversation_files',
  'idx_conversations_recent',
  'idx_conversations_project_recent',
  'idx_conversation_messages_order',
  'idx_conversation_files_order',
  'idx_conversation_files_file_id',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    tempDir = await Directory.systemTemp.createTemp('c0_v19_');
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<Database> openSeam(String path) =>
      DatabaseHelper.instance.openPathForTesting(path);

  Future<Database> openRaw(String path) =>
      databaseFactory.openDatabase(path, options: OpenDatabaseOptions());

  Future<int> userVersion(Database db) async {
    final rows = await db.rawQuery('PRAGMA user_version');
    return rows.single['user_version'] as int;
  }

  Future<Map<String, String>> c0Schema(Database db) async {
    final rows = await db.rawQuery(
      "SELECT name, sql FROM sqlite_master WHERE name IN (${List.filled(_c0Objects.length, '?').join(',')}) ORDER BY name",
      _c0Objects.toList(growable: false),
    );
    return <String, String>{
      for (final row in rows) row['name']! as String: row['sql']! as String,
    };
  }

  Future<void> seedV18Data(Database db) async {
    await db.insert('library_files', <String, Object?>{
      'file_id': 'file-c0',
      'display_name': 'preserved.pdf',
      'mime_type': 'application/pdf',
      'size_bytes': 3,
      'sha256':
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      'storage_key': 'library/file-c0',
      'created_at': 1700000000,
    });
    await db.insert('projects', <String, Object?>{
      'project_id': 'project-c0',
      'display_name': 'preserved project',
      'created_at': 1700000000,
    });
    await db.insert('project_files', <String, Object?>{
      'project_id': 'project-c0',
      'file_id': 'file-c0',
    });
    await db.insert('project_banks', <String, Object?>{
      'project_id': 'project-c0',
      'bank_name': 'preserved bank',
    });
    await db.insert('library_folders', <String, Object?>{
      'folder_id': 'folder-c0',
      'display_name': '资料',
      'created_at': 1700000000,
    });
    await db.insert('library_file_folders', <String, Object?>{
      'file_id': 'file-c0',
      'folder_id': 'folder-c0',
    });
    await db.insert('questions', <String, Object?>{
      'id': 'q-c0',
      'type': 0,
      'content': 'synthetic stem',
      'options': jsonEncode(<String>['A', 'B']),
      'standard_answer': 'A',
      'explanation': 'synthetic explanation',
      'raw_explanation': 'synthetic raw',
      'created_at': 1700000000,
      'bank_name': 'preserved bank',
    });
    await db.insert('question_v2_payloads', <String, Object?>{
      'question_id': 'q-c0',
      'payload_schema_version': 2,
      'payload_json': '{"schemaVersion":2,"synthetic":true}',
    });
    await db.insert('review_states', <String, Object?>{
      'question_id': 'q-c0',
      'state': 3,
      'lapses': 2,
      'difficulty': 3.0,
      'stability': 8.0,
      'reps': 4,
    });
  }

  Future<void> downgradeToV18(Database db) async {
    await db.execute('DROP TABLE conversation_files');
    await db.execute('DROP TABLE conversation_messages');
    await db.execute('DROP TABLE conversations');
    await db.execute('PRAGMA user_version = 18');
  }

  test('fresh v19 creates exact C0 tables, indexes, and foreign keys',
      () async {
    final db = await openSeam(inMemoryDatabasePath);
    try {
      expect(await userVersion(db), DatabaseHelper.databaseVersion);
      expect((await c0Schema(db)).keys.toSet(), _c0Objects);
      final conversationFk = await db.rawQuery(
        'PRAGMA foreign_key_list(conversations)',
      );
      expect(conversationFk.single['table'], 'projects');
      expect(conversationFk.single['on_delete'], 'SET NULL');
      final fileFks = await db.rawQuery(
        'PRAGMA foreign_key_list(conversation_files)',
      );
      expect(fileFks.map((row) => row['table']).toSet(), <String>{
        'conversations',
        'library_files',
      });
      expect(fileFks.map((row) => row['on_delete']).toSet(), <String>{
        'CASCADE',
      });
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      await db.close();
    }
  });

  test('v18 to v19 preserves typed, asset, Folder, and Project data', () async {
    final path = p.join(tempDir.path, 'v18_to_v19.db');
    final created = await openSeam(path);
    await seedV18Data(created);
    final freshSchema = await c0Schema(created);
    await downgradeToV18(created);
    await created.close();

    final upgraded = await openSeam(path);
    try {
      expect(await userVersion(upgraded), DatabaseHelper.databaseVersion);
      expect(await c0Schema(upgraded), freshSchema);
      expect(await upgraded.query('conversations'), isEmpty);
      expect(await upgraded.query('conversation_messages'), isEmpty);
      expect(await upgraded.query('conversation_files'), isEmpty);
      expect(await upgraded.query('library_file_folders'), hasLength(1));
      expect(await upgraded.query('project_files'), hasLength(1));
      expect(await upgraded.query('project_banks'), hasLength(1));
      expect(await upgraded.query('question_v2_payloads'), hasLength(1));
      expect((await upgraded.query('review_states')).single['lapses'], 2);
      expect(await upgraded.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      await upgraded.close();
    }
  });

  test('malformed C0 schema fails atomically and leaves v18 intact', () async {
    final path = p.join(tempDir.path, 'malformed_v19.db');
    final created = await openSeam(path);
    await seedV18Data(created);
    await downgradeToV18(created);
    await created.execute('''
      CREATE TABLE conversations (
        conversation_id TEXT PRIMARY KEY NOT NULL,
        scope_kind TEXT NOT NULL,
        project_id TEXT,
        title TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await created.close();

    await expectLater(
      openSeam(path),
      throwsA(
        isA<ConversationSchemaException>().having(
          (error) => error.failure,
          'failure',
          ConversationSchemaFailure.malformedSchema,
        ),
      ),
    );

    final probe = await openRaw(path);
    try {
      expect(await userVersion(probe), 18);
      final tables = await probe.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      );
      final names = tables.map((row) => row['name']).toSet();
      expect(names, contains('conversations'));
      expect(names, isNot(contains('conversation_messages')));
      expect(names, isNot(contains('conversation_files')));
      expect(await probe.query('library_file_folders'), hasLength(1));
      expect(await probe.query('project_files'), hasLength(1));
      expect(await probe.query('question_v2_payloads'), hasLength(1));
    } finally {
      await probe.close();
    }
  });
}
