import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/core/database/sqflite_runtime_standalone.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(initializeStandaloneDatabaseRuntime);

  test('Windows FFI runtime supports RAG1 external-content FTS5', () async {
    final database = await databaseFactory.openDatabase(inMemoryDatabasePath);
    try {
      await database.execute('''
        CREATE TABLE retrieval_chunks (
          chunk_id TEXT PRIMARY KEY NOT NULL,
          heading TEXT NOT NULL,
          body TEXT NOT NULL
        )
      ''');
      await database.execute('''
        CREATE VIRTUAL TABLE retrieval_chunks_fts USING fts5(
          heading,
          body,
          content='retrieval_chunks',
          content_rowid='rowid'
        )
      ''');
      await database.execute('''
        CREATE TRIGGER retrieval_chunks_ai
        AFTER INSERT ON retrieval_chunks BEGIN
          INSERT INTO retrieval_chunks_fts(rowid, heading, body)
          VALUES (new.rowid, new.heading, new.body);
        END
      ''');

      await database.insert('retrieval_chunks', <String, Object?>{
        'chunk_id': 'chunk-1',
        'heading': 'quadratic function',
        'body': 'find the minimum value',
      });

      final rows = await database.rawQuery('''
        SELECT c.chunk_id, bm25(retrieval_chunks_fts, 4.0, 1.0) AS rank
        FROM retrieval_chunks_fts
        JOIN retrieval_chunks c ON c.rowid = retrieval_chunks_fts.rowid
        WHERE retrieval_chunks_fts MATCH ?
      ''', <Object?>['"quadratic" AND "function"']);

      expect(rows, hasLength(1));
      expect(rows.single['chunk_id'], 'chunk-1');
      expect(rows.single['rank'], isA<num>());
    } finally {
      await database.close();
    }
  });
}
