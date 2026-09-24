import 'dart:async';
import 'dart:io';

import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/content/content_asset_authority.dart';
import 'package:shiroha_quiz/application/content/content_asset_reclamation_reset.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/core/observability/app_logger.dart';
import 'package:shiroha_quiz/core/observability/log_record.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_source_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_format.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_result.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document_client.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_import_service.dart';
import 'package:shiroha_quiz/services/task_manager.dart';

import '../../support/unsupported_ai_engine_store.dart';

const _sourceId = '11111111-1111-4111-8111-111111111111';
const _secondSourceId = '44444444-4444-4444-8444-444444444444';
const _questionId = '22222222-2222-4222-8222-222222222222';
const _reviewId = '33333333-3333-4333-8333-333333333333';
const _pngDataUrl = 'data:image/png;base64,'
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
    '+A8AAQUBAScY42YAAAAASUVORK5CYII=';

/// Wraps a real store and reports a post-visibility failure for the first
/// created identity, so the adapter's ownership callback path is exercised
/// without changing the production store.
final class _VisibilityFailingStore implements ContentAssetStore {
  _VisibilityFailingStore(this.delegate);

  final ContentAssetStore delegate;

  @override
  ContentAssetWriteResult storeBytesSync({
    required String sourceId,
    required String localAssetId,
    required List<int> bytes,
    required String mimeType,
  }) {
    final stored = delegate.storeBytesSync(
      sourceId: sourceId,
      localAssetId: localAssetId,
      bytes: bytes,
      mimeType: mimeType,
    );
    if (stored.created) throw const ContentAssetWriteVisibilityException();
    return stored;
  }

  @override
  String storageKey({required String sourceId, required String localAssetId}) =>
      delegate.storageKey(sourceId: sourceId, localAssetId: localAssetId);

  @override
  Future<ContentAssetWriteResult> storeBytes({
    required String sourceId,
    required String localAssetId,
    required List<int> bytes,
    required String mimeType,
  }) =>
      delegate.storeBytes(
        sourceId: sourceId,
        localAssetId: localAssetId,
        bytes: bytes,
        mimeType: mimeType,
      );

  @override
  Future<ContentAssetRollbackResult> deleteCandidateAssets(
    ContentAssetCandidateLease lease,
  ) =>
      delegate.deleteCandidateAssets(lease);

  @override
  List<int>? readAssetBytes({
    required String sourceId,
    required String localAssetId,
  }) =>
      delegate.readAssetBytes(sourceId: sourceId, localAssetId: localAssetId);

  @override
  Future<bool> assetExists({
    required String sourceId,
    required String localAssetId,
  }) =>
      delegate.assetExists(sourceId: sourceId, localAssetId: localAssetId);

  @override
  Future<List<ContentAssetRecord>> listAssets() => delegate.listAssets();
}

final class _ResetProbe implements ContentAssetReclamationResetPort {
  final List<(String, List<String>)> calls = <(String, List<String>)>[];

  @override
  Future<void> resetBeforeOwnership({
    required String sourceId,
    required Iterable<String> localAssetIds,
  }) async {
    calls.add((sourceId, localAssetIds.toList(growable: false)));
  }
}

/// Records whether every byte write happened after a reclamation reset.
final class _ResetOrderWitnessStore implements ContentAssetStore {
  _ResetOrderWitnessStore(this.delegate, this.probe);

  final ContentAssetStore delegate;
  final _ResetProbe probe;
  bool everyWriteHadReset = true;

  @override
  ContentAssetWriteResult storeBytesSync({
    required String sourceId,
    required String localAssetId,
    required List<int> bytes,
    required String mimeType,
  }) {
    if (probe.calls.isEmpty) everyWriteHadReset = false;
    return delegate.storeBytesSync(
      sourceId: sourceId,
      localAssetId: localAssetId,
      bytes: bytes,
      mimeType: mimeType,
    );
  }

  @override
  String storageKey({required String sourceId, required String localAssetId}) =>
      delegate.storageKey(sourceId: sourceId, localAssetId: localAssetId);

  @override
  Future<ContentAssetWriteResult> storeBytes({
    required String sourceId,
    required String localAssetId,
    required List<int> bytes,
    required String mimeType,
  }) =>
      delegate.storeBytes(
        sourceId: sourceId,
        localAssetId: localAssetId,
        bytes: bytes,
        mimeType: mimeType,
      );

  @override
  Future<ContentAssetRollbackResult> deleteCandidateAssets(
    ContentAssetCandidateLease lease,
  ) =>
      delegate.deleteCandidateAssets(lease);

  @override
  List<int>? readAssetBytes({
    required String sourceId,
    required String localAssetId,
  }) =>
      delegate.readAssetBytes(sourceId: sourceId, localAssetId: localAssetId);

  @override
  Future<bool> assetExists({
    required String sourceId,
    required String localAssetId,
  }) =>
      delegate.assetExists(sourceId: sourceId, localAssetId: localAssetId);

  @override
  Future<List<ContentAssetRecord>> listAssets() => delegate.listAssets();
}

final class _ImportEngineRepository extends AiEngineRepository {
  _ImportEngineRepository(this.profile)
      : super(
          store: const UnsupportedAiEngineStore(),
          credentialStore: const UnsupportedEngineCredentialStore(),
        );

  final AiEngineProfile? profile;

  @override
  Future<AiEngineProfile?> getActiveOcrEngine() async => profile;
}

final class _StaticOcrClient implements OcrDocumentClient {
  _StaticOcrClient(this.document);

  final OcrDocument document;

  @override
  String get modelId => 'synthetic-ocr';

  @override
  Future<OcrDocument> parseFile({
    required AiEngineProfile profile,
    required String filePath,
    required String sourceName,
    Duration timeout = const Duration(minutes: 8),
  }) async =>
      document;
}

AiEngineProfile _syntheticOcrProfile() => AiEngineProfile(
      id: 'ocr-synthetic',
      engineType: AiEngineType.ocr,
      name: 'synthetic-ocr',
      apiKey: 'synthetic-key',
      baseUrl: 'https://open.bigmodel.cn/api/paas',
      modelName: 'glm-ocr',
      temperature: 0.1,
      reasoningEffort: '',
      isActive: true,
    );

