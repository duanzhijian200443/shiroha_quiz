import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_ports.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/parsed_artifact_repository.dart';
import 'package:shiroha_quiz/domain/assets/parsed_artifact.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _sourceSha256 =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
const _payloadSha256 =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

ParsedArtifactMetadata metadata({
  String fileId = 'file-1',
  String artifactId = 'artifact-1',
  int revision = 1,
  String storageKey = 'artifacts/artifact-1.json',
}) {
  return ParsedArtifactMetadata(
    artifact: ParsedArtifact(
      fileId: fileId,
      artifactId: artifactId,
      revision: revision,
      payloadSchemaVersion: 1,
    ),
    sourceSha256: _sourceSha256,
    cacheKeyVersion: 1,
    cacheFingerprint: 'fingerprint-v1',
    parserRoute: 'pdf_text',
    parserVersion: '1.0.0',
    optionsSchemaVersion: 1,
    storageKey: storageKey,
    payloadSha256: _payloadSha256,
    sizeBytes: 42,
    publishedAt: 1700000000000,
  );
}

class _ThrowingDatabaseHelper extends Fake implements DatabaseHelper {
  _ThrowingDatabaseHelper(this.error);

  final Object error;

  @override
  Future<Database> get database async => throw error;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  Future<(ParsedArtifactRepository, Database)> openRepository() async {
    final repository = ParsedArtifactRepository();
    final db = await DatabaseHelper.instance.database;
    return (repository, db);
  }

  Future<void> seedFile(Database db, String fileId) async {
    await db.insert('library_files', <String, Object?>{
      'file_id': fileId,
      'display_name': 'source.pdf',
      'mime_type': 'application/pdf',
      'size_bytes': 3,
      'sha256': _sourceSha256,
      'storage_key': 'library/$fileId',
      'created_at': 1700000000,
    });
  }

  Future<void> seedQuestionData(Database db) async {
    await db.insert('questions', <String, Object?>{
      'id': 'q-repo',
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
      'question_id': 'q-repo',
      'payload_schema_version': 2,
      'payload_json': '{"schemaVersion":2,"synthetic":true}',
    });
    await db.insert('review_states', <String, Object?>{
      'question_id': 'q-repo',
      'state': 3,
      'lapses': 2,
      'difficulty': 3.0,
      'stability': 8.0,
      'reps': 4,
    });
  }

  group('ParsedArtifactRepository read primitives', () {
    test('reports no artifact and no head for an empty file', () async {
      final (repository, _) = await openRepository();

      expect(await repository.findCurrentByFileId('file-1'), isNull);
      expect(await repository.readRevisionHead('file-1'), 0);
    });

    test('reads exact current metadata after first publish', () async {
      final (repository, db) = await openRepository();
      await seedFile(db, 'file-1');

      final result = await repository.publishCurrent(
        fileId: 'file-1',
        candidate: metadata(),
        expectedRevision: 0,
      );

      expect(result.status, ParsedArtifactPublishStatus.published);
      expect(result.current, metadata());
      final current = await repository.findCurrentByFileId('file-1');
      expect(current, metadata());
      expect(current?.fileId, 'file-1');
      expect(current?.artifactId, 'artifact-1');
      expect(current?.revision, 1);
      expect(current?.payloadSchemaVersion, 1);
      expect(current?.sourceSha256, _sourceSha256);
      expect(current?.cacheKeyVersion, 1);
      expect(current?.cacheFingerprint, 'fingerprint-v1');
      expect(current?.parserRoute, 'pdf_text');
      expect(current?.parserVersion, '1.0.0');
      expect(current?.optionsSchemaVersion, 1);
      expect(current?.storageKey, 'artifacts/artifact-1.json');
      expect(current?.payloadSha256, _payloadSha256);
      expect(current?.sizeBytes, 42);
      expect(current?.publishedAt, 1700000000000);
      expect(await repository.readRevisionHead('file-1'), 1);
    });
  });

