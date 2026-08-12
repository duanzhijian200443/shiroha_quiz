import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_ports.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/library_file_repository.dart';
import 'package:shiroha_quiz/data/repositories/parsed_artifact_repository.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/assets/parsed_artifact.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/source/parsed_artifact_payload_codec.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/file_library/managed_artifact_storage.dart';
import 'package:shiroha_quiz/services/file_library/managed_artifact_storage_adapter.dart';
import 'package:shiroha_quiz/services/parsed_artifacts/parsed_artifact_lifecycle_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _sha256A =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
const _sha256B =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

const _options = ParsedArtifactParseOptions(
  routeSelection: ParsedArtifactRouteSelection.auto,
);

LibraryFile seededFile({
  String fileId = 'file-1',
  String sha256 = _sha256A,
  String storageKey = 'library/file-1',
  String displayName = 'source.pdf',
}) {
  return LibraryFile(
    fileId: fileId,
    displayName: displayName,
    mimeType: 'application/pdf',
    sizeBytes: 3,
    sha256: sha256,
    storageKey: storageKey,
    createdAt: DateTime.utc(2026, 8, 12),
  );
}

class _FakeGenerationPort implements ParsedArtifactGenerationPort {
  int resolveCalls = 0;
  int generateCalls = 0;
  ParsedArtifactGenerationException? resolveError;
  ParsedArtifactGenerationException? generateError;
  Object? unexpectedGenerateError;
  Completer<void>? pause;
  String? overrideSourceId;
  ParsedArtifactGenerationPlan Function(ParsedArtifactRouteSelection selection)?
      planOverride;

  @override
  Future<ParsedArtifactGenerationPlan> resolvePlan({
    required LibraryFile file,
    required ParsedArtifactParseOptions options,
  }) async {
    resolveCalls++;
    if (resolveError != null) throw resolveError!;
    if (planOverride != null) {
      return planOverride!(options.routeSelection);
    }
    final route = switch (options.routeSelection) {
      ParsedArtifactRouteSelection.auto => 'pdf_text',
      ParsedArtifactRouteSelection.pdfText => 'pdf_text',
      ParsedArtifactRouteSelection.docxText => 'docx_text',
      ParsedArtifactRouteSelection.txt => 'txt',
      ParsedArtifactRouteSelection.markdown => 'markdown',
      ParsedArtifactRouteSelection.ocrPdf => 'ocr_pdf',
      ParsedArtifactRouteSelection.ocrImage => 'ocr_image',
    };
    return ParsedArtifactGenerationPlan(
      parserRoute: route,
      parserVersion: '1.0.0',
      optionsSchemaVersion: 1,
    );
  }

  @override
  Future<SourceDocument> generate({
    required LibraryFile file,
    required String artifactId,
    required ParsedArtifactGenerationPlan plan,
  }) async {
    generateCalls++;
    if (pause != null) await pause!.future;
    if (generateError != null) {
      final error = generateError!;
      generateError = null;
      throw error;
    }
    if (unexpectedGenerateError != null) {
      final error = unexpectedGenerateError!;
      unexpectedGenerateError = null;
      throw error;
    }
    final sourceId = overrideSourceId ?? artifactId;
    return SourceDocument(
      sourceId: sourceId,
      displayLabel: file.displayName,
      parts: <SourcePart>[
        SourceContentPart(
          sourceRef: SourceRef.document(sourceId: sourceId),
          content: RichContent(
            nodes: const <ContentNode>[TextNode('parsed')],
          ),
        ),
      ],
    );
  }
}

class _ConflictInjectingRepository implements ParsedArtifactRepositoryPort {
  _ConflictInjectingRepository(this.inner);

  final ParsedArtifactRepositoryPort inner;
  bool inject = false;

  @override
  Future<ParsedArtifactMetadata?> findCurrentByFileId(String fileId) =>
      inner.findCurrentByFileId(fileId);

  @override
  Future<int> readRevisionHead(String fileId) => inner.readRevisionHead(fileId);

  @override
  Future<ParsedArtifactPublishResult> publishCurrent({
    required String fileId,
    required ParsedArtifactMetadata candidate,
    required int expectedRevision,
  }) {
    if (inject) {
      return Future.value(
        ParsedArtifactPublishResult.revisionConflict(expectedRevision),
      );
    }
    return inner.publishCurrent(
      fileId: fileId,
      candidate: candidate,
      expectedRevision: expectedRevision,
    );
  }

  @override
  Future<ParsedArtifactRemoveResult> removeCurrent({
    required String fileId,
    required int expectedRevision,
  }) {
    return inner.removeCurrent(
      fileId: fileId,
      expectedRevision: expectedRevision,
    );
  }
}

class _FailingDeleteStorage implements ManagedArtifactStorage {
  _FailingDeleteStorage(this.inner);

  final ManagedArtifactStorage inner;
  bool failAllDeletes = false;

  @override
  String allocateArtifactStorageKey(String artifactId) =>
      inner.allocateArtifactStorageKey(artifactId);

  @override
  Future<ArtifactWriteResult> writeArtifact({
    required String storageKey,
    required List<int> bytes,
  }) {
    return inner.writeArtifact(storageKey: storageKey, bytes: bytes);
  }

