// R7B permanent acceptance: production OCR shadow typed candidate chain.
//
// Evidence class: synthetic fixtures only. The full chain runs in memory:
//   synthetic OcrDocument -> OcrQuestionRegionizer -> reference-answer merge
//   -> legacy assembly -> typed candidate -> quality gate/finalization
//   -> parity gate -> _typed_review_v1 envelope -> ImportParseResult
//   -> ImportTaskCoordinator -> real TaskManager persistence/reload
//   -> strict envelope decode.
//
// There is no Provider, Replay, network, database, UI, filesystem or
// application call site; Provider calls are 0 by construction and the fake
// OCR client is only invoked through the injected in-memory document.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_format.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/import_pipeline/local_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document_client.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_import_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/single_question_repair_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';
import 'package:shiroha_quiz/services/task_manager.dart';

import 'support/memory_content_asset_store.dart';
import 'support/unsupported_ai_engine_store.dart';

const _sourceName = 'r7b_acceptance_single.pdf';

class _FakeAiEngineRepository extends AiEngineRepository {
  _FakeAiEngineRepository(this.profile)
      : super(
          store: const UnsupportedAiEngineStore(),
          credentialStore: const UnsupportedEngineCredentialStore(),
        );

  final AiEngineProfile profile;

  @override
  Future<AiEngineProfile?> getActiveOcrEngine() async => profile;
}

class _FakeOcrDocumentClient implements OcrDocumentClient {
  _FakeOcrDocumentClient(this.document);

  final OcrDocument document;
  int callCount = 0;

  @override
  String get modelId => 'fake-ocr-model';

  @override
  Future<OcrDocument> parseFile({
    required AiEngineProfile profile,
    required String filePath,
    required String sourceName,
    Duration timeout = const Duration(minutes: 8),
  }) async {
    callCount++;
    return document;
  }
}

class _FakeRepairService extends SingleQuestionRepairService {
  const _FakeRepairService();

  @override
  Future<LocalAssemblyResult> repair({
    required TextQuestionRegion region,
    required LocalAssemblyResult localResult,
    required bool requireAnswer,
    required ExplanationRetentionMode explanationRetentionMode,
  }) async {
    return localResult;
  }
}

AiEngineProfile _ocrProfile() {
  return const AiEngineProfile(
    id: 'r7b-ocr',
    engineType: AiEngineType.ocr,
    name: 'zhipu-ocr',
    apiKey: 'test-key',
    baseUrl: 'https://open.bigmodel.cn/api/paas',
    modelName: 'glm-ocr',
    temperature: 0.1,
    reasoningEffort: '',
    isActive: true,
  );
}

/// Deterministic canonical UUIDv4 factory so every identity is reproducible.
String Function() _uuidFactory() {
  var index = 0;
  return () {
    index++;
    return '0d8b7a3e-7f1c-4b2a-9d3e-${index.toRadixString(16).padLeft(12, '0')}';
  };
}

OcrBlock _block(
  String blockId,
  int pageIndex,
  int readingOrder,
  String text, {
  String type = 'text',
}) {
  return OcrBlock(
    blockId: blockId,
    pageIndex: pageIndex,
    type: type,
    text: text,
    bbox: const <double>[],
    readingOrder: readingOrder,
  );
}

OcrDocument _document(String sourceName, List<OcrPage> pages) {
  return OcrDocument(
    sourceName: sourceName,
    pages: pages,
    markdown: '',
    rawResponses: const <Map<String, dynamic>>[],
    usage: const <String, dynamic>{},
  );
}

/// Two short-answer questions with inline answers and explanations in
/// document order, matching the parity-proven R3D fixture shape.
OcrDocument _inlineAnswerDocument() {
  return _document(
    _sourceName,
    <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('section', 1, 0, '三、解答题'),
          _block('q_1', 1, 1, '1. Synthetic prompt marker 1.'),
          _block('answer_1', 1, 2, '答案：synthetic-result-1'),
          _block('e_1', 1, 3, '解析：Synthetic explanation 1'),
          _block('q_2', 1, 4, '2. Synthetic prompt marker 2.'),
          _block('answer_2', 1, 5, '答案：synthetic-result-2'),
          _block('e_2', 1, 6, '解析：Synthetic explanation 2'),
        ],
      ),
    ],
  );
}

