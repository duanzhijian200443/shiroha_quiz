import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_ports.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/persistence/ai_engine_store.dart';
import 'package:shiroha_quiz/data/persistence/engine_credential_store.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/assets/parsed_artifact.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document_client.dart';
import 'package:shiroha_quiz/services/parsed_artifacts/deterministic_parsed_artifact_generation_adapter.dart';
import 'package:shiroha_quiz/services/parsed_artifacts/ocr_parsed_artifact_generation_adapter.dart';
import 'package:shiroha_quiz/services/parsed_artifacts/parsed_artifact_generation_router.dart';
import 'package:shiroha_quiz/services/retrieval/deterministic_source_chunker.dart';
import 'package:shiroha_quiz/services/retrieval/parsed_artifact_retrieval_source.dart';

const _sha = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

LibraryFile _file(String id, {String name = 'doc.pdf'}) => LibraryFile(
      fileId: id,
      displayName: name,
      mimeType: name.endsWith('.pdf') ? 'application/pdf' : 'text/plain',
      sizeBytes: 1024,
      sha256: _sha,
      storageKey: 'library/$id',
      createdAt: DateTime.utc(2026, 8, 14),
    );

final class _FakeManagedFileStorage extends Fake implements ManagedFileStorage {
  final Map<String, List<int>> storage = <String, List<int>>{};

  @override
  Future<bool> managedFileExists(String storageKey) async =>
      storage.containsKey(storageKey);

  @override
  File resolveManagedFile(String storageKey) {
    final tempDir = Directory.systemTemp.createTempSync('storage_test_');
    final file = File('${tempDir.path}/test.pdf');
    file.writeAsBytesSync(storage[storageKey] ?? <int>[1, 2, 3]);
    return file;
  }
}

final class _FakeAiEngineStore extends Fake implements AiEngineStore {
  AiEngineProfile? activeOcrProfile;

  @override
  Future<AiEngineProfile?> getActiveAiEngine(AiEngineType type) async {
    return type == AiEngineType.ocr ? activeOcrProfile : null;
  }

  @override
  Future<List<AiEngineProfile>> listAiEngines(AiEngineType type) async {
    final p = activeOcrProfile;
    return (type == AiEngineType.ocr && p != null)
        ? <AiEngineProfile>[p]
        : <AiEngineProfile>[];
  }
}

final class _FakeCredentialStore extends Fake implements EngineCredentialStore {
  final Map<String, String> credentials = <String, String>{};

  @override
  Future<String?> readCredential(String engineId) async =>
      credentials[engineId];

  @override
  Future<void> writeCredential(String engineId, String secret) async {
    credentials[engineId] = secret;
  }

  @override
  Future<void> deleteCredential(String engineId) async {
    credentials.remove(engineId);
  }
}

final class _FakeOcrClient extends Fake implements OcrDocumentClient {
  int parseCalls = 0;
  AiEngineProfile? lastProfile;

  @override
  String get modelId => 'glm-ocr';

  @override
  Future<OcrDocument> parseFile({
    required AiEngineProfile profile,
    required String filePath,
    required String sourceName,
    Duration timeout = const Duration(minutes: 8),
  }) async {
    parseCalls++;
    lastProfile = profile;
    return const OcrDocument(
      sourceName: 'test.pdf',
      markdown: '# OCR Extracted Content\nSample recognized paragraph.',
      pages: <OcrPage>[
        OcrPage(
          pageIndex: 0,
          blocks: <OcrBlock>[
            OcrBlock(
              blockId: 'b1',
              pageIndex: 0,
              type: 'text',
              readingOrder: 1,
              text: 'Sample recognized paragraph.',
              bbox: <double>[],
            ),
          ],
        ),
      ],
      rawResponses: <Map<String, dynamic>>[],
      usage: <String, dynamic>{},
    );
  }
}

final class _FakeLifecyclePort extends Fake
    implements ParsedArtifactLifecyclePort {
  final Map<String, ParsedArtifactSnapshot> artifacts =
      <String, ParsedArtifactSnapshot>{};

  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async {
    final a = artifacts[fileId];
    if (a == null) {
      throw const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.artifactMissing,
      );
    }
    return a;
  }
}

final class _FakeMetadataPort extends Fake
    implements ParsedArtifactRepositoryPort {
  final Map<String, ParsedArtifactMetadata> metadata =
      <String, ParsedArtifactMetadata>{};

  @override
  Future<ParsedArtifactMetadata?> findCurrentByFileId(String fileId) async =>
      metadata[fileId];
}