void main() {
  late Directory temp;

  setUp(() {
    BackupRestoreMutationGate.resetForTesting();
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ocr_asset_lifecycle_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
    BackupRestoreMutationGate.resetForTesting();
  });

  test('missing writer predeclaration exposes no candidate bytes', () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final fixture = _fixture();
    final region = const OcrQuestionRegionizer().regionize(fixture).regions;
    final legacyQuestion =
        const OcrQuestionAssembler().assemble(region.single).question;
    final batch = buildOcrTypedCandidateBatch(
      document: fixture,
      regions: region,
      legacyQuestions: <Map<String, dynamic>>[legacyQuestion],
      uuidV4Factory: _uuidSequence(),
      assetStore: store,
    );
    expect(batch.failure, OcrTypedCandidateFailure.unsupportedStructure);
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      isNull,
    );
  });

  test('pipeline fallback rolls back newly acquired candidate assets',
      () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final fixture = _fixture();
    final region = const OcrQuestionRegionizer().regionize(fixture).regions;
    final legacyQuestion =
        const OcrQuestionAssembler().assemble(region.single).question;
    final batch = buildOcrTypedCandidateBatch(
      document: fixture,
      regions: region,
      legacyQuestions: <Map<String, dynamic>>[legacyQuestion],
      uuidV4Factory: _uuidSequence(),
      assetStore: store,
      predeclaredAssetIds:
          OcrSourceDocumentAdapter.assetIdsRequiringPredeclaration(fixture),
    );
    final lease = batch.candidateAssetLease;
    expect(lease, isNotNull);
    expect(lease!.localAssetIds, <String>['img_001']);
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      isNotNull,
    );

    final finalQuestion = Map<String, dynamic>.from(legacyQuestion)
      ..['explanation'] = 'different final explanation';
    final pipeline = ImportPipelineService.forTesting(
      taskManager: TaskManager.forTesting(),
      contentAssetStore: store,
      textParser: (_, {required taskId, required isMarkdown}) async => const [],
      visionParser: (_) async => const [],
      ocrParser: ({
        required filePath,
        required sourceName,
        required format,
        required explanationRetentionMode,
      }) async {
        return OcrImportResult(
          usedOcr: true,
          questions: <Map<String, dynamic>>[finalQuestion],
          warnings: const <String>[],
          diagnostics: const <String, dynamic>{},
          typedCandidateBatch: batch,
        );
      },
    );

    final result = await pipeline.parseFiles(
      const ImportParseRequest(
        filePaths: <String>['fixture.png'],
        fileNames: <String>['fixture.png'],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
        taskId: 'lifecycle-fallback',
      ),
    );

    expect(result.storageRoute.name, 'legacyV1');
    expect(result.storageReason, 'typed_candidate_raw_explanation_diverged');
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      isNull,
    );
  });

  test(
      'allQuestionTypes keeps an objective explanation through the production chain',
      () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    const mode = ExplanationRetentionMode.allQuestionTypes;
    final fixture = _objectiveFixture();
    final regions = const OcrQuestionRegionizer().regionize(fixture).regions;
    final assembled = const OcrQuestionAssembler().assemble(regions.single);
    final sourceQuestion = const ImportQuestionFieldPolicy().applyToMap(
      assembled.question,
      mode: mode,
    );
    final sourceRawExplanation = sourceQuestion['raw_explanation'];
    expect(sourceQuestion['type'], 0);
    expect(sourceRawExplanation, isA<String>());
    expect((sourceRawExplanation as String).isNotEmpty, isTrue);
    expect(sourceQuestion['explanation'], isNotEmpty);

    final batch = buildOcrTypedCandidateBatch(
      document: fixture,
      regions: regions,
      legacyQuestions: <Map<String, dynamic>>[sourceQuestion],
      uuidV4Factory: _uuidSequence(),
      assetStore: store,
      predeclaredAssetIds:
          OcrSourceDocumentAdapter.assetIdsRequiringPredeclaration(fixture),
      explanationRetentionMode: mode,
    );
    expect(batch.failure, isNull);
    final candidate = batch.candidates.single;
    expect(candidate.draft.explanation, isNotNull);
    expect(candidate.projectedLegacy.explanation, isNotEmpty);

    final result = await _pipelineForSingleBatch(
      store: store,
      batch: batch,
      questions: <Map<String, dynamic>>[sourceQuestion],
    ).parseFiles(
      const ImportParseRequest(
        filePaths: <String>['all-question-types.png'],
        fileNames: <String>['all-question-types.png'],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
        taskId: 'a2-all-question-types',
        explanationRetentionMode: mode,
      ),
    );

    final projectedLegacy = result.questions.single;
    expect(projectedLegacy['type'], 0);
    expect(projectedLegacy['raw_explanation'], isNotEmpty);
    expect(projectedLegacy['explanation'], isNotEmpty);
    expect(result.storageRoute, ImportStorageRoute.typedV2);
    expect(result.storageReason, ocrTypedCandidateReadyReason);
    final snapshot = const TypedReviewSnapshotCodec().decodeRequired(
      projectedLegacy[TypedReviewSnapshotCodec.mapKey],
    );
    expect(snapshot.draft.explanation, isNotNull);
  });

  test('multi-file OCR rolls back every candidate lease on legacy fallback',
      () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final fixtureA = _fixture();
    final regionA = const OcrQuestionRegionizer().regionize(fixtureA).regions;
    final legacyA =
        const OcrQuestionAssembler().assemble(regionA.single).question;
    final batchA = buildOcrTypedCandidateBatch(
      document: fixtureA,
      regions: regionA,
      legacyQuestions: <Map<String, dynamic>>[legacyA],
      uuidV4Factory: _uuidSequence(),
      assetStore: store,
      predeclaredAssetIds:
          OcrSourceDocumentAdapter.assetIdsRequiringPredeclaration(fixtureA),
    );
    final fixtureB = _fixture(number: 2);
    final regionB = const OcrQuestionRegionizer().regionize(fixtureB).regions;
    final legacyB =
        const OcrQuestionAssembler().assemble(regionB.single).question;
    final batchB = buildOcrTypedCandidateBatch(
      document: fixtureB,
      regions: regionB,
      legacyQuestions: <Map<String, dynamic>>[legacyB],
      uuidV4Factory: _uuidSequence(
        sourceId: _secondSourceId,
        questionId: '55555555-5555-4555-8555-555555555555',
        reviewId: '66666666-6666-4666-8666-666666666666',
      ),
      assetStore: store,
      predeclaredAssetIds:
          OcrSourceDocumentAdapter.assetIdsRequiringPredeclaration(fixtureB),
    );

    var parserCalls = 0;
    final pipeline = ImportPipelineService.forTesting(
      taskManager: TaskManager.forTesting(),
      contentAssetStore: store,
      textParser: (_, {required taskId, required isMarkdown}) async => const [],
      visionParser: (_) async => const [],
      ocrParser: ({
        required filePath,
        required sourceName,
        required format,
        required explanationRetentionMode,
      }) async {
        final isFirst = parserCalls++ == 0;
        return OcrImportResult(
          usedOcr: true,
          questions: <Map<String, dynamic>>[isFirst ? legacyA : legacyB],
          warnings: const <String>[],
          diagnostics: const <String, dynamic>{},
          typedCandidateBatch: isFirst ? batchA : batchB,
        );
      },
    );

    final result = await pipeline.parseFiles(
      const ImportParseRequest(
        filePaths: <String>['first.png', 'second.png'],
        fileNames: <String>['first.png', 'second.png'],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
        taskId: 'lifecycle-multi-file-fallback',
      ),
    );

    expect(result.storageRoute, ImportStorageRoute.legacyV1);
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      isNull,
    );
    expect(
      store.readAssetBytes(
        sourceId: _secondSourceId,
        localAssetId: 'img_001',
      ),
      isNull,
    );
  });

  test('quality-gate empty result rolls back the acquired candidate lease',
      () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final fixture = _fixture();
    final regions = const OcrQuestionRegionizer().regionize(fixture).regions;
    final legacyQuestion =
        const OcrQuestionAssembler().assemble(regions.single).question;
    final batch = _buildBatch(
      fixture,
      legacyQuestion,
      store,
    );

    final pipeline = ImportPipelineService.forTesting(
      taskManager: TaskManager.forTesting(),
      contentAssetStore: store,
      textParser: (_, {required taskId, required isMarkdown}) async => const [],
      visionParser: (_) async => const [],
      ocrParser: ({
        required filePath,
        required sourceName,
        required format,
        required explanationRetentionMode,
      }) async {
        return OcrImportResult(
          usedOcr: true,
          questions: const <Map<String, dynamic>>[],
          warnings: const <String>[],
          diagnostics: const <String, dynamic>{},
          typedCandidateBatch: batch,
        );
      },
    );

    final result = await pipeline.parseFiles(
      const ImportParseRequest(
        filePaths: <String>['empty.png'],
        fileNames: <String>['empty.png'],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
        taskId: 'lifecycle-quality-empty',
      ),
    );

    expect(result.questions, isEmpty);
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      isNull,
    );
  });

  test('post-acquisition merger exception rolls back every candidate lease',
      () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final fixtureA = _fixture();
    final regionsA = const OcrQuestionRegionizer().regionize(fixtureA).regions;
    final legacyA =
        const OcrQuestionAssembler().assemble(regionsA.single).question;
    final batchA = _buildBatch(fixtureA, legacyA, store);
    final fixtureB = _fixture(number: 2);
    final regionsB = const OcrQuestionRegionizer().regionize(fixtureB).regions;
    final legacyB =
        const OcrQuestionAssembler().assemble(regionsB.single).question;
    final batchB = buildOcrTypedCandidateBatch(
      document: fixtureB,
      regions: regionsB,
      legacyQuestions: <Map<String, dynamic>>[legacyB],
      uuidV4Factory: _uuidSequence(
        sourceId: _secondSourceId,
        questionId: '55555555-5555-4555-8555-555555555555',
        reviewId: '66666666-6666-4666-8666-666666666666',
      ),
      assetStore: store,
      predeclaredAssetIds:
          OcrSourceDocumentAdapter.assetIdsRequiringPredeclaration(fixtureB),
    );
    var parserCalls = 0;
    final pipeline = ImportPipelineService.forTesting(
      taskManager: TaskManager.forTesting(),
      contentAssetStore: store,
      questionMerger: (_) async => throw const FormatException(
        'synthetic merger failure',
      ),
      textParser: (_, {required taskId, required isMarkdown}) async => const [],
      visionParser: (_) async => const [],
      ocrParser: ({
        required filePath,
        required sourceName,
        required format,
        required explanationRetentionMode,
      }) async {
        final isFirst = parserCalls++ == 0;
        return OcrImportResult(
          usedOcr: true,
          questions: <Map<String, dynamic>>[isFirst ? legacyA : legacyB],
          warnings: const <String>[],
          diagnostics: const <String, dynamic>{},
          typedCandidateBatch: isFirst ? batchA : batchB,
        );
      },
    );

    await expectLater(
      pipeline.parseFiles(
        const ImportParseRequest(
          filePaths: <String>['first.png', 'second.png'],
          fileNames: <String>['first.png', 'second.png'],
          mode: ImportParseMode.ocr,
          maxConcurrency: 1,
          taskId: 'lifecycle-merger-exception',
        ),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      isNull,
    );
    expect(
      store.readAssetBytes(
        sourceId: _secondSourceId,
        localAssetId: 'img_001',
      ),
      isNull,
    );
  });

  test('typed success prunes decorative candidate assets', () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final fixture = _fixture(includeDecorativeImages: true);
    final regions = const OcrQuestionRegionizer().regionize(fixture).regions;
    final legacyQuestion =
        const OcrQuestionAssembler().assemble(regions.single).question;
    final batch = _buildBatch(fixture, legacyQuestion, store);
    expect(batch.candidateAssetLease?.localAssetIds,
        containsAll(<String>['logo', 'img_001', 'footer']));

    final pipeline = _pipelineForSingleBatch(
      store: store,
      batch: batch,
      questions: <Map<String, dynamic>>[legacyQuestion],
    );
    final result = await pipeline.parseFiles(
      const ImportParseRequest(
        filePaths: <String>['decorative.png'],
        fileNames: <String>['decorative.png'],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
        taskId: 'lifecycle-prune-decorative',
      ),
    );

    expect(
      result.storageRoute,
      ImportStorageRoute.typedV2,
      reason: 'storageReason=${result.storageReason}',
    );
    expect(result.candidateAssetLease?.localAssetIds, <String>['img_001']);
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      isNotNull,
    );
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'logo'),
      isNull,
    );
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'footer'),
      isNull,
    );
  });

  test('typed success retains multiple reachable candidate images', () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final fixture = _fixture(includeSecondImage: true);
    final regions = const OcrQuestionRegionizer().regionize(fixture).regions;
    final legacyQuestion =
        const OcrQuestionAssembler().assemble(regions.single).question;
    final batch = _buildBatch(fixture, legacyQuestion, store);
    final pipeline = _pipelineForSingleBatch(
      store: store,
      batch: batch,
      questions: <Map<String, dynamic>>[legacyQuestion],
    );

    final result = await pipeline.parseFiles(
      const ImportParseRequest(
        filePaths: <String>['two-images.png'],
        fileNames: <String>['two-images.png'],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
        taskId: 'lifecycle-prune-multiple-used',
      ),
    );

    expect(
      result.storageRoute,
      ImportStorageRoute.typedV2,
      reason: 'storageReason=${result.storageReason}',
    );
    expect(
      result.candidateAssetLease?.localAssetIds,
      containsAll(<String>['img_001', 'img_002']),
    );
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      isNotNull,
    );
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_002'),
      isNotNull,
    );
  });

  test('typed success retains a finalized explanation image', () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final fixture = _fixture();
    final regions = const OcrQuestionRegionizer().regionize(fixture).regions;
    final legacyQuestion =
        const OcrQuestionAssembler().assemble(regions.single).question;
    final originalBatch = _buildBatch(fixture, legacyQuestion, store);
    final original = originalBatch.candidates.single;
    final image = reachableImageNodes(original.draft.stem).single;
    final projectedContent =
        original.projectedLegacy.content.replaceAll('[图片]', '').trim();
    const projectedExplanation = '<p>Synthetic explanation 1</p>[图片]';
    const finalizedExplanation = 'Synthetic explanation 1\n[图片]';
    final explanation = RichContent(
      nodes: <ContentNode>[
        const TextNode('<p>Synthetic explanation 1</p>'),
        image,
      ],
    );
    final candidate = OcrTypedCandidate(
      questionNumber: original.questionNumber,
      reviewItemId: original.reviewItemId,
      questionId: original.questionId,
      draft: QuestionDraftV2(
        questionId: original.draft.questionId,
        kind: original.draft.kind,
        questionNumber: original.draft.questionNumber,
        stem: RichContent(
          nodes: <ContentNode>[TextNode(projectedContent)],
        ),
        options: original.draft.options,
        answer: original.draft.answer,
        explanation: explanation,
        sourceRefs: original.draft.sourceRefs,
        assetRefs: original.draft.assetRefs,
        issues: original.draft.issues,
      ),
      projectedLegacy: LegacyReviewBaseline(
        type: original.projectedLegacy.type,
        questionNumber: original.projectedLegacy.questionNumber,
        content: projectedContent,
        options: original.projectedLegacy.options,
        standardAnswer: original.projectedLegacy.standardAnswer,
        explanation: projectedExplanation,
      ),
      sourcePageIndices: original.sourcePageIndices,
      sourceBlockIds: original.sourceBlockIds,
    );
    final question = <String, dynamic>{
      ...legacyQuestion,
      'content': projectedContent,
      'explanation': projectedExplanation,
      'raw_explanation': projectedExplanation,
    };

    final result = await _pipelineForSingleBatch(
      store: store,
      batch: OcrTypedCandidateBatch(
        candidates: <OcrTypedCandidate>[candidate],
        candidateAssetLease: originalBatch.candidateAssetLease,
      ),
      questions: <Map<String, dynamic>>[question],
    ).parseFiles(
      const ImportParseRequest(
        filePaths: <String>['explanation-image.png'],
        fileNames: <String>['explanation-image.png'],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
        taskId: 'lifecycle-explanation-image',
      ),
    );

    expect(result.storageRoute, ImportStorageRoute.typedV2,
        reason: 'storageReason=${result.storageReason}');
    expect(result.storageReason, ocrTypedCandidateReadyReason);
    expect(result.questions.single['explanation'], finalizedExplanation);
    expect(result.questions.single['raw_explanation'], projectedExplanation);
    final snapshot = const TypedReviewSnapshotCodec().decodeRequired(
      result.questions.single[TypedReviewSnapshotCodec.mapKey],
    );
    expect(reachableImageNodes(snapshot.draft.explanation!), hasLength(1));
    expect(result.candidateAssetLease?.localAssetIds, <String>['img_001']);
  });

  test('typed gate fails closed when leased image bytes are unavailable',
      () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final fixture = _fixture();
    final regions = const OcrQuestionRegionizer().regionize(fixture).regions;
    final legacyQuestion =
        const OcrQuestionAssembler().assemble(regions.single).question;
    final batch = _buildBatch(fixture, legacyQuestion, store);
    final lease = batch.candidateAssetLease!;
    expect(lease.localAssetIds, <String>['img_001']);
    final deletion = await store.deleteCandidateAssets(lease);
    expect(deletion.isComplete, isTrue);

    final result = await _pipelineForSingleBatch(
      store: store,
      batch: batch,
      questions: <Map<String, dynamic>>[legacyQuestion],
    ).parseFiles(
      const ImportParseRequest(
        filePaths: <String>['missing-image.png'],
        fileNames: <String>['missing-image.png'],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
        taskId: 'lifecycle-missing-image',
      ),
    );

    expect(result.storageRoute, ImportStorageRoute.legacyV1);
    expect(result.storageReason, 'typed_candidate_unsupported_structure');
    expect(
      result.questions.single.containsKey(TypedReviewSnapshotCodec.mapKey),
      isFalse,
    );
  });

  test('baseline failure precedes unavailable leased asset', () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final fixture = _fixture();
    final regions = const OcrQuestionRegionizer().regionize(fixture).regions;
    final legacyQuestion =
        const OcrQuestionAssembler().assemble(regions.single).question;
    final batch = _buildBatch(fixture, legacyQuestion, store);
    final lease = batch.candidateAssetLease!;
    final deletion = await store.deleteCandidateAssets(lease);
    expect(deletion.isComplete, isTrue);

    final malformedBaseline = <String, dynamic>{
      ...legacyQuestion,
      'content': 42,
    };
    final result = await _pipelineForSingleBatch(
      store: store,
      batch: batch,
      questions: <Map<String, dynamic>>[malformedBaseline],
    ).parseFiles(
      const ImportParseRequest(
        filePaths: <String>['malformed-baseline.png'],
        fileNames: <String>['malformed-baseline.png'],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
        taskId: 'lifecycle-baseline-before-asset',
      ),
    );

    expect(result.storageRoute, ImportStorageRoute.legacyV1);
    expect(result.storageReason, 'typed_candidate_baseline_invalid');
    expect(result.candidateAssetLease, isNull);
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      isNull,
    );
  });

  test('typed gate rejects a reachable asset outside the candidate lease',
      () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final bytes = OcrImagePayload.fromDataUrl(_pngDataUrl)!.bytes;
    store.storeBytesSync(
      sourceId: _sourceId,
      localAssetId: 'img_001',
      bytes: bytes,
      mimeType: 'image/png',
    );
    final fixture = _fixture(includeDecorativeImages: true);
    final regions = const OcrQuestionRegionizer().regionize(fixture).regions;
    final legacyQuestion =
        const OcrQuestionAssembler().assemble(regions.single).question;
    final batch = _buildBatch(fixture, legacyQuestion, store);
    expect(batch.candidateAssetLease?.localAssetIds,
        containsAll(<String>['logo', 'footer']));
    expect(
        batch.candidateAssetLease?.localAssetIds, isNot(contains('img_001')));

    final result = await _pipelineForSingleBatch(
      store: store,
      batch: batch,
      questions: <Map<String, dynamic>>[legacyQuestion],
    ).parseFiles(
      const ImportParseRequest(
        filePaths: <String>['pre-existing.png'],
        fileNames: <String>['pre-existing.png'],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
        taskId: 'lifecycle-prune-pre-existing',
      ),
    );

    expect(
      result.storageRoute,
      ImportStorageRoute.legacyV1,
    );
    expect(result.storageReason, 'typed_candidate_identity_mismatch');
    expect(result.candidateAssetLease, isNull);
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      bytes,
    );
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'logo'),
      isNull,
    );
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'footer'),
      isNull,
    );
  });

  test('incomplete rollback emits a fixed count-only diagnostic', () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final fixture = _fixture();
    final region = const OcrQuestionRegionizer().regionize(fixture).regions;
    final legacyQuestion =
        const OcrQuestionAssembler().assemble(region.single).question;
    final batch = buildOcrTypedCandidateBatch(
      document: fixture,
      regions: region,
      legacyQuestions: <Map<String, dynamic>>[legacyQuestion],
      uuidV4Factory: _uuidSequence(),
      assetStore: store,
      predeclaredAssetIds:
          OcrSourceDocumentAdapter.assetIdsRequiringPredeclaration(fixture),
    );
    final finalQuestion = Map<String, dynamic>.from(legacyQuestion)
      ..['explanation'] = 'different final explanation';
    final sink = _MemoryLogSink();
    AppLogger.setSink(sink);
    addTearDown(() => AppLogger.setSink(null));
    final pipeline = ImportPipelineService.forTesting(
      taskManager: TaskManager.forTesting(),
      contentAssetStore: _IncompleteRollbackStore(store),
      textParser: (_, {required taskId, required isMarkdown}) async => const [],
      visionParser: (_) async => const [],
      ocrParser: ({
        required filePath,
        required sourceName,
        required format,
        required explanationRetentionMode,
      }) async {
        return OcrImportResult(
          usedOcr: true,
          questions: <Map<String, dynamic>>[finalQuestion],
          warnings: const <String>[],
          diagnostics: const <String, dynamic>{},
          typedCandidateBatch: batch,
        );
      },
    );

    await pipeline.parseFiles(
      const ImportParseRequest(
        filePaths: <String>['fixture.png'],
        fileNames: <String>['fixture.png'],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
        taskId: 'lifecycle-incomplete-rollback',
      ),
    );
    await AppLogger.flush();

    final records = sink.records
        .where(
          (record) =>
              record.data['code'] == 'candidate_asset_rollback_incomplete',
        )
        .toList();
    expect(records, hasLength(1));
    expect(records.single.data['status'], 'incomplete');
    expect(records.single.data['deletedCount'], 0);
    expect(records.single.data['missingCount'], 0);
    expect(records.single.data['failedCount'], 1);
    expect(
      records.single.toJson().toString(),
      isNot(contains('fixture.png')),
    );
  });

  test(
      'candidate lease excludes pre-existing identity and rollback is idempotent',
      () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final bytes = OcrImagePayload.fromDataUrl(_pngDataUrl)!.bytes;
    store.storeBytesSync(
      sourceId: _sourceId,
      localAssetId: 'img_001',
      bytes: bytes,
      mimeType: 'image/png',
    );
    final fixture = _fixture();
    final region = const OcrQuestionRegionizer().regionize(fixture).regions;
    final legacyQuestion =
        const OcrQuestionAssembler().assemble(region.single).question;
    final batch = buildOcrTypedCandidateBatch(
      document: fixture,
      regions: region,
      legacyQuestions: <Map<String, dynamic>>[legacyQuestion],
      uuidV4Factory: _uuidSequence(),
      assetStore: store,
      predeclaredAssetIds:
          OcrSourceDocumentAdapter.assetIdsRequiringPredeclaration(fixture),
    );

    expect(batch.candidateAssetLease, isNotNull);
    expect(batch.candidateAssetLease!.localAssetIds, isEmpty);
    final firstRollback =
        await store.deleteCandidateAssets(batch.candidateAssetLease!);
    final secondRollback =
        await store.deleteCandidateAssets(batch.candidateAssetLease!);
    expect(firstRollback.isComplete, isTrue);
    expect(secondRollback.isComplete, isTrue);
    expect(firstRollback.deletedCount, 0);
    expect(firstRollback.missingCount, 0);
    expect(firstRollback.failedCount, 0);
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      bytes,
    );
  });

  test('cancellation rolls back a lease returned after the cancel boundary',
      () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final bytes = OcrImagePayload.fromDataUrl(_pngDataUrl)!.bytes;
    store.storeBytesSync(
      sourceId: _sourceId,
      localAssetId: 'img_001',
      bytes: bytes,
      mimeType: 'image/png',
    );
    final lease = ContentAssetCandidateLease(
      sourceId: _sourceId,
      localAssetIds: const <String>['img_001'],
    );
    final release = Completer<void>();
    var started = false;
    final manager = TaskManager.forTesting();
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: manager.ready,
      contentAssetStore: store,
      taskIdFactory: () => 'cancel-lifecycle-task',
      traceIdFactory: () => 'cancel-lifecycle-trace',
    );

    final handle = await coordinator.dispatch(
      sourceDescription: 'fixture.pdf',
      mode: ImportParseMode.ocr,
      parse: (_) async {
        started = true;
        await release.future;
        return ImportParseResult(
          questions: const <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': '1',
              'type': 0,
              'content': 'Synthetic cancellation question',
              'options': <String>[],
              'standard_answer': '',
              'explanation': '',
            },
          ],
          candidateAssetLease: lease,
        );
      },
    );
    while (!started) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(
      await coordinator.cancelOcrTask(handle.taskId),
      ImportAttemptWriteStatus.applied,
    );
    release.complete();
    await _waitForTask(
      manager,
      handle.taskId,
      (task) => task.attemptState == ImportAttemptState.cancelled,
    );
    await _waitForAsset(
      store,
      exists: false,
    );
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      isNull,
    );
  });

  test('retry invalidState preserves the previous candidate lease', () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final bytes = OcrImagePayload.fromDataUrl(_pngDataUrl)!.bytes;
    store.storeBytesSync(
      sourceId: _sourceId,
      localAssetId: 'img_001',
      bytes: bytes,
      mimeType: 'image/png',
    );
    final manager = TaskManager.forTesting();
    final task = ImportTask(
      id: 'retry-invalid-state',
      title: 'Synthetic invalid state retry',
      status: TaskStatus.pendingReview,
      diagnostics: <String, dynamic>{
        TaskManager.keyParseMode: ImportParseMode.ocr.name,
        TaskManager.keyAttemptNumber: 1,
        TaskManager.keyAttemptToken: 'retry-invalid-token',
        TaskManager.keyTraceId: 'retry-invalid-trace',
        TaskManager.keyAttemptState: ImportAttemptState.readyForReview.name,
        ImportTaskCoordinator.keyCandidateAssetSourceId: _sourceId,
        ImportTaskCoordinator.keyCandidateAssetLocalIds: const <String>[
          'img_001',
        ],
      },
    );
    manager.tasks.add(task);
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: manager.ready,
      contentAssetStore: store,
    );

    await expectLater(
      coordinator.retryOcrTask(
        taskId: task.id,
        sourceDescription: 'synthetic.png',
        parse: (_) async => fail('retry parser must not run'),
      ),
      throwsA(isA<ImportTaskRetryRejectedException>()),
    );
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      bytes,
    );
  });

  test('retry persistenceFailed preserves the previous candidate lease',
      () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final bytes = OcrImagePayload.fromDataUrl(_pngDataUrl)!.bytes;
    store.storeBytesSync(
      sourceId: _sourceId,
      localAssetId: 'img_001',
      bytes: bytes,
      mimeType: 'image/png',
    );
    final manager = TaskManager.forTesting(
      saveTask: (_) async => throw StateError('synthetic retry persistence'),
    );
    final task = ImportTask(
      id: 'retry-persistence-state',
      title: 'Synthetic persistence failure retry',
      status: TaskStatus.error,
      diagnostics: <String, dynamic>{
        TaskManager.keyParseMode: ImportParseMode.ocr.name,
        TaskManager.keyAttemptNumber: 1,
        TaskManager.keyAttemptToken: 'retry-persistence-token',
        TaskManager.keyTraceId: 'retry-persistence-trace',
        TaskManager.keyAttemptState: ImportAttemptState.failed.name,
        ImportTaskCoordinator.keyCandidateAssetSourceId: _sourceId,
        ImportTaskCoordinator.keyCandidateAssetLocalIds: const <String>[
          'img_001',
        ],
      },
    );
    manager.tasks.add(task);
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: manager.ready,
      contentAssetStore: store,
    );

    await expectLater(
      coordinator.retryOcrTask(
        taskId: task.id,
        sourceDescription: 'synthetic.png',
        parse: (_) async => fail('retry parser must not run'),
      ),
      throwsA(isA<ImportTaskRetryRejectedException>()),
    );
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      bytes,
    );
  });

  test('retry rolls back the previous attempt namespace before restart',
      () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final bytes = OcrImagePayload.fromDataUrl(_pngDataUrl)!.bytes;
    store.storeBytesSync(
      sourceId: _sourceId,
      localAssetId: 'img_001',
      bytes: bytes,
      mimeType: 'image/png',
    );
    final lease = ContentAssetCandidateLease(
      sourceId: _sourceId,
      localAssetIds: const <String>['img_001'],
    );
    final manager = TaskManager.forTesting();
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: manager.ready,
      contentAssetStore: store,
      taskIdFactory: () => 'retry-lifecycle-task',
      traceIdFactory: () => 'retry-lifecycle-trace',
      attemptTokenFactory: () => 'retry-lifecycle-token',
    );

    final first = await coordinator.dispatch(
      sourceDescription: 'fixture.pdf',
      mode: ImportParseMode.ocr,
      parse: (_) async => ImportParseResult(
        questions: const <Map<String, dynamic>>[
          <String, dynamic>{
            'q_num': '1',
            'type': 0,
            'content': 'Synthetic first attempt',
            'options': <String>[],
            'standard_answer': '',
            'explanation': '',
          },
        ],
        candidateAssetLease: lease,
      ),
    );
    await _waitForTask(
      manager,
      first.taskId,
      (task) => task.status == TaskStatus.pendingReview,
    );
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      isNotNull,
    );
    final failedTask = manager.tasks.single;
    failedTask.status = TaskStatus.error;
    failedTask.errorMsg = 'synthetic failure';
    failedTask.diagnostics = <String, dynamic>{
      ...?failedTask.diagnostics,
      TaskManager.keyAttemptState: ImportAttemptState.failed.name,
    };

    await coordinator.retryOcrTask(
      taskId: first.taskId,
      sourceDescription: 'fixture.pdf',
      parse: (_) async => const ImportParseResult(
        questions: <Map<String, dynamic>>[
          <String, dynamic>{
            'q_num': '2',
            'type': 0,
            'content': 'Synthetic retry attempt',
            'options': <String>[],
            'standard_answer': '',
            'explanation': '',
          },
        ],
      ),
    );
    await _waitForTask(
      manager,
      first.taskId,
      (task) =>
          task.status == TaskStatus.pendingReview && task.attemptNumber == 2,
    );
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      isNull,
    );
  });
  test('a post-visibility write failure keeps exact candidate ownership',
      () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    store.storeBytesSync(
      sourceId: _sourceId,
      localAssetId: 'asset-keep',
      bytes: OcrImagePayload.fromDataUrl(_pngDataUrl)!.bytes,
      mimeType: 'image/png',
    );
    final fixture = _fixture();
    final region = const OcrQuestionRegionizer().regionize(fixture).regions;
    final legacyQuestion =
        const OcrQuestionAssembler().assemble(region.single).question;

    final batch = buildOcrTypedCandidateBatch(
      document: fixture,
      regions: region,
      legacyQuestions: <Map<String, dynamic>>[legacyQuestion],
      uuidV4Factory: _uuidSequence(),
      assetStore: _VisibilityFailingStore(store),
      predeclaredAssetIds:
          OcrSourceDocumentAdapter.assetIdsRequiringPredeclaration(fixture),
    );

    final lease = batch.candidateAssetLease;
    expect(lease, isNotNull);
    expect(lease!.sourceId, _sourceId);
    expect(lease.localAssetIds, <String>['img_001']);
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      isNotNull,
    );

    final rollback = await store.deleteCandidateAssets(lease);
    expect(rollback.deletedCount, 1);
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      isNull,
    );
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'asset-keep'),
      isNotNull,
    );
  });
  test('the import writer resets grace before the first asset byte', () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final probe = _ResetProbe();
    final witness = _ResetOrderWitnessStore(store, probe);
    final service = OcrImportService(
      ocrClient: _StaticOcrClient(_fixture()),
      engineRepository: _ImportEngineRepository(_syntheticOcrProfile()),
      contentAssetStore: witness,
      reclamationReset: probe,
      uuidV4Factory: _uuidSequence(),
    );

    final result = await service.tryParse(
      filePath: 'synthetic.png',
      sourceName: 'synthetic.png',
      format: ImportFormat.image,
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );

    expect(result, isNotNull);
    expect(result!.diagnostics['status'], 'used_ocr');
    expect(probe.calls, hasLength(1));
    expect(probe.calls.single.$1, _sourceId);
    expect(probe.calls.single.$2, <String>['img_001']);
    expect(witness.everyWriteHadReset, isTrue);
  });

  test('a store without reset authority reports the typed refusal', () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final service = OcrImportService(
      ocrClient: _StaticOcrClient(_fixture()),
      engineRepository: _ImportEngineRepository(_syntheticOcrProfile()),
      contentAssetStore: store,
      uuidV4Factory: _uuidSequence(),
    );

    final result = await service.tryParse(
      filePath: 'synthetic.png',
      sourceName: 'synthetic.png',
      format: ImportFormat.image,
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );

    expect(
      result?.typedCandidateBatch?.failure,
      OcrTypedCandidateFailure.resetAuthorityMissing,
    );
    expect(await store.listAssets(), isEmpty);
  });
}

