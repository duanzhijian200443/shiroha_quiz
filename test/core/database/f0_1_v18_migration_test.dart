import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
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
    tempDir = await Directory.systemTemp.createTemp('f0_1_v18_');
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

  Future<void> expectV18Shape(Database db) async {
    final folders = await db.rawQuery('PRAGMA table_info(library_folders)');
    expect(
      folders.map((row) => row['name']).toList(),
      <String>['folder_id', 'display_name', 'created_at'],
    );
    expect(folders.map((row) => row['pk']).toList(), <int>[1, 0, 0]);

    final relations = await db.rawQuery(
      'PRAGMA table_info(library_file_folders)',
    );
    expect(
      relations.map((row) => row['name']).toList(),
      <String>['file_id', 'folder_id'],
    );
    expect(relations.map((row) => row['pk']).toList(), <int>[1, 0]);

    final foreignKeys = await db.rawQuery(
      'PRAGMA foreign_key_list(library_file_folders)',
    );
    expect(foreignKeys.map((row) => row['table']).toSet(), <String>{
      'library_files',
      'library_folders',
    });
    expect(
      foreignKeys.map((row) => row['on_delete']).toSet(),
      <String>{'CASCADE'},
    );

    final folderIndexes = await db.rawQuery(
      'PRAGMA index_list(library_folders)',
    );
    expect(
      folderIndexes.singleWhere(
        (row) => row['name'] == 'idx_library_folders_display_name_nocase',
      )['unique'],
      1,
    );
    final relationIndexes = await db.rawQuery(
      'PRAGMA index_list(library_file_folders)',
    );
    expect(
      relationIndexes.any(
        (row) => row['name'] == 'idx_library_file_folders_folder_id',
      ),
      isTrue,
    );
  }

  Future<void> seedV17Data(Database db) async {
    await db.insert('library_files', <String, Object?>{
      'file_id': 'file-v18',
      'display_name': 'preserved.pdf',
      'mime_type': 'application/pdf',
      'size_bytes': 3,
      'sha256':
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      'storage_key': 'library/file-v18',
      'created_at': 1700000000,
    });
    await db.insert('projects', <String, Object?>{
      'project_id': 'project-v18',
      'display_name': 'preserved project',
      'created_at': 1700000000,
    });
    await db.insert('project_files', <String, Object?>{
      'project_id': 'project-v18',
      'file_id': 'file-v18',
    });
    await db.insert('questions', <String, Object?>{
      'id': 'q-v18',
      'type': 0,
      'content': 'synthetic stem',
      'options': jsonEncode(<String>['A', 'B']),
      'standard_answer': 'A',
      'explanation': 'synthetic explanation',
      'raw_explanation': 'synthetic raw',
      'created_at': 1700000000,
      'bank_name': 'synthetic bank',
    });
    await db.insert('question_v2_payloads', <String, Object?>{
      'question_id': 'q-v18',
      'payload_schema_version': 2,
      'payload_json': '{"schemaVersion":2,"synthetic":true}',
    });
    await db.insert('review_states', <String, Object?>{
      'question_id': 'q-v18',
      'state': 3,
      'lapses': 2,
      'difficulty': 3.0,
      'stability': 8.0,
      'reps': 4,
    });
  }

  test('fresh current schema retains exact v18 Folder tables and constraints',
      () async {
    final db = await openSeam(inMemoryDatabasePath);
    try {
      expect(await userVersion(db), 19);
      await expectV18Shape(db);
      expect(await db.query('library_folders'), isEmpty);
      expect(await db.query('library_file_folders'), isEmpty);
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      await db.close();
    }
  });

  test('v17 to v18 preserves files, Project, sidecar, and review state',
      () async {
    final path = p.join(tempDir.path, 'v17_to_v18.db');
    final created = await openSeam(path);
    await seedV17Data(created);
    await created.close();

    final raw = await openRaw(path);
    await raw.execute('DROP TABLE library_file_folders');
    await raw.execute('DROP TABLE library_folders');
    await raw.execute('PRAGMA user_version = 17');
    await raw.close();

    final upgraded = await openSeam(path);
    try {
      expect(await userVersion(upgraded), 19);
      await expectV18Shape(upgraded);
      expect(await upgraded.query('library_folders'), isEmpty);
      expect(await upgraded.query('library_file_folders'), isEmpty);
      expect(
        (await upgraded.query('library_files')).single['storage_key'],
        'library/file-v18',
      );
      expect(await upgraded.query('project_files'), hasLength(1));
      expect(
        (await upgraded.query('question_v2_payloads'))
            .single['payload_schema_version'],
        2,
      );
      expect((await upgraded.query('review_states')).single['lapses'], 2);
      expect(await upgraded.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      await upgraded.close();
    }
  });

  test('malformed v18 schema fails atomically and leaves v17 intact', () async {
    final path = p.join(tempDir.path, 'malformed_v18.db');
    final created = await openSeam(path);
    await seedV17Data(created);
    await created.close();

    final raw = await openRaw(path);
    await raw.execute('DROP TABLE library_file_folders');
    await raw.execute('DROP TABLE library_folders');
    await raw.execute('''
      CREATE TABLE library_folders (
        folder_id TEXT PRIMARY KEY NOT NULL,
        display_name TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await raw.execute('PRAGMA user_version = 17');
    await raw.close();

    await expectLater(
      openSeam(path),
      throwsA(
        isA<LibraryFolderSchemaException>().having(
          (error) => error.failure,
          'failure',
          LibraryFolderSchemaFailure.malformedSchema,
        ),
      ),
    );

    final probe = await openRaw(path);
    try {
      expect(await userVersion(probe), 17);
      final tables = await probe.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      );
      expect(
        tables.map((row) => row['name']),
        isNot(contains('library_file_folders')),
      );
      expect(await probe.query('library_files'), hasLength(1));
      expect(await probe.query('project_files'), hasLength(1));
    } finally {
      await probe.close();
    }
  });
}