  @override
  Future<ArtifactReadResult?> readArtifact({
    required String storageKey,
    String? expectedSha256,
    int? expectedSizeBytes,
  }) {
    return inner.readArtifact(
      storageKey: storageKey,
      expectedSha256: expectedSha256,
      expectedSizeBytes: expectedSizeBytes,
    );
  }

  @override
  Future<void> deleteArtifact(String storageKey) async {
    if (failAllDeletes) {
      throw const ManagedArtifactStorageException(
        ManagedArtifactStorageFailure.ioFailed,
      );
    }
    return inner.deleteArtifact(storageKey);
  }
}

class _TamperedReadStorage implements ManagedArtifactStorage {
  _TamperedReadStorage(this.inner);

  final ManagedArtifactStorage inner;
  final Map<String, List<int>> tamperedBytes = <String, List<int>>{};

  @override
  String allocateArtifactStorageKey(String artifactId) =>
      inner.allocateArtifactStorageKey(artifactId);

  @override
  Future<ArtifactWriteResult> writeArtifact({
    required String storageKey,
    required List<int> bytes,
  }) {
    return inner.writeArtifact(storageKey: storageKey, bytes: bytes);
  }

  @override
  Future<ArtifactReadResult?> readArtifact({
    required String storageKey,
    String? expectedSha256,
    int? expectedSizeBytes,
  }) async {
    final tampered = tamperedBytes[storageKey];
    if (tampered != null) {
      return ArtifactReadResult(
        bytes: tampered,
        sha256: 'tampered',
        sizeBytes: tampered.length,
      );
    }
    return inner.readArtifact(
      storageKey: storageKey,
      expectedSha256: expectedSha256,
      expectedSizeBytes: expectedSizeBytes,
    );
  }

  @override
  Future<void> deleteArtifact(String storageKey) =>
      inner.deleteArtifact(storageKey);
}

ParsedArtifactMetadata scriptedMetadata({
  String artifactId = 'artifact-1',
  int revision = 1,
  String storageKey = 'artifacts/artifact-1.json',
}) {
  return ParsedArtifactMetadata(
    artifact: ParsedArtifact(
      fileId: 'file-1',
      artifactId: artifactId,
      revision: revision,
      payloadSchemaVersion: 1,
    ),
    sourceSha256: _sha256A,
    cacheKeyVersion: 1,
    cacheFingerprint: 'fingerprint-v1',
    parserRoute: 'pdf_text',
    parserVersion: '1.0.0',
    optionsSchemaVersion: 1,
    storageKey: storageKey,
    payloadSha256: _sha256B,
    sizeBytes: 42,
    publishedAt: 1700000000000,
  );
}

List<int> scriptedPayloadBytes(ParsedArtifactMetadata metadata) {
  final payload = ParsedArtifactPayload(
    schemaVersion: ParsedArtifactPayloadCodec.schemaVersion,
    artifactId: metadata.artifactId,
    fileId: metadata.fileId,
    sourceDocument: SourceDocument(sourceId: metadata.artifactId),
  );
  return utf8.encode(
    jsonEncode(const ParsedArtifactPayloadCodec().encode(payload)),
  );
}

/// Scripts the sequence of current-metadata observations so the bounded
/// replacement-race retry can be driven deterministically.
class _ScriptedCurrentRepository implements ParsedArtifactRepositoryPort {
  _ScriptedCurrentRepository(this.currentSequence);

  final List<ParsedArtifactMetadata?> currentSequence;
  int reads = 0;

  @override
  Future<ParsedArtifactMetadata?> findCurrentByFileId(String fileId) async {
    final index =
        reads < currentSequence.length ? reads : currentSequence.length - 1;
    reads++;
    return currentSequence[index];
  }

  @override
  Future<int> readRevisionHead(String fileId) async => 0;

  @override
  Future<ParsedArtifactPublishResult> publishCurrent({
    required String fileId,
    required ParsedArtifactMetadata candidate,
    required int expectedRevision,
  }) async {
    return ParsedArtifactPublishResult.published(candidate);
  }

  @override
  Future<ParsedArtifactRemoveResult> removeCurrent({
    required String fileId,
    required int expectedRevision,
  }) async {
    return const ParsedArtifactRemoveResult.removed();
  }
}

/// Scripted sidecar store: only keys present in [availableByKey] resolve;
/// every other read reports a missing sidecar.
class _ScriptedSidecarStorage implements ManagedArtifactStorage {
  _ScriptedSidecarStorage(this.availableByKey);

  final Map<String, List<int>> availableByKey;

  @override
  String allocateArtifactStorageKey(String artifactId) =>
      'artifacts/$artifactId.json';

  @override
  Future<ArtifactWriteResult> writeArtifact({
    required String storageKey,
    required List<int> bytes,
  }) async {
    throw UnsupportedError('not used');
  }

  @override
  Future<ArtifactReadResult?> readArtifact({
    required String storageKey,
    String? expectedSha256,
    int? expectedSizeBytes,
  }) async {
    final bytes = availableByKey[storageKey];
    if (bytes == null) return null;
    return ArtifactReadResult(
      bytes: bytes,
      sha256: 'scripted',
      sizeBytes: bytes.length,
    );
  }