Future<ImportTask> _waitForTask(
  TaskManager manager,
  String taskId,
  bool Function(ImportTask task) predicate,
) async {
  for (var index = 0; index < 100; index++) {
    final matches = manager.tasks.where((task) => task.id == taskId);
    if (matches.isNotEmpty && predicate(matches.single)) return matches.single;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('Synthetic import task did not reach the expected state.');
}

Future<void> _waitForAsset(
  ManagedContentAssetStore store, {
  required bool exists,
}) async {
  for (var index = 0; index < 100; index++) {
    final present = store.readAssetBytes(
          sourceId: _sourceId,
          localAssetId: 'img_001',
        ) !=
        null;
    if (present == exists) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError(
      'Synthetic candidate asset did not reach the expected state.');
}

OcrDocument _fixture({
  int number = 1,
  bool includeDecorativeImages = false,
  bool includeSecondImage = false,
}) {
  final blocks = <OcrBlock>[];
  if (includeDecorativeImages) {
    blocks.add(_block('logo', 'image', _pngDataUrl, 0));
  }
  final sectionOrder = includeDecorativeImages ? 1 : 0;
  final questionOrder = sectionOrder + 1;
  blocks.add(_block('section', 'text', '三、解答题', sectionOrder));
  blocks.add(
    _block(
      'q_$number',
      'text',
      '$number. Prompt before image',
      questionOrder,
    ),
  );
  blocks.add(_block('img_001', 'image', _pngDataUrl, questionOrder + 1));
  if (includeSecondImage) {
    blocks.add(_block('img_002', 'image', _pngDataUrl, questionOrder + 2));
  }
  blocks.add(
    _block(
      'answer_$number',
      'text',
      '答案：synthetic-result-$number',
      questionOrder + (includeSecondImage ? 3 : 2),
    ),
  );
  blocks.add(
    _block(
      'explanation_$number',
      'text',
      '解析：Synthetic explanation $number',
      questionOrder + (includeSecondImage ? 4 : 3),
    ),
  );
  if (includeDecorativeImages) {
    blocks.add(
      _block(
        'section_end',
        'text',
        '四、解答题',
        questionOrder + (includeSecondImage ? 5 : 4),
      ),
    );
    blocks.add(
      _block(
        'footer',
        'image',
        _pngDataUrl,
        questionOrder + (includeSecondImage ? 6 : 5),
      ),
    );
  }
  return OcrDocument(
    sourceName: 'synthetic.pdf',
    pages: <OcrPage>[
      OcrPage(pageIndex: 1, blocks: blocks),
    ],
    markdown: '',
    rawResponses: const <Map<String, dynamic>>[],
    usage: const <String, dynamic>{},
  );
}

OcrDocument _objectiveFixture() {
  return OcrDocument(
    sourceName: 'synthetic-objective.pdf',
    pages: <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('section', 'text', '一、选择题', 0),
          _block(
            'q_1',
            'text',
            '1. Prompt before image\n'
                'A. Alpha\n'
                'B. Beta\n'
                'C. Gamma\n'
                'D. Delta',
            1,
          ),
          _block('img_001', 'image', _pngDataUrl, 2),
          _block('answer_1', 'text', '答案：A', 3),
          _block(
              'explanation_1', 'text', '解析：Synthetic objective explanation', 4),
        ],
      ),
    ],
    markdown: '',
    rawResponses: const <Map<String, dynamic>>[],
    usage: const <String, dynamic>{},
  );
}

