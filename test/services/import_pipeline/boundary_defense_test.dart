import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/docx_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_signals.dart';
import 'package:shiroha_quiz/services/import_pipeline/docx_text_first_parse_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/local_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';
import 'package:shiroha_quiz/services/import_pipeline/single_question_repair_service.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/services/llm_api_client.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_quality_gate.dart';

void main() {
  group('Boundary Defense Tests - LocalQuestionAssembler', () {
    test('1. region 文本包含“答案 B. 分析 ...”时，answer=B，explanation=分析正文。', () {
      const region = TextQuestionRegion(
        number: 1,
        rawText: '''
1. 这是一个单选题
A. 选项 A
B. 选项 B
答案 B. 分析 这里的分析正文非常长。
''',
        startOffset: 0,
        endOffset: 100,
        kind: TextQuestionKind.choice,
        health: RegionHealth.clean,
      );

      final assembler = const LocalQuestionAssembler();
      final result = assembler.assemble(region);

      expect(result.question['standard_answer'], equals('B'));
      expect(result.question['explanation'], equals('这里的分析正文非常长。'));
      expect(result.question['options'], equals(['A. 选项 A', 'B. 选项 B']));
    });

    test('1b. Phase 4 — 紧凑内联“答案+分析”格式：从正文行内提取 answer/explanation', () {
      const region = TextQuestionRegion(
        number: 1,
        rawText:
            '1 设函数 f(x) ... (A) f(1)=0 (B) f(1)=1 答案 B. 分析 本题考查极限。',
        startOffset: 0,
        endOffset: 80,
        kind: TextQuestionKind.choice,
        health: RegionHealth.clean,
      );

      const assembler = LocalQuestionAssembler();
      final result = assembler.assemble(region);

      expect(result.question['standard_answer'], 'B');
      expect(result.question['explanation'], contains('本题考查'));
      expect(result.question['options'], isNotEmpty);
      expect(result.question['type'], 0);
    });

    test('2. region 文本包含”(A)... (B)... (C)... (D)...”时，options 被正确拆出。', () {
      const region = TextQuestionRegion(
        number: 2,
        rawText: '''
2. 另一个选择题
(A) 选项 A 内容 (B) 选项 B 内容 (C) 选项 C 内容 (D) 选项 D 内容
''',
        startOffset: 0,
        endOffset: 100,
        kind: TextQuestionKind.choice,
        health: RegionHealth.clean,
      );

      final assembler = const LocalQuestionAssembler();
      final result = assembler.assemble(region);

      expect(result.question['options'], equals([
        'A. 选项 A 内容',
        'B. 选项 B 内容',
        'C. 选项 C 内容',
        'D. 选项 D 内容',
      ]));
    });

    test('3. 选择题被识别为选择题，不得默认为简答题。', () {
      // 哪怕解析出错导致没有提取到 options，由于 kind 是 choice，依然必须被识别为选择题（type = 0）
      const region = TextQuestionRegion(
        number: 3,
        rawText: '''
3. 这个选择题格式非常奇怪，导致无法切出 options。
但它依然是选择题。
''',
        startOffset: 0,
        endOffset: 100,
        kind: TextQuestionKind.choice,
        health: RegionHealth.clean,
      );

      final assembler = const LocalQuestionAssembler();
      final result = assembler.assemble(region);

      expect(result.question['type'], equals(0)); // 0 代表选择题，3 代表简答题
    });
  });

  group('Boundary Defense Tests - DocxDocumentAdapter', () {
    late Directory tempDir;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('boundary_test');
    });

    tearDownAll(() async {
      await tempDir.delete(recursive: true);
    });

    File createMockDocx(String name, String documentXml) {
      final archive = Archive();
      final docBytes = utf8.encode(documentXml);
      archive.addFile(ArchiveFile('word/document.xml', docBytes.length, docBytes));

      final encoder = ZipEncoder();
      final zipBytes = encoder.encode(archive)!;

      final file = File('${tempDir.path}/$name');
      file.writeAsBytesSync(zipBytes);
      return file;
    }

    test('4. DOCX rawText 中公式节点缺失时，至少输出 [FORMULA] 占位，不得静默吞掉。', () async {
      // 公式节点存在但内部文字节点缺失/为空
      final xml = '''
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math">
          <w:body>
            <w:p>
              <w:r><w:t>请计算公式：</w:t></w:r>
              <m:oMath>
                <m:r><m:t></m:t></m:r>
              </m:oMath>
              <w:r><w:t> 的结果。</w:t></w:r>
            </w:p>
          </w:body>
        </w:document>
      ''';

      final file = createMockDocx('test_empty_formula.docx', xml);

      final parsed = await DocxDocumentAdapter.parse(
        filePath: file.path,
        sourceName: 'test_empty_formula.docx',
      );

      expect(parsed.fallbackUsed, false);
      final plainText = parsed.toPlainTextForParsing();
      expect(plainText, contains('[FORMULA]'));
      expect(plainText, contains('请计算公式： [FORMULA]  的结果。'));
    });
  });

  group('Boundary Defense Tests - DocxTextFirstParseService', () {
    test('5. expected=21 actual=7 时，blocked=true，UI 禁止入库。', () async {
      // 构造 7 道合法的选择题文本
      const rawText = '''
1. 题干
A. 选项A
B. 选项B
2. 题干
A. 选项A
B. 选项B
3. 题干
A. 选项A
B. 选项B
4. 题干
A. 选项A
B. 选项B
5. 题干
A. 选项A
B. 选项B
6. 题干
A. 选项A
B. 选项B
7. 题干
A. 选项A
B. 选项B
''';

      final parseService = DocxTextFirstParseService();
      final result = await parseService.parseDocxText(
        rawText: rawText,
        sourceName: 'test',
        documentSignals: const DocumentSignals(questionMarkerCount: 21),
      );

      expect(result.blocked, isTrue);
      expect(result.warnings.any((w) => w.contains('解析完整率过低')), isTrue);
      expect(result.questions.length, equals(7));
    });
  });

  group('Boundary Defense Tests - SingleQuestionRepairService', () {
    const profile = AiEngineProfile(
      id: 'test',
      engineType: AiEngineType.text,
      name: 'test',
      apiKey: 'key',
      baseUrl: 'url',
      modelName: 'model',
      temperature: 0.0,
      reasoningEffort: '',
      isActive: true,
    );

    test('6. 成功修复：AI返回符合规范的JSON对象时，合并应用修复', () async {
      final mockClient = MockLlmApiClient('''
      {
        "question_number": 5,
        "type": 0,
        "content": "被修复后的题干",
        "options": ["A. 新选项A", "B. 新选项B"],
        "standard_answer": "A",
        "explanation": "被修复后的解析"
      }
      ''');
      final mockRepo = MockAiEngineRepository(profile);
      final repairService = SingleQuestionRepairService(
        apiClient: mockClient,
        engineRepository: mockRepo,
      );

      const region = TextQuestionRegion(
        number: 5,
        rawText: '5. 原始破损题干...',
        startOffset: 0,
        endOffset: 50,
        kind: TextQuestionKind.choice,
        health: RegionHealth.repairable,
      );

      final localResult = const LocalQuestionAssembler().assemble(region);

      final result = await repairService.repair(
        region: region,
        localResult: localResult,
      );

      expect(result.question['content'], equals('被修复后的题干'));
      expect(result.question['options'], equals(['A. 新选项A', 'B. 新选项B']));
      expect(result.question['standard_answer'], equals('A'));
      expect(result.question['explanation'], equals('被修复后的解析'));
      expect(result.diagnostics, contains('ai_repair_applied'));
    });

    test('7. 题号变更拒绝：AI改变题号时，拒绝合并修复，追加错误诊断', () async {
      final mockClient = MockLlmApiClient('''
      {
        "question_number": 6,
        "type": 0,
        "content": "被修复后的题干",
        "options": ["A. 新选项A", "B. 新选项B"],
        "standard_answer": "A",
        "explanation": "被修复后的解析"
      }
      ''');
      final mockRepo = MockAiEngineRepository(profile);
      final repairService = SingleQuestionRepairService(
        apiClient: mockClient,
        engineRepository: mockRepo,
      );

      const region = TextQuestionRegion(
        number: 5,
        rawText: '5. 原始破损题干...',
        startOffset: 0,
        endOffset: 50,
        kind: TextQuestionKind.choice,
        health: RegionHealth.repairable,
      );

      final localResult = const LocalQuestionAssembler().assemble(region);

      final result = await repairService.repair(
        region: region,
        localResult: localResult,
      );

      expect(result.diagnostics, contains('repair_rejected_question_number_changed'));
      expect(result.question['content'], equals('原始破损题干...')); // 保留原本内容
    });

    test('8. AI返回数组拒绝：AI返回JSON数组而非单个对象时，报错并保留本地结果', () async {
      final mockClient = MockLlmApiClient('''
      [
        {
          "question_number": 5,
          "content": "被修复后的题干"
        }
      ]
      ''');
      final mockRepo = MockAiEngineRepository(profile);
      final repairService = SingleQuestionRepairService(
        apiClient: mockClient,
        engineRepository: mockRepo,
      );

      const region = TextQuestionRegion(
        number: 5,
        rawText: '5. 原始破损题干...',
        startOffset: 0,
        endOffset: 50,
        kind: TextQuestionKind.choice,
        health: RegionHealth.repairable,
      );

      final localResult = const LocalQuestionAssembler().assemble(region);

      final result = await repairService.repair(
        region: region,
        localResult: localResult,
      );

      expect(result.diagnostics.any((d) => d.contains('repair_failed')), isTrue);
    });
  });

  group('Boundary Defense Tests - ImportQualityGate', () {
    test('9. expectedCount 应计算多个信号（regionCount, maxDetected, answerCount, markerCount）的最大值', () {
      const gate = ImportQualityGate();
      const input = ImportQualityGateInput(
        regionCount: 8,
        actualQuestionCount: 8,
        maxQuestionNumberDetected: 12,
        answerCount: 15,
        documentSignals: DocumentSignals(questionMarkerCount: 20),
        criticalDiagnostics: [],
      );

      final result = gate.evaluateDocx(input);
      expect(result.expectedCount, equals(20)); // 应是 8, 12, 15, 20 的最大值即 20
      expect(result.blocked, isTrue); // expectedCount 为 20 且 actualQuestionCount 为 8（小于 20 * 0.8 = 16），判定为 blocked
      expect(result.severity, equals('critical_under_parse'));
    });

    test('10. regionCount = 0 时判定为 regionizer_empty 且 blocked = true', () {
      const gate = ImportQualityGate();
      const input = ImportQualityGateInput(
        regionCount: 0,
        actualQuestionCount: 0,
        maxQuestionNumberDetected: 0,
        answerCount: 0,
        documentSignals: DocumentSignals(questionMarkerCount: 0),
        criticalDiagnostics: [],
      );

      final result = gate.evaluateDocx(input);
      expect(result.blocked, isTrue);
      expect(result.severity, equals('regionizer_empty'));
      expect(result.diagnostics['policy'], equals('no_full_text_ai_fallback_for_docx'));
    });

    test('11. criticalDiagnostics 不为空时判定为 critical_diagnostics 且 blocked = true', () {
      const gate = ImportQualityGate();
      const input = ImportQualityGateInput(
        regionCount: 5,
        actualQuestionCount: 5,
        maxQuestionNumberDetected: 5,
        answerCount: 5,
        documentSignals: DocumentSignals(questionMarkerCount: 5),
        criticalDiagnostics: ['Dangling formula detected'],
      );

      final result = gate.evaluateDocx(input);
      expect(result.blocked, isTrue);
      expect(result.severity, equals('critical_diagnostics'));
      expect(result.diagnostics['criticalDiagnostics'], contains('Dangling formula detected'));
    });

    test('12. Phase 6 — regionCount=7 / maxDetected=21 / actual=7 触发 critical_under_parse', () {
      const gate = ImportQualityGate();

      final result = gate.evaluateDocx(
        const ImportQualityGateInput(
          regionCount: 7,
          actualQuestionCount: 7,
          maxQuestionNumberDetected: 21,
          answerCount: 21,
          documentSignals: null,
          criticalDiagnostics: [],
        ),
      );

      expect(result.blocked, true);
      expect(result.severity, 'critical_under_parse');
    });
  });
}

class MockLlmApiClient extends LlmApiClient {
  final String responseText;
  MockLlmApiClient(this.responseText);

  @override
  Future<String> callText({
    required AiEngineProfile profile,
    required String prompt,
    String? systemPrompt,
    double? temperature,
    String? reasoningEffort,
    int maxTokens = 8192,
    bool jsonResponse = false,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    return responseText;
  }
}

class MockAiEngineRepository extends AiEngineRepository {
  final AiEngineProfile? profile;
  MockAiEngineRepository(this.profile);

  @override
  Future<AiEngineProfile?> getActiveTextEngine() async {
    return profile;
  }
}