  @override
  Future<void> deleteArtifact(String storageKey) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LibraryFileRepository libraryRepository;
  late ParsedArtifactRepository artifactRepository;
  late ManagedArtifactStorageAdapter storage;
  late _FakeGenerationPort generation;
  late ParsedArtifactLifecycleService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    tempDir = await Directory.systemTemp.createTemp('a1_lifecycle_');
    libraryRepository = LibraryFileRepository();
    artifactRepository = ParsedArtifactRepository();
    storage = ManagedArtifactStorageAdapter(managedRoot: tempDir);
    generation = _FakeGenerationPort();
    service = ParsedArtifactLifecycleService(
      libraryFileRepository: libraryRepository,
      artifactRepository: artifactRepository,
      artifactStorage: storage,
      generationPort: generation,
    );
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> seedLibraryFile({String fileId = 'file-1'}) async {
    await libraryRepository.save(
      seededFile(fileId: fileId, storageKey: 'library/$fileId'),
    );
  }

  Future<ParsedArtifactEnsureResult> ensure({
    String fileId = 'file-1',
    ParsedArtifactParseOptions options = _options,
  }) {
    return service.ensureParsedArtifact(fileId: fileId, options: options);
  }

  Future<ParsedArtifactSnapshot> currentArtifact(String fileId) {
    return service.getCurrentArtifact(fileId);
  }

  List<String> artifactDirEntries() {
    final dir = Directory(p.join(tempDir.path, 'artifacts'));
    if (!dir.existsSync()) return <String>[];
    return dir.listSync().map((entity) => p.basename(entity.path)).toList();
  }

  Future<void> waitUntil(bool Function() condition) async {
    for (var attempt = 0; attempt < 500; attempt++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    fail('condition not reached within the bounded wait');
  }

  ParsedArtifactLifecycleException expectLifecycleFailure(
    Object error, {
    required ParsedArtifactLifecycleFailure failure,
  }) {
    expect(error, isA<ParsedArtifactLifecycleException>());
    final typed = error as ParsedArtifactLifecycleException;
    expect(typed.failure, failure);
    return typed;
  }

  group('getCurrentArtifact', () {
    test('missing LibraryFile is fileNotFound', () async {
      try {
        await currentArtifact('file-missing');
        fail('expected fileNotFound');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.fileNotFound,
        );
      }
    });

    test('missing current artifact is artifactMissing', () async {
      await seedLibraryFile();
      try {
        await currentArtifact('file-1');
        fail('expected artifactMissing');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.artifactMissing,
        );
      }
    });

    test('valid current returns the exact safe snapshot', () async {
      await seedLibraryFile();
      final published = await ensure();
      expect(published.outcome, ParsedArtifactLifecycleOutcome.published);

      final snapshot = await currentArtifact('file-1');
      expect(snapshot.artifact, published.snapshot.artifact);
      expect(snapshot.artifact.artifactId, isNot('file-1'));
      expect(snapshot.artifact.revision, 1);
      expect(snapshot.sourceDocument.documentRef.sourceId,
          snapshot.artifact.artifactId);
      expect(snapshot.sourceDocument.parts.single.sourceRef.sourceId,
          snapshot.artifact.artifactId);
    });

    test('stably missing sidecar is artifactCorrupt', () async {
      await seedLibraryFile();
      await ensure();
      final entry = artifactDirEntries().single;
      await File(p.join(tempDir.path, 'artifacts', entry)).delete();

      try {
        await currentArtifact('file-1');
        fail('expected artifactCorrupt');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.artifactCorrupt,
        );
      }
      expect(await artifactRepository.readRevisionHead('file-1'), 1);
      expect(
        (await artifactRepository.findCurrentByFileId('file-1'))!.revision,
        1,
      );
    });

