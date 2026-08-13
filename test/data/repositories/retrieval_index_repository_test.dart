import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/retrieval/retrieval.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/retrieval_index_repository.dart';
import 'package:shiroha_quiz/domain/retrieval/retrieval_chunk.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(DatabaseHelper.resetRuntimeProfileForTesting);
  tearDown(DatabaseHelper.resetRuntimeProfileForTesting);

  test(
      'cache hit is idempotent, heading ranks first, and reparse removes old build',
      () async {
    final helper = DatabaseHelper.instance;
    final db = await helper.openPathForTesting(inMemoryDatabasePath);
    await _seedFileAndArtifact(db,
        artifact: 'artifact-1', revision: 1, digest: 'b' * 64);
    final repository = SqliteRetrievalIndexRepository(databaseHelper: helper);
    final first = RetrievalArtifactSnapshot(
        fileId: 'file-1',
        artifactId: 'artifact-1',
        revision: 1,
        payloadDigest: 'b' * 64,
        displayLabel: 'public.txt');
    final chunks = <RetrievalChunk>[
      _chunk(
          id: 'chunk-heading',
          artifact: 'artifact-1',
          revision: 1,
          ordinal: 0,
          heading: 'quadratic function',
          content: 'overview'),
      _chunk(
          id: 'chunk-body',
          artifact: 'artifact-1',
          revision: 1,
          ordinal: 1,
          heading: 'other',
          content: 'quadratic function',
          sourceRef: SourceRef.range(
              sourceId: 'artifact-1',
              displayLabel: 'public.txt',
              start: SourcePoint.block(
                  pageNumber: 2, blockId: 'b1', readingOrder: 0),
              end: SourcePoint.block(
                  pageNumber: 2, blockId: 'b2', readingOrder: 1))),
    ];
    await repository.ensureBuild(
        snapshot: first,
        chunkerVersion: 'rag1.chunk.v1',
        lexicalProjectionVersion: 'rag1.lexical.v1',
        chunks: chunks);
    await repository.ensureBuild(
        snapshot: first,
        chunkerVersion: 'rag1.chunk.v1',
        lexicalProjectionVersion: 'rag1.lexical.v1',
        chunks: chunks);
    expect(await db.query('retrieval_index_builds'), hasLength(1));
    expect(await db.query('retrieval_chunks'), hasLength(2));
    await db.update('retrieval_chunks', {'safe_content': 'corrupt'},
        where: 'chunk_id = ?', whereArgs: ['chunk-body']);
    await repository.ensureBuild(
        snapshot: first,
        chunkerVersion: 'rag1.chunk.v1',
        lexicalProjectionVersion: 'rag1.lexical.v1',
        chunks: chunks);
    expect(
        (await db.query('retrieval_chunks',
                columns: ['safe_content'],
                where: 'chunk_id = ?',
                whereArgs: ['chunk-body']))
            .single['safe_content'],
        'quadratic function');
    final searchResult = await repository.search(
        snapshots: [first],
        matchExpression: '"quadratic" AND "function"',
        limit: 8,
        maxHitBytes: 6000,
        maxResultBytes: 24000);
    final hits = searchResult.hits;
    expect(hits.first.chunkId, 'chunk-heading');
    expect(
        hits.first.lexicalScore, greaterThanOrEqualTo(hits.last.lexicalScore));
    final bodyHit = hits.singleWhere((hit) => hit.chunkId == 'chunk-body');
    expect(bodyHit.displayLabel, 'public.txt');
    expect(bodyHit.sourceRef.displayLabel, 'public.txt');
    expect(bodyHit.sourceRef.start?.blockId, 'b1');
    expect(bodyHit.sourceRef.end?.blockId, 'b2');

    await db.update(
        'parsed_artifacts',
        {
          'artifact_id': 'artifact-2',
          'revision': 2,
          'payload_sha256': 'c' * 64
        },
        where: 'file_id = ?',
        whereArgs: ['file-1']);
    final second = RetrievalArtifactSnapshot(
        fileId: 'file-1',
        artifactId: 'artifact-2',
        revision: 2,
        payloadDigest: 'c' * 64);
    await repository.ensureBuild(
        snapshot: second,
        chunkerVersion: 'rag1.chunk.v1',
        lexicalProjectionVersion: 'rag1.lexical.v1',
        chunks: [
          _chunk(
              id: 'chunk-new',
              artifact: 'artifact-2',
              revision: 2,
              ordinal: 0,
              heading: 'new',
              content: 'new function')
        ]);
    expect((await db.query('retrieval_index_builds')).single['artifact_id'],
        'artifact-2');
    expect(
        (await db.query('retrieval_chunks')).single['chunk_id'], 'chunk-new');
    final stale = await repository.search(
        snapshots: [first],
        matchExpression: '"quadratic"',
        limit: 8,
        maxHitBytes: 6000,
        maxResultBytes: 24000);
    expect(stale.hits, isEmpty);
    expect(stale.sourceChangedFileIds, ['file-1']);
    await db.close();
  });

  test('concurrent ensure converges to one exact build and remove cascades FTS',
      () async {
    final helper = DatabaseHelper.instance;
    final db = await helper.openPathForTesting(inMemoryDatabasePath);
    await _seedFileAndArtifact(db,
        artifact: 'artifact-1', revision: 1, digest: 'b' * 64);
    final repository = SqliteRetrievalIndexRepository(databaseHelper: helper);
    final snapshot = RetrievalArtifactSnapshot(
        fileId: 'file-1',
        artifactId: 'artifact-1',
        revision: 1,
        payloadDigest: 'b' * 64);
    final chunk = _chunk(
        id: 'chunk-1',
        artifact: 'artifact-1',
        revision: 1,
        ordinal: 0,
        heading: '函数',
        content: '二次函数');
    await Future.wait([
      for (var i = 0; i < 5; i++)
        repository.ensureBuild(
            snapshot: snapshot,
            chunkerVersion: 'rag1.chunk.v1',
            lexicalProjectionVersion: 'rag1.lexical.v1',
            chunks: [chunk])
    ]);
    expect(await db.query('retrieval_index_builds'), hasLength(1));
    await repository.removeIndex('file-1');
    expect(await db.query('retrieval_chunks'), isEmpty);
    expect(
        (await db
                .rawQuery('SELECT count(*) AS count FROM retrieval_chunks_fts'))
            .single['count'],
        0);
    await db.close();
  });

  test('ensure reports an authoritative generation mismatch as sourceChanged',
      () async {
    final helper = DatabaseHelper.instance;
    final db = await helper.openPathForTesting(inMemoryDatabasePath);
    await _seedFileAndArtifact(db,
        artifact: 'artifact-2', revision: 2, digest: 'c' * 64);
    final repository = SqliteRetrievalIndexRepository(databaseHelper: helper);
    final stale = RetrievalArtifactSnapshot(
        fileId: 'file-1',
        artifactId: 'artifact-1',
        revision: 1,
        payloadDigest: 'b' * 64);

    await expectLater(
      repository.ensureBuild(
          snapshot: stale,
          chunkerVersion: 'rag1.chunk.v1',
          lexicalProjectionVersion: 'rag1.lexical.v1',
          chunks: <RetrievalChunk>[
            _chunk(
                id: 'chunk-stale',
                artifact: 'artifact-1',
                revision: 1,
                ordinal: 0,
                heading: 'old',
                content: 'old function')
          ]),
      throwsA(
        isA<RetrievalException>().having(
          (error) => error.failure,
          'failure',
          RetrievalFailure.sourceChanged,
        ),
      ),
    );
    expect(await db.query('retrieval_index_builds'), isEmpty);
    await db.close();
  });
}

