// J0 v16 -> v17 additive migration matrix.
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

/// Independent copy of the frozen v17 Project definitions with deliberately
/// different formatting, used to prove canonical SQL equality.
const String _projectsDdl = '''
CREATE TABLE projects (
    project_id TEXT PRIMARY KEY NOT NULL,
    display_name TEXT NOT NULL CHECK ( length(display_name) > 0 ),
    created_at INTEGER NOT NULL
);
''';

const String _projectFilesDdl = '''
CREATE TABLE project_files (
    project_id TEXT NOT NULL,
    file_id TEXT NOT NULL,
    PRIMARY KEY ( project_id, file_id ),
    FOREIGN KEY ( project_id ) REFERENCES projects( project_id ) ON DELETE CASCADE,
    FOREIGN KEY ( file_id ) REFERENCES library_files( file_id ) ON DELETE CASCADE
);
''';

const String _projectBanksDdl = '''
CREATE TABLE project_banks (
    project_id TEXT NOT NULL,
    bank_name TEXT NOT NULL CHECK ( length(bank_name) > 0 ),
    PRIMARY KEY ( project_id, bank_name ),
    FOREIGN KEY ( project_id ) REFERENCES projects( project_id ) ON DELETE CASCADE
);
''';

const Map<String, List<String>> _expectedColumns = <String, List<String>>{
  'projects': <String>['project_id', 'display_name', 'created_at'],
  'project_files': <String>['project_id', 'file_id'],
  'project_banks': <String>['project_id', 'bank_name'],
};