/// Two short-answer questions whose answers are merged from a tail
/// reference-answer section by the real production merger.
OcrDocument _referenceAnswerDocument() {
  return _document(
    _sourceName,
    <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('section', 1, 0, '三、解答题'),
          _block('q_1', 1, 1, '1. Synthetic prompt marker 1.'),
          _block('e_1', 1, 2, '解析：Synthetic explanation 1'),
          _block('q_2', 1, 3, '2. Synthetic prompt marker 2.'),
          _block('e_2', 1, 4, '解析：Synthetic explanation 2'),
          _block('reference_title', 1, 5, '2022 模拟试卷参考答案汇总'),
          _block('reference_1', 1, 6, '(1) Final answer one'),
          _block('reference_2', 1, 7, '（2）Final answer two'),
        ],
      ),
    ],
  );
}

/// Second question's stem block is a table: legacy import succeeds, but the
/// typed candidate batch must be rejected as unsupported structure.
OcrDocument _unsupportedSecondQuestionDocument() {
  return _document(
    _sourceName,
    <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('section', 1, 0, '三、解答题（共2题）'),
          _block('q_1', 1, 1, '1. Synthetic prompt marker 1.'),
          _block('answer_1', 1, 2, '答案：synthetic-result-1'),
          _block('e_1', 1, 3, '解析：Synthetic explanation 1'),
          _block('q_2', 1, 4, '2. Synthetic prompt marker 2.', type: 'table'),
          _block('answer_2', 1, 5, '答案：synthetic-result-2'),
          _block('e_2', 1, 6, '解析：Synthetic explanation 2'),
        ],
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'eligible batch reaches shadow-ready with envelopes preserved across '
      'real TaskManager persistence and reload', () async {
    final client = _FakeOcrDocumentClient(_inlineAnswerDocument());
    final ocrService = OcrImportService(
      engineRepository: _FakeAiEngineRepository(_ocrProfile()),
      ocrClient: client,
      assetStore: MemoryContentAssetStore(),
      repairService: const _FakeRepairService(),
      uuidV4Factory: _uuidFactory(),
    );
    final pipeline = ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async =>
          fail('text parser must not run'),
      visionParser: (imagePaths) async => fail('vision parser must not run'),
      ocrParser: ocrService.tryParse,
    );
    final parseResult = await pipeline.parseFiles(
      ImportParseRequest(
        filePaths: const <String>['single.pdf'],
        fileNames: const <String>[_sourceName],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
        taskId: 'r7b-acceptance-parse',
      ),
    );

    expect(parseResult.storageRoute, ImportStorageRoute.typedV2);
    expect(parseResult.storageReason, 'typed_candidate_ready');
    expect(parseResult.questions, hasLength(2));
    for (final question in parseResult.questions) {
      expect(
        question.containsKey(TypedReviewSnapshotCodec.mapKey),
        isTrue,
      );
    }
    expect(client.callCount, 1,
        reason: 'one fake OCR invocation; Provider calls are 0 by '
            'construction');

    final savedMaps = <Map<String, dynamic>>[];
    final manager = TaskManager.forTesting(
      saveTask: (taskMap) async {
        savedMaps.add(Map<String, dynamic>.from(taskMap));
      },
    );
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: pipeline.parseFiles,
      taskIdFactory: () => 'r7b-acceptance-task',
      traceIdFactory: () => 'r7b-acceptance-trace',
    );
    final handle = await coordinator.dispatchRequest(
      sourceDescription: _sourceName,
      filePaths: const <String>['single.pdf'],
      fileNames: const <String>[_sourceName],
      mode: ImportParseMode.ocr,
      maxConcurrency: 1,
    );
    final task = await _waitForImportTask(
      manager,
      handle.taskId,
      (task) => task.status == TaskStatus.pendingReview,
    );

    expect(task.diagnostics?[TaskManager.keyImportStorageRoute], 'typedV2');
    expect(
      task.diagnostics?[TaskManager.keyImportStorageReason],
      'typed_candidate_ready',
    );
    expect(task.parsedData, hasLength(2));
    final userVisibleDiagnostics = jsonEncode(task.parsedData);
    expect(userVisibleDiagnostics, isNot(contains('typed_candidate_')));
    expect(userVisibleDiagnostics, isNot(contains('_importStorageRoute')));
    final taskDiagnostics = jsonEncode(task.diagnostics);
    expect(taskDiagnostics, isNot(contains('_typed_review_v1')));

    // Real TaskManager persistence/reload: the captured toMap snapshot is
    // restored through the same fromMap/load path used by the repository.
    final lastSaved = ImportTask.fromMap(savedMaps.last);
    final reloadedManager = TaskManager.forTesting(
      loadTasks: () async => <Map<String, dynamic>>[lastSaved.toMap()],
    );
    await reloadedManager.ready;
    final reloaded = reloadedManager.tasks.single;
    expect(reloaded.status, TaskStatus.pendingReview);
    expect(
      reloaded.diagnostics?[TaskManager.keyImportStorageRoute],
      'typedV2',
    );
    expect(
      reloaded.diagnostics?[TaskManager.keyImportStorageReason],
      'typed_candidate_ready',
    );
    expect(reloaded.parsedData, hasLength(2));

    const codec = TypedReviewSnapshotCodec();
    for (final question in reloaded.parsedData!) {
      final envelope = question[TypedReviewSnapshotCodec.mapKey];
      expect(envelope, isA<Map<String, Object?>>());
      final decoded = codec.decodeRequired(envelope);
      expect(isCanonicalUuidV4(decoded.reviewItemId), isTrue);
      expect(isCanonicalUuidV4(decoded.questionId), isTrue);
      expect(decoded.questionId, decoded.draft.questionId);
      expect(
        decoded.baselineLegacy,
        LegacyReviewBaseline(
          type: question['type'] as int,
          questionNumber: question['question_number'] as int,
          content: question['content'] as String,
          options: List<String>.from(
            question['options'] as List<Object?>,
          ),
          standardAnswer: question['standard_answer'] as String,
          explanation: question['explanation'] as String,
        ),
        reason: 'baseline must equal the user-visible final legacy map',
      );
      final sourceRefs = decoded.draft.sourceRefs;
      expect(sourceRefs, isNotEmpty);
      for (final sourceRef in sourceRefs) {
        expect(isCanonicalUuidV4(sourceRef.sourceId), isTrue);
        expect(sourceRef.displayLabel, isNull,
            reason: 'typed source identity never carries file information');
      }
      final envelopeJson = jsonEncode(envelope);
      expect(envelopeJson, isNot(contains(_sourceName)));
      expect(envelopeJson, isNot(contains('single.pdf')));
      expect(envelopeJson, isNot(contains(r'C:\')));
      expect(envelopeJson, isNot(contains('filePath')));
      expect(envelopeJson, isNot(contains('sourceName')));
    }

    expect(task.attemptRef, isNotNull);
  });

  test(
      'unreferenced table outside question regions does not disqualify '
      'the batch and reaches typedV2', () async {
    final client = _FakeOcrDocumentClient(_unreferencedTableDocument());
    final ocrService = OcrImportService(
      engineRepository: _FakeAiEngineRepository(_ocrProfile()),
      ocrClient: client,
      assetStore: MemoryContentAssetStore(),
      repairService: const _FakeRepairService(),
      uuidV4Factory: _uuidFactory(),
    );
    final pipeline = ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async =>
          fail('text parser must not run'),
      visionParser: (imagePaths) async => fail('vision parser must not run'),
      ocrParser: ocrService.tryParse,
    );
    final parseResult = await pipeline.parseFiles(
      ImportParseRequest(
        filePaths: const <String>['single.pdf'],
        fileNames: const <String>[_sourceName],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
        taskId: 'r7b-acceptance-unreferenced-table',
      ),
    );

    expect(parseResult.storageRoute, ImportStorageRoute.typedV2);
    expect(parseResult.storageReason, 'typed_candidate_ready');
    expect(parseResult.questions, hasLength(1));
    expect(
      parseResult.questions.single.containsKey(TypedReviewSnapshotCodec.mapKey),
      isTrue,
    );
  });

  test(
      'OCR document with image block persists image to ContentAssetStore '
      'and produces resolved ImageNode in typedV2 snapshot', () async {
    final tempDir = Directory.systemTemp.createTempSync('r7b_image_test_');
    try {
      final store = ManagedContentAssetStore(managedRoot: tempDir);
      final client = _FakeOcrDocumentClient(_imageInQuestionDocument());
      final ocrService = OcrImportService(
        engineRepository: _FakeAiEngineRepository(_ocrProfile()),
        ocrClient: client,
        assetStore: store,
        repairService: const _FakeRepairService(),
        uuidV4Factory: _uuidFactory(),
      );
      final pipeline = ImportPipelineService.forTesting(
        textParser: (rawText, {required taskId, required isMarkdown}) async =>
            fail('text parser must not run'),
        visionParser: (imagePaths) async => fail('vision parser must not run'),
        ocrParser: ocrService.tryParse,
      );
      final parseResult = await pipeline.parseFiles(
        ImportParseRequest(
          filePaths: const <String>['single.pdf'],
          fileNames: const <String>[_sourceName],
          mode: ImportParseMode.ocr,
          maxConcurrency: 1,
          taskId: 'r7b-acceptance-image',
        ),
      );

      expect(
        parseResult.storageRoute,
        ImportStorageRoute.typedV2,
        reason:
            'storageReason: ${parseResult.storageReason}, failure: ${parseResult.warnings}',
      );
      expect(parseResult.storageReason, 'typed_candidate_ready');
      expect(parseResult.questions, hasLength(1));

      final envelope =
          parseResult.questions.single[TypedReviewSnapshotCodec.mapKey];
      expect(envelope, isA<Map<String, Object?>>());
      final decoded = const TypedReviewSnapshotCodec().decodeRequired(envelope);
      final imageNodes =
          decoded.draft.stem.nodes.whereType<ImageNode>().toList();
      expect(imageNodes, hasLength(1));
      final imageNode = imageNodes.single;
      expect(imageNode.assetRef, startsWith('content_assets/'));

      final resolvedFile = store.resolveAsset(imageNode.assetRef);
      expect(resolvedFile, isNotNull);
      expect(resolvedFile!.existsSync(), isTrue);
      expect(resolvedFile.lengthSync(), greaterThan(0));
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test(
      'reference-answer merged regions still generate candidates but strict '
      'provenance parity keeps the batch legacy', () async {
    final client = _FakeOcrDocumentClient(_referenceAnswerDocument());
    final ocrService = OcrImportService(
      engineRepository: _FakeAiEngineRepository(_ocrProfile()),
      ocrClient: client,
      assetStore: MemoryContentAssetStore(),
      repairService: const _FakeRepairService(),
      uuidV4Factory: _uuidFactory(),
    );
    final serviceResult = await ocrService.tryParse(
      filePath: 'single.pdf',
      sourceName: _sourceName,
      format: ImportFormat.pdf,
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );
    expect(serviceResult, isNotNull);
    final batch = serviceResult!.typedCandidateBatch!;
    expect(batch.failure, isNull,
        reason: 'merged regions can generate typed candidates');
    expect(batch.candidates, hasLength(2));
    expect(
      batch.candidates
          .map((candidate) => candidate.projectedLegacy.standardAnswer)
          .toList(),
      <String>['Final answer one', 'Final answer two'],
    );

    final pipeline = ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async =>
          fail('text parser must not run'),
      visionParser: (imagePaths) async => fail('vision parser must not run'),
      ocrParser: ocrService.tryParse,
    );
    final parseResult = await pipeline.parseFiles(
      ImportParseRequest(
        filePaths: const <String>['single.pdf'],
        fileNames: const <String>[_sourceName],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
        taskId: 'r7b-acceptance-reference',
      ),
    );

    expect(parseResult.storageRoute, ImportStorageRoute.legacyV1);
    expect(parseResult.storageReason, 'typed_candidate_projection_mismatch',
        reason: 'tail reference answers reorder legacy source_block_ids '
            'relative to the typed fragment order, so strict parity rejects '
            'the batch without changing legacy import');
    expect(parseResult.questions, hasLength(2));
    expect(
      parseResult.questions.every(
        (question) => !question.containsKey(TypedReviewSnapshotCodec.mapKey),
      ),
      isTrue,
    );
    expect(client.callCount, 2,
        reason: 'one direct service probe and one pipeline parse; Provider '
            'calls are 0 by construction');
  });

  test(
      'unsupported second question keeps legacy import but strips all '
      'envelopes with the fixed reason', () async {
    final client = _FakeOcrDocumentClient(_unsupportedSecondQuestionDocument());
    final ocrService = OcrImportService(
      engineRepository: _FakeAiEngineRepository(_ocrProfile()),
      ocrClient: client,
      assetStore: MemoryContentAssetStore(),
      repairService: const _FakeRepairService(),
      uuidV4Factory: _uuidFactory(),
    );
    final pipeline = ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async =>
          fail('text parser must not run'),
      visionParser: (imagePaths) async => fail('vision parser must not run'),
      ocrParser: ocrService.tryParse,
    );
    final parseResult = await pipeline.parseFiles(
      ImportParseRequest(
        filePaths: const <String>['single.pdf'],
        fileNames: const <String>[_sourceName],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
        taskId: 'r7b-acceptance-unsupported',
      ),
    );

    expect(parseResult.storageRoute, ImportStorageRoute.legacyV1);
    expect(
      parseResult.storageReason,
      'typed_candidate_unsupported_structure',
    );
    expect(parseResult.questions, hasLength(2),
        reason: 'legacy import must still succeed');
    for (final question in parseResult.questions) {
      expect(
        question.containsKey(TypedReviewSnapshotCodec.mapKey),
        isFalse,
        reason: 'a single unsupported structure removes every envelope',
      );
    }
    expect(client.callCount, 1);
  });

  test('multi-file OCR requests never attach envelopes', () async {
    final client = _FakeOcrDocumentClient(_referenceAnswerDocument());
    final ocrService = OcrImportService(
      engineRepository: _FakeAiEngineRepository(_ocrProfile()),
      ocrClient: client,
      assetStore: MemoryContentAssetStore(),
      repairService: const _FakeRepairService(),
      uuidV4Factory: _uuidFactory(),
    );
    final pipeline = ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async =>
          fail('text parser must not run'),
      visionParser: (imagePaths) async => fail('vision parser must not run'),
      ocrParser: ocrService.tryParse,
    );
    final parseResult = await pipeline.parseFiles(
      ImportParseRequest(
        filePaths: const <String>['one.pdf', 'two.pdf'],
        fileNames: const <String>['one.pdf', 'two.pdf'],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
        taskId: 'r7b-acceptance-multi',
      ),
    );

    expect(parseResult.storageRoute, ImportStorageRoute.legacyV1);
    expect(parseResult.storageReason, 'typed_candidate_not_single_file');
    expect(parseResult.questions, hasLength(4));
    for (final question in parseResult.questions) {
      expect(
        question.containsKey(TypedReviewSnapshotCodec.mapKey),
        isFalse,
      );
    }
    expect(client.callCount, 2,
        reason: 'two fake invocations; Provider calls are 0 by construction');
  });

  test(
      'restart clears old envelopes so stale candidates cannot pollute a '
      'new attempt', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(
      ImportTask(
        id: 'r7b-retry-task',
        title: 'Synthetic failed task',
        status: TaskStatus.error,
        parsedData: <Map<String, dynamic>>[
          <String, dynamic>{
            'q_num': '1',
            'type': 3,
            'content': 'Synthetic stale content',
            'options': <String>[],
            'standard_answer': 'A',
            'explanation': '',
            TypedReviewSnapshotCodec.mapKey: <String, Object?>{
              'schemaVersion': 1,
              'route': 'typedV2',
              'reviewItemId': '0d8b7a3e-7f1c-4b2a-9d3e-000000000001',
              'questionId': '0d8b7a3e-7f1c-4b2a-9d3e-000000000002',
              'draft': <String, Object?>{},
              'baselineLegacy': <String, Object?>{},
            },
          },
        ],
        diagnostics: <String, dynamic>{
          TaskManager.keyTraceId: 'r7b-old-trace',
          TaskManager.keyParseMode: 'ocr',
          TaskManager.keyImportStorageRoute: 'legacyV1',
          TaskManager.keyImportStorageReason: 'typed_candidate_shadow_ready',
          TaskManager.keyAttemptNumber: 1,
          TaskManager.keyAttemptToken: 'r7b-old-attempt',
          TaskManager.keyAttemptState: ImportAttemptState.failed.name,
        },
      ),
    );
    final nextAttempt = ImportAttemptRef(
      taskId: 'r7b-retry-task',
      attemptNumber: 2,
      attemptToken: 'r7b-new-attempt',
      traceId: 'r7b-new-trace',
    );

    expect(
      await manager.restartAttempt(
        nextAttempt,
        parseMode: ImportParseMode.ocr.name,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      ),
      ImportAttemptWriteStatus.applied,
    );
    final restarted = manager.tasks.single;
    expect(restarted.parsedData, isNull,
        reason: 'old candidates must never pollute a new attempt');
    expect(restarted.attemptNumber, 2);
    expect(
      restarted.diagnostics?[TaskManager.keyImportStorageRoute],
      'legacyV1',
    );
    expect(
      restarted.diagnostics?[TaskManager.keyImportStorageReason],
      'typed_candidate_shadow_ready',
    );
  });

  test('typedV2 activation is gated to the ready reason only', () {
    for (final path in const <String>[
      'lib/services/import_pipeline/import_pipeline_service.dart',
      'lib/services/import_pipeline/import_task_coordinator.dart',
      'lib/services/import_pipeline/ocr_import_service.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(
        source,
        isNot(contains('ImportStorageRoute.typedV2')),
        reason: path,
      );
    }
    final gateSource =
        File('lib/services/import_pipeline/ocr_typed_candidate.dart')
            .readAsStringSync();
    expect(
      gateSource,
      contains('ImportStorageRoute.typedV2'),
      reason: 'the eligible gate must activate the typed route',
    );
    expect(
      gateSource,
      contains('typed_candidate_ready'),
      reason: 'typedV2 must always pair with the ready reason',
    );
  });
}

