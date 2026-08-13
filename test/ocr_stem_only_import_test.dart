import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_document_role.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_format.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/local_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_import_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/single_question_repair_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';
import 'package:shiroha_quiz/services/import_pipeline/vision_question_quality_gate.dart';
import 'package:shiroha_quiz/services/llm_providers/zhipu_ocr_client.dart';

import 'support/unsupported_ai_engine_store.dart';

class _EngineRepository extends AiEngineRepository {
  _EngineRepository()
      : super(
          store: const UnsupportedAiEngineStore(),
          credentialStore: const UnsupportedEngineCredentialStore(),
        );

  @override
  Future<AiEngineProfile?> getActiveOcrEngine() async => const AiEngineProfile(
        id: 'ocr-stem-only-test',
        engineType: AiEngineType.ocr,
        name: 'zhipu-ocr',
        apiKey: 'test-key',
        baseUrl: 'https://open.bigmodel.cn/api/paas',
        modelName: 'glm-ocr',
        temperature: 0,
        reasoningEffort: '',
        isActive: true,
      );
}

class _CountingOcrClient extends ZhipuOcrClient {
  _CountingOcrClient(this.document);

  final OcrDocument document;
  int callCount = 0;

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

class _StubAssembler extends OcrQuestionAssembler {
  const _StubAssembler(this.builder);

  final LocalAssemblyResult Function(OcrQuestionRegion region) builder;

  @override
  LocalAssemblyResult assemble(OcrQuestionRegion region) => builder(region);
}

class _RecordingRepairService extends SingleQuestionRepairService {
  _RecordingRepairService({this.answer = '', this.explanation = ''});

  final String answer;
  final String explanation;
  int callCount = 0;