  group('ParsedArtifactRepository publish CAS', () {
    test('first publish is 0 -> 1', () async {
      final (repository, db) = await openRepository();
      await seedFile(db, 'file-1');

      final result = await repository.publishCurrent(
        fileId: 'file-1',
        candidate: metadata(),
        expectedRevision: 0,
      );

      expect(result.status, ParsedArtifactPublishStatus.published);
      expect(await repository.readRevisionHead('file-1'), 1);
    });

    test('replaces 1 -> 2 and keeps exactly one current row', () async {
      final (repository, db) = await openRepository();
      await seedFile(db, 'file-1');
      await repository.publishCurrent(
        fileId: 'file-1',
        candidate: metadata(),
        expectedRevision: 0,
      );

      final replacement = metadata(
        artifactId: 'artifact-2',
        revision: 2,
        storageKey: 'artifacts/artifact-2.json',
      );
      final result = await repository.publishCurrent(
        fileId: 'file-1',
        candidate: replacement,
        expectedRevision: 1,
      );

      expect(result.status, ParsedArtifactPublishStatus.published);
      expect(await repository.findCurrentByFileId('file-1'), replacement);
      expect(await repository.readRevisionHead('file-1'), 2);
      final rows = await db.query('parsed_artifacts');
      expect(rows, hasLength(1));
    });

    test('stale publish CAS is a zero-mutation conflict', () async {
      final (repository, db) = await openRepository();
      await seedFile(db, 'file-1');
      await repository.publishCurrent(
        fileId: 'file-1',
        candidate: metadata(),
        expectedRevision: 0,
      );

      final stale = await repository.publishCurrent(
        fileId: 'file-1',
        candidate: metadata(revision: 2, artifactId: 'artifact-2'),
        expectedRevision: 0,
      );

      expect(stale.status, ParsedArtifactPublishStatus.revisionConflict);
      expect(stale.actualRevision, 1);
      expect(await repository.readRevisionHead('file-1'), 1);
      expect((await repository.findCurrentByFileId('file-1'))?.revision, 1);
      expect(await db.query('parsed_artifacts'), hasLength(1));
    });

    test('candidate revision skip or reuse is rejected', () async {
      final (repository, db) = await openRepository();
      await seedFile(db, 'file-1');

      await repository.publishCurrent(
        fileId: 'file-1',
        candidate: metadata(),
        expectedRevision: 0,
      );
      final skipped = await repository.publishCurrent(
        fileId: 'file-1',
        candidate: metadata(revision: 3, artifactId: 'artifact-3'),
        expectedRevision: 1,
      );
      final reused = await repository.publishCurrent(
        fileId: 'file-1',
        candidate: metadata(revision: 1, artifactId: 'artifact-3'),
        expectedRevision: 1,
      );

      expect(skipped.status, ParsedArtifactPublishStatus.revisionConflict);
      expect(reused.status, ParsedArtifactPublishStatus.revisionConflict);
      expect(await repository.readRevisionHead('file-1'), 1);
      expect((await repository.findCurrentByFileId('file-1'))?.revision, 1);
    });

    test('publishing for a missing parent file is a typed no-op', () async {
      final (repository, _) = await openRepository();

      final result = await repository.publishCurrent(
        fileId: 'missing-file',
        candidate: metadata(fileId: 'missing-file'),
        expectedRevision: 0,
      );

      expect(result.status, ParsedArtifactPublishStatus.parentMissing);
      expect(await repository.readRevisionHead('missing-file'), 0);
      expect(await repository.findCurrentByFileId('missing-file'), isNull);
    });

    test('duplicate artifactId or storageKey is a safe failure', () async {
      final (repository, db) = await openRepository();
      await seedFile(db, 'file-1');
      await seedFile(db, 'file-2');
      await repository.publishCurrent(
        fileId: 'file-1',
        candidate: metadata(),
        expectedRevision: 0,
      );

      await expectLater(
        repository.publishCurrent(
          fileId: 'file-2',
          candidate: metadata(
            fileId: 'file-2',
            artifactId: 'artifact-1',
          ),
          expectedRevision: 0,
        ),
        throwsA(
          isA<ParsedArtifactRepositoryException>().having(
            (error) => error.failure,
            'failure',
            ParsedArtifactRepositoryFailure.duplicateIdentity,
          ),
        ),
      );
      await expectLater(
        repository.publishCurrent(
          fileId: 'file-2',
          candidate: metadata(
            fileId: 'file-2',
            artifactId: 'artifact-2',
            storageKey: 'artifacts/artifact-1.json',
          ),
          expectedRevision: 0,
        ),
        throwsA(
          isA<ParsedArtifactRepositoryException>().having(
            (error) => error.failure,
            'failure',
            ParsedArtifactRepositoryFailure.duplicateIdentity,
          ),
        ),
      );
      expect(await repository.readRevisionHead('file-2'), 0);
      expect(await repository.findCurrentByFileId('file-2'), isNull);
    });
  });