    test('ensure hard-fails on stably missing sidecar without generation',
        () async {
      await seedLibraryFile();
      await ensure();
      final generateBefore = generation.generateCalls;
      final entry = artifactDirEntries().single;
      await File(p.join(tempDir.path, 'artifacts', entry)).delete();

      try {
        await ensure();
        fail('expected artifactCorrupt');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.artifactCorrupt,
        );
      }
      expect(generation.generateCalls, generateBefore);
      expect(await artifactRepository.readRevisionHead('file-1'), 1);
      expect(
        (await artifactRepository.findCurrentByFileId('file-1'))!.revision,
        1,
      );
    });

    test('replacement recovers the new current after the old sidecar vanished',
        () async {
      await seedLibraryFile();
      final first = await ensure();
      final oldKey = 'artifacts/${first.snapshot.artifact.artifactId}.json';
      await File(p.join(tempDir.path, oldKey)).delete();

      final reparsed = await service.reparseArtifact(
        fileId: 'file-1',
        options: _options,
        expectedRevision: 1,
      );

      expect(reparsed.outcome, ParsedArtifactLifecycleOutcome.published);
      expect(reparsed.snapshot.artifact.revision, 2);
      final current = await currentArtifact('file-1');
      expect(current.artifact.revision, 2);
      expect(await artifactRepository.readRevisionHead('file-1'), 2);
    });

    test('digest mismatch is artifactCorrupt', () async {
      await seedLibraryFile();
      await ensure();
      final entry = artifactDirEntries().single;
      final path = p.join(tempDir.path, 'artifacts', entry);
      final bytes = await File(path).readAsBytes();
      bytes[0] ^= 0xff;
      await File(path).writeAsBytes(bytes);

      try {
        await currentArtifact('file-1');
        fail('expected artifactCorrupt');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.artifactCorrupt,
        );
      }
    });

    test('size mismatch is artifactCorrupt', () async {
      await seedLibraryFile();
      await ensure();
      final entry = artifactDirEntries().single;
      await File(p.join(tempDir.path, 'artifacts', entry))
          .writeAsBytes(<int>[1, 2]);

      try {
        await currentArtifact('file-1');
        fail('expected artifactCorrupt');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.artifactCorrupt,
        );
      }
    });

    test('malformed JSON payload is artifactCorrupt', () async {
      await seedLibraryFile();
      final published = await ensure();
      final tamperedStorage = _TamperedReadStorage(storage);
      tamperedStorage.tamperedBytes[
              'artifacts/${published.snapshot.artifact.artifactId}.json'] =
          utf8.encode('{not json');
      final tamperedService = ParsedArtifactLifecycleService(
        libraryFileRepository: libraryRepository,
        artifactRepository: artifactRepository,
        artifactStorage: tamperedStorage,
        generationPort: generation,
      );

      try {
        await tamperedService.getCurrentArtifact('file-1');
        fail('expected artifactCorrupt');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.artifactCorrupt,
        );
      }
    });

    test('identity mismatch is artifactCorrupt', () async {
      await seedLibraryFile();
      final published = await ensure();
      final other = ParsedArtifactPayload(
        schemaVersion: ParsedArtifactPayloadCodec.schemaVersion,
        artifactId: 'other-artifact-0001',
        fileId: 'file-1',
        sourceDocument: SourceDocument(
          sourceId: 'other-artifact-0001',
          displayLabel: 'other',
        ),
      );
      final tamperedStorage = _TamperedReadStorage(storage);
      tamperedStorage.tamperedBytes[
              'artifacts/${published.snapshot.artifact.artifactId}.json'] =
          utf8.encode(
        jsonEncode(
          const ParsedArtifactPayloadCodec().encode(other),
        ),
      );
      final tamperedService = ParsedArtifactLifecycleService(
        libraryFileRepository: libraryRepository,
        artifactRepository: artifactRepository,
        artifactStorage: tamperedStorage,
        generationPort: generation,
      );

      try {
        await tamperedService.getCurrentArtifact('file-1');
        fail('expected artifactCorrupt');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.artifactCorrupt,
        );
      }
    });

    test('unsupported payload version is payloadUnsupported', () async {
      await seedLibraryFile();
      final published = await ensure();
      final tamperedStorage = _TamperedReadStorage(storage);
      tamperedStorage.tamperedBytes[
              'artifacts/${published.snapshot.artifact.artifactId}.json'] =
          utf8.encode(
        jsonEncode(<String, Object?>{
          'schemaVersion': 2,
          'artifactId': 'x',
          'fileId': 'y',
          'sourceDocument': <String, Object?>{},
        }),
      );
      final tamperedService = ParsedArtifactLifecycleService(
        libraryFileRepository: libraryRepository,
        artifactRepository: artifactRepository,
        artifactStorage: tamperedStorage,
        generationPort: generation,
      );

      try {
        await tamperedService.getCurrentArtifact('file-1');
        fail('expected payloadUnsupported');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.payloadUnsupported,
        );
      }
    });

    test('safe failures never leak raw path or payload text', () async {
      await seedLibraryFile();
      await ensure();
      final entry = artifactDirEntries().single;
      final path = p.join(tempDir.path, 'artifacts', entry);
      final bytes = await File(path).readAsBytes();
      bytes[0] ^= 0xff;
      await File(path).writeAsBytes(bytes);

      try {
        await currentArtifact('file-1');
        fail('expected artifactCorrupt');
      } catch (error) {
        final typed = expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.artifactCorrupt,
        );
        expect(typed.toString(), isNot(contains(tempDir.path)));
        expect(typed.toString(), isNot(contains('artifacts')));
        expect(typed.toString(), isNot(contains('file-1')));
        expect(typed.toString(), isNot(contains('parsed')));
        expect(typed.toString(), isNot(contains('UNIQUE')));
      }
    });
  });

  group('cache fingerprint v1', () {
    test('identical semantic inputs produce the same fingerprint', () {
      final first = computeParsedArtifactCacheKeyV1(
        sourceSha256: _sha256A,
        payloadSchemaVersion: 1,
        parserRoute: 'pdf_text',
        parserVersion: '1.0.0',
        optionsSchemaVersion: 1,
      );
      final second = computeParsedArtifactCacheKeyV1(
        sourceSha256: _sha256A,
        payloadSchemaVersion: 1,
        parserRoute: 'pdf_text',
        parserVersion: '1.0.0',
        optionsSchemaVersion: 1,
      );
      expect(first, second);
      expect(first.version, 1);
      expect(first.fingerprint, hasLength(64));
    });

    test('every semantic input changes the fingerprint', () {
      final base = computeParsedArtifactCacheKeyV1(
        sourceSha256: _sha256A,
        payloadSchemaVersion: 1,
        parserRoute: 'pdf_text',
        parserVersion: '1.0.0',
        optionsSchemaVersion: 1,
      );
      final variants = <ParsedArtifactCacheKey>[
        computeParsedArtifactCacheKeyV1(
          sourceSha256: _sha256B,
          payloadSchemaVersion: 1,
          parserRoute: 'pdf_text',
          parserVersion: '1.0.0',
          optionsSchemaVersion: 1,
        ),
        computeParsedArtifactCacheKeyV1(
          sourceSha256: _sha256A,
          payloadSchemaVersion: 2,
          parserRoute: 'pdf_text',
          parserVersion: '1.0.0',
          optionsSchemaVersion: 1,
        ),
        computeParsedArtifactCacheKeyV1(
          sourceSha256: _sha256A,
          payloadSchemaVersion: 1,
          parserRoute: 'txt',
          parserVersion: '1.0.0',
          optionsSchemaVersion: 1,
        ),
        computeParsedArtifactCacheKeyV1(
          sourceSha256: _sha256A,
          payloadSchemaVersion: 1,
          parserRoute: 'pdf_text',
          parserVersion: '2.0.0',
          optionsSchemaVersion: 1,
        ),
        computeParsedArtifactCacheKeyV1(
          sourceSha256: _sha256A,
          payloadSchemaVersion: 1,
          parserRoute: 'pdf_text',
          parserVersion: '1.0.0',
          optionsSchemaVersion: 2,
        ),
      ];
      for (final variant in variants) {
        expect(variant.fingerprint, isNot(base.fingerprint));
      }
    });

    test('non-semantic file facts never change the fingerprint', () async {
      await seedLibraryFile();
      await ensure();
      final firstMetadata =
          (await artifactRepository.findCurrentByFileId('file-1'))!;

      await libraryRepository.save(
        seededFile(
          fileId: 'file-2',
          displayName: 'renamed.pdf',
          storageKey: 'library/file-2',
        ),
      );
      final second = await service.ensureParsedArtifact(
        fileId: 'file-2',
        options: _options,
      );
      expect(second.outcome, ParsedArtifactLifecycleOutcome.published);
      final secondMetadata =
          (await artifactRepository.findCurrentByFileId('file-2'))!;

      expect(secondMetadata.cacheFingerprint, firstMetadata.cacheFingerprint);
      expect(secondMetadata.cacheKeyVersion, 1);
      expect(secondMetadata.sourceSha256, _sha256A);
    });
  });

  group('ensureParsedArtifact', () {
    test('first ensure publishes revision 1 with a bound generation', () async {
      await seedLibraryFile();
      final result = await ensure();

      expect(result.outcome, ParsedArtifactLifecycleOutcome.published);
      expect(result.snapshot.artifact.revision, 1);
      expect(result.snapshot.artifact.artifactId, isNot('file-1'));
      expect(result.snapshot.sourceDocument.documentRef.sourceId,
          result.snapshot.artifact.artifactId);
      final metadata =
          (await artifactRepository.findCurrentByFileId('file-1'))!;
      expect(metadata.revision, 1);
      expect(metadata.sizeBytes, greaterThan(0));
      expect(
        await storage.readArtifact(
          storageKey: metadata.storageKey,
          expectedSha256: metadata.payloadSha256,
          expectedSizeBytes: metadata.sizeBytes,
        ),
        isNotNull,
      );
    });

    test('semantic cache match returns cacheHit with zero generation writes',
        () async {
      await seedLibraryFile();
      final first = await ensure();
      expect(first.outcome, ParsedArtifactLifecycleOutcome.published);

      final second = await ensure();

      expect(second.outcome, ParsedArtifactLifecycleOutcome.cacheHit);
      expect(second.snapshot.artifact, first.snapshot.artifact);
      expect(generation.generateCalls, 1);
      expect(artifactDirEntries(), hasLength(1));
      expect(await artifactRepository.readRevisionHead('file-1'), 1);
    });

    test('changed source sha256 is a cache miss and publishes revision 2',
        () async {
      await seedLibraryFile();
      final first = await ensure();
      expect(first.snapshot.artifact.revision, 1);
      final db = await DatabaseHelper.instance.database;
      await db.update(
        'library_files',
        <String, Object?>{'sha256': _sha256B},
        where: 'file_id = ?',
        whereArgs: <Object?>['file-1'],
      );

      final second = await ensure();

      expect(second.outcome, ParsedArtifactLifecycleOutcome.published);
      expect(second.snapshot.artifact.revision, 2);
      expect(second.snapshot.artifact.artifactId,
          isNot(first.snapshot.artifact.artifactId));
      final current = await currentArtifact('file-1');
      expect(current.artifact.revision, 2);
    });

    test('explicit route mismatch with the plan is an internal error',
        () async {
      await seedLibraryFile();
      generation.planOverride = (selection) => ParsedArtifactGenerationPlan(
            parserRoute: 'ocr_pdf',
            parserVersion: '1.0.0',
            optionsSchemaVersion: 1,
          );
      try {
        await ensure(
          options: const ParsedArtifactParseOptions(
            routeSelection: ParsedArtifactRouteSelection.pdfText,
          ),
        );
        fail('expected internalError');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.internalError,
        );
      }
    });

    test('auto never resolves to an OCR route', () async {
      await seedLibraryFile();
      generation.planOverride = (selection) => ParsedArtifactGenerationPlan(
            parserRoute: 'ocr_pdf',
            parserVersion: '1.0.0',
            optionsSchemaVersion: 1,
          );
      try {
        await ensure();
        fail('expected internalError');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.internalError,
        );
      }
    });
  });

  group('reparseArtifact', () {
    test('identical fingerprint still creates a new generation', () async {
      await seedLibraryFile();
      final first = await ensure();
      final firstMetadata =
          (await artifactRepository.findCurrentByFileId('file-1'))!;

      final reparsed = await service.reparseArtifact(
        fileId: 'file-1',
        options: _options,
        expectedRevision: 1,
      );

      expect(reparsed.outcome, ParsedArtifactLifecycleOutcome.published);
      expect(reparsed.snapshot.artifact.revision, 2);
      expect(reparsed.snapshot.artifact.artifactId,
          isNot(first.snapshot.artifact.artifactId));
      final secondMetadata =
          (await artifactRepository.findCurrentByFileId('file-1'))!;
      expect(secondMetadata.cacheFingerprint, firstMetadata.cacheFingerprint);
    });

    test('stale expectedRevision conflicts before any generation call',
        () async {
      await seedLibraryFile();
      await ensure();
      final resolveAfterEnsure = generation.resolveCalls;
      final generateAfterEnsure = generation.generateCalls;

      try {
        await service.reparseArtifact(
          fileId: 'file-1',
          options: _options,
          expectedRevision: 5,
        );
        fail('expected publishConflict');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.publishConflict,
        );
      }
      expect(generation.resolveCalls, resolveAfterEnsure);
      expect(generation.generateCalls, generateAfterEnsure);
      expect(await artifactRepository.readRevisionHead('file-1'), 1);
    });

    test('parse failure preserves the old current and head', () async {
      await seedLibraryFile();
      await ensure();
      generation.generateError = const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.parseFailed,
      );

      try {
        await service.reparseArtifact(
          fileId: 'file-1',
          options: _options,
          expectedRevision: 1,
        );
        fail('expected parseFailed');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.parseFailed,
        );
      }
      final current = await currentArtifact('file-1');
      expect(current.artifact.revision, 1);
      expect(await artifactRepository.readRevisionHead('file-1'), 1);
      expect(artifactDirEntries(), hasLength(1));
    });

    test('reparse replaces a corrupt old payload', () async {
      await seedLibraryFile();
      await ensure();
      final entry = artifactDirEntries().single;
      await File(p.join(tempDir.path, 'artifacts', entry)).delete();

      final reparsed = await service.reparseArtifact(
        fileId: 'file-1',
        options: _options,
        expectedRevision: 1,
      );

      expect(reparsed.outcome, ParsedArtifactLifecycleOutcome.published);
      expect(reparsed.snapshot.artifact.revision, 2);
      final current = await currentArtifact('file-1');
      expect(current.artifact.revision, 2);
    });
  });

  group('publish CAS and cleanup', () {
    test('CAS loser cleans the candidate and leaves the old current intact',
        () async {
      await seedLibraryFile();
      final injectingRepository =
          _ConflictInjectingRepository(artifactRepository);
      final casService = ParsedArtifactLifecycleService(
        libraryFileRepository: libraryRepository,
        artifactRepository: injectingRepository,
        artifactStorage: storage,
        generationPort: generation,
      );
      await casService.ensureParsedArtifact(
          fileId: 'file-1', options: _options);
      expect(artifactDirEntries(), hasLength(1));

      injectingRepository.inject = true;
      try {
        await casService.reparseArtifact(
          fileId: 'file-1',
          options: _options,
          expectedRevision: 1,
        );
        fail('expected publishConflict');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.publishConflict,
        );
      }
      expect(artifactDirEntries(), hasLength(1));
      final current = await casService.getCurrentArtifact('file-1');
      expect(current.artifact.revision, 1);
      expect(await artifactRepository.readRevisionHead('file-1'), 1);
    });

    test('old-sidecar cleanup failure never rolls back publication', () async {
      await seedLibraryFile();
      final failingStorage = _FailingDeleteStorage(storage);
      final cleanupService = ParsedArtifactLifecycleService(
        libraryFileRepository: libraryRepository,
        artifactRepository: artifactRepository,
        artifactStorage: failingStorage,
        generationPort: generation,
      );
      final first = await cleanupService.ensureParsedArtifact(
        fileId: 'file-1',
        options: _options,
      );
      expect(first.outcome, ParsedArtifactLifecycleOutcome.published);
      final oldKey = 'artifacts/${first.snapshot.artifact.artifactId}.json';

      failingStorage.failAllDeletes = true;
      final reparsed = await cleanupService.reparseArtifact(
        fileId: 'file-1',
        options: _options,
        expectedRevision: 1,
      );

      expect(reparsed.outcome, ParsedArtifactLifecycleOutcome.published);
      expect(reparsed.snapshot.artifact.revision, 2);
      final current = await cleanupService.getCurrentArtifact('file-1');
      expect(current.artifact.revision, 2);
      expect(File(p.join(tempDir.path, oldKey)).existsSync(), isTrue);
    });

    test('candidate cleanup failure does not replace the primary failure',
        () async {
      await seedLibraryFile();
      final injectingRepository =
          _ConflictInjectingRepository(artifactRepository);
      final failingStorage = _FailingDeleteStorage(storage);
      final casService = ParsedArtifactLifecycleService(
        libraryFileRepository: libraryRepository,
        artifactRepository: injectingRepository,
        artifactStorage: failingStorage,
        generationPort: generation,
      );
      await casService.ensureParsedArtifact(
          fileId: 'file-1', options: _options);

      injectingRepository.inject = true;
      failingStorage.failAllDeletes = true;
      try {
        await casService.reparseArtifact(
          fileId: 'file-1',
          options: _options,
          expectedRevision: 1,
        );
        fail('expected publishConflict');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.publishConflict,
        );
      }
      final current = await casService.getCurrentArtifact('file-1');
      expect(current.artifact.revision, 1);
      expect(artifactDirEntries(), hasLength(2));
    });

    test('remove-sidecar cleanup failure still returns removed', () async {
      await seedLibraryFile();
      final failingStorage = _FailingDeleteStorage(storage);
      final cleanupService = ParsedArtifactLifecycleService(
        libraryFileRepository: libraryRepository,
        artifactRepository: artifactRepository,
        artifactStorage: failingStorage,
        generationPort: generation,
      );
      final first = await cleanupService.ensureParsedArtifact(
        fileId: 'file-1',
        options: _options,
      );
      final oldKey = 'artifacts/${first.snapshot.artifact.artifactId}.json';

      failingStorage.failAllDeletes = true;
      await cleanupService.removeCurrentArtifact(
        fileId: 'file-1',
        expectedRevision: 1,
      );

      expect(await artifactRepository.findCurrentByFileId('file-1'), isNull);
      expect(await artifactRepository.readRevisionHead('file-1'), 1);
      expect(File(p.join(tempDir.path, oldKey)).existsSync(), isTrue);
    });
  });

  group('removeCurrentArtifact', () {
    test('removes current, retains the head, and continues revision', () async {
      await seedLibraryFile();
      await ensure();

      await service.removeCurrentArtifact(
        fileId: 'file-1',
        expectedRevision: 1,
      );

      expect(await artifactRepository.findCurrentByFileId('file-1'), isNull);
      expect(await artifactRepository.readRevisionHead('file-1'), 1);
      expect(artifactDirEntries(), isEmpty);

      final next = await ensure();
      expect(next.outcome, ParsedArtifactLifecycleOutcome.published);
      expect(next.snapshot.artifact.revision, 2);
    });

    test('repeated remove is artifactMissing', () async {
      await seedLibraryFile();
      await ensure();
      await service.removeCurrentArtifact(
        fileId: 'file-1',
        expectedRevision: 1,
      );

      try {
        await service.removeCurrentArtifact(
          fileId: 'file-1',
          expectedRevision: 1,
        );
        fail('expected artifactMissing');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.artifactMissing,
        );
      }
      expect(await artifactRepository.readRevisionHead('file-1'), 1);
    });

    test('stale expectedRevision is publishConflict', () async {
      await seedLibraryFile();
      await ensure();

      try {
        await service.removeCurrentArtifact(
          fileId: 'file-1',
          expectedRevision: 2,
        );
        fail('expected publishConflict');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.publishConflict,
        );
      }
      expect((await currentArtifact('file-1')).artifact.revision, 1);
    });

    test('remove on a missing LibraryFile is fileNotFound', () async {
      try {
        await service.removeCurrentArtifact(
          fileId: 'file-missing',
          expectedRevision: 0,
        );
        fail('expected fileNotFound');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.fileNotFound,
        );
      }
    });
  });

  group('concurrency', () {
    test('two concurrent ensures produce one published and one cacheHit',
        () async {
      await seedLibraryFile();

      final results = await Future.wait(<Future<ParsedArtifactEnsureResult>>[
        ensure(),
        ensure(),
      ]);

      final outcomes = results.map((result) => result.outcome).toList();
      expect(
        outcomes.where(
          (outcome) => outcome == ParsedArtifactLifecycleOutcome.published,
        ),
        hasLength(1),
      );
      expect(
        outcomes.where(
          (outcome) => outcome == ParsedArtifactLifecycleOutcome.cacheHit,
        ),
        hasLength(1),
      );
      expect(generation.generateCalls, 1);
      expect(results[0].snapshot.artifact, results[1].snapshot.artifact);
      expect(await artifactRepository.readRevisionHead('file-1'), 1);
    });

    test('two concurrent reparses produce one published and one conflict',
        () async {
      await seedLibraryFile();
      await ensure();
      final resolveBeforeReparse = generation.resolveCalls;
      final generateBeforeReparse = generation.generateCalls;

      final results = await Future.wait(<Future<Object>>[
        service
            .reparseArtifact(
              fileId: 'file-1',
              options: _options,
              expectedRevision: 1,
            )
            .then<Object>((result) => result),
        service
            .reparseArtifact(
              fileId: 'file-1',
              options: _options,
              expectedRevision: 1,
            )
            .then<Object>((result) => result, onError: (Object error) => error),
      ]);

      final successes =
          results.whereType<ParsedArtifactEnsureResult>().toList();
      final failures =
          results.whereType<ParsedArtifactLifecycleException>().toList();
      expect(successes, hasLength(1));
      expect(failures, hasLength(1));
      expect(
        failures.single.failure,
        ParsedArtifactLifecycleFailure.publishConflict,
      );
      expect(generation.resolveCalls, resolveBeforeReparse + 1);
      expect(generation.generateCalls, generateBeforeReparse + 1);
      expect(await artifactRepository.readRevisionHead('file-1'), 2);
    });

    test('different fileIds do not share one global lock', () async {
      await seedLibraryFile(fileId: 'file-1');
      await seedLibraryFile(fileId: 'file-2');

      final results = await Future.wait(<Future<ParsedArtifactEnsureResult>>[
        ensure(fileId: 'file-1'),
        ensure(fileId: 'file-2'),
      ]);

      expect(
        results.every(
          (result) =>
              result.outcome == ParsedArtifactLifecycleOutcome.published,
        ),
        isTrue,
      );
      expect(generation.generateCalls, 2);
      expect(await artifactRepository.readRevisionHead('file-1'), 1);
      expect(await artifactRepository.readRevisionHead('file-2'), 1);
    });
  });

  group('visibility during generation', () {
    test('an in-flight reparse keeps the old artifact readable', () async {
      await seedLibraryFile();
      await ensure();

      generation.pause = Completer<void>();
      final reparseFuture = service.reparseArtifact(
        fileId: 'file-1',
        options: _options,
        expectedRevision: 1,
      );
      await waitUntil(() => generation.generateCalls == 1);

      final during = await currentArtifact('file-1');
      expect(during.artifact.revision, 1);

      generation.pause!.complete();
      final result = await reparseFuture;
      expect(result.outcome, ParsedArtifactLifecycleOutcome.published);
      expect(result.snapshot.artifact.revision, 2);

      final after = await currentArtifact('file-1');
      expect(after.artifact.revision, 2);
    });

    test('a failed paused reparse leaves the old artifact readable', () async {
      await seedLibraryFile();
      await ensure();

      generation.pause = Completer<void>();
      generation.generateError = const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.parseFailed,
      );
      final reparseFuture = service.reparseArtifact(
        fileId: 'file-1',
        options: _options,
        expectedRevision: 1,
      );
      await waitUntil(() => generation.generateCalls == 1);

      generation.pause!.complete();
      try {
        await reparseFuture;
        fail('expected parseFailed');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.parseFailed,
        );
      }
      final current = await currentArtifact('file-1');
      expect(current.artifact.revision, 1);
    });
  });

  group('replacement race boundaries', () {
    ParsedArtifactLifecycleService scriptedService(
      ParsedArtifactRepositoryPort repository,
      ManagedArtifactStorage storage,
    ) {
      return ParsedArtifactLifecycleService(
        libraryFileRepository: libraryRepository,
        artifactRepository: repository,
        artifactStorage: storage,
        generationPort: generation,
      );
    }

    test('stable generation with missing sidecar is artifactCorrupt', () async {
      await seedLibraryFile();
      final metadata = scriptedMetadata();
      final service = scriptedService(
        _ScriptedCurrentRepository(
            <ParsedArtifactMetadata?>[metadata, metadata]),
        _ScriptedSidecarStorage(const <String, List<int>>{}),
      );

      try {
        await service.getCurrentArtifact('file-1');
        fail('expected artifactCorrupt');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.artifactCorrupt,
        );
      }
    });

    test('changed generation recovers through the latest current', () async {
      await seedLibraryFile();
      final first = scriptedMetadata();
      final latest = scriptedMetadata(
        artifactId: 'artifact-2',
        revision: 2,
        storageKey: 'artifacts/artifact-2.json',
      );
      final service = scriptedService(
        _ScriptedCurrentRepository(<ParsedArtifactMetadata?>[first, latest]),
        _ScriptedSidecarStorage(
          <String, List<int>>{latest.storageKey: scriptedPayloadBytes(latest)},
        ),
      );

      final snapshot = await service.getCurrentArtifact('file-1');

      expect(snapshot.artifact.artifactId, 'artifact-2');
      expect(snapshot.artifact.revision, 2);
    });

    test('continuously changing generations become transient, not missing',
        () async {
      await seedLibraryFile();
      final first = scriptedMetadata();
      final second = scriptedMetadata(
        artifactId: 'artifact-2',
        revision: 2,
        storageKey: 'artifacts/artifact-2.json',
      );
      final third = scriptedMetadata(
        artifactId: 'artifact-3',
        revision: 3,
        storageKey: 'artifacts/artifact-3.json',
      );
      final service = scriptedService(
        _ScriptedCurrentRepository(
          <ParsedArtifactMetadata?>[first, second, third],
        ),
        _ScriptedSidecarStorage(const <String, List<int>>{}),
      );

      try {
        await service.getCurrentArtifact('file-1');
        fail('expected temporarilyUnavailable');
      } catch (error) {
        expectLifecycleFailure(
          error,
          failure: ParsedArtifactLifecycleFailure.temporarilyUnavailable,
        );
      }
    });
  });
}
