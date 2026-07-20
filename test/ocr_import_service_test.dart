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
