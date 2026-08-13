library;

import 'sqflite_runtime.dart';

const int retrievalSchemaVersion = 21;

const String retrievalBuildsDdl = '''
CREATE TABLE retrieval_index_builds (
  build_id TEXT PRIMARY KEY NOT NULL,
  file_id TEXT NOT NULL,
  artifact_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision > 0),
  payload_digest TEXT NOT NULL CHECK(length(payload_digest) = 64),
  chunker_version TEXT NOT NULL CHECK(length(chunker_version) BETWEEN 1 AND 64),
  lexical_projection_version TEXT NOT NULL CHECK(length(lexical_projection_version) BETWEEN 1 AND 64),
  chunk_count INTEGER NOT NULL CHECK(chunk_count >= 0),
  chunk_digest TEXT NOT NULL CHECK(length(chunk_digest) = 64),
  UNIQUE(file_id, artifact_id, revision, payload_digest, chunker_version, lexical_projection_version),
  FOREIGN KEY(file_id) REFERENCES library_files(file_id) ON DELETE CASCADE
);
''';

const String retrievalHeadsDdl = '''
CREATE TABLE retrieval_index_heads (
  file_id TEXT PRIMARY KEY NOT NULL,
  build_id TEXT NOT NULL UNIQUE,
  FOREIGN KEY(file_id) REFERENCES library_files(file_id) ON DELETE CASCADE,
  FOREIGN KEY(build_id) REFERENCES retrieval_index_builds(build_id) ON DELETE CASCADE
);
''';

const String retrievalChunksDdl = '''
CREATE TABLE retrieval_chunks (
  chunk_id TEXT PRIMARY KEY NOT NULL,
  build_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
  kind TEXT NOT NULL,
  locator TEXT NOT NULL,
  safe_heading TEXT,
  heading TEXT NOT NULL,
  body TEXT NOT NULL,
  safe_content TEXT NOT NULL CHECK(length(safe_content) > 0),
  content_hash TEXT NOT NULL CHECK(length(content_hash) = 64),
  part_ordinal INTEGER NOT NULL CHECK(part_ordinal >= 0),
  window_ordinal INTEGER NOT NULL CHECK(window_ordinal >= 0),
  page_number INTEGER,
  block_id TEXT,
  reading_order INTEGER,
  end_page_number INTEGER,
  end_block_id TEXT,
  end_reading_order INTEGER,
  UNIQUE(build_id, ordinal),
  FOREIGN KEY(build_id) REFERENCES retrieval_index_builds(build_id) ON DELETE CASCADE
);
''';

const String retrievalFtsDdl = '''
CREATE VIRTUAL TABLE retrieval_chunks_fts USING fts5(
  heading,
  body,
  content='retrieval_chunks',
  content_rowid='rowid'
);
''';

const String retrievalInsertTriggerDdl = '''
CREATE TRIGGER retrieval_chunks_ai AFTER INSERT ON retrieval_chunks BEGIN
  INSERT INTO retrieval_chunks_fts(rowid, heading, body)
  VALUES (new.rowid, new.heading, new.body);
END;
''';

const String retrievalDeleteTriggerDdl = '''
CREATE TRIGGER retrieval_chunks_ad AFTER DELETE ON retrieval_chunks BEGIN
  INSERT INTO retrieval_chunks_fts(retrieval_chunks_fts, rowid, heading, body)
  VALUES ('delete', old.rowid, old.heading, old.body);
END;
''';

const String retrievalUpdateTriggerDdl = '''
CREATE TRIGGER retrieval_chunks_au AFTER UPDATE ON retrieval_chunks BEGIN
  INSERT INTO retrieval_chunks_fts(retrieval_chunks_fts, rowid, heading, body)
  VALUES ('delete', old.rowid, old.heading, old.body);
  INSERT INTO retrieval_chunks_fts(rowid, heading, body)
  VALUES (new.rowid, new.heading, new.body);
END;
''';

const List<String> _retrievalDdl = <String>[
  retrievalBuildsDdl,
  retrievalHeadsDdl,
  retrievalChunksDdl,
  retrievalFtsDdl,
  retrievalInsertTriggerDdl,
  retrievalDeleteTriggerDdl,
  retrievalUpdateTriggerDdl,
];

Future<void> createRetrievalV21Schema(DatabaseExecutor db) async {
  for (final ddl in _retrievalDdl) {
    await db.execute(ddl
        .replaceFirst('CREATE TABLE ', 'CREATE TABLE IF NOT EXISTS ')
        .replaceFirst(
            'CREATE VIRTUAL TABLE ', 'CREATE VIRTUAL TABLE IF NOT EXISTS ')
        .replaceFirst('CREATE TRIGGER ', 'CREATE TRIGGER IF NOT EXISTS '));
  }
}

Future<void> validateRetrievalV21Schema(DatabaseExecutor db) async {
  const expected = <String, String>{
    'retrieval_index_builds': retrievalBuildsDdl,
    'retrieval_index_heads': retrievalHeadsDdl,
    'retrieval_chunks': retrievalChunksDdl,
    'retrieval_chunks_fts': retrievalFtsDdl,
    'retrieval_chunks_ai': retrievalInsertTriggerDdl,
    'retrieval_chunks_ad': retrievalDeleteTriggerDdl,
    'retrieval_chunks_au': retrievalUpdateTriggerDdl,
  };
  final rows = await db.rawQuery(
      "SELECT name, sql FROM sqlite_master WHERE name LIKE 'retrieval_%'");
  final actual = <String, String?>{
    for (final row in rows) row['name']! as String: row['sql'] as String?
  };
  for (final entry in expected.entries) {
    final storedSql = actual[entry.key];
    if (storedSql == null ||
        _canonicalizeSql(storedSql) != _canonicalizeSql(entry.value)) {
      throw const RetrievalSchemaException(
          RetrievalSchemaFailure.malformedSchema);
    }
  }
  final foreignKeyIssues = await db.rawQuery('PRAGMA foreign_key_check');
  if (foreignKeyIssues.isNotEmpty) {
    throw const RetrievalSchemaException(
        RetrievalSchemaFailure.malformedSchema);
  }
  await db.execute('SAVEPOINT rag1_fts_probe');
  try {
    await db.rawQuery(
        "SELECT bm25(retrieval_chunks_fts, 4.0, 1.0) FROM retrieval_chunks_fts WHERE retrieval_chunks_fts MATCH ?",
        <Object?>['"capability"']);
  } on DatabaseException {
    throw const RetrievalSchemaException(
        RetrievalSchemaFailure.fts5Unavailable);
  } finally {
    await db.execute('ROLLBACK TO rag1_fts_probe');
    await db.execute('RELEASE rag1_fts_probe');
  }
}

String _canonicalizeSql(String sql) => sql
    .replaceAll(RegExp(r'\bIF\s+NOT\s+EXISTS\b', caseSensitive: false), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'\s*([(),=])\s*'), r'$1')
    .replaceAll(RegExp(r';\s*$'), '')
    .trim()
    .toLowerCase();

enum RetrievalSchemaFailure { malformedSchema, fts5Unavailable }

final class RetrievalSchemaException implements Exception {
  const RetrievalSchemaException(this.failure);
  final RetrievalSchemaFailure failure;
  @override
  String toString() => 'RetrievalSchemaException(${failure.name})';
}
