import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/repositories/library_file_repository.dart';
import 'package:shiroha_quiz/data/repositories/parsed_artifact_repository.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/services/file_library/managed_artifact_storage_adapter.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document_client.dart';
import 'package:shiroha_quiz/services/parsed_artifacts/deterministic_parsed_artifact_generation_adapter.dart';
import 'package:shiroha_quiz/services/parsed_artifacts/ocr_parsed_artifact_generation_adapter.dart';
import 'package:shiroha_quiz/services/parsed_artifacts/parsed_artifact_generation_router.dart';
import 'package:shiroha_quiz/services/parsed_artifacts/parsed_artifact_lifecycle_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _sha256 =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

class _FakeOcrClient implements OcrDocumentClient {
  int callCount = 0;

  @override
  String get modelId => 'glm-ocr';

  @override
  Future<OcrDocument> parseFile({
    required AiEngineProfile profile,
    required String filePath,
    required String sourceName,
    Duration timeout = const Duration(minutes: 8),
  }) async {
    callCount++;
    return OcrDocument(
      sourceName: sourceName,
      pages: <OcrPage>[
        OcrPage(
          pageIndex: 1,
          blocks: <OcrBlock>[
            OcrBlock(
              blockId: 'p001_b0001',
              pageIndex: 1,
              type: 'text',
              text: 'formal ocr text',
              bbox: const <double>[],
              readingOrder: 0,
            ),
          ],
        ),
      ],
      markdown: '',
      rawResponses: const <Map<String, dynamic>>[],
      usage: const <String, dynamic>{},
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LibraryFileRepository libraryRepository;
  late ParsedArtifactRepository artifactRepository;
  late ManagedFileStorageAdapter originalStorage;
  late ManagedArtifactStorageAdapter artifactStorage;
  late _FakeOcrClient ocrClient;
  AiEngineProfile? activeProfile;
  late ParsedArtifactLifecycleService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    tempDir = await Directory.systemTemp.createTemp('i2_integration_');
    libraryRepository = LibraryFileRepository();
    artifactRepository = ParsedArtifactRepository();
    originalStorage = ManagedFileStorageAdapter(managedRoot: tempDir);
    artifactStorage = ManagedArtifactStorageAdapter(managedRoot: tempDir);
    ocrClient = _FakeOcrClient();
    activeProfile = const AiEngineProfile(
      id: 'test-ocr',
      engineType: AiEngineType.ocr,
      name: 'Test OCR',
      apiKey: 'fixture-key',
      baseUrl: 'https://open.bigmodel.cn/api/paas',
      modelName: 'glm-ocr',
      temperature: 0,
      reasoningEffort: '',
      isActive: true,
    );
    final router = ParsedArtifactGenerationRouter(
      deterministicGeneration: DeterministicParsedArtifactGenerationAdapter(
        managedFileStorage: originalStorage,
      ),
      ocrGeneration: OcrParsedArtifactGenerationAdapter(
        managedFileStorage: originalStorage,
        ocrClient: ocrClient,
        activeOcrProfileLoader: () async => activeProfile,
      ),
    );
    service = ParsedArtifactLifecycleService(
      libraryFileRepository: libraryRepository,
      artifactRepository: artifactRepository,
      artifactStorage: artifactStorage,
      generationPort: router,
    );
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> seedOcrImage() async {
    final fixture = File(p.join(tempDir.path, 'source_fixture.png'));
    await fixture.writeAsBytes(<int>[137, 80, 78, 71, 1, 2, 3, 4]);
    await originalStorage.copyIntoManagedStorage(
      externalPath: fixture.path,
      storageKey: 'library/file-1',
    );
    await fixture.delete();
    await libraryRepository.save(
      LibraryFile(
        fileId: 'file-1',
        displayName: 'page.png',
        mimeType: 'image/png',
        sizeBytes: 8,
        sha256: _sha256,
        storageKey: 'library/file-1',
        createdAt: DateTime.utc(2026, 8, 13),
      ),
    );
  }

  ParsedArtifactParseOptions ocrOptions() {
    return const ParsedArtifactParseOptions(
      routeSelection: ParsedArtifactRouteSelection.ocrImage,
    );
  }

  test('explicit OCR ensure -> publish -> cacheHit -> reparse end to end',
      () async {
    await seedOcrImage();

    final first = await service.ensureParsedArtifact(
      fileId: 'file-1',
      options: ocrOptions(),
    );
    expect(first.outcome, ParsedArtifactLifecycleOutcome.published);
    expect(first.snapshot.artifact.revision, 1);
    expect(first.snapshot.artifact.artifactId, isNot('file-1'));
    final metadata = (await artifactRepository.findCurrentByFileId('file-1'))!;
    expect(metadata.parserRoute, 'ocr_image');
    expect(metadata.parserVersion, 'glm-ocr.ocr-source-adapter.v1');
    expect(ocrClient.callCount, 1);

    final current = await service.getCurrentArtifact('file-1');
    expect(current.artifact, first.snapshot.artifact);
    expect(current.sourceDocument.documentRef.sourceId,
        first.snapshot.artifact.artifactId);

    final second = await service.ensureParsedArtifact(
      fileId: 'file-1',
      options: ocrOptions(),
    );
    expect(second.outcome, ParsedArtifactLifecycleOutcome.cacheHit);
    expect(second.snapshot.artifact, first.snapshot.artifact);
    expect(ocrClient.callCount, 1);

    final reparsed = await service.reparseArtifact(
      fileId: 'file-1',
      options: ocrOptions(),
      expectedRevision: 1,
    );
    expect(reparsed.outcome, ParsedArtifactLifecycleOutcome.published);
    expect(reparsed.snapshot.artifact.revision, 2);
    expect(reparsed.snapshot.artifact.artifactId,
        isNot(first.snapshot.artifact.artifactId));
    expect(ocrClient.callCount, 2);
  });

  test('cache stays readable after OCR config removal; reparse unavailables',
      () async {
    await seedOcrImage();
    await service.ensureParsedArtifact(fileId: 'file-1', options: ocrOptions());
    expect(ocrClient.callCount, 1);

    activeProfile = null;

    final cached = await service.ensureParsedArtifact(
      fileId: 'file-1',
      options: ocrOptions(),
    );
    expect(cached.outcome, ParsedArtifactLifecycleOutcome.cacheHit);
    expect(ocrClient.callCount, 1);

    try {
      await service.reparseArtifact(
        fileId: 'file-1',
        options: ocrOptions(),
        expectedRevision: 1,
      );
      fail('expected temporarilyUnavailable');
    } on ParsedArtifactLifecycleException catch (error) {
      expect(
        error.failure,
        ParsedArtifactLifecycleFailure.temporarilyUnavailable,
      );
    }

    final preserved = await service.getCurrentArtifact('file-1');
    expect(preserved.artifact.revision, 1);
    expect(await artifactRepository.readRevisionHead('file-1'), 1);
  });
}
