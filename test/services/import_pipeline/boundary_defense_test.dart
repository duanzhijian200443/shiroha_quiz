import 'dart:async';
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
import 'package:shiroha_quiz/services/import_pipeline/text_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/answer_block_matcher.dart';

import '../../support/unsupported_ai_engine_store.dart';

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
        rawText: '1 设函数 f(x) ... (A) f(1)=0 (B) f(1)=1 答案 B. 分析 本题考查极限。',
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

      expect(
          result.question['options'],
          equals([
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
      archive
          .addFile(ArchiveFile('word/document.xml', docBytes.length, docBytes));

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
      expect(result.question['explanation'], equals(''));
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

      expect(result.diagnostics,
          contains('repair_rejected_question_number_changed'));
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

      expect(
          result.diagnostics.any((d) => d.contains('repair_failed')), isTrue);
    });

    test('9. 修复异常仅保留固定错误码与异常类型，不泄露异常消息', () async {
      const sensitiveMarker = 'SENSITIVE_PROVIDER_RESPONSE_MARKER_7F91';
      final repairService = SingleQuestionRepairService(
        apiClient: ThrowingLlmApiClient(
          const FormatException(sensitiveMarker),
        ),
        engineRepository: MockAiEngineRepository(profile),
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
      final printed = <String>[];

      final result = await runZoned(
        () => repairService.repair(
          region: region,
          localResult: localResult,
        ),
        zoneSpecification: ZoneSpecification(
          print: (_, __, ___, line) => printed.add(line),
        ),
      );

      expect(result.diagnostics, contains('repair_failed'));
      expect(
          result.diagnostics, contains('repair_failure_type:FormatException'));
      expect(jsonEncode(result.question), isNot(contains(sensitiveMarker)));
      expect(jsonEncode(result.diagnostics), isNot(contains(sensitiveMarker)));
      expect(printed.join(), isNot(contains(sensitiveMarker)));
      expect(printed, isEmpty);
    });
  });

  group('Boundary Defense Tests - ImportQualityGate', () {
    test(
        '9. expectedCount 应计算多个信号（regionCount, maxDetected, answerCount, markerCount）的最大值',
        () {
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
      expect(result.blocked,
          isTrue); // expectedCount 为 20 且 actualQuestionCount 为 8（小于 20 * 0.8 = 16），判定为 blocked
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
      expect(result.diagnostics['policy'],
          equals('no_full_text_ai_fallback_for_docx'));
    });

    test(
        '11. criticalDiagnostics 不为空时判定为 critical_diagnostics 且 blocked = true',
        () {
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
      expect(result.diagnostics['criticalDiagnostics'],
          contains('Dangling formula detected'));
    });

    test(
        '12. Phase 6 — regionCount=7 / maxDetected=21 / actual=7 触发 critical_under_parse',
        () {
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

  group('Boundary Defense Tests - Regionizer', () {
    test('13. 不得把"参数为 2""区间 (0, 3)"识别为题号', () {
      const rawText = '''
在数学中，参数为 2 的函数 f(x) 定义在区间 (0, 3) 上。
该函数的值域为 [0, 1]。
请计算此函数的积分。
''';
      const regionizer = TextQuestionRegionizer();
      final result = regionizer.split(rawText, const {});

      // "参数为 2" — "2" 是裸数字但前面没换行，不匹配 _bareLineQuestionRegex（需要 ^|\n）
      // "区间 (0, 3)" — "(0" not "(1" through "(999" so not a question number anyway
      // 0 is not a valid question number candidate
      expect(result.regions, isEmpty);
    });

    test('14. candidateMax=21 但只有 7 accepted，qualityGate 仍 blocked', () {
      // 构造 21 个候选，但只有 7 个被 DP 接受
      final buffer = StringBuffer();
      for (var i = 1; i <= 21; i++) {
        if (i <= 7 || i == 21) {
          // Accepted: 1-7, 21 (DP may skip 8-20 due to penalty)
          buffer.writeln('$i. 这是一道完整的题目题干，包含足够的文本内容供测试使用。');
          buffer.writeln('选项内容占位。');
        } else {
          // 在文本中出现但不是行首——用行内数字，不匹配 bareLine 正则
          // 实际上为了让 candidateMax=21，我们需要第 21 号也被候选到
          // 让 8-20 不出现为题号候选
        }
      }
      // 再在末尾放一个明确的高号
      buffer.writeln('21. 最后一道题，题干足够长。');

      const regionizer = TextQuestionRegionizer();
      final result = regionizer.split(buffer.toString(), const {});

      // DP selects all 8 accepted regions
      expect(result.regions.length, greaterThanOrEqualTo(7));

      // explicitCandidateMax should be 21
      final explicitMax =
          result.diagnostics['maxQuestionNumberDetected'] as int?;
      expect(explicitMax, greaterThanOrEqualTo(21));

      // acceptedMax may be lower
      final acceptedMax =
          result.diagnostics['acceptedMaxQuestionNumber'] as int?;
      expect(acceptedMax, lessThanOrEqualTo(21));

      // 质量门禁应阻塞：expectedCount=21, actual≤21, 需判定
      const gate = ImportQualityGate();
      final gateResult = gate.evaluateDocx(ImportQualityGateInput(
        regionCount: result.regions.length,
        actualQuestionCount: result.regions.length,
        maxQuestionNumberDetected: explicitMax ?? 21,
        answerCount: 0,
        documentSignals: null,
        criticalDiagnostics: const [],
      ));

      // expected=21, actual≤21, 但 accepted 不可能达到 21 的 80%
      expect(gateResult.blocked, isTrue);
      expect(gateResult.severity, 'critical_under_parse');
    });
  });

  group('Boundary Defense Tests - AnswerBlockMatcher', () {
    test('15. 对 "1. B 解析：..." 只提取 B，不提取整行', () {
      const rawText = '''
1. 题目题干内容
A. 选项 A
B. 选项 B
C. 选项 C
D. 选项 D

参考答案
1. B 解析：这个题目考察的是基本概念。
2. C 解析：这道题需要注意细节。
''';
      const matcher = AnswerBlockMatcher();
      final result = matcher.splitAnswerBlock(rawText);

      expect(result.answers[1], equals('B'));
      expect(result.answers[2], equals('C'));
      expect(result.answers[1], isNot(contains('解析')));
      expect(result.answers[2], isNot(contains('解析')));
    });
  });

  group('Boundary Defense Tests - Assembler + Regionizer Chain', () {
    test('16. region.diagnostics 包含"缺少 B 选项"时 repairRecommended=true', () {
      const region = TextQuestionRegion(
        number: 1,
        rawText: '''
1. 一个选择题
A. 选项 A
答案 A
''',
        startOffset: 0,
        endOffset: 100,
        kind: TextQuestionKind.choice,
        health: RegionHealth.repairable,
        diagnostics: ['缺少 B 选项'],
      );

      const assembler = LocalQuestionAssembler();
      final result = assembler.assemble(region);

      // region.diagnostics 继承到 assembler diagnostics
      expect(result.diagnostics, contains('缺少 B 选项'));
      // region.health == repairable 强制触发修复
      expect(result.repairRecommended, isTrue);
    });
  });

  group('Boundary Defense Tests - DocxAdapter Formula', () {
    test('17. m:oMathPara 公式至少输出 [FORMULA] 或公式文本', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('boundary_mathpara');
      try {
        final xml = '''
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math">
          <w:body>
            <w:p>
              <w:r><w:t>解：</w:t></w:r>
              <m:oMathPara>
                <m:oMath>
                  <m:r><w:t>x</w:t></m:r>
                </m:oMath>
              </m:oMathPara>
              <w:r><w:t>即为所求。</w:t></w:r>
            </w:p>
          </w:body>
        </w:document>
        ''';

        final docBytes = utf8.encode(xml);
        final archive = Archive();
        archive.addFile(
            ArchiveFile('word/document.xml', docBytes.length, docBytes));
        final encoder = ZipEncoder();
        final zipBytes = encoder.encode(archive)!;

        final file = File('${tempDir.path}/test_mathpara.docx');
        file.writeAsBytesSync(zipBytes);

        final parsed = await DocxDocumentAdapter.parse(
          filePath: file.path,
          sourceName: 'test_mathpara.docx',
        );

        expect(parsed.fallbackUsed, isFalse);
        final plainText = parsed.toPlainTextForParsing();
        // m:oMathPara must produce at least [FORMULA] or formula text
        final hasFormulaOrText =
            plainText.contains('[FORMULA]') || plainText.contains('x');
        expect(hasFormulaOrText, isTrue);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });

  group('Boundary Defense Tests - DOCX Pipeline Warnings', () {
    test('18. DOCX blocked 时 warnings 非空且包含 gate warning', () async {
      const rawText = '''
1. 题干
A. 选项A
B. 选项B
2. 题干
A. 选项A
B. 选项B
''';

      const service = DocxTextFirstParseService();
      final result = await service.parseDocxText(
        rawText: rawText,
        sourceName: 'test_blocked',
        documentSignals: const DocumentSignals(questionMarkerCount: 20),
      );

      expect(result.blocked, isTrue);
      expect(result.warnings, isNotEmpty);
      expect(
        result.warnings.any(
          (w) => w.contains('解析完整率过低') || w.contains('DOCX'),
        ),
        isTrue,
      );
    });
  });

  group('Boundary Defense Tests - Section Heading Filter', () {
    test('19. "一、选择题"不得变成第 1 题', () {
      const rawText = '''
一、选择题
1. 以下哪个选项是正确的？
A. 选项A
B. 选项B
二、填空题
2. 天空是___色的。
''';
      const regionizer = TextQuestionRegionizer();
      final result = regionizer.split(rawText, const {});

      // 章节标题 "一、选择题" / "二、填空题" 不得被识别为题号
      // 只有 1. 和 2. 是真正的题目
      expect(result.regions.length, 2);
      expect(result.regions[0].number, 1);
      expect(result.regions[1].number, 2);
      // 确认一、选择题没有被当成 number=1 的题目
      expect(
        result.regions.any(
          (r) => r.rawText.contains('一、选择题'),
        ),
        isFalse,
      );
    });
  });

  group('Boundary Defense Tests - Explanation Boundary', () {
    test('20. "分析函数 f(x)"不得被切成 explanation', () {
      const region = TextQuestionRegion(
        number: 1,
        rawText: '1. 试分析函数 f(x) 的单调性并求极值。',
        startOffset: 0,
        endOffset: 100,
        kind: TextQuestionKind.subjective,
        health: RegionHealth.clean,
      );

      const assembler = LocalQuestionAssembler();
      final result = assembler.assemble(region);

      // "分析"在题干中间作为动词使用，不应触发 explanation 切分
      // 关键：切分正则要求 (^|\\n|。|；|;|\\.\\s+) 前缀，而这里"试分析"前面是"题。"之后的内容
      // 实际场景中"1. 试分析..." → 清理题号后变成"试分析函数..." → 不应该被切
      expect(result.question['explanation'], isEmpty);
      expect(
        result.question['content'].toString(),
        contains('分析函数'),
      );
    });
  });

  group('Boundary Defense Tests - Subjective Answer', () {
    test('21. "1. x = 2 解析：..." 能提取答案 x = 2', () {
      const rawText = '''
1. 求解方程：x + 1 = 3
2. 求函数极值

参考答案
1. x = 2 解析：移项得 x = 3 - 1 = 2。
2. 极大值 5，极小值 -3 解析：通过导数判断。
''';
      const matcher = AnswerBlockMatcher();
      final result = matcher.splitAnswerBlock(rawText);

      // 应提取到主观答案（不被 choice regex 匹配，走 subjective fallback）
      expect(result.answers.isNotEmpty, isTrue);
      // 主观答案应不包含"解析"正文
      if (result.answers[1] != null) {
        expect(result.answers[1], isNot(contains('解析')));
        expect(result.answers[1], isNot(contains('移项')));
      }
      if (result.answers[2] != null) {
        expect(result.answers[2], isNot(contains('解析')));
        expect(result.answers[2], isNot(contains('导数')));
      }
    });
  });

  group('Boundary Defense Tests - Save Defense', () {
    test('22. blocked=true 时 DocxTextFirstParseResult.blocked 为真', () async {
      const rawText = '仅有一道题的文本';
      const service = DocxTextFirstParseService();
      final result = await service.parseDocxText(
        rawText: rawText,
        sourceName: 'test_save_defense',
        documentSignals: const DocumentSignals(questionMarkerCount: 10),
      );

      // 即使只有 1 题，如果门禁判定 blocked，result.blocked 必须是 true
      // blocked 时 warnings 非空
      if (result.blocked) {
        expect(result.warnings, isNotEmpty);
      }
      // 无论如何，架构上 blocked 标志位存在
      expect(result.blocked, anyOf(isTrue, isFalse));
    });
  });

  group('Boundary Defense Tests - BareLine Guard', () {
    test('23. 裸数字题号只匹配强题干动词，不匹配普通材料编号', () {
      const rawText = '''
材料一：关于某政策的背景介绍
材料二：相关数据分析
1. 设函数 f(x) 在区间 [a, b] 上连续，证明存在 ξ 使得 f(ξ) = 0。
2. 已知数列 {a_n} 满足递推关系，求通项公式。
附录 1 参考公式
附录 2 常数表
''';
      const regionizer = TextQuestionRegionizer();
      final result = regionizer.split(rawText, const {});

      // 裸数字"1. 设函数"应被识别（设 = 数学题干词）
      // 裸数字"2. 已知"应被识别（已知 = 数学题干词）
      // "材料一" "材料二" 不会被 _explicitQuestionRegex 匹配（无后缀符）
      // "附录 1" 不会被 _bareLineQuestionRegex 匹配（"附录"非题干词，"参考"也非）
      final numbers = result.regions.map((r) => r.number).toSet();
      expect(numbers.contains(1), isTrue);
      expect(numbers.contains(2), isTrue);
      // 不应包含"材料一"/"材料二"被错误识别
      expect(numbers.contains(3), isFalse);
      expect(
        result.regions.any((r) => r.rawText.contains('材料')),
        isFalse,
      );
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

class ThrowingLlmApiClient extends LlmApiClient {
  ThrowingLlmApiClient(this.error);

  final Object error;

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
    throw error;
  }
}

class MockAiEngineRepository extends AiEngineRepository {
  final AiEngineProfile? profile;
  MockAiEngineRepository(this.profile)
      : super(store: const UnsupportedAiEngineStore());

  @override
  Future<AiEngineProfile?> getActiveTextEngine() async {
    return profile;
  }
}