  @override
  Future<LocalAssemblyResult> repair({
    required TextQuestionRegion region,
    required LocalAssemblyResult localResult,
    required bool requireAnswer,
    required ExplanationRetentionMode explanationRetentionMode,
  }) async {
    callCount++;
    final question = Map<String, dynamic>.from(localResult.question)
      ..['standard_answer'] = answer
      ..['explanation'] = explanation
      ..['raw_explanation'] = explanation.isEmpty ? null : explanation;
    return LocalAssemblyResult(
      question: question,
      diagnostics: [...localResult.diagnostics, 'ai_repair_applied'],
      repairRecommended: false,
      rejected: false,
    );
  }
}

OcrDocument _document({
  int questionCount = 23,
  List<String> trailingBlocks = const [],
}) {
  final blocks = <OcrBlock>[];
  var order = 0;
  for (var number = 1; number <= questionCount; number++) {
    blocks.add(
      OcrBlock(
        blockId: 'q$number',
        pageIndex: 1,
        type: 'text',
        text: '$number. PRIVATE_STEM_$number',
        bbox: const [],
        readingOrder: order++,
      ),
    );
  }
  for (final text in trailingBlocks) {
    blocks.add(
      OcrBlock(
        blockId: 'tail_$order',
        pageIndex: 1,
        type: 'text',
        text: text,
        bbox: const [],
        readingOrder: order++,
      ),
    );
  }
  return OcrDocument(
    sourceName: 'safe.pdf',
    markdown: '',
    rawResponses: const [],
    usage: const {},
    pages: [OcrPage(pageIndex: 1, blocks: blocks)],
  );
}

LocalAssemblyResult _assembly(
  OcrQuestionRegion region, {
  String answer = '',
  String explanation = '',
  bool repairRecommended = false,
  bool structurallyBroken = false,
}) {
  final diagnostics = <String>[
    if (answer.isEmpty) 'missing_answer',
    if (structurallyBroken) 'choice_options_less_than_2',
  ];
  return LocalAssemblyResult(
    question: {
      'question_number': region.number,
      'type': 0,
      'content': 'PRIVATE_STEM_${region.number}',
      'options': structurallyBroken
          ? <String>['A. one']
          : <String>['A. one', 'B. two', 'C. three', 'D. four'],
      'standard_answer': answer,
      'explanation': explanation,
      'raw_explanation': explanation.isEmpty ? null : explanation,
      'diagnostics': diagnostics,
    },
    diagnostics: diagnostics,
    repairRecommended: repairRecommended,
    rejected: false,
  );
}

OcrImportService _service({
  required OcrDocument document,
  required OcrQuestionAssembler assembler,
  required SingleQuestionRepairService repairService,
  _CountingOcrClient? client,
}) {
  return OcrImportService(
    engineRepository: _EngineRepository(),
    ocrClient: client ?? _CountingOcrClient(document),
    assembler: assembler,
    repairService: repairService,
  );
}

void main() {
  group('OCR stemOnly document role', () {
    test('keeps 23 stems while clearing assembler answer pollution', () async {
      final document = _document();
      final client = _CountingOcrClient(document);
      final repair = _RecordingRepairService();
      final service = _service(
        document: document,
        client: client,
        repairService: repair,
        assembler: _StubAssembler(
          (region) => _assembly(
            region,
            answer: region.number == 7 ? 'PRIVATE_ANSWER' : '',
          ),
        ),
      );

      final result = await service.tryParse(
        filePath: r'C:\private\PRIVATE_PATH.pdf',
        sourceName: 'safe.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result, isNotNull);
      expect(result!.questions, hasLength(23));
      expect(result.diagnostics['documentRole'], 'stemOnly');
      expect(result.diagnostics['documentRoleConfidence'], greaterThan(0));
      expect(result.diagnostics['explicitAnswerMarkerCount'], 0);
      expect(result.diagnostics['explicitExplanationMarkerCount'], 0);
      expect(result.diagnostics['clearedAssemblerAnswerCount'], 1);
      expect(result.diagnostics['finalQuestionCount'], 23);
      expect(result.diagnostics['finalNonEmptyAnswerCount'], 0);
      expect(result.diagnostics['finalNonEmptyExplanationCount'], 0);
      expect(
        result.questions.every(
          (question) =>
              question['standard_answer'] == '' &&
              question['explanation'] == '' &&
              question['raw_explanation'] == null,
        ),
        isTrue,
      );
      expect(client.callCount, 1);
      expect(repair.callCount, 0);

      final safeDiagnostics = jsonEncode(result.diagnostics);
      expect(safeDiagnostics, isNot(contains('PRIVATE_STEM')));
      expect(safeDiagnostics, isNot(contains('PRIVATE_ANSWER')));
      expect(safeDiagnostics, isNot(contains('PRIVATE_PATH')));
      expect(safeDiagnostics, isNot(contains('data:image')));
    });

    test('skips answer-only repair for a stemOnly choice question', () async {
      final document = _document(questionCount: 1);
      final repair = _RecordingRepairService(answer: 'PRIVATE_AI_ANSWER');
      final service = _service(
        document: document,
        repairService: repair,
        assembler: _StubAssembler(
          (region) => _assembly(region, repairRecommended: true),
        ),
      );

      final result = await service.tryParse(
        filePath: 'safe.pdf',
        sourceName: 'safe.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result!.diagnostics['documentRole'], 'stemOnly');
      expect(repair.callCount, 0);
      expect(result.diagnostics['repairAttemptCount'], 0);
      expect(result.diagnostics['repairSkippedForStemOnlyCount'], 1);
      expect(result.questions.single['standard_answer'], '');
    });

    test('discards answer returned by structural repair for stemOnly',
        () async {
      final document = _document(questionCount: 1);
      final repair = _RecordingRepairService(
        answer: 'PRIVATE_AI_ANSWER',
        explanation: 'PRIVATE_AI_EXPLANATION',
      );
      final service = _service(
        document: document,
        repairService: repair,
        assembler: _StubAssembler(
          (region) => _assembly(
            region,
            repairRecommended: true,
            structurallyBroken: true,
          ),
        ),
      );

      final result = await service.tryParse(
        filePath: 'safe.pdf',
        sourceName: 'safe.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(repair.callCount, 1);
      expect(result!.diagnostics['repairAttemptCount'], 1);
      expect(result.diagnostics['discardedAnswerFromRepairCount'], 1);
      expect(result.questions.single['standard_answer'], '');
      expect(result.questions.single['explanation'], '');
      expect(result.questions.single['raw_explanation'], isNull);
    });

    test('preserves answer-bearing content with explicit field markers',
        () async {
      final document = _document(
        questionCount: 1,
        trailingBlocks: const ['【答案】A', '【解】脱敏说明'],
      );
      final service = _service(
        document: document,
        repairService: _RecordingRepairService(),
        assembler: _StubAssembler(
          (region) => _assembly(
            region,
            answer: 'A',
            explanation: '脱敏说明',
          ),
        ),
      );

      final result = await service.tryParse(
        filePath: 'safe.pdf',
        sourceName: 'safe.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
      );

      expect(result!.diagnostics['documentRole'], 'answerBearing');
      expect(result.diagnostics['explicitAnswerMarkerCount'], 1);
      expect(result.diagnostics['explicitExplanationMarkerCount'], 1);
      expect(result.questions.single['standard_answer'], 'A');
      expect(result.questions.single['explanation'], '脱敏说明');
      expect(result.diagnostics['requiresReview'], isFalse);
    });

    test('marks contradictory unlabeled answer coverage as ambiguous',
        () async {
      final document = _document();
      final service = _service(
        document: document,
        repairService: _RecordingRepairService(),
        assembler: _StubAssembler(
          (region) => _assembly(
            region,
            answer: region.number <= 10 ? 'A' : '',
          ),
        ),
      );

      final result = await service.tryParse(
        filePath: 'safe.pdf',
        sourceName: 'safe.pdf',
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result!.diagnostics['documentRole'], 'ambiguous');
      expect(result.diagnostics['requiresReview'], isTrue);
      expect(result.questions.where((q) => q['standard_answer'] == 'A'),
          hasLength(10));
      expect(result.warnings, contains('文档答案结构不明确，请人工复核。'));
    });
  });

  group('stemOnly quality semantics', () {
    List<Map<String, dynamic>> emptyAnswerQuestions(int count) => List.generate(
          count,
          (index) => <String, dynamic>{
            'q_num': '${index + 1}',
            'type': 3,
            'content': 'PRIVATE_STEM_${index + 1}',
            'options': <String>[],
            'standard_answer': '',
            'explanation': '',
            'source': 'glm_ocr_intermediate',
          },
        );

    test('does not treat missing answers as a stemOnly quality risk', () {
      final result = const VisionQuestionQualityGate().evaluate(
        emptyAnswerQuestions(23),
        sourceName: 'glm_ocr_intermediate',
        documentRole: ImportDocumentRole.stemOnly,
      );

      final issues = result.diagnostics['issueCounts'] as Map?;
      expect(issues?['missing_answer_or_explanation'], isNull);
      expect(result.diagnostics['lowQuality'], isFalse);
      expect(result.diagnostics['blocked'], isFalse);
      expect(result.diagnostics['requiresReview'], isFalse);
      expect(
        result.questions.every((question) {
          final review = question[VisionQuestionQualityGate.importReviewKey];
          final hints = review is Map ? review['riskHints'] as List : const [];
          return !hints.contains('missing_answer_or_explanation');
        }),
        isTrue,
      );
    });

    test('keeps answer-bearing missing-answer checks and flags ambiguous role',
        () {
      final answerBearing = const VisionQuestionQualityGate().evaluate(
        [emptyAnswerQuestions(1).single],
        sourceName: 'glm_ocr_intermediate',
        documentRole: ImportDocumentRole.answerBearing,
      );
      final answerIssues = answerBearing.diagnostics['issueCounts'] as Map;
      expect(answerIssues['missing_answer_or_explanation'], 1);

      final ambiguous = const VisionQuestionQualityGate().evaluate(
        [emptyAnswerQuestions(1).single],
        sourceName: 'glm_ocr_intermediate',
        documentRole: ImportDocumentRole.ambiguous,
      );
      expect(ambiguous.diagnostics['requiresReview'], isTrue);
    });

    test('OCR Pipeline passes stemOnly role without invoking Vision', () async {
      var ocrCalls = 0;
      var visionCalls = 0;
      final pipeline = ImportPipelineService.forTesting(
        textParser: (rawText, {required taskId, required isMarkdown}) async =>
            fail('text parser must not run'),
        visionParser: (paths) async {
          visionCalls++;
          return const [];
        },
        ocrParser: ({
          required filePath,
          required sourceName,
          required ImportFormat format,
          required ExplanationRetentionMode explanationRetentionMode,
        }) async {
          ocrCalls++;
          return OcrImportResult(
            usedOcr: true,
            questions: emptyAnswerQuestions(1),
            warnings: const [],
            diagnostics: const {
              'status': 'used_ocr',
              'documentRole': 'stemOnly',
              'requiresReview': false,
            },
          );
        },
      );

      final result = await pipeline.parseFiles(
        const ImportParseRequest(
          filePaths: ['safe.png'],
          fileNames: ['safe.png'],
          mode: ImportParseMode.ocr,
          maxConcurrency: 1,
          taskId: 'stem-only-pipeline-test',
        ),
      );

      expect(result.questions, hasLength(1));
      expect(ocrCalls, 1);
      expect(visionCalls, 0);
      final gate = result.diagnostics['ocr_quality_gate_file_0'] as Map;
      final issues = gate['issueCounts'] as Map?;
      expect(issues?['missing_answer_or_explanation'], isNull);
      expect(gate['lowQuality'], isFalse);
      expect(gate['blocked'], isFalse);
      expect(result.blocked, isFalse);
    });
  });
}