  group('ParsedArtifactRepository remove CAS', () {
    test('removes the current row while preserving the revision head',
        () async {
      final (repository, db) = await openRepository();
      await seedFile(db, 'file-1');
      await repository.publishCurrent(
        fileId: 'file-1',
        candidate: metadata(),
        expectedRevision: 0,
      );

      final result = await repository.removeCurrent(
        fileId: 'file-1',
        expectedRevision: 1,
      );

      expect(result.status, ParsedArtifactRemoveStatus.removed);
      expect(await repository.findCurrentByFileId('file-1'), isNull);
      expect(await repository.readRevisionHead('file-1'), 1);
      expect(await db.query('parsed_artifacts'), isEmpty);
    });

    test('stale remove is a zero-mutation conflict', () async {
      final (repository, db) = await openRepository();
      await seedFile(db, 'file-1');
      await repository.publishCurrent(
        fileId: 'file-1',
        candidate: metadata(),
        expectedRevision: 0,
      );

      final result = await repository.removeCurrent(
        fileId: 'file-1',
        expectedRevision: 2,
      );

      expect(result.status, ParsedArtifactRemoveStatus.revisionConflict);
      expect(result.actualRevision, 1);
      expect((await repository.findCurrentByFileId('file-1'))?.revision, 1);
      expect(await repository.readRevisionHead('file-1'), 1);
      expect(await db.query('parsed_artifacts'), hasLength(1));
    });

    test('remove on an empty file is a typed not-found no-op', () async {
      final (repository, _) = await openRepository();

      final result = await repository.removeCurrent(
        fileId: 'file-1',
        expectedRevision: 0,
      );

      expect(result.status, ParsedArtifactRemoveStatus.notFound);
      expect(await repository.readRevisionHead('file-1'), 0);
    });

    test('repeated same-revision remove is notFound and keeps the head',
        () async {
      final (repository, db) = await openRepository();
      await seedFile(db, 'file-1');
      await repository.publishCurrent(
        fileId: 'file-1',
        candidate: metadata(),
        expectedRevision: 0,
      );

      final first = await repository.removeCurrent(
        fileId: 'file-1',
        expectedRevision: 1,
      );
      expect(first.status, ParsedArtifactRemoveStatus.removed);

      final second = await repository.removeCurrent(
        fileId: 'file-1',
        expectedRevision: 1,
      );
      expect(second.status, ParsedArtifactRemoveStatus.notFound);
      expect(await repository.readRevisionHead('file-1'), 1);
      expect(await repository.findCurrentByFileId('file-1'), isNull);

      final again = await repository.publishCurrent(
        fileId: 'file-1',
        candidate: metadata(
          artifactId: 'artifact-2',
          revision: 2,
          storageKey: 'artifacts/artifact-2.json',
        ),
        expectedRevision: 1,
      );
      expect(again.status, ParsedArtifactPublishStatus.published);
      expect((await repository.findCurrentByFileId('file-1'))?.revision, 2);
    });

    test('publishing after removal continues from the retained head', () async {
      final (repository, db) = await openRepository();
      await seedFile(db, 'file-1');
      await repository.publishCurrent(
        fileId: 'file-1',
        candidate: metadata(),
        expectedRevision: 0,
      );
      await repository.removeCurrent(fileId: 'file-1', expectedRevision: 1);

      final again = await repository.publishCurrent(
        fileId: 'file-1',
        candidate: metadata(
          artifactId: 'artifact-2',
          revision: 2,
          storageKey: 'artifacts/artifact-2.json',
        ),
        expectedRevision: 1,
      );

      expect(again.status, ParsedArtifactPublishStatus.published);
      expect((await repository.findCurrentByFileId('file-1'))?.revision, 2);
      expect(await repository.readRevisionHead('file-1'), 2);
    });
  });