RetrievalChunk _chunk(
        {required String id,
        required String artifact,
        required int revision,
        required int ordinal,
        required String heading,
        required String content,
        SourceRef? sourceRef}) =>
    RetrievalChunk(
        chunkId: id,
        fileId: 'file-1',
        artifactId: artifact,
        revision: revision,
        sourceId: artifact,
        ordinal: ordinal,
        kind: RetrievalContentKind.paragraph,
        locator: 'part:$ordinal',
        partOrdinal: ordinal,
        windowOrdinal: 0,
        content: content,
        contentHash: 'd' * 64,
        heading: heading,
        sourceRef: sourceRef ?? SourceRef.document(sourceId: artifact));

Future<void> _seedFileAndArtifact(Database db,
    {required String artifact,
    required int revision,
    required String digest}) async {
  await db.insert('library_files', {
    'file_id': 'file-1',
    'display_name': 'public.txt',
    'mime_type': 'text/plain',
    'size_bytes': 1,
    'sha256': 'a' * 64,
    'storage_key': 'library/file-1',
    'created_at': 1
  });
  await db.insert('parsed_artifact_heads',
      {'file_id': 'file-1', 'last_revision': revision});
  await db.insert('parsed_artifacts', {
    'file_id': 'file-1',
    'artifact_id': artifact,
    'revision': revision,
    'source_sha256': 'a' * 64,
    'cache_key_version': 1,
    'cache_fingerprint': 'cache',
    'parser_route': 'txt',
    'parser_version': '1',
    'options_schema_version': 1,
    'payload_schema_version': 1,
    'storage_key': 'artifacts/$artifact.json',
    'payload_sha256': digest,
    'size_bytes': 1,
    'published_at': 1
  });
}
