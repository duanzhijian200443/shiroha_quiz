// F0 v16 additive migration matrix.
//
// All databases in this file are synthetic temp files created by the test
// framework. No real application database, private document, OCR, Replay,
// Provider, or network path is touched.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Independent copy of the frozen library_files definition with deliberately
/// different formatting, used to prove canonical SQL equality.
const String _libraryFilesDdl = '''
CREATE TABLE library_files (
    file_id TEXT PRIMARY KEY NOT NULL,
    display_name TEXT NOT NULL CHECK ( length(display_name) > 0 ),
    mime_type TEXT NOT NULL CHECK ( length(mime_type) > 0 ),
    size_bytes INTEGER NOT NULL CHECK ( size_bytes >= 0 ),
    sha256 TEXT NOT NULL CHECK ( length(sha256) = 64 ),
    storage_key TEXT NOT NULL UNIQUE CHECK ( length(storage_key) > 0 ),
    created_at INTEGER NOT NULL
);
''';

const List<String> _expectedColumns = <String>[
  'file_id',
  'display_name',
  'mime_type',
  'size_bytes',
  'sha256',
  'storage_key',
  'created_at',
];

/// Independent, simpler canonicalizer used only to compare accepted stored
/// SQL against the frozen definition.
String testCanonical(String sql) {
  var s = sql.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), ' ');
  s = s.replaceAll(RegExp(r'--[^\n]*'), ' ');
  s = s.toLowerCase();
  s = s
      .replaceAll('"', '')
      .replaceAll('`', '')
      .replaceAll('[', '')
      .replaceAll(']', '');
  s = s.replaceAllMapped(
    RegExp(r'\s*([(),;])\s*'),
    (match) => ' ${match[1]} ',
  );
  s = s.replaceAllMapped(
    RegExp(r'\s*(>=|<=|!=|<>|==|>|<|=)\s*'),
    (match) => ' ${match[1]} ',
  );
  s = s.replaceAll(RegExp(r'\s+'), ' ');
  s = s.trim();
  if (s.endsWith(';')) {
    s = s.substring(0, s.length - 1).trim();
  }
  s = s.replaceFirst(
    RegExp(r'^create table if not exists '),
    'create table ',
  );
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    tempDir = await Directory.systemTemp.createTemp('f0_v16_');
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  String dbPath(String name) => p.join(tempDir.path, name);

  Future<Database> openSeam(String path) =>
      DatabaseHelper.instance.openPathForTesting(path);

  Future<Database> openRaw(String path) {
    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(),
    );
  }

  Future<void> setUserVersion(Database db, int version) async {
    await db.execute('PRAGMA user_version = $version');
  }

  Future<int> userVersion(Database db) async {
    final rows = await db.rawQuery('PRAGMA user_version');
    return rows.single['user_version'] as int;
  }

  Future<String> tableSql(Database db, String table) async {
    final rows = await db.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
      <Object?>[table],
    );
    return rows.single['sql'] as String;
  }

  Future<void> expectCanonicalLibraryFiles(Database db) async {
    final stored = await tableSql(db, 'library_files');
    expect(testCanonical(stored), testCanonical(_libraryFilesDdl));

    final columns = await db.rawQuery('PRAGMA table_info(library_files)');
    expect(
      columns.map((row) => row['name']).toList(),
      _expectedColumns,
    );
    expect(
      columns.map((row) => (row['type'] as String).toUpperCase()).toList(),
      <String>[
        'TEXT',
        'TEXT',
        'TEXT',
        'INTEGER',
        'TEXT',
        'TEXT',
        'INTEGER',
      ],
    );
    expect(columns.map((row) => row['notnull']).toList(),
        <int>[1, 1, 1, 1, 1, 1, 1]);
    expect(
      columns.map((row) => row['pk']).toList(),
      <int>[1, 0, 0, 0, 0, 0, 0],
    );

    final indexes = await db.rawQuery('PRAGMA index_list(library_files)');
    final uniqueIndexes = indexes.where((row) => row['origin'] == 'u').toList();
    expect(uniqueIndexes, hasLength(1));
    final indexColumns = await db.rawQuery(
      'PRAGMA index_info(${uniqueIndexes.single['name']})',
    );
    expect(
      indexColumns.map((row) => row['name']).toList(),
      <String>['storage_key'],
    );
  }

  Future<void> seedTypedAndReviewData(Database db) async {
    await db.insert('questions', <String, Object?>{
      'id': 'q_f0_1',
      'type': 0,
      'content': 'typed stem one',
      'options': jsonEncode(<String>['A. one', 'B. two']),
      'standard_answer': 'A',
      'explanation': 'typed explanation',
      'raw_explanation': 'typed raw',
      'created_at': 1700000001,
      'bank_name': 'f0_bank',
    });
    await db.insert('question_v2_payloads', <String, Object?>{
      'question_id': 'q_f0_1',
      'payload_schema_version': 2,
      'payload_json': '{"schemaVersion":2,"f0":true,"preserve":"exact"}',
    });
    await db.insert('review_states', <String, Object?>{
      'question_id': 'q_f0_1',
      'state': 3,
      'next_review_time': 1700002000,
      'lapses': 4,
      'difficulty': 2.5,
      'stability': 9.5,
      'reps': 7,
      'last_lapse_time': 1700000500,
      'last_review_time': 1700001000,
    });
    await db.insert('import_tasks', <String, Object?>{
      'id': 'task_f0_1',
      'title': 'f0 task',
      'status': 1,
      'progress_text': 'pending',
      'percent': 0.0,
      'created_at': 1700000000,
    });
  }

  test('fresh v16 create matches the frozen library_files contract', () async {
    final db = await openSeam(inMemoryDatabasePath);
    try {
      expect(await userVersion(db), 18);
      expect(
        (await db.rawQuery('PRAGMA foreign_keys')).single.values.single,
        1,
      );
      await expectCanonicalLibraryFiles(db);
      expect(await db.query('library_files'), isEmpty);
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
    } finally {
      await db.close();
    }
  });

  test('v15 to v16 preserves typed questions and review state', () async {
    final path = dbPath('v15_to_v16.db');
    final created = await openSeam(path);
    await seedTypedAndReviewData(created);
    await created.close();

    final raw = await openRaw(path);
    await raw.execute('DROP TABLE library_files');
    await setUserVersion(raw, 15);
    await raw.close();

    final upgraded = await openSeam(path);
    try {
      expect(await userVersion(upgraded), 18);
      await expectCanonicalLibraryFiles(upgraded);
      expect(await upgraded.query('library_files'), isEmpty);

      final sidecar = (await upgraded.query(
        'question_v2_payloads',
        where: 'question_id = ?',
        whereArgs: <Object?>['q_f0_1'],
      ))
          .single;
      expect(sidecar['payload_schema_version'], 2);
      expect(sidecar['payload_json'],
          '{"schemaVersion":2,"f0":true,"preserve":"exact"}');

      final review = (await upgraded.query(
        'review_states',
        where: 'question_id = ?',
        whereArgs: <Object?>['q_f0_1'],
      ))
          .single;
      expect(review['state'], 3);
      expect(review['lapses'], 4);
      expect(review['difficulty'], 2.5);
      expect(review['stability'], 9.5);

      final question = (await upgraded.query(
        'questions',
        where: 'id = ?',
        whereArgs: <Object?>['q_f0_1'],
      ))
          .single;
      expect(question['content'], 'typed stem one');
      expect(question['standard_answer'], 'A');
      expect(question['raw_explanation'], 'typed raw');
      expect((await upgraded.query('import_tasks')).single['title'], 'f0 task');
      expect(await upgraded.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      await upgraded.close();
    }

    // Reopen at v16 is idempotent and retains everything.
    final reopened = await openSeam(path);
    try {
      expect(await userVersion(reopened), 18);
      expect(
        await reopened.query(
          'question_v2_payloads',
          where: 'question_id = ?',
          whereArgs: <Object?>['q_f0_1'],
        ),
        hasLength(1),
      );
    } finally {
      await reopened.close();
    }
  });

  test('v14 still migrates through v16 with sidecar and library tables',
      () async {
    final path = dbPath('v14_to_v16.db');
    final created = await openSeam(path);
    await seedTypedAndReviewData(created);
    await created.close();

    final raw = await openRaw(path);
    await raw.execute('DROP TABLE library_files');
    await raw.execute('DROP TABLE question_v2_payloads');
    await setUserVersion(raw, 14);
    await raw.close();

    final upgraded = await openSeam(path);
    try {
      expect(await userVersion(upgraded), 18);
      await expectCanonicalLibraryFiles(upgraded);
      // The v14 fixture dropped the sidecar table entirely, so v16 recreates
      // it empty; the underlying rows and review state must survive.
      expect(await upgraded.query('question_v2_payloads'), isEmpty);
      expect(
        (await upgraded.query(
          'review_states',
          where: 'question_id = ?',
          whereArgs: <Object?>['q_f0_1'],
        ))
            .single['lapses'],
        4,
      );
    } finally {
      await upgraded.close();
    }
  });

  test('duplicate storage keys are rejected by the table constraint', () async {
    final db = await openSeam(inMemoryDatabasePath);
    try {
      final row = <String, Object?>{
        'file_id': 'file-v16-0001',
        'display_name': 'a.pdf',
        'mime_type': 'application/pdf',
        'size_bytes': 3,
        'sha256':
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        'storage_key': 'library/file-v16-0001',
        'created_at': 1700000000,
      };
      await db.insert('library_files', row);
      await expectLater(
        db.insert('library_files', {
          ...row,
          'file_id': 'file-v16-0002',
          'storage_key': 'library/file-v16-0001',
        }),
        throwsA(isA<DatabaseException>()),
      );
    } finally {
      await db.close();
    }
  });

  test('malformed library_files schema fails the open safely', () async {
    final path = dbPath('malformed_library.db');
    final created = await openSeam(path);
    await created.close();

    final raw = await openRaw(path);
    await raw.execute('DROP TABLE library_files');
    await raw.execute('''
      CREATE TABLE library_files (
        file_id TEXT PRIMARY KEY NOT NULL,
        display_name TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        sha256 TEXT NOT NULL,
        storage_key TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await setUserVersion(raw, 15);
    await raw.close();

    LibraryFilesSchemaException? caught;
    try {
      await openSeam(path);
    } on LibraryFilesSchemaException catch (error) {
      caught = error;
    }
    expect(caught, isNotNull);
    expect(caught!.failure, LibraryFilesSchemaFailure.malformedTable);
    expect(
      caught.toString(),
      'LibraryFilesSchemaException(malformedTable): '
      'The library_files table does not match the frozen v16 definition.',
    );

    final probe = await openRaw(path);
    expect(await userVersion(probe), 15);
    expect(
      await tableSql(probe, 'library_files'),
      isNot(contains('CHECK')),
    );
    await probe.close();
  });
}