  group('ParsedArtifactRepository isolation', () {
    test('parent deletion cascades artifact metadata only', () async {
      final (repository, db) = await openRepository();
      await seedFile(db, 'file-1');
      await seedQuestionData(db);
      await repository.publishCurrent(
        fileId: 'file-1',
        candidate: metadata(),
        expectedRevision: 0,
      );

      await db.delete('library_files',
          where: 'file_id = ?', whereArgs: <Object?>['file-1']);

      expect(await repository.findCurrentByFileId('file-1'), isNull);
      expect(await repository.readRevisionHead('file-1'), 0);
      expect(await db.query('parsed_artifacts'), isEmpty);
      expect(await db.query('parsed_artifact_heads'), isEmpty);
      expect(await db.query('questions'), hasLength(1));
      expect(await db.query('question_v2_payloads'), hasLength(1));
      expect(await db.query('review_states'), hasLength(1));
    });

    test('publish and remove never touch question or review rows', () async {
      final (repository, db) = await openRepository();
      await seedFile(db, 'file-1');
      await seedQuestionData(db);

      await repository.publishCurrent(
        fileId: 'file-1',
        candidate: metadata(),
        expectedRevision: 0,
      );
      await repository.removeCurrent(fileId: 'file-1', expectedRevision: 1);

      expect(await db.query('questions'), hasLength(1));
      expect(await db.query('question_v2_payloads'), hasLength(1));
      final review = await db.query('review_states');
      expect(review.single['question_id'], 'q-repo');
      expect(review.single['lapses'], 2);
    });
  });

  group('ParsedArtifactRepository safe failure translation', () {
    test('read and mutation paths translate acquisition failures', () async {
      final repository = ParsedArtifactRepository(
        databaseHelper: _ThrowingDatabaseHelper(
          const DatabaseRuntimeException(DatabaseRuntimeFailure.unavailable),
        ),
      );

      for (final operation in <Future<Object?>>[
        repository.findCurrentByFileId('file-1'),
        repository.readRevisionHead('file-1'),
        repository.publishCurrent(
          fileId: 'file-1',
          candidate: metadata(),
          expectedRevision: 0,
        ),
        repository.removeCurrent(fileId: 'file-1', expectedRevision: 1),
      ]) {
        await expectLater(
          operation,
          throwsA(
            isA<ParsedArtifactRepositoryException>().having(
              (error) => error.failure,
              'failure',
              ParsedArtifactRepositoryFailure.unavailable,
            ),
          ),
        );
      }
    });

    test('query and transaction failures become safe unavailable', () async {
      final (repository, db) = await openRepository();
      await seedFile(db, 'file-1');
      await db.execute('DROP TABLE parsed_artifacts');
      await db.execute('DROP TABLE parsed_artifact_heads');

      try {
        await repository.findCurrentByFileId('file-1');
        fail('expected unavailable');
      } on ParsedArtifactRepositoryException catch (error) {
        expect(error.failure, ParsedArtifactRepositoryFailure.unavailable);
        expect(error.toString(), isNot(contains('no such table')));
        expect(error.toString(), isNot(contains('parsed_artifacts')));
      }
      try {
        await repository.publishCurrent(
          fileId: 'file-1',
          candidate: metadata(),
          expectedRevision: 0,
        );
        fail('expected unavailable');
      } on ParsedArtifactRepositoryException catch (error) {
        expect(error.failure, ParsedArtifactRepositoryFailure.unavailable);
        expect(error.toString(), isNot(contains('no such table')));
      }
      try {
        await repository.removeCurrent(fileId: 'file-1', expectedRevision: 0);
        fail('expected unavailable');
      } on ParsedArtifactRepositoryException catch (error) {
        expect(error.failure, ParsedArtifactRepositoryFailure.unavailable);
        expect(error.toString(), isNot(contains('no such table')));
      }
    });

    test('malformed persisted rows translate to safe unavailable', () async {
      final (repository, db) = await openRepository();
      await seedFile(db, 'file-1');
      await db.insert('parsed_artifact_heads', <String, Object?>{
        'file_id': 'file-1',
        'last_revision': 1,
      });
      await db.insert('parsed_artifacts', <String, Object?>{
        'file_id': 'file-1',
        'artifact_id': 'artifact-bad',
        'revision': 1,
        'source_sha256': _sourceSha256,
        'cache_key_version': 1,
        'cache_fingerprint': 'fingerprint-v1',
        'parser_route': 'Bad Route!',
        'parser_version': '1.0.0',
        'options_schema_version': 1,
        'payload_schema_version': 1,
        'storage_key': 'artifacts/artifact-bad.json',
        'payload_sha256': _payloadSha256,
        'size_bytes': 42,
        'published_at': 1700000000000,
      });

      try {
        await repository.findCurrentByFileId('file-1');
        fail('expected unavailable');
      } on ParsedArtifactRepositoryException catch (error) {
        expect(error.failure, ParsedArtifactRepositoryFailure.unavailable);
        expect(error.toString(), isNot(contains('Bad Route')));
        expect(error.toString(), isNot(contains('parser_route')));
      }
    });
  });
}