OcrDocument _unreferencedTableDocument() {
  return _document(
    'r7b_synthetic_unreferenced_table.pdf',
    <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('header_table', 1, 0, '表格：考试科目与分数分布表', type: 'table'),
          _block('section', 1, 1, '三、解答题'),
          _block('q_1', 1, 2, '1. Synthetic prompt marker 1.'),
          _block('answer_1', 1, 3, '答案：synthetic-result-1'),
          _block('explanation_1', 1, 4, '解析：Synthetic explanation 1'),
        ],
      ),
    ],
  );
}

OcrDocument _imageInQuestionDocument() {
  const tinyPngDataUrl =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
  return _document(
    'r7b_synthetic_image_in_question.pdf',
    <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('section', 1, 0, '三、解答题'),
          _block('q_1_text', 1, 1, '1. 如图所示：'),
          _block('q_1_img', 1, 2, tinyPngDataUrl, type: 'image'),
          _block('answer_1', 1, 3, '答案：synthetic-result-1'),
          _block('explanation_1', 1, 4, '解析：Synthetic explanation 1'),
        ],
      ),
    ],
  );
}

Future<ImportTask> _waitForImportTask(
  TaskManager manager,
  String taskId,
  bool Function(ImportTask task) predicate,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final matches = manager.tasks.where((task) => task.id == taskId);
    if (matches.isNotEmpty && predicate(matches.first)) return matches.first;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Task did not reach the expected state.');
}
