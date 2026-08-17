import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/retrieval_v21_schema.dart';
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
    tempDir = await Directory.systemTemp.createTemp('rag1_v21_');
  });
  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test(
      'fresh v21 creates retrieval cache, FTS, triggers, and no question changes',
      () async {
    final db =
        await DatabaseHelper.instance.openPathForTesting(inMemoryDatabasePath);
    try {
      expect((await db.rawQuery('PRAGMA user_version')).single['user_version'],
          23);
      final objects = await db.rawQuery(
          "SELECT type, name FROM sqlite_master WHERE name LIKE 'retrieval_%' ORDER BY name");
      expect(
          objects.map((row) => row['name']).toSet(),
          containsAll(<String>{
            'retrieval_index_builds',
            'retrieval_index_heads',
            'retrieval_chunks',
            'retrieval_chunks_fts',
            'retrieval_chunks_ai',
            'retrieval_chunks_ad',
            'retrieval_chunks_au',
          }));
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect(
          await db.rawQuery(
              "SELECT name FROM sqlite_master WHERE name = 'questions_fts'"),
          isEmpty);
    } finally {
      await db.close();
    }
  });

  test('v20 to v21 is additive and trigger is the only FTS mutation authority',
      () async {
    final path = p.join(tempDir.path, 'upgrade.db');
    final created = await DatabaseHelper.instance.openPathForTesting(path);
    await created.insert('library_files', <String, Object?>{
      'file_id': 'file-rag1',
      'display_name': 'public.txt',
      'mime_type': 'text/plain',
      'size_bytes': 1,
      'sha256': 'a' * 64,
      'storage_key': 'library/file-rag1',
      'created_at': 1,
    });
    for (final name in <String>[
      'retrieval_chunks_au',
      'retrieval_chunks_ad',
      'retrieval_chunks_ai'
    ]) {
      await created.execute('DROP TRIGGER $name');
    }
    await created.execute('DROP TABLE retrieval_chunks_fts');
    await created.execute('DROP TABLE retrieval_index_heads');
    await created.execute('DROP TABLE retrieval_chunks');
    await created.execute('DROP TABLE retrieval_index_builds');
    await created.execute('PRAGMA user_version = 20');
    await created.close();

    final upgraded = await DatabaseHelper.instance.openPathForTesting(path);
    try {
      expect(
          (await upgraded.rawQuery('PRAGMA user_version'))
              .single['user_version'],
          22);
      expect(await upgraded.query('library_files'), hasLength(1));
      await upgraded.insert('retrieval_index_builds', <String, Object?>{
        'build_id': 'build-rag1',
        'file_id': 'file-rag1',
        'artifact_id': 'artifact-rag1',
        'revision': 1,
        'payload_digest': 'b' * 64,
        'chunker_version': 'rag1.chunk.v1',
        'lexical_projection_version': 'rag1.lexical.v1',
        'chunk_count': 1,
        'chunk_digest': 'c' * 64,
      });
      await upgraded.insert('retrieval_chunks', <String, Object?>{
        'chunk_id': 'chunk-rag1',
        'build_id': 'build-rag1',
        'ordinal': 0,
        'kind': 'paragraph',
        'locator': 'part:0',
        'safe_heading': '函数',
        'heading': '函数',
        'body': '二次 次函 函数',
        'safe_content': '二次函数',
        'content_hash': 'd' * 64,
        'part_ordinal': 0,
        'window_ordinal': 0,
      });
      final hit = await upgraded.rawQuery(
          "SELECT count(*) AS count FROM retrieval_chunks_fts WHERE retrieval_chunks_fts MATCH ?",
          <Object?>['"二次" AND "次函" AND "函数"']);
      expect(hit.single['count'], 1);
      await upgraded.delete('retrieval_index_builds',
          where: 'build_id = ?', whereArgs: <Object?>['build-rag1']);
      expect(
          (await upgraded.rawQuery(
                  'SELECT count(*) AS count FROM retrieval_chunks_fts'))
              .single['count'],
          0);
      expect(await upgraded.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      await upgraded.close();
    }
  });

  test('malformed preexisting v21 cache fails atomically and leaves v20',
      () async {
    final path = p.join(tempDir.path, 'malformed.db');
    final created = await DatabaseHelper.instance.openPathForTesting(path);
    for (final name in <String>[
      'retrieval_chunks_au',
      'retrieval_chunks_ad',
      'retrieval_chunks_ai'
    ]) {
      await created.execute('DROP TRIGGER $name');
    }
    await created.execute('DROP TABLE retrieval_chunks_fts');
    await created.execute('DROP TABLE retrieval_index_heads');
    await created.execute('DROP TABLE retrieval_chunks');
    await created.execute('DROP TABLE retrieval_index_builds');
    await created.execute(
        'CREATE TABLE retrieval_index_builds (build_id TEXT PRIMARY KEY)');
    await created.execute('PRAGMA user_version = 20');
    await created.close();

    await expectLater(
      DatabaseHelper.instance.openPathForTesting(path),
      throwsA(isA<RetrievalSchemaException>().having(
        (error) => error.failure,
        'failure',
        RetrievalSchemaFailure.malformedSchema,
      )),
    );

    final probe = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
    try {
      expect(
          (await probe.rawQuery('PRAGMA user_version')).single['user_version'],
          20);
      final objects = await probe.rawQuery(
          "SELECT name FROM sqlite_master WHERE name LIKE 'retrieval_%'");
      expect(objects.map((row) => row['name']), ['retrieval_index_builds']);
    } finally {
      await probe.close();
    }
  });
}