/// Independent, simpler canonicalizer used only to compare accepted stored
/// SQL against the frozen definitions.
String testCanonical(String sql) {
  var s = sql.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), ' ');
  s = s.replaceAll(RegExp(r'--[^\n]*'), ' ');
  s = s.toLowerCase();
  s = s
      .replaceAll('"', '')
      .replaceAll('`', '')
      .replaceAll('[', '')
      .replaceAll(']', '');
  s = s.replaceAllMapped(RegExp(r'\s*([(),;])\s*'), (match) => ' ${match[1]} ');
  s = s.replaceAllMapped(
    RegExp(r'\s*(>=|<=|!=|<>|==|>|<|=)\s*'),
    (match) => ' ${match[1]} ',
  );
  s = s.replaceAll(RegExp(r'\s+'), ' ');
  s = s.trim();
  if (s.endsWith(';')) {
    s = s.substring(0, s.length - 1).trim();
  }
  s = s.replaceFirst(RegExp(r'^create table if not exists '), 'create table ');
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
    tempDir = await Directory.systemTemp.createTemp('j0_v17_');
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
    return databaseFactory.openDatabase(path, options: OpenDatabaseOptions());
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

  Future<void> expectCanonicalProjectTables(Database db) async {
    final expectedSql = <String, String>{
      'projects': _projectsDdl,
      'project_files': _projectFilesDdl,
      'project_banks': _projectBanksDdl,
    };
    for (final entry in expectedSql.entries) {
      final stored = await tableSql(db, entry.key);
      expect(
        testCanonical(stored),
        testCanonical(entry.value),
        reason: 'canonical SQL mismatch for ${entry.key}',
      );

      final columns = await db.rawQuery('PRAGMA table_info(${entry.key})');
      expect(
        columns.map((row) => row['name']).toList(),
        _expectedColumns[entry.key],
      );
    }

    final filesColumns = await db.rawQuery('PRAGMA table_info(project_files)');
    expect(filesColumns.map((row) => row['pk']).toList(), <int>[1, 2]);
    final banksColumns = await db.rawQuery('PRAGMA table_info(project_banks)');
    expect(banksColumns.map((row) => row['pk']).toList(), <int>[1, 2]);
    final projectsColumns = await db.rawQuery('PRAGMA table_info(projects)');
    expect(projectsColumns.map((row) => row['pk']).toList(), <int>[1, 0, 0]);

    final filesFks = await db.rawQuery(
      'PRAGMA foreign_key_list(project_files)',
    );
    expect(filesFks.map((row) => row['table']).toSet(), <String>{
      'projects',
      'library_files',
    });
    final banksFks = await db.rawQuery(
      'PRAGMA foreign_key_list(project_banks)',
    );
    expect(banksFks.map((row) => row['table']).toSet(), <String>{'projects'});
  }

  Future<void> seedTypedAndReviewData(Database db) async {
    await db.insert('questions', <String, Object?>{
      'id': 'q_j0_typed',
      'type': 0,
      'content': 'typed stem one',
      'options': jsonEncode(<String>['A. one', 'B. two']),
      'standard_answer': 'A',
      'explanation': 'typed explanation',
      'raw_explanation': 'typed raw',
      'created_at': 1700000001,
      'bank_name': 'j0_bank',
    });
    await db.insert('questions', <String, Object?>{
      'id': 'q_j0_legacy',
      'type': 1,
      'content': 'legacy stem',
      'options': '[]',
      'standard_answer': 'B',
      'explanation': 'legacy explanation',
      'created_at': 1700000003,
      'bank_name': 'legacy_bank',
    });
    await db.insert('question_v2_payloads', <String, Object?>{
      'question_id': 'q_j0_typed',
      'payload_schema_version': 2,
      'payload_json': '{"schemaVersion":2,"j0":true,"preserve":"exact"}',
    });
    await db.insert('review_states', <String, Object?>{
      'question_id': 'q_j0_typed',
      'state': 3,
      'next_review_time': 1700002000,
      'lapses': 4,
      'difficulty': 2.5,
      'stability': 9.5,
      'reps': 7,
      'last_lapse_time': 1700000500,
      'last_review_time': 1700001000,
    });
    await db.insert('library_files', <String, Object?>{
      'file_id': 'file-j0-0001',
      'display_name': 'report.pdf',
      'mime_type': 'application/pdf',
      'size_bytes': 3,
      'sha256':
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      'storage_key': 'library/file-j0-0001',
      'created_at': 1700000000,
    });
    await db.insert('import_tasks', <String, Object?>{
      'id': 'task_j0_1',
      'title': 'j0 task',
      'status': 1,
      'progress_text': 'pending',
      'percent': 0.0,
      'created_at': 1700000000,
    });
  }

  test('fresh v17 create matches the frozen J0 Project contract', () async {
    final db = await openSeam(inMemoryDatabasePath);
    try {
      expect(await userVersion(db), 21);
      expect(
        (await db.rawQuery('PRAGMA foreign_keys')).single.values.single,
        1,
      );
      await expectCanonicalProjectTables(db);
      expect(await db.query('projects'), isEmpty);
      expect(await db.query('project_files'), isEmpty);
      expect(await db.query('project_banks'), isEmpty);
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      await db.close();
    }
  });

  test(
      'v16 to v17 preserves files, typed and legacy questions, sidecars, '
      'and review state', () async {
    final path = dbPath('v16_to_v17.db');
    final created = await openSeam(path);
    await seedTypedAndReviewData(created);
    await created.close();

    final raw = await openRaw(path);
    await raw.execute('DROP TABLE project_files');
    await raw.execute('DROP TABLE project_banks');
    await raw.execute('DROP TABLE projects');
    await setUserVersion(raw, 16);
    await raw.close();

    final upgraded = await openSeam(path);
    try {
      expect(await userVersion(upgraded), 21);
      await expectCanonicalProjectTables(upgraded);
      expect(await upgraded.query('projects'), isEmpty);
      expect(await upgraded.query('project_files'), isEmpty);
      expect(await upgraded.query('project_banks'), isEmpty);

      final file = (await upgraded.query(
        'library_files',
        where: 'file_id = ?',
        whereArgs: <Object?>['file-j0-0001'],
      ))
          .single;
      expect(file['display_name'], 'report.pdf');
      expect(file['storage_key'], 'library/file-j0-0001');

      final sidecar = (await upgraded.query(
        'question_v2_payloads',
        where: 'question_id = ?',
        whereArgs: <Object?>['q_j0_typed'],
      ))
          .single;
      expect(sidecar['payload_schema_version'], 2);
      expect(
        sidecar['payload_json'],
        '{"schemaVersion":2,"j0":true,"preserve":"exact"}',
      );

      final review = (await upgraded.query(
        'review_states',
        where: 'question_id = ?',
        whereArgs: <Object?>['q_j0_typed'],
      ))
          .single;
      expect(review['state'], 3);
      expect(review['lapses'], 4);
      expect(review['stability'], 9.5);

      final typed = (await upgraded.query(
        'questions',
        where: 'id = ?',
        whereArgs: <Object?>['q_j0_typed'],
      ))
          .single;
      expect(typed['content'], 'typed stem one');
      expect(typed['raw_explanation'], 'typed raw');

      final legacy = (await upgraded.query(
        'questions',
        where: 'id = ?',
        whereArgs: <Object?>['q_j0_legacy'],
      ))
          .single;
      expect(legacy['content'], 'legacy stem');
      expect(legacy['bank_name'], 'legacy_bank');
      expect((await upgraded.query('import_tasks')).single['title'], 'j0 task');
      expect(await upgraded.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      await upgraded.close();
    }

    // Reopen at v17 is idempotent and retains everything.
    final reopened = await openSeam(path);
    try {
      expect(await userVersion(reopened), 21);
      expect(
        await reopened.query(
          'question_v2_payloads',
          where: 'question_id = ?',
          whereArgs: <Object?>['q_j0_typed'],
        ),
        hasLength(1),
      );
    } finally {
      await reopened.close();
    }
  });

  test(
    'v15 migrates through v17 with sidecar, library, and Project tables',
    () async {
      final path = dbPath('v15_to_v17.db');
      final created = await openSeam(path);
      await seedTypedAndReviewData(created);
      await created.close();

      final raw = await openRaw(path);
      await raw.execute('DROP TABLE project_files');
      await raw.execute('DROP TABLE project_banks');
      await raw.execute('DROP TABLE projects');
      await raw.execute('DROP TABLE library_files');
      await setUserVersion(raw, 15);
      await raw.close();

      final upgraded = await openSeam(path);
      try {
        expect(await userVersion(upgraded), 21);
        await expectCanonicalProjectTables(upgraded);
        expect(
          (await upgraded.query(
            'review_states',
            where: 'question_id = ?',
            whereArgs: <Object?>['q_j0_typed'],
          ))
              .single['lapses'],
          4,
        );
      } finally {
        await upgraded.close();
      }
    },
  );

  test('malformed Project schema fails the open atomically (L)', () async {
    final path = dbPath('malformed_projects.db');
    final created = await openSeam(path);
    await seedTypedAndReviewData(created);
    await created.close();

    final raw = await openRaw(path);
    await raw.execute('DROP TABLE project_files');
    await raw.execute('DROP TABLE project_banks');
    await raw.execute('DROP TABLE projects');
    await raw.execute('''
      CREATE TABLE projects (
        project_id TEXT PRIMARY KEY NOT NULL,
        display_name TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await setUserVersion(raw, 16);
    await raw.close();

    ProjectSchemaException? caught;
    try {
      await openSeam(path);
    } on ProjectSchemaException catch (error) {
      caught = error;
    }
    expect(caught, isNotNull);
    expect(caught!.failure, ProjectSchemaFailure.malformedTable);
    expect(
      caught.toString(),
      'ProjectSchemaException(malformedTable): '
      'The J0 Project tables do not match the frozen v17 definition.',
    );

    final probe = await openRaw(path);
    expect(await userVersion(probe), 16);
    // The failed upgrade rolled back completely: no half-created relation
    // tables remain and the pre-existing malformed projects table is intact.
    expect(await tableSql(probe, 'projects'), isNot(contains('CHECK')));
    final tableNames = (await probe.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    ))
        .map((row) => row['name'])
        .toList();
    expect(tableNames, isNot(contains('project_files')));
    expect(tableNames, isNot(contains('project_banks')));
    // Preservation still holds: pre-migration data was not disturbed.
    expect(
      await probe.query(
        'library_files',
        where: 'file_id = ?',
        whereArgs: <Object?>['file-j0-0001'],
      ),
      hasLength(1),
    );
    expect(await probe.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    await probe.close();
  });
}
