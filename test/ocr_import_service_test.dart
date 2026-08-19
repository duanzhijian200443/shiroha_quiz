import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/services/import_pipeline/local_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/single_question_repair_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_import_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_format.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document_client.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_request_scheduler.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';
import 'package:shiroha_quiz/services/import_pipeline/subjective_answer_distillation_policy.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/task_center_projection.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';

import 'support/memory_content_asset_store.dart';
import 'support/unsupported_ai_engine_store.dart';

class FakeAiEngineRepository extends AiEngineRepository {
  FakeAiEngineRepository(this.profile)
      : super(
          store: const UnsupportedAiEngineStore(),
          credentialStore: const UnsupportedEngineCredentialStore(),
        );

  final AiEngineProfile? profile;

  @override
  Future<AiEngineProfile?> getActiveOcrEngine() async => profile;
}

class FakeOcrDocumentClient implements OcrDocumentClient {
  FakeOcrDocumentClient(this.document, {this.model = 'fake-ocr-model'});

  final OcrDocument document;
  final String model;
  int callCount = 0;

  @override
  String get modelId => model;

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

class FakeRepairService extends SingleQuestionRepairService {
  const FakeRepairService();

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

class RecordingRepairService extends SingleQuestionRepairService {
  int callCount = 0;
  int inFlight = 0;
  int maxInFlight = 0;
  final List<int> questionNumbers = [];
  final List<ExplanationRetentionMode> retentionModes = [];

