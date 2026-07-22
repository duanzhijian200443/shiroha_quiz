import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/services/import_pipeline/local_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/single_question_repair_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_import_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_format.dart';
import 'package:shiroha_quiz/services/llm_providers/zhipu_ocr_client.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';

class FakeAiEngineRepository extends AiEngineRepository {
  FakeAiEngineRepository(this.profile) : super();

  final AiEngineProfile? profile;

  @override
  Future<AiEngineProfile?> getActiveOcrEngine() async => profile;
}

class FakeZhipuOcrClient extends ZhipuOcrClient {
  FakeZhipuOcrClient(this.document);

  final OcrDocument document;

  @override
  Future<OcrDocument> parseFile({
    required AiEngineProfile profile,
    required String filePath,
    required String sourceName,
    Duration timeout = const Duration(minutes: 8),
  }) async {
    return document;
  }
}

class FakeRepairService extends SingleQuestionRepairService {
  const FakeRepairService();

  @override
  Future<LocalAssemblyResult> repair({
    required TextQuestionRegion region,
    required LocalAssemblyResult localResult,
  }) async {
    return localResult;
  }
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
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: FakeZhipuOcrClient(document),
        repairService: const FakeRepairService(),
      );

      final result = await service.tryParse(
        filePath: 'C:\\tmp\\sample.pdf',
        sourceName: 'sample.pdf',
        format: ImportFormat.pdf,
      );

      expect(result, isNotNull);
      expect(result!.usedOcr, isTrue);
      expect(result.questions, hasLength(1));
      expect(result.questions.first['q_num'], '1');
      expect(result.questions.first['source'], 'glm_ocr_intermediate');
      expect(result.diagnostics['status'], 'used_ocr');
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
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: FakeZhipuOcrClient(document),
        repairService: const FakeRepairService(),
      );

      final result = await service.tryParse(
        filePath: 'C:\\tmp\\regionizer-regression.pdf',
        sourceName: 'regionizer-regression.pdf',
        format: ImportFormat.pdf,
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
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: FakeZhipuOcrClient(
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
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: FakeZhipuOcrClient(
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
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: FakeZhipuOcrClient(document),
        repairService: const FakeRepairService(),
      );

      final result = await service.tryParse(
        filePath: 'C:\\tmp\\no-question-number.pdf',
        sourceName: 'no-question-number.pdf',
        format: ImportFormat.pdf,
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
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: FakeZhipuOcrClient(document),
        repairService: const FakeRepairService(),
      );

      final result = await service.tryParse(
        filePath: 'C:\\tmp\\empty.pdf',
        sourceName: 'empty.pdf',
        format: ImportFormat.pdf,
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
        engineRepository: FakeAiEngineRepository(null),
      );

      final result = await service.tryParse(
        filePath: 'C:\\tmp\\sample.pdf',
        sourceName: 'sample.pdf',
        format: ImportFormat.pdf,
      );

      expect(result, isNotNull);
      expect(result!.usedOcr, isFalse);
      expect(result.questions, isEmpty);
      expect(result.diagnostics['status'], 'failed_not_configured');
      expect(result.warnings, contains('未配置可用的智谱 OCR 引擎，请先完成 OCR 配置。'));
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
        engineRepository: FakeAiEngineRepository(profile),
        ocrClient: ThrowingZhipuOcrClient(),
      );

      final result = await service.tryParse(
        filePath: 'C:\\tmp\\sample.pdf',
        sourceName: 'sample.pdf',
        format: ImportFormat.pdf,
      );

      expect(result, isNotNull);
      expect(result!.usedOcr, isFalse);
      expect(result.questions, isEmpty);
      expect(result.diagnostics['status'], 'failed_request');
      expect(result.warnings, contains('OCR 请求失败，请检查 OCR 配置或网络后重试。'));
      expect(result.warnings.join(), isNot(contains('视觉')));
    });
  });
}

class ThrowingZhipuOcrClient extends ZhipuOcrClient {
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