OcrBlock _block(String id, String type, String text, int order) {
  return OcrBlock(
    blockId: id,
    pageIndex: 1,
    type: type,
    text: text,
    bbox: const <double>[],
    readingOrder: order,
  );
}

String Function() _uuidSequence({
  String sourceId = _sourceId,
  String questionId = _questionId,
  String reviewId = _reviewId,
}) {
  final values = <String>[sourceId, questionId, reviewId];
  var index = 0;
  return () => values[index++];
}

OcrTypedCandidateBatch _buildBatch(
  OcrDocument document,
  Map<String, dynamic> legacyQuestion,
  ManagedContentAssetStore store,
) {
  final regions = const OcrQuestionRegionizer().regionize(document).regions;
  return buildOcrTypedCandidateBatch(
    document: document,
    regions: regions,
    legacyQuestions: <Map<String, dynamic>>[legacyQuestion],
    uuidV4Factory: _uuidSequence(),
    assetStore: store,
    predeclaredAssetIds:
        OcrSourceDocumentAdapter.assetIdsRequiringPredeclaration(document),
  );
}

ImportPipelineService _pipelineForSingleBatch({
  required ManagedContentAssetStore store,
  required OcrTypedCandidateBatch batch,
  required List<Map<String, dynamic>> questions,
}) {
  return ImportPipelineService.forTesting(
    taskManager: TaskManager.forTesting(),
    contentAssetStore: store,
    textParser: (_, {required taskId, required isMarkdown}) async => const [],
    visionParser: (_) async => const [],
    ocrParser: ({
      required filePath,
      required sourceName,
      required format,
      required explanationRetentionMode,
    }) async {
      return OcrImportResult(
        usedOcr: true,
        questions: questions,
        warnings: const <String>[],
        diagnostics: const <String, dynamic>{},
        typedCandidateBatch: batch,
      );
    },
  );
}