void main() {
  late _FakeManagedFileStorage managedStorage;
  late _FakeAiEngineStore aiEngineStore;
  late _FakeCredentialStore credentialStore;
  late AiEngineRepository engineRepository;
  late _FakeOcrClient ocrClient;
  late ParsedArtifactGenerationRouter router;

  setUp(() {
    managedStorage = _FakeManagedFileStorage();
    managedStorage.storage['library/file-pdf'] = <int>[37, 80, 68, 70]; // %PDF
    aiEngineStore = _FakeAiEngineStore();
    credentialStore = _FakeCredentialStore();
    engineRepository = AiEngineRepository(
      store: aiEngineStore,
      credentialStore: credentialStore,
    );
    ocrClient = _FakeOcrClient();

    router = ParsedArtifactGenerationRouter(
      deterministicGeneration: DeterministicParsedArtifactGenerationAdapter(
        managedFileStorage: managedStorage,
      ),
      ocrGeneration: OcrParsedArtifactGenerationAdapter(
        managedFileStorage: managedStorage,
        ocrClient: ocrClient,
        activeOcrProfileLoader: engineRepository.getActiveOcrEngine,
      ),
    );
  });

  test(
      'production generation router routes deterministic vs OCR plans correctly',
      () async {
    final pdfFile = _file('file-pdf', name: 'scan.pdf');

    // Auto resolves deterministic
    final autoPlan = await router.resolvePlan(
      file: pdfFile,
      options: const ParsedArtifactParseOptions(
        routeSelection: ParsedArtifactRouteSelection.auto,
      ),
    );
    expect(autoPlan.parserRoute, 'pdf_text');

    // Explicit ocrPdf resolves ocr_pdf
    final ocrPlan = await router.resolvePlan(
      file: pdfFile,
      options: const ParsedArtifactParseOptions(
        routeSelection: ParsedArtifactRouteSelection.ocrPdf,
      ),
    );
    expect(ocrPlan.parserRoute, 'ocr_pdf');
  });

  test('OCR generation adapter loads active OCR engine profile from repository',
      () async {
    const ocrEngineId = 'ocr-engine-1';
    aiEngineStore.activeOcrProfile = const AiEngineProfile(
      id: ocrEngineId,
      name: 'GLM OCR',
      engineType: AiEngineType.ocr,
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      modelName: 'glm-ocr',
      apiKey: '',
      temperature: 0.7,
      reasoningEffort: 'medium',
      isActive: true,
    );
    credentialStore.credentials[ocrEngineId] = 'test-secret-key';

    final pdfFile = _file('file-pdf', name: 'scan.pdf');
    final plan = const ParsedArtifactGenerationPlan(
      parserRoute: 'ocr_pdf',
      parserVersion: 'v1',
      optionsSchemaVersion: 1,
    );

    final doc = await router.generate(
      file: pdfFile,
      artifactId: 'art-ocr-1',
      plan: plan,
    );

    expect(doc.documentRef.sourceId, 'art-ocr-1');
    expect(ocrClient.parseCalls, 1);
    expect(ocrClient.lastProfile, isNotNull);
    expect(ocrClient.lastProfile!.apiKey, 'test-secret-key');
    expect(ocrClient.lastProfile!.engineType, AiEngineType.ocr);
  });

  test(
      'RAG lexical retrieval source successfully provisions and chunks OCR-produced ParsedArtifact',
      () async {
    final lifecycle = _FakeLifecyclePort();
    final metadata = _FakeMetadataPort();

    const artifactId = 'art-ocr-123';
    final ocrDoc = SourceDocument(
      sourceId: artifactId,
      parts: <SourcePart>[
        SourceContentPart(
          sourceRef: SourceRef.document(sourceId: artifactId),
          content: RichContent(
            nodes: <ContentNode>[
              const TextNode(
                'Machine learning is a field of artificial intelligence.',
              ),
            ],
          ),
        ),
      ],
    );

    final snapshot = ParsedArtifactSnapshot(
      artifact: ParsedArtifact(
        fileId: 'file-pdf',
        artifactId: artifactId,
        revision: 1,
        payloadSchemaVersion: 1,
      ),
      sourceDocument: ocrDoc,
      parserRoute: 'ocr_pdf',
    );

    lifecycle.artifacts['file-pdf'] = snapshot;
    metadata.metadata['file-pdf'] = ParsedArtifactMetadata(
      artifact: snapshot.artifact,
      sourceSha256: _sha,
      cacheKeyVersion: 1,
      cacheFingerprint: 'fp-1',
      parserRoute: 'ocr_pdf',
      parserVersion: 'v1',
      optionsSchemaVersion: 1,
      storageKey: 'library/art-ocr-123',
      payloadSha256: _sha,
      sizeBytes: 100,
      publishedAt: 1723651200,
    );

    final source = ParsedArtifactRetrievalSource(
      lifecycle: lifecycle,
      metadata: metadata,
    );

    final retrievalResult = await source.loadCurrent('file-pdf');
    expect(retrievalResult.sourceDocument.documentRef.sourceId, artifactId);
    expect(retrievalResult.identity.artifactId, artifactId);

    const chunker = DeterministicSourceChunker();
    final projection = chunker.project(
      fileId: 'file-pdf',
      artifactId: artifactId,
      revision: 1,
      document: retrievalResult.sourceDocument,
    );
    expect(projection.chunks, isNotEmpty);
    expect(projection.chunks.first.content, contains('Machine learning'));
  });
}