  @override
  Future<LocalAssemblyResult> repair({
    required TextQuestionRegion region,
    required LocalAssemblyResult localResult,
    required bool requireAnswer,
    required ExplanationRetentionMode explanationRetentionMode,
  }) async {
    callCount++;
    questionNumbers.add(region.number);
    retentionModes.add(explanationRetentionMode);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    await Future<void>.delayed(Duration.zero);
    inFlight--;
    final question = Map<String, dynamic>.from(localResult.question);
    if ((question['content']?.toString().trim() ?? '').isEmpty) {
      question['content'] = 'Synthetic repaired question ${region.number}';
    }
    final type = question['type'];
    if (type == 0 || type == 1) {
      question['options'] = const <String>['A. First', 'B. Second'];
      if (requireAnswer &&
          (question['standard_answer']?.toString().trim().isEmpty ?? true)) {
        question['standard_answer'] = 'A';
      }
    }
    return LocalAssemblyResult(
      question: question,
      diagnostics: [...localResult.diagnostics, 'ai_repair_applied'],
      repairRecommended: false,
      rejected: false,
    );
  }
}

OcrDocument objectiveExplanationDocument({
  required String explanation,
  String section = '一、选择题（共 1 题）',
  String question = '1. Valid stem (A) one (B) two (C) three (D) four',
  String? answer,
}) {
  return OcrDocument(
    sourceName: 'objective-explanation.pdf',
    markdown: '',
    rawResponses: const [],
    usage: const {},
    pages: [
      OcrPage(
        pageIndex: 1,
        blocks: [
          OcrBlock(
            blockId: 'section',
            pageIndex: 1,
            type: 'text',
            text: section,
            bbox: const [],
            readingOrder: 0,
          ),
          OcrBlock(
            blockId: 'question',
            pageIndex: 1,
            type: 'text',
            text: question,
            bbox: const [],
            readingOrder: 1,
          ),
          if (answer != null)
            OcrBlock(
              blockId: 'answer',
              pageIndex: 1,
              type: 'text',
              text: answer,
              bbox: const [],
              readingOrder: 2,
            ),
          OcrBlock(
            blockId: 'explanation',
            pageIndex: 1,
            type: 'text',
            text: explanation,
            bbox: const [],
            readingOrder: answer == null ? 2 : 3,
          ),
        ],
      ),
    ],
  );
}

AiEngineProfile ocrTestProfile() {
  return AiEngineProfile(
    id: 'ocr-1',
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

OcrDocument unsupportedStructureDocument({bool includeUnsupported = true}) {
  return OcrDocument(
    sourceName: 'unsupported-structure.pdf',
    markdown: '',
    rawResponses: const [],
    usage: const {},
    pages: [
      OcrPage(
        pageIndex: 1,
        blocks: [
          const OcrBlock(
            blockId: 'section',
            pageIndex: 1,
            type: 'text',
            text: 'SECTION 1',
            bbox: [],
            readingOrder: 0,
          ),
          const OcrBlock(
            blockId: 'question',
            pageIndex: 1,
            type: 'text',
            text: '1. Valid stem (A) one (B) two (C) three (D) four',
            bbox: [],
            readingOrder: 1,
          ),
          const OcrBlock(
            blockId: 'answer',
            pageIndex: 1,
            type: 'text',
            text: '答案：A',
            bbox: [],
            readingOrder: 2,
          ),
          const OcrBlock(
            blockId: 'explanation',
            pageIndex: 1,
            type: 'text',
            text: '解析：valid explanation',
            bbox: [],
            readingOrder: 3,
          ),
          if (includeUnsupported) ...[
            const OcrBlock(
              blockId: 'canary_img_1',
              pageIndex: 1,
              type: 'image',
              text: '',
              bbox: [1, 2, 3, 4],
              readingOrder: 4,
            ),
            const OcrBlock(
              blockId: 'canary_figure_1',
              pageIndex: 1,
              type: ' Figure ',
              text: '',
              bbox: [],
              readingOrder: 5,
            ),
            const OcrBlock(
              blockId: 'canary_table_1',
              pageIndex: 1,
              type: 'TABLE',
              text: '',
              bbox: [],
              readingOrder: 6,
            ),
            const OcrBlock(
              blockId: 'canary_chart_1',
              pageIndex: 1,
              type: 'chart',
              text: '',
              bbox: [],
              readingOrder: 7,
            ),
          ],
        ],
      ),
    ],
  );
}

void main() {
  group('OcrImportService', () {
    test('uses OCR path when GLM-OCR returns a valid document', () async {
      final profile = AiEngineProfile(
        id: 'ocr-1',
        engineType: AiEngineType.ocr,
        name: 'zhipu-ocr',
        apiKey: 'test-key',
        baseUrl: 'https://open.bigmodel.cn/api/paas',
        modelName: 'glm-ocr',
        temperature: 0.1,
        reasoningEffort: '',
        isActive: true,
      );

      final document = OcrDocument(
        sourceName: 'sample.pdf',
        markdown: '',
        rawResponses: const [],
        usage: const {},
        pages: [
          OcrPage(
            pageIndex: 1,
            blocks: [
              const OcrBlock(
                blockId: 'p001_b0001',
                pageIndex: 1,
                type: 'text',
                text:
                    '1 设 lim f(x)/ln x = 1，则（ ）\n(A) f(1)=0\n(B) lim f(x)=0\n(C) f\'(1)=1\n(D) lim f\'(x)=1',
                bbox: [],
                readingOrder: 0,
              ),
              const OcrBlock(
                blockId: 'p001_b0002',
                pageIndex: 1,
                type: 'text',
                text: '答案：B',
                bbox: [],
                readingOrder: 1,
              ),
              const OcrBlock(
                blockId: 'p001_b0003',
                pageIndex: 1,
                type: 'text',
                text: '解析：由极限可知 ...',
                bbox: [],
                readingOrder: 2,
              ),
            ],
          ),
        ],
      );

      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: FakeOcrDocumentClient(document),
        repairService: const FakeRepairService(),
      );

      final result = await service.tryParse(
        filePath: 'C:\\tmp\\sample.pdf',
        sourceName: 'sample.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      expect(result!.usedOcr, isTrue);
      expect(result.questions, hasLength(1));
      expect(result.questions.first['q_num'], '1');
      expect(result.questions.first['source'], 'glm_ocr_intermediate');
      expect(result.diagnostics['status'], 'used_ocr');
    });

    test('records safe image/table counts without changing question output',
        () async {
      final profile = ocrTestProfile();
      final client = FakeOcrDocumentClient(unsupportedStructureDocument());
      final repairService = RecordingRepairService();
      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: client,
        repairService: repairService,
      );
      final baselineClient = FakeOcrDocumentClient(
        unsupportedStructureDocument(includeUnsupported: false),
      );
      final baselineService = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: baselineClient,
        repairService: const FakeRepairService(),
      );

      final result = await service.tryParse(
        filePath: 'C:\\tmp\\sample.pdf',
        sourceName: 'sample.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );
      final baseline = await baselineService.tryParse(
        filePath: 'C:\\tmp\\sample.pdf',
        sourceName: 'sample.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      expect(result!.usedOcr, isTrue);
      expect(result.questions, hasLength(1));
      expect(result.questions, baseline!.questions,
          reason: 'unsupported structure blocks must not change question maps');
      expect(result.diagnostics['status'], 'used_ocr');
      expect(
        result.diagnostics['unsupportedStructureSummary'],
        <String, int>{'imageBlockCount': 2, 'tableBlockCount': 1},
        reason: 'image/figure counts normalize case and whitespace',
      );
      expect(
        baseline.diagnostics.containsKey('unsupportedStructureSummary'),
        isFalse,
      );

      final diagnosticsJson = jsonEncode(result.diagnostics);
      expect(diagnosticsJson, isNot(contains('canary_img_1')));
      expect(diagnosticsJson, isNot(contains('canary_figure_1')));
      expect(diagnosticsJson, isNot(contains('canary_table_1')));
      expect(diagnosticsJson, isNot(contains('canary_chart_1')));
      expect(diagnosticsJson, isNot(contains('bbox')));

      expect(client.callCount, 1,
          reason: 'structure counting must not add OCR provider calls');
      expect(repairService.callCount, 0,
          reason: 'structure counting must not trigger repair');
    });

    test('omits unsupported structure summary when no image or table blocks',
        () async {
      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(ocrTestProfile()),
        ocrClient: FakeOcrDocumentClient(
          unsupportedStructureDocument(includeUnsupported: false),
        ),
        repairService: const FakeRepairService(),
      );

      final result = await service.tryParse(
        filePath: 'C:\\tmp\\sample.pdf',
        sourceName: 'sample.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      expect(
        result!.diagnostics.containsKey('unsupportedStructureSummary'),
        isFalse,
      );
    });

    test(
        'attaches tail reference answers when compound heading is embedded in a block',
        () async {
      const profile = AiEngineProfile(
        id: 'ocr-reference-answers',
        engineType: AiEngineType.ocr,
        name: 'zhipu-ocr',
        apiKey: 'test-key',
        baseUrl: 'https://open.bigmodel.cn/api/paas',
        modelName: 'glm-ocr',
        temperature: 0.1,
        reasoningEffort: '',
        isActive: true,
      );
      const document = OcrDocument(
        sourceName: 'reference-answers.pdf',
        markdown: '',
        rawResponses: [],
        usage: {},
        pages: [
          OcrPage(
            pageIndex: 1,
            blocks: [
              OcrBlock(
                blockId: 'section',
                pageIndex: 1,
                type: 'text',
                text: '三、解答题（共2题）',
                bbox: [],
                readingOrder: 0,
              ),
              OcrBlock(
                blockId: 'q1',
                pageIndex: 1,
                type: 'text',
                text: '1. Synthetic subjective question one',
                bbox: [],
                readingOrder: 1,
              ),
              OcrBlock(
                blockId: 'e1',
                pageIndex: 1,
                type: 'text',
                text: '解析：Synthetic explanation one',
                bbox: [],
                readingOrder: 2,
              ),
              OcrBlock(
                blockId: 'q2',
                pageIndex: 1,
                type: 'text',
                text: '2. Synthetic subjective question two',
                bbox: [],
                readingOrder: 3,
              ),
              OcrBlock(
                blockId: 'e2',
                pageIndex: 1,
                type: 'text',
                text: '解析：Synthetic explanation two',
                bbox: [],
                readingOrder: 4,
              ),
              OcrBlock(
                blockId: 'reference_title',
                pageIndex: 1,
                type: 'text',
                text: '安全尾注\n'
                    '第二行安全尾注\n'
                    '2022 模拟试卷参考答案汇总\n'
                    '安全说明\n'
                    '第二行安全说明',
                bbox: [],
                readingOrder: 5,
              ),
              OcrBlock(
                blockId: 'reference_1',
                pageIndex: 1,
                type: 'text',
                text: '(1) Final answer one',
                bbox: [],
                readingOrder: 6,
              ),
              OcrBlock(
                blockId: 'reference_2',
                pageIndex: 1,
                type: 'text',
                text: '（2）Final answer two',
                bbox: [],
                readingOrder: 7,
              ),
            ],
          ),
        ],
      );
      final repair = RecordingRepairService();
      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: FakeOcrDocumentClient(document),
        repairService: repair,
      );

      final result = await service.tryParse(
        filePath: r'C:\tmp\reference-answers.pdf',
        sourceName: 'reference-answers.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      expect(result!.questions, hasLength(2));
      expect(
        result.questions.map((question) => question['question_number']),
        [1, 2],
      );
      expect(
        result.questions.map((question) => question['standard_answer']),
        ['Final answer one', 'Final answer two'],
      );
      expect(
        result.questions.map((question) => question['explanation']),
        [
          'Synthetic explanation one',
          'Synthetic explanation two\n'
              '安全尾注\n'
              '第二行安全尾注',
        ],
      );
      expect(
        result.questions.last['explanation'],
        isNot(contains('安全说明')),
      );
      expect(
        result.questions.every(
          (question) => (question['diagnostics'] as List)
              .contains('reference_answer_attached'),
        ),
        isTrue,
      );
      expect(repair.callCount, 0);
      expect(
        result.questions.every(
          (question) => !const SubjectiveAnswerDistillationPolicy().isCandidate(
            QuestionDraft.fromMap(question),
            isStemOnly: false,
          ),
        ),
        isTrue,
      );
      expect(result.diagnostics['referenceAnswerSectionDetected'], isTrue);
      expect(result.diagnostics['referenceAnswerAcceptedNumbers'], [1, 2]);
      expect(result.diagnostics['referenceAnswerAttachedCount'], 2);
      expect(result.diagnostics['referenceAnswerConflictCount'], 0);
      final safeDiagnostics = jsonEncode(result.diagnostics);
      expect(safeDiagnostics, isNot(contains('Final answer one')));
      expect(safeDiagnostics, isNot(contains('Final answer two')));
    });

    test('healthy cross-page question preserves provenance without repair',
        () async {
      final profile = AiEngineProfile(
        id: 'ocr-cross-page',
        engineType: AiEngineType.ocr,
        name: 'zhipu-ocr',
        apiKey: 'test-key',
        baseUrl: 'https://open.bigmodel.cn/api/paas',
        modelName: 'glm-ocr',
        temperature: 0.1,
        reasoningEffort: '',
        isActive: true,
      );
      final repair = RecordingRepairService();
      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: FakeOcrDocumentClient(
          const OcrDocument(
            sourceName: 'cross-page.pdf',
            markdown: '',
            rawResponses: [],
            usage: {},
            pages: [
              OcrPage(
                pageIndex: 1,
                blocks: [
                  OcrBlock(
                    blockId: 'section',
                    pageIndex: 1,
                    type: 'text',
                    text: '一、选择题（共 1 题）',
                    bbox: [],
                    readingOrder: 0,
                  ),
                  OcrBlock(
                    blockId: 'question',
                    pageIndex: 1,
                    type: 'text',
                    text: '1. Safe cross-page stem\n'
                        '(A) one (B) two (C) three (D) four',
                    bbox: [],
                    readingOrder: 1,
                  ),
                ],
              ),
              OcrPage(
                pageIndex: 2,
                blocks: [
                  OcrBlock(
                    blockId: 'answer',
                    pageIndex: 2,
                    type: 'text',
                    text: '答案：A',
                    bbox: [],
                    readingOrder: 0,
                  ),
                ],
              ),
            ],
          ),
        ),
        repairService: repair,
      );

      final result = await service.tryParse(
        filePath: r'C:\tmp\cross-page.pdf',
        sourceName: 'cross-page.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      expect(result!.questions, hasLength(1));
      expect(repair.callCount, 0);
      expect(result.diagnostics['repairRecommendedCount'], 1);
      expect(result.diagnostics['repairEligibleCount'], 0);
      expect(result.diagnostics['repairAttemptedCount'], 0);
      expect(result.diagnostics['repairSkippedNonStructuralCount'], 1);
      expect(
        result.questions.single['diagnostics'],
        contains('cross_page_region'),
      );
      expect(result.questions.single['source_page_indices'], [1, 2]);
      expect(
        result.questions.single['source_block_ids'],
        containsAll(<String>['question', 'answer']),
      );
      final timing = result.diagnostics['timing'] as Map<String, dynamic>;
      expect(timing['repairAttempts'], isEmpty);
      expect(timing['totalDurationMs'], isA<int>());
    });

    test('hidden objective explanation defects do not call repair', () async {
      final profile = AiEngineProfile(
        id: 'ocr-hidden-explanation',
        engineType: AiEngineType.ocr,
        name: 'zhipu-ocr',
        apiKey: 'test-key',
        baseUrl: 'https://open.bigmodel.cn/api/paas',
        modelName: 'glm-ocr',
        temperature: 0.1,
        reasoningEffort: '',
        isActive: true,
      );
      final repair = RecordingRepairService();
      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: FakeOcrDocumentClient(
          objectiveExplanationDocument(
            explanation: r'解析：故选 B。Hidden broken formula \(x',
          ),
        ),
        repairService: repair,
      );

      final result = await service.tryParse(
        filePath: r'C:\tmp\hidden-explanation.pdf',
        sourceName: 'hidden-explanation.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      final question = result!.questions.single;
      expect(question['standard_answer'], 'B');
      expect(question['explanation'], isEmpty);
      expect(question['raw_explanation'], contains(r'\(x'));
      expect(question['diagnostics'], isNot(contains('dangling_latex')));
      final metadata = question['_import_review'] as Map<String, dynamic>;
      expect(
        metadata['repairCandidateCodes'],
        isNot(contains('dangling_latex')),
      );
      expect(repair.callCount, 0);
      expect(result.diagnostics['repairEligibleCount'], 0);
      expect(result.diagnostics['repairAttemptedCount'], 0);
    });

    test('hidden fill explanation HTML does not call repair', () async {
      final profile = AiEngineProfile(
        id: 'ocr-hidden-fill-explanation',
        engineType: AiEngineType.ocr,
        name: 'zhipu-ocr',
        apiKey: 'test-key',
        baseUrl: 'https://open.bigmodel.cn/api/paas',
        modelName: 'glm-ocr',
        temperature: 0.1,
        reasoningEffort: '',
        isActive: true,
      );
      final repair = RecordingRepairService();
      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: FakeOcrDocumentClient(
          objectiveExplanationDocument(
            section: '二、填空题（共 1 题）',
            question: '1. Synthetic value is ____.',
            answer: '答案：42',
            explanation:
                '解析：<div>Hidden explanation</div><script>unsafe()</script>',
          ),
        ),
        repairService: repair,
      );

      final result = await service.tryParse(
        filePath: r'C:\tmp\hidden-fill-explanation.pdf',
        sourceName: 'hidden-fill-explanation.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      final question = result!.questions.single;
      expect(question['standard_answer'], '42');
      expect(question['explanation'], isEmpty);
      expect(question['raw_explanation'], contains('<script>'));
      expect(question['diagnostics'], isNot(contains('raw_html_tag')));
      expect(repair.callCount, 0);
      expect(result.diagnostics['repairEligibleCount'], 0);
      expect(result.diagnostics['repairAttemptedCount'], 0);
    });

    test(
        'retained objective explanation defects stay review-only without repair',
        () async {
      final profile = AiEngineProfile(
        id: 'ocr-retained-explanation',
        engineType: AiEngineType.ocr,
        name: 'zhipu-ocr',
        apiKey: 'test-key',
        baseUrl: 'https://open.bigmodel.cn/api/paas',
        modelName: 'glm-ocr',
        temperature: 0.1,
        reasoningEffort: '',
        isActive: true,
      );
      final repair = RecordingRepairService();
      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: FakeOcrDocumentClient(
          objectiveExplanationDocument(
            explanation:
                r'解析：故选 B。Retained broken formula \(\begin{matrix}1\end{pmatrix}\)',
          ),
        ),
        repairService: repair,
      );

      final result = await service.tryParse(
        filePath: r'C:\tmp\retained-explanation.pdf',
        sourceName: 'retained-explanation.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
      );

      expect(result, isNotNull);
      final question = result!.questions.single;
      expect(question['standard_answer'], 'B');
      expect(question['explanation'], contains(r'\begin{matrix}'));
      final metadata = question['_import_review'] as Map<String, dynamic>;
      expect(metadata['riskHints'], contains('latex_unrenderable'));
      expect(
        metadata['repairCandidateCodes'],
        isNot(contains('dangling_latex')),
      );
      expect(repair.callCount, 0);
      expect(repair.retentionModes, isEmpty);
      expect(result.diagnostics['repairEligibleCount'], 0);
      expect(result.diagnostics['repairAttemptedCount'], 0);
    });

    test('real structural defects repair serially with safe timing', () async {
      final profile = AiEngineProfile(
        id: 'ocr-structural-repair',
        engineType: AiEngineType.ocr,
        name: 'zhipu-ocr',
        apiKey: 'test-key',
        baseUrl: 'https://open.bigmodel.cn/api/paas',
        modelName: 'glm-ocr',
        temperature: 0.1,
        reasoningEffort: '',
        isActive: true,
      );
      final repair = RecordingRepairService();
      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: FakeOcrDocumentClient(
          const OcrDocument(
            sourceName: 'structural.pdf',
            markdown: '',
            rawResponses: [],
            usage: {},
            pages: [
              OcrPage(
                pageIndex: 1,
                blocks: [
                  OcrBlock(
                    blockId: 'section',
                    pageIndex: 1,
                    type: 'text',
                    text: '一、选择题（共 2 题）',
                    bbox: [],
                    readingOrder: 0,
                  ),
                  OcrBlock(
                    blockId: 'q1',
                    pageIndex: 1,
                    type: 'text',
                    text: '1. SENSITIVE_FIXTURE_BODY_ONE',
                    bbox: [],
                    readingOrder: 1,
                  ),
                  OcrBlock(
                    blockId: 'a1',
                    pageIndex: 1,
                    type: 'text',
                    text: '答案：A',
                    bbox: [],
                    readingOrder: 2,
                  ),
                  OcrBlock(
                    blockId: 'q2',
                    pageIndex: 1,
                    type: 'text',
                    text: '2. SENSITIVE_FIXTURE_BODY_TWO',
                    bbox: [],
                    readingOrder: 3,
                  ),
                  OcrBlock(
                    blockId: 'a2',
                    pageIndex: 1,
                    type: 'text',
                    text: '答案：B',
                    bbox: [],
                    readingOrder: 4,
                  ),
                ],
              ),
            ],
          ),
        ),
        repairService: repair,
      );

      final result = await service.tryParse(
        filePath: r'C:\tmp\structural.pdf',
        sourceName: 'structural.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      expect(result!.questions, hasLength(2));
      expect(repair.callCount, 2);
      expect(repair.questionNumbers, [1, 2]);
      expect(repair.maxInFlight, 1);
      expect(result.diagnostics['repairEligibleCount'], 2);
      expect(result.diagnostics['repairAttemptedCount'], 2);
      expect(result.diagnostics['repairAppliedCount'], 2);
      final timing = result.diagnostics['timing'] as Map<String, dynamic>;
      final attempts = timing['repairAttempts'] as List<Map<String, dynamic>>;
      expect(attempts, hasLength(2));
      expect(
        attempts.map((attempt) => attempt['questionNumber']),
        [1, 2],
      );
      expect(
        attempts.every(
          (attempt) =>
              (attempt['triggerCodes'] as List)
                  .contains('choice_options_less_than_2') &&
              attempt['outcome'] == 'applied' &&
              attempt['durationMs'] is int &&
              (attempt['durationMs'] as int) >= 0,
        ),
        isTrue,
      );
      final safeDiagnostics = jsonEncode(result.diagnostics);
      expect(safeDiagnostics, isNot(contains('SENSITIVE_FIXTURE_BODY')));
      expect(safeDiagnostics, isNot(contains(r'C:\tmp')));
    });

    test('cleans safe HTML wrappers before returning OCR questions', () async {
      final profile = AiEngineProfile(
        id: 'ocr-html-cleanup',
        engineType: AiEngineType.ocr,
        name: 'zhipu-ocr',
        apiKey: 'test-key',
        baseUrl: 'https://open.bigmodel.cn/api/paas',
        modelName: 'glm-ocr',
        temperature: 0.1,
        reasoningEffort: '',
        isActive: true,
      );
      final document = OcrDocument(
        sourceName: 'html-cleanup.pdf',
        markdown: '',
        rawResponses: const [],
        usage: const {},
        pages: [
          OcrPage(
            pageIndex: 1,
            blocks: const [
              OcrBlock(
                blockId: 'question',
                pageIndex: 1,
                type: 'text',
                text: '1. <div>Question <span>body</span></div>',
                bbox: [],
                readingOrder: 0,
              ),
              OcrBlock(
                blockId: 'answer',
                pageIndex: 1,
                type: 'text',
                text: '答案：<p>Answer value</p>',
                bbox: [],
                readingOrder: 1,
              ),
              OcrBlock(
                blockId: 'explanation',
                pageIndex: 1,
                type: 'text',
                text: '解析：<div>Explanation<br>line</div>'
                    '<script>dangerousScript()</script>',
                bbox: [],
                readingOrder: 2,
              ),
            ],
          ),
        ],
      );
      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: FakeOcrDocumentClient(document),
        repairService: const FakeRepairService(),
      );

      final result = await service.tryParse(
        filePath: r'C:\tmp\html-cleanup.pdf',
        sourceName: 'html-cleanup.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      expect(result!.usedOcr, isTrue);
      final question = result.questions.single;
      expect(question['content'], 'Question body');
      expect(question['standard_answer'], 'Answer value');
      expect(question['explanation'], 'Explanation\nline');
      expect(question['explanation'], isNot(contains('dangerousScript')));
      expect(question['raw_explanation'], contains('<div>'));
      expect(
        question['diagnostics'],
        contains('unsafe_html_content_removed'),
      );
    });

    test('assembles split and inline question markers through OCR service',
        () async {
      final profile = AiEngineProfile(
        id: 'ocr-regionizer-regression',
        engineType: AiEngineType.ocr,
        name: 'zhipu-ocr',
        apiKey: 'test-key',
        baseUrl: 'https://open.bigmodel.cn/api/paas',
        modelName: 'glm-ocr',
        temperature: 0.1,
        reasoningEffort: '',
        isActive: true,
      );

      final document = OcrDocument(
        sourceName: 'regionizer-regression.pdf',
        markdown: '',
        rawResponses: const [],
        usage: const {},
        pages: [
          OcrPage(
            pageIndex: 1,
            blocks: [
              const OcrBlock(
                blockId: 'section_heading',
                pageIndex: 1,
                type: 'text',
                text: '一、选择题（共 2 题）',
                bbox: [],
                readingOrder: 0,
              ),
              const OcrBlock(
                blockId: 'question_1_number',
                pageIndex: 1,
                type: 'text',
                text: '1．',
                bbox: [],
                readingOrder: 1,
              ),
              const OcrBlock(
                blockId: 'question_1_stem',
                pageIndex: 1,
                type: 'text',
                text: '某对象满足条件，求值。',
                bbox: [],
                readingOrder: 2,
              ),
              const OcrBlock(
                blockId: 'question_2',
                pageIndex: 1,
                type: 'text',
                text: '2. 给定对象，判断结论。',
                bbox: [],
                readingOrder: 3,
              ),
            ],
          ),
        ],
      );

      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: FakeOcrDocumentClient(document),
        repairService: const FakeRepairService(),
      );

      final result = await service.tryParse(
        filePath: 'C:\\tmp\\regionizer-regression.pdf',
        sourceName: 'regionizer-regression.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      expect(result!.usedOcr, isTrue);
      expect(result.questions, isNotEmpty);
      expect(
        result.questions.map((question) => question['question_number']),
        [1, 2],
      );

      final firstQuestion = result.questions.first;
      expect(firstQuestion['content'], contains('某对象满足条件'));
      expect(
        firstQuestion['source_block_ids'],
        containsAll(['question_1_number', 'question_1_stem']),
      );
      expect(firstQuestion['type'], 0);
      expect(
        firstQuestion['diagnostics'],
        contains('kind_declared_from_section:choice'),
      );

      expect(result.warnings, isEmpty);
      expect(result.diagnostics['status'], 'used_ocr');
      expect(result.diagnostics['status'], isNot('failed_no_question_regions'));
      expect(result.diagnostics['assembledQuestionCount'], 2);
      expect(result.diagnostics['repairRecommendedCount'], 2);
      expect(result.diagnostics['repairAttemptedCount'], 2);
      expect(result.diagnostics['repairAppliedCount'], 0);
      expect(result.diagnostics['rejectedRegionCount'], 0);
      expect(
        result.questions.every(
          (question) => question['source'] == 'glm_ocr_intermediate',
        ),
        isTrue,
      );
      expect(result.warnings.join(), isNot(contains('视觉')));
    });

    test('imports 23 sequenced parenthesized questions without answers',
        () async {
      final profile = AiEngineProfile(
        id: 'ocr-parenthesized-sequence',
        engineType: AiEngineType.ocr,
        name: 'zhipu-ocr',
        apiKey: 'test-key',
        baseUrl: 'https://open.bigmodel.cn/api/paas',
        modelName: 'glm-ocr',
        temperature: 0.1,
        reasoningEffort: '',
        isActive: true,
      );

      final blocks = <OcrBlock>[];
      var order = 0;

      void addBlock(String id, String text) {
        blocks.add(
          OcrBlock(
            blockId: id,
            pageIndex: 1,
            type: 'text',
            text: text,
            bbox: const [],
            readingOrder: order++,
          ),
        );
      }

      addBlock(
        'choice_section',
        '## 一、选择题（本题共8小题，每小题4分，共32分。在每小题给出的四个选项中，只有一项符合要求。）',
      );
      for (var number = 1; number <= 8; number++) {
        addBlock('q$number', '（$number）第$number道选择占位题干。');
      }
      addBlock('fill_section', '## 二、填空题（本题共6小题）');
      for (var number = 9; number <= 14; number++) {
        addBlock('q$number', '（$number）第$number道填空占位题干。');
      }
      addBlock('subjective_section', '## 三、解答题（本题共9小题）');
      for (var number = 15; number <= 23; number++) {
        addBlock('q$number', '（$number）第$number道解答占位题干。');
        if (number == 15) {
          addBlock('q15_roman_1', '（Ⅰ）求第一部分；');
          addBlock('q15_roman_2', '（Ⅱ）证明第二部分。');
        }
      }

      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: FakeOcrDocumentClient(
          OcrDocument(
            sourceName: 'parenthesized-sequence.pdf',
            markdown: '',
            rawResponses: const [],
            usage: const {},
            pages: [OcrPage(pageIndex: 1, blocks: blocks)],
          ),
        ),
        repairService: const FakeRepairService(),
      );

      final result = await service.tryParse(
        filePath: 'C:\\tmp\\parenthesized-sequence.pdf',
        sourceName: 'parenthesized-sequence.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      expect(result!.usedOcr, isTrue);
      expect(result.questions, hasLength(23));
      expect(
        result.questions.map((question) => question['question_number']),
        List<int>.generate(23, (index) => index + 1),
      );
      expect(
        result.questions.every(
          (question) => question['standard_answer'].toString().isEmpty,
        ),
        isTrue,
      );
      expect(
        result.questions.map((question) => question['question_number']),
        isNot(contains('Ⅰ')),
      );
      final question15 = result.questions[14];
      expect(question15['content'], contains('（Ⅰ）'));
      expect(question15['content'], contains('（Ⅱ）'));
      expect(
        question15['source_block_ids'],
        containsAll(['q15', 'q15_roman_1', 'q15_roman_2']),
      );

      final regionizerDiagnostics =
          result.diagnostics['regionizer'] as Map<String, dynamic>;
      expect(regionizerDiagnostics['acceptedNumbers'],
          List<int>.generate(23, (index) => index + 1));
      expect(regionizerDiagnostics['regionCount'], 23);
      expect(regionizerDiagnostics['sectionHeadingCount'], 3);
      expect(regionizerDiagnostics['parenthesizedArabicCandidateCount'], 23);
      expect(regionizerDiagnostics['parenthesizedArabicAcceptedCount'], 23);
      expect(regionizerDiagnostics['parenthesizedArabicRejectedCount'], 0);
      expect(regionizerDiagnostics['romanSubquestionCount'], 2);
      expect(result.diagnostics['status'], 'used_ocr');
      expect(result.diagnostics['status'], isNot('failed_no_question_regions'));
      expect(result.warnings.join(), isNot(contains('视觉')));
    });

    test('imports all 23 questions across pages with Markdown-prefixed tails',
        () async {
      const profile = AiEngineProfile(
        id: 'ocr-markdown-four-pages',
        engineType: AiEngineType.ocr,
        name: 'zhipu-ocr',
        apiKey: 'test-key',
        baseUrl: 'https://open.bigmodel.cn/api/paas',
        modelName: 'glm-ocr',
        temperature: 0.1,
        reasoningEffort: '',
        isActive: true,
      );

      OcrBlock questionBlock(int page, int number, int order) {
        final marker = switch (number % 3) {
          0 => '> （$number）',
          1 => '## （$number）',
          _ => '### ($number)',
        };
        return OcrBlock(
          blockId: 'p${page}_q$number',
          pageIndex: page,
          type: 'text',
          text: number >= 16
              ? '$marker 第$number道脱敏题干。'
              : '（$number）第$number道脱敏题干。',
          bbox: const [],
          readingOrder: order,
        );
      }

      final pages = <OcrPage>[];
      for (final range in <(int, int, int)>[
        (1, 1, 8),
        (2, 9, 16),
        (3, 17, 20),
        (4, 21, 23),
      ]) {
        final blocks = <OcrBlock>[];
        var order = 0;
        if (range.$1 == 1) {
          blocks.add(OcrBlock(
            blockId: 'choice_section',
            pageIndex: range.$1,
            type: 'text',
            text: '一、选择题（共8题）',
            bbox: const [],
            readingOrder: order++,
          ));
        } else if (range.$1 == 2) {
          blocks.add(OcrBlock(
            blockId: 'fill_section',
            pageIndex: range.$1,
            type: 'text',
            text: '二、填空题（共6题）',
            bbox: const [],
            readingOrder: order++,
          ));
        } else if (range.$1 == 3) {
          blocks.add(OcrBlock(
            blockId: 'subjective_section',
            pageIndex: range.$1,
            type: 'text',
            text: '三、解答题（共9题）',
            bbox: const [],
            readingOrder: order++,
          ));
        }
        for (var number = range.$2; number <= range.$3; number++) {
          blocks.add(questionBlock(range.$1, number, order++));
        }
        pages.add(OcrPage(pageIndex: range.$1, blocks: blocks));
      }

      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: FakeOcrDocumentClient(
          OcrDocument(
            sourceName: 'markdown-four-pages.pdf',
            markdown: 'present',
            rawResponses: const [],
            usage: const {},
            pages: pages,
          ),
        ),
        repairService: const FakeRepairService(),
      );

      final result = await service.tryParse(
        filePath: 'C:\\tmp\\markdown-four-pages.pdf',
        sourceName: 'markdown-four-pages.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      expect(result!.usedOcr, isTrue);
      expect(result.questions, hasLength(23));
      expect(
        result.questions.map((question) => question['question_number']),
        List<int>.generate(23, (index) => index + 1),
      );
      expect(result.diagnostics['status'], isNot('failed_no_question_regions'));
      final regionizerDiagnostics =
          result.diagnostics['regionizer'] as Map<String, dynamic>;
      expect(regionizerDiagnostics['regionCount'], 23);
      expect(regionizerDiagnostics['acceptedQuestionCount'], 23);
      expect(regionizerDiagnostics['expectedQuestionCount'], 23);
      expect(regionizerDiagnostics['tailMissingNumbers'], isEmpty);
      expect(regionizerDiagnostics['pageCandidateCounts'], {
        '1': 8,
        '2': 8,
        '3': 4,
        '4': 3,
      });
      expect(regionizerDiagnostics['markdownPrefixedCandidateCount'], 8);
      expect(regionizerDiagnostics['internalLineCandidateCount'], 0);
      expect(result.diagnostics['assembledQuestionCount'], 23);
      expect(result.warnings.join(), isNot(contains('视觉')));
    });

    test('non-empty OCR text without question numbers fails without Vision',
        () async {
      final profile = AiEngineProfile(
        id: 'ocr-no-question-number',
        engineType: AiEngineType.ocr,
        name: 'zhipu-ocr',
        apiKey: 'test-key',
        baseUrl: 'https://open.bigmodel.cn/api/paas',
        modelName: 'glm-ocr',
        temperature: 0.1,
        reasoningEffort: '',
        isActive: true,
      );

      final document = OcrDocument(
        sourceName: 'no-question-number.pdf',
        markdown: '',
        rawResponses: const [],
        usage: const {},
        pages: [
          OcrPage(
            pageIndex: 1,
            blocks: [
              const OcrBlock(
                blockId: 'plain_text',
                pageIndex: 1,
                type: 'text',
                text: '这是一段没有任何有效题号的脱敏文本。',
                bbox: [],
                readingOrder: 0,
              ),
            ],
          ),
        ],
      );

      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: FakeOcrDocumentClient(document),
        repairService: const FakeRepairService(),
      );

      final result = await service.tryParse(
        filePath: 'C:\\tmp\\no-question-number.pdf',
        sourceName: 'no-question-number.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      expect(result!.usedOcr, isFalse);
      expect(result.questions, isEmpty);
      expect(result.diagnostics['status'], 'failed_no_question_regions');
      expect(
        result.warnings,
        contains('OCR 未识别到有效题目区域，请检查文档内容后重试。'),
      );
      expect(result.warnings.join(), isNot(contains('视觉')));
    });

    test('fails explicitly when GLM-OCR returns only empty blocks', () async {
      final profile = AiEngineProfile(
        id: 'ocr-1',
        engineType: AiEngineType.ocr,
        name: 'zhipu-ocr',
        apiKey: 'test-key',
        baseUrl: 'https://open.bigmodel.cn/api/paas',
        modelName: 'glm-ocr',
        temperature: 0.1,
        reasoningEffort: '',
        isActive: true,
      );

      final document = OcrDocument(
        sourceName: 'empty.pdf',
        markdown: '',
        rawResponses: const [],
        usage: const {},
        pages: [
          OcrPage(
            pageIndex: 1,
            blocks: const [],
          ),
        ],
      );

      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: FakeOcrDocumentClient(document),
        repairService: const FakeRepairService(),
      );

      final result = await service.tryParse(
        filePath: 'C:\\tmp\\empty.pdf',
        sourceName: 'empty.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      expect(result!.usedOcr, isFalse);
      expect(result.questions, isEmpty);
      expect(result.warnings, contains('OCR 未识别到有效文字，请检查文档清晰度后重试。'));
      expect(result.diagnostics['status'], 'failed_empty_ocr_blocks');
      expect(result.warnings.join(), isNot(contains('视觉')));
    });

    test('fails explicitly when OCR is not configured', () async {
      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(null),
        ocrClient: FakeOcrDocumentClient(
          const OcrDocument(
            sourceName: 'unconfigured.pdf',
            markdown: '',
            rawResponses: [],
            usage: {},
            pages: [],
          ),
        ),
      );

      final result = await service.tryParse(
        filePath: 'C:\\tmp\\sample.pdf',
        sourceName: 'sample.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      expect(result!.usedOcr, isFalse);
      expect(result.questions, isEmpty);
      expect(result.diagnostics['status'], 'failed_not_configured');
      expect(result.warnings, contains('未配置可用的智谱 OCR 引擎，请先完成 OCR 配置。'));
    });

    test('releases the OCR slot before downstream repair completes', () async {
      final profile = _concurrencyProfile();
      final client = ControlledOcrDocumentClient();
      final scheduler = OcrRequestScheduler(maxConcurrentRequests: 2);
      final repair = BlockingRepairService();
      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: client,
        requestScheduler: scheduler,
        repairService: repair,
      );

      final first = service.tryParse(
        filePath: 'first.pdf',
        sourceName: 'first.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );
      final second = service.tryParse(
        filePath: 'second.pdf',
        sourceName: 'second.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );
      final third = service.tryParse(
        filePath: 'third.pdf',
        sourceName: 'third.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );
      var firstCompleted = false;
      unawaited(first.then<void>((_) {
        firstCompleted = true;
      }));

      await Future.wait<void>(<Future<void>>[
        client.waitUntilStarted('first.pdf'),
        client.waitUntilStarted('second.pdf'),
      ]);
      expect(client.hasStarted('third.pdf'), isFalse);

      client.complete('first.pdf', _structuralConcurrencyDocument());
      await client.waitUntilStarted('third.pdf');
      await repair.started.future;

      expect(firstCompleted, isFalse);
      expect(client.maxActiveCount, 2);

      repair.release.complete();
      final validDocument = objectiveExplanationDocument(
        explanation: 'Synthetic explanation',
        answer: '答案：A',
      );
      client.complete('second.pdf', validDocument);
      client.complete('third.pdf', validDocument);

      final results = await Future.wait<OcrImportResult?>(
        <Future<OcrImportResult?>>[first, second, third],
      );
      expect(results.every((result) => result?.usedOcr == true), isTrue);
      expect(client.callCount, 3);
    });

    test('releases the OCR slot when the client throws', () async {
      final client = ControlledOcrDocumentClient();
      final scheduler = OcrRequestScheduler(maxConcurrentRequests: 2);
      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(_concurrencyProfile()),
        ocrClient: client,
        requestScheduler: scheduler,
        repairService: const FakeRepairService(),
      );

      final first = service.tryParse(
        filePath: 'failed.pdf',
        sourceName: 'failed.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );
      final second = service.tryParse(
        filePath: 'second.pdf',
        sourceName: 'second.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );
      final third = service.tryParse(
        filePath: 'third.pdf',
        sourceName: 'third.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      await Future.wait<void>(<Future<void>>[
        client.waitUntilStarted('failed.pdf'),
        client.waitUntilStarted('second.pdf'),
      ]);
      expect(client.hasStarted('third.pdf'), isFalse);

      client.fail('failed.pdf', StateError('synthetic client failure'));
      await client.waitUntilStarted('third.pdf');

      final validDocument = objectiveExplanationDocument(
        explanation: 'Synthetic explanation',
        answer: '答案：A',
      );
      client.complete('second.pdf', validDocument);
      client.complete('third.pdf', validDocument);

      final results = await Future.wait<OcrImportResult?>(
        <Future<OcrImportResult?>>[first, second, third],
      );
      expect(results.first?.usedOcr, isFalse);
      expect(results.first?.diagnostics['status'], 'failed_request');
      expect(results[1]?.usedOcr, isTrue);
      expect(results[2]?.usedOcr, isTrue);
      expect(client.callCount, 3);
      expect(client.maxActiveCount, 2);
    });

    test(
        'four independent tasks traverse pipeline with one shared OCR scheduler',
        () async {
      final manager = TaskManager.forTesting();
      final client = ControlledOcrDocumentClient();
      final scheduler = OcrRequestScheduler(maxConcurrentRequests: 2);
      final ocrService = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(_concurrencyProfile()),
        ocrClient: client,
        requestScheduler: scheduler,
        taskManager: manager,
        repairService: const FakeRepairService(),
      );
      var mergerCalls = 0;
      final pipeline = ImportPipelineService.forTesting(
        textParser: (
          rawText, {
          required taskId,
          required isMarkdown,
        }) async =>
            fail('text parser must not run'),
        visionParser: (imagePaths) async => fail('vision parser must not run'),
        ocrParser: ocrService.tryParse,
        questionMerger: (fileResults) async {
          mergerCalls++;
          return fileResults.expand((questions) => questions).toList();
        },
        taskManager: manager,
      );
      var taskIndex = 0;
      var traceIndex = 0;
      final coordinator = ImportTaskCoordinator(
        taskManager: manager,
        requestScheduler: scheduler,
        taskIdFactory: () => 'integrated-task-${taskIndex++}',
        traceIdFactory: () => 'integrated-trace-${traceIndex++}',
        batchIdFactory: () => 'integrated-batch',
      );

      final batch = await coordinator.dispatchIndependentBatch(
        items: List<ImportTaskBatchItem>.generate(
          4,
          (index) => ImportTaskBatchItem(
            sourceDescription: 'same.pdf',
            mode: ImportParseMode.ocr,
            parse: (taskId) => pipeline.parseFiles(
              ImportParseRequest(
                filePaths: <String>['synthetic-$index.pdf'],
                fileNames: <String>['synthetic-$index.pdf'],
                mode: ImportParseMode.ocr,
                maxConcurrency: 1,
                taskId: taskId,
              ),
            ),
          ),
        ),
      );

      await Future.wait<void>(<Future<void>>[
        client.waitUntilStarted('synthetic-0.pdf'),
        client.waitUntilStarted('synthetic-1.pdf'),
      ]);
      expect(manager.tasks, hasLength(4));
      expect(client.hasStarted('synthetic-2.pdf'), isFalse);
      expect(client.hasStarted('synthetic-3.pdf'), isFalse);

      client.fail(
        'synthetic-1.pdf',
        StateError('synthetic client failure'),
      );
      await client.waitUntilStarted('synthetic-2.pdf');
      expect(client.hasStarted('synthetic-3.pdf'), isFalse);

      final validDocument = objectiveExplanationDocument(
        explanation: 'Synthetic explanation',
        answer: '答案：A',
      );
      client.complete('synthetic-0.pdf', validDocument);
      await client.waitUntilStarted('synthetic-3.pdf');

      client.complete('synthetic-3.pdf', validDocument);
      await _waitForImportTask(
        manager,
        batch.tasks[3].taskId,
        (task) => task.status == TaskStatus.pendingReview,
      );
      client.complete('synthetic-2.pdf', validDocument);
      for (final handle in batch.tasks) {
        await _waitForImportTask(
          manager,
          handle.taskId,
          (task) => task.status != TaskStatus.processing,
        );
      }

      expect(client.callCount, 4);
      expect(client.maxActiveCount, 2);
      expect(mergerCalls, 0);
      expect(
        manager.tasks.map((task) => task.status),
        <TaskStatus>[
          TaskStatus.pendingReview,
          TaskStatus.error,
          TaskStatus.pendingReview,
          TaskStatus.pendingReview,
        ],
      );
      expect(manager.tasks.map((task) => task.id).toSet(), hasLength(4));
      expect(manager.tasks.map((task) => task.traceId).toSet(), hasLength(4));
      expect(
        manager.tasks.map((task) => task.batchId).toSet(),
        <String?>{'integrated-batch'},
      );
      expect(
        manager.tasks.map((task) => task.selectionIndex),
        <int?>[0, 1, 2, 3],
      );

      final restored = manager.tasks
          .map((task) => ImportTask.fromMap(task.toMap()))
          .toList();
      expect(
        restored.map((task) => task.batchId).toSet(),
        <String?>{'integrated-batch'},
      );
      expect(
        restored.map((task) => task.selectionIndex),
        <int?>[0, 1, 2, 3],
      );

      final projection = TaskCenterProjection.fromTasks(manager.tasks);
      expect(
        projection
            .tasksFor(TaskCenterCategory.pendingReview)
            .map((task) => task.selectionIndex),
        <int?>[0, 2, 3],
      );
      expect(
        projection
            .tasksFor(TaskCenterCategory.error)
            .map((task) => task.selectionIndex),
        <int?>[1],
      );
    });

    test('request exception fails explicitly without Vision fallback',
        () async {
      final profile = AiEngineProfile(
        id: 'ocr-1',
        engineType: AiEngineType.ocr,
        name: 'zhipu-ocr',
        apiKey: 'test-key',
        baseUrl: 'https://open.bigmodel.cn/api/paas',
        modelName: 'glm-ocr',
        temperature: 0.1,
        reasoningEffort: '',
        isActive: true,
      );
      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: ThrowingOcrDocumentClient(),
      );

      final result = await service.tryParse(
        filePath: 'C:\\tmp\\sample.pdf',
        sourceName: 'sample.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      expect(result!.usedOcr, isFalse);
      expect(result.questions, isEmpty);
      expect(result.diagnostics['status'], 'failed_request');
      expect(result.warnings, contains('OCR 请求失败，请检查 OCR 配置或网络后重试。'));
      expect(result.warnings.join(), isNot(contains('视觉')));
    });
  });

  group('OcrImportService shadow typed candidates', () {
    test('a clean single-file parse produces an eligible candidate batch',
        () async {
      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(ocrTestProfile()),
        ocrClient: FakeOcrDocumentClient(
          objectiveExplanationDocument(
            explanation: 'Synthetic explanation',
            answer: '答案：A',
          ),
        ),
        repairService: const FakeRepairService(),
        uuidV4Factory: () => '0d8b7a3e-7f1c-4b2a-9d3e-000000000001',
      );

      final result = await service.tryParse(
        filePath: 'C:\\tmp\\sample.pdf',
        sourceName: 'sample.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      expect(result!.typedCandidateBatch, isNotNull);
      final batch = result.typedCandidateBatch!;
      expect(batch.failure, isNull);
      expect(batch.candidates, hasLength(1));
      final candidate = batch.candidates.single;
      expect(isCanonicalUuidV4(candidate.reviewItemId), isTrue);
      expect(isCanonicalUuidV4(candidate.questionId), isTrue);
      expect(candidate.draft.questionId, candidate.questionId);
      expect(
        isCanonicalUuidV4(candidate.draft.sourceRefs.first.sourceId),
        isTrue,
      );
      expect(candidate.draft.sourceRefs.first.displayLabel, isNull);
      expect(
        jsonEncode(result.diagnostics),
        isNot(contains('_typed_review_v1')),
      );
    });

    test(
        'unsupported structure yields a fixed failure without changing '
        'legacy questions', () async {
      final document = OcrDocument(
        sourceName: 'table-question.pdf',
        markdown: '',
        rawResponses: const [],
        usage: const {},
        pages: [
          OcrPage(
            pageIndex: 1,
            blocks: [
              const OcrBlock(
                blockId: 'section',
                pageIndex: 1,
                type: 'text',
                text: '三、解答题',
                bbox: [],
                readingOrder: 0,
              ),
              const OcrBlock(
                blockId: 'question',
                pageIndex: 1,
                type: 'table',
                text: '1. Synthetic table question',
                bbox: [],
                readingOrder: 1,
              ),
              const OcrBlock(
                blockId: 'answer',
                pageIndex: 1,
                type: 'text',
                text: '答案：A',
                bbox: [],
                readingOrder: 2,
              ),
            ],
          ),
        ],
      );
      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(ocrTestProfile()),
        ocrClient: FakeOcrDocumentClient(document),
        repairService: const FakeRepairService(),
        uuidV4Factory: () => '0d8b7a3e-7f1c-4b2a-9d3e-000000000001',
      );

      final result = await service.tryParse(
        filePath: 'C:\\tmp\\sample.pdf',
        sourceName: 'sample.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      expect(result!.usedOcr, isTrue);
      expect(result.questions, hasLength(1),
          reason: 'legacy assembly is unaffected by candidate failures');
      final batch = result.typedCandidateBatch!;
      expect(batch.candidates, isEmpty);
      expect(
        batch.failure,
        OcrTypedCandidateFailure.unsupportedStructure,
      );
    });

    test('ai_repair_applied fails the whole candidate batch', () async {
      final document = OcrDocument(
        sourceName: 'repair-candidate.pdf',
        markdown: '',
        rawResponses: const [],
        usage: const {},
        pages: [
          OcrPage(
            pageIndex: 1,
            blocks: [
              const OcrBlock(
                blockId: 'section',
                pageIndex: 1,
                type: 'text',
                text: '一、选择题（共 1 题）',
                bbox: [],
                readingOrder: 0,
              ),
              const OcrBlock(
                blockId: 'question',
                pageIndex: 1,
                type: 'text',
                text: '1. Valid stem (A) one (B) two (C) three (D) four',
                bbox: [],
                readingOrder: 1,
              ),
              const OcrBlock(
                blockId: 'answer',
                pageIndex: 1,
                type: 'text',
                text: '答案：',
                bbox: [],
                readingOrder: 2,
              ),
              const OcrBlock(
                blockId: 'explanation',
                pageIndex: 1,
                type: 'text',
                text: '解析：Synthetic explanation',
                bbox: [],
                readingOrder: 3,
              ),
            ],
          ),
        ],
      );
      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(ocrTestProfile()),
        ocrClient: FakeOcrDocumentClient(document),
        repairService: RecordingRepairService(),
        uuidV4Factory: () => '0d8b7a3e-7f1c-4b2a-9d3e-000000000001',
      );

      final result = await service.tryParse(
        filePath: 'C:\\tmp\\sample.pdf',
        sourceName: 'sample.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      expect(result!.usedOcr, isTrue,
          reason: 'candidate failure must not fail legacy OCR import');
      expect(result.questions, hasLength(1));
      final batch = result.typedCandidateBatch!;
      expect(batch.candidates, isEmpty);
      expect(batch.failure, OcrTypedCandidateFailure.repairApplied);
    });

    test(
        'an unexpected candidate error maps to internal_error without '
        'failing legacy import', () async {
      final service = OcrImportService(
        assetStore: MemoryContentAssetStore(),
        engineRepository: FakeAiEngineRepository(ocrTestProfile()),
        ocrClient: FakeOcrDocumentClient(
          objectiveExplanationDocument(
            explanation: 'Synthetic explanation',
            answer: '答案：A',
          ),
        ),
        repairService: const FakeRepairService(),
        uuidV4Factory: () => throw StateError('synthetic uuid failure'),
      );

      final result = await service.tryParse(
        filePath: 'C:\\tmp\\sample.pdf',
        sourceName: 'sample.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      expect(result!.usedOcr, isTrue);
      expect(result.questions, hasLength(1));
      final batch = result.typedCandidateBatch!;
      expect(batch.candidates, isEmpty);
      expect(batch.failure, OcrTypedCandidateFailure.internalError);
    });
  });
}

class ThrowingOcrDocumentClient implements OcrDocumentClient {
  @override
  String get modelId => 'throwing-ocr-model';

  @override
  Future<OcrDocument> parseFile({
    required AiEngineProfile profile,
    required String filePath,
    required String sourceName,
    Duration timeout = const Duration(minutes: 8),
  }) {
    throw Exception('request failed');
  }
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

AiEngineProfile _concurrencyProfile() {
  return const AiEngineProfile(
    id: 'ocr-concurrency',
    engineType: AiEngineType.ocr,
    name: 'synthetic-ocr',
    apiKey: 'test-key',
    baseUrl: 'https://open.bigmodel.cn/api/paas',
    modelName: 'glm-ocr',
    temperature: 0,
    reasoningEffort: '',
    isActive: true,
  );
}

OcrDocument _structuralConcurrencyDocument() {
  return const OcrDocument(
    sourceName: 'first.pdf',
    markdown: '',
    rawResponses: <Map<String, dynamic>>[],
    usage: <String, dynamic>{},
    pages: <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          OcrBlock(
            blockId: 'section',
            pageIndex: 1,
            type: 'text',
            text: '一、选择题（共 1 题）',
            bbox: <double>[],
            readingOrder: 0,
          ),
          OcrBlock(
            blockId: 'question',
            pageIndex: 1,
            type: 'text',
            text: '1. Synthetic stem',
            bbox: <double>[],
            readingOrder: 1,
          ),
          OcrBlock(
            blockId: 'answer',
            pageIndex: 1,
            type: 'text',
            text: '答案：A',
            bbox: <double>[],
            readingOrder: 2,
          ),
        ],
      ),
    ],
  );
}

class ControlledOcrDocumentClient implements OcrDocumentClient {
  final Map<String, Completer<OcrDocument>> _responses =
      <String, Completer<OcrDocument>>{};
  final Map<String, Completer<void>> _starts = <String, Completer<void>>{};

