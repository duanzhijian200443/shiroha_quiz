import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _v20Objects = <String>{'parsed_artifact_heads', 'parsed_artifacts'};

const _headsDdl = '''
CREATE TABLE parsed_artifact_heads (
  file_id TEXT PRIMARY KEY NOT NULL,
  last_revision INTEGER NOT NULL CHECK(last_revision >= 0),
  FOREIGN KEY(file_id)
    REFERENCES library_files(file_id) ON DELETE CASCADE
);
''';

const _artifactsDdl = '''
CREATE TABLE parsed_artifacts (
  file_id TEXT PRIMARY KEY NOT NULL,
  artifact_id TEXT NOT NULL UNIQUE,
  revision INTEGER NOT NULL CHECK(revision > 0),
  source_sha256 TEXT NOT NULL CHECK(length(source_sha256) = 64),
  cache_key_version INTEGER NOT NULL CHECK(cache_key_version > 0),
  cache_fingerprint TEXT NOT NULL
    CHECK(length(cache_fingerprint) BETWEEN 1 AND 128),
  parser_route TEXT NOT NULL
    CHECK(length(parser_route) BETWEEN 1 AND 64),
  parser_version TEXT NOT NULL
    CHECK(length(parser_version) BETWEEN 1 AND 64),
  options_schema_version INTEGER NOT NULL
    CHECK(options_schema_version > 0),
  payload_schema_version INTEGER NOT NULL
    CHECK(payload_schema_version > 0),
  storage_key TEXT NOT NULL UNIQUE CHECK(length(storage_key) > 0),
  payload_sha256 TEXT NOT NULL CHECK(length(payload_sha256) = 64),
  size_bytes INTEGER NOT NULL CHECK(size_bytes >= 0),
  published_at INTEGER NOT NULL CHECK(published_at >= 0),
  FOREIGN KEY(file_id)
    REFERENCES parsed_artifact_heads(file_id) ON DELETE CASCADE
);
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    tempDir = await Directory.systemTemp.createTemp('f1_v20_');
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

  Future<Map<String, String>> v20Schema(Database db) async {
    final rows = await db.rawQuery(
      "SELECT name, sql FROM sqlite_master WHERE name IN (${List.filled(_v20Objects.length, '?').join(',')}) ORDER BY name",
      _v20Objects.toList(growable: false),
    );
    return <String, String>{
      for (final row in rows) row['name']! as String: row['sql']! as String,
    };
  }

  Future<void> seedV19Data(Database db) async {
    await db.insert('library_files', <String, Object?>{
      'file_id': 'file-f1',
      'display_name': 'preserved.pdf',
      'mime_type': 'application/pdf',
      'size_bytes': 3,
      'sha256':
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      'storage_key': 'library/file-f1',
      'created_at': 1700000000,
    });
    await db.insert('projects', <String, Object?>{
      'project_id': 'project-f1',
      'display_name': 'preserved project',
      'created_at': 1700000000,
    });
    await db.insert('project_files', <String, Object?>{
      'project_id': 'project-f1',
      'file_id': 'file-f1',
    });
    await db.insert('project_banks', <String, Object?>{
      'project_id': 'project-f1',
      'bank_name': 'preserved bank',
    });
    await db.insert('library_folders', <String, Object?>{
      'folder_id': 'folder-f1',
      'display_name': '资料',
      'created_at': 1700000000,
    });
    await db.insert('library_file_folders', <String, Object?>{
      'file_id': 'file-f1',
      'folder_id': 'folder-f1',
    });
    await db.insert('conversations', <String, Object?>{
      'conversation_id': 'conversation-f1',
      'scope_kind': 'global',
      'project_id': null,
      'title': 'preserved conversation',
      'created_at': 1700000000,
      'updated_at': 1700000000,
    });
    await db.insert('conversation_messages', <String, Object?>{
      'message_id': 'message-f1',
      'conversation_id': 'conversation-f1',
      'sequence': 1,
      'role': 'user',
      'content': 'preserved message',
      'created_at': 1700000000,
    });
    await db.insert('conversation_files', <String, Object?>{
      'conversation_id': 'conversation-f1',
      'file_id': 'file-f1',
      'attached_at': 1700000000,
    });
    await db.insert('questions', <String, Object?>{
      'id': 'q-f1',
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
      'question_id': 'q-f1',
      'payload_schema_version': 2,
      'payload_json': '{"schemaVersion":2,"synthetic":true}',
    });
    await db.insert('review_states', <String, Object?>{
      'question_id': 'q-f1',
      'state': 3,
      'lapses': 2,
      'difficulty': 3.0,
      'stability': 8.0,
      'reps': 4,
    });
  }

  Future<void> downgradeToV19(Database db) async {
    await db.execute('DROP TABLE parsed_artifacts');
    await db.execute('DROP TABLE parsed_artifact_heads');
    await db.execute('PRAGMA user_version = 19');
  }

  test('fresh v20 creates exact parsed artifact tables and foreign keys',
      () async {
    final db = await openSeam(inMemoryDatabasePath);
    try {
      expect(await userVersion(db), 21);
      final schema = await v20Schema(db);
      expect(schema.keys.toSet(), _v20Objects);
      expect(_normalized(schema['parsed_artifact_heads']!),
          _normalized(_headsDdl));
      expect(
          _normalized(schema['parsed_artifacts']!), _normalized(_artifactsDdl));

      final heads =
          await db.rawQuery('PRAGMA table_info(parsed_artifact_heads)');
      expect(
        heads
            .map(
              (row) =>
                  '${row['name']}|${row['type']}|${row['notnull']}|${row['pk']}',
            )
            .toList(),
        <String>['file_id|TEXT|1|1', 'last_revision|INTEGER|1|0'],
      );
      final artifacts =
          await db.rawQuery('PRAGMA table_info(parsed_artifacts)');
      expect(artifacts, hasLength(14));

      final headFk = await db.rawQuery(
        'PRAGMA foreign_key_list(parsed_artifact_heads)',
      );
      expect(headFk.single['table'], 'library_files');
      expect(headFk.single['on_delete'], 'CASCADE');
      final artifactFks = await db.rawQuery(
        'PRAGMA foreign_key_list(parsed_artifacts)',
      );
      expect(artifactFks.map((row) => row['table']).toSet(), <String>{
        'parsed_artifact_heads',
      });
      expect(artifactFks.map((row) => row['on_delete']).toSet(), <String>{
        'CASCADE',
      });

      final indexes = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND tbl_name IN ('parsed_artifact_heads', 'parsed_artifacts') "
        "AND name NOT LIKE 'sqlite_autoindex%'",
      );
      expect(indexes, isEmpty);
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      await db.close();
    }
  });

  test('v19 to v20 preserves typed, asset, Folder, Project, and C0 data',
      () async {
    final path = p.join(tempDir.path, 'v19_to_v20.db');
    final created = await openSeam(path);
    await seedV19Data(created);
    final freshSchema = await v20Schema(created);
    await downgradeToV19(created);
    await created.close();

    final upgraded = await openSeam(path);
    try {
      expect(await userVersion(upgraded), 21);
      expect(await v20Schema(upgraded), freshSchema);
      expect(await upgraded.query('library_files'), hasLength(1));
      expect(await upgraded.query('projects'), hasLength(1));
      expect(await upgraded.query('project_files'), hasLength(1));
      expect(await upgraded.query('project_banks'), hasLength(1));
      expect(await upgraded.query('library_folders'), hasLength(1));
      expect(await upgraded.query('library_file_folders'), hasLength(1));
      expect(await upgraded.query('conversations'), hasLength(1));
      expect(await upgraded.query('conversation_messages'), hasLength(1));
      expect(await upgraded.query('conversation_files'), hasLength(1));
      expect(await upgraded.query('question_v2_payloads'), hasLength(1));
      expect((await upgraded.query('review_states')).single['lapses'], 2);
      expect(await upgraded.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      await upgraded.close();
    }
  });

  test('repeated reopen at v20 is stable', () async {
    final path = p.join(tempDir.path, 'reopen_v20.db');
    final first = await openSeam(path);
    final firstSchema = await v20Schema(first);
    await first.close();

    final second = await openSeam(path);
    try {
      expect(await userVersion(second), 21);
      expect(await v20Schema(second), firstSchema);
      expect(await second.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      await second.close();
    }
  });

  test('malformed preexisting v20 schema fails atomically and leaves v19',
      () async {
    final path = p.join(tempDir.path, 'malformed_v20.db');
    final created = await openSeam(path);
    await seedV19Data(created);
    await downgradeToV19(created);
    await created.execute('''
      CREATE TABLE parsed_artifacts (
        file_id TEXT PRIMARY KEY NOT NULL,
        artifact_id TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK(revision > 0),
        source_sha256 TEXT NOT NULL CHECK(length(source_sha256) = 64),
        cache_key_version INTEGER NOT NULL CHECK(cache_key_version > 0),
        cache_fingerprint TEXT NOT NULL
          CHECK(length(cache_fingerprint) BETWEEN 1 AND 128),
        parser_route TEXT NOT NULL
          CHECK(length(parser_route) BETWEEN 1 AND 64),
        parser_version TEXT NOT NULL
          CHECK(length(parser_version) BETWEEN 1 AND 64),
        options_schema_version INTEGER NOT NULL
          CHECK(options_schema_version > 0),
        payload_schema_version INTEGER NOT NULL
          CHECK(payload_schema_version > 0),
        storage_key TEXT NOT NULL UNIQUE CHECK(length(storage_key) > 0),
        payload_sha256 TEXT NOT NULL CHECK(length(payload_sha256) = 64),
        size_bytes INTEGER NOT NULL CHECK(size_bytes >= 0),
        published_at INTEGER NOT NULL CHECK(published_at >= 0),
        FOREIGN KEY(file_id)
          REFERENCES parsed_artifact_heads(file_id) ON DELETE CASCADE
      )
    ''');
    await created.close();

    await expectLater(
      openSeam(path),
      throwsA(
        isA<ParsedArtifactSchemaException>().having(
          (error) => error.failure,
          'failure',
          ParsedArtifactSchemaFailure.malformedSchema,
        ),
      ),
    );

    final probe = await openRaw(path);
    try {
      expect(await userVersion(probe), 19);
      final tables = await probe.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      );
      final names = tables.map((row) => row['name']).toSet();
      expect(names, contains('parsed_artifacts'));
      expect(names, isNot(contains('parsed_artifact_heads')));
      expect(await probe.query('library_files'), hasLength(1));
      expect(await probe.query('projects'), hasLength(1));
      expect(await probe.query('conversations'), hasLength(1));
      expect(await probe.query('question_v2_payloads'), hasLength(1));
      expect(await probe.query('review_states'), hasLength(1));
    } finally {
      await probe.close();
    }
  });

  test('deleting a LibraryFile cascades only artifact head and current rows',
      () async {
    final db = await openSeam(inMemoryDatabasePath);
    try {
      await db.insert('library_files', <String, Object?>{
        'file_id': 'file-f1',
        'display_name': 'preserved.pdf',
        'mime_type': 'application/pdf',
        'size_bytes': 3,
        'sha256':
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        'storage_key': 'library/file-f1',
        'created_at': 1700000000,
      });
      await db.insert('parsed_artifact_heads', <String, Object?>{
        'file_id': 'file-f1',
        'last_revision': 1,
      });
      await db.insert('parsed_artifacts', <String, Object?>{
        'file_id': 'file-f1',
        'artifact_id': 'artifact-f1',
        'revision': 1,
        'source_sha256':
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        'cache_key_version': 1,
        'cache_fingerprint': 'fingerprint-v1',
        'parser_route': 'pdf_text',
        'parser_version': '1.0.0',
        'options_schema_version': 1,
        'payload_schema_version': 1,
        'storage_key': 'artifacts/artifact-f1.json',
        'payload_sha256':
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        'size_bytes': 42,
        'published_at': 1700000000000,
      });
      await db.insert('questions', <String, Object?>{
        'id': 'q-f1',
        'type': 0,
        'content': 'synthetic stem',
        'options': jsonEncode(<String>['A', 'B']),
        'standard_answer': 'A',
        'explanation': 'synthetic explanation',
        'raw_explanation': 'synthetic raw',
        'created_at': 1700000000,
        'bank_name': 'preserved bank',
      });
      await db.insert('review_states', <String, Object?>{
        'question_id': 'q-f1',
        'state': 3,
        'lapses': 2,
        'difficulty': 3.0,
        'stability': 8.0,
        'reps': 4,
      });

      await db.delete('library_files',
          where: 'file_id = ?', whereArgs: <Object?>['file-f1']);

      expect(await db.query('parsed_artifact_heads'), isEmpty);
      expect(await db.query('parsed_artifacts'), isEmpty);
      expect(await db.query('questions'), hasLength(1));
      expect(await db.query('review_states'), hasLength(1));
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      await db.close();
    }
  });
}

String _normalized(String sql) =>
    sql.replaceAll(RegExp(r'\s+'), '').replaceAll(';', '');