final class _MemoryLogSink implements LogSink {
  final List<LogRecord> records = <LogRecord>[];

  @override
  Future<void> write(LogRecord record) async {
    records.add(record);
  }

  @override
  Future<void> flush() async {}
}

final class _IncompleteRollbackStore implements ContentAssetStore {
  _IncompleteRollbackStore(this._delegate);

  final ManagedContentAssetStore _delegate;

  @override
  String storageKey({required String sourceId, required String localAssetId}) =>
      _delegate.storageKey(sourceId: sourceId, localAssetId: localAssetId);

  @override
  Future<ContentAssetWriteResult> storeBytes({
    required String sourceId,
    required String localAssetId,
    required List<int> bytes,
    required String mimeType,
  }) =>
      _delegate.storeBytes(
        sourceId: sourceId,
        localAssetId: localAssetId,
        bytes: bytes,
        mimeType: mimeType,
      );

  @override
  ContentAssetWriteResult storeBytesSync({
    required String sourceId,
    required String localAssetId,
    required List<int> bytes,
    required String mimeType,
  }) =>
      _delegate.storeBytesSync(
        sourceId: sourceId,
        localAssetId: localAssetId,
        bytes: bytes,
        mimeType: mimeType,
      );

  @override
  Future<ContentAssetRollbackResult> deleteCandidateAssets(
    ContentAssetCandidateLease lease,
  ) async =>
      const ContentAssetRollbackResult(failedCount: 1);

  @override
  List<int>? readAssetBytes({
    required String sourceId,
    required String localAssetId,
  }) =>
      _delegate.readAssetBytes(
        sourceId: sourceId,
        localAssetId: localAssetId,
      );

  @override
  Future<bool> assetExists({
    required String sourceId,
    required String localAssetId,
  }) =>
      _delegate.assetExists(sourceId: sourceId, localAssetId: localAssetId);

  @override
  Future<List<ContentAssetRecord>> listAssets() => _delegate.listAssets();
}