  int callCount = 0;
  int activeCount = 0;
  int maxActiveCount = 0;

  @override
  String get modelId => 'controlled-ocr-model';

  bool hasStarted(String sourceName) =>
      _starts[sourceName]?.isCompleted ?? false;

  Future<void> waitUntilStarted(String sourceName) {
    return _starts.putIfAbsent(sourceName, Completer<void>.new).future;
  }

  void complete(String sourceName, OcrDocument document) {
    _responses[sourceName]!.complete(document);
  }

  void fail(String sourceName, Object error) {
    _responses[sourceName]!.completeError(error);
  }

  @override
  Future<OcrDocument> parseFile({
    required AiEngineProfile profile,
    required String filePath,
    required String sourceName,
    Duration timeout = const Duration(minutes: 8),
  }) async {
    callCount++;
    activeCount++;
    maxActiveCount =
        activeCount > maxActiveCount ? activeCount : maxActiveCount;
    _starts.putIfAbsent(sourceName, Completer<void>.new).complete();
    try {
      return await _responses
          .putIfAbsent(sourceName, Completer<OcrDocument>.new)
          .future;
    } finally {
      activeCount--;
    }
  }
}

class BlockingRepairService extends SingleQuestionRepairService {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<LocalAssemblyResult> repair({
    required TextQuestionRegion region,
    required LocalAssemblyResult localResult,
    required bool requireAnswer,
    required ExplanationRetentionMode explanationRetentionMode,
  }) async {
    if (!started.isCompleted) {
      started.complete();
    }
    await release.future;
    return LocalAssemblyResult(
      question: <String, dynamic>{
        ...localResult.question,
        'content': 'Synthetic repaired stem',
        'options': const <String>['A. First', 'B. Second'],
        'standard_answer': 'A',
      },
      diagnostics: <String>[
        ...localResult.diagnostics,
        'ai_repair_applied',
      ],
      repairRecommended: false,
      rejected: false,
    );
  }
}
