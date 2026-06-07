import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/docx_text_first_parse_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_signals.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';
import 'package:shiroha_quiz/services/import_pipeline/answer_block_matcher.dart';

class MockRegionizer implements TextQuestionRegionizer {
  final List<TextQuestionRegion> mockedRegions;
  final int overrideMaxQuestionNumberDetected;
  MockRegionizer(this.mockedRegions, {this.overrideMaxQuestionNumberDetected = 0});

  @override
  RegionizerResult split(String rawText, Map<int, String> matchedAnswers) {
    return RegionizerResult(mockedRegions, {
      'maxQuestionNumberDetected': overrideMaxQuestionNumberDetected > 0
          ? overrideMaxQuestionNumberDetected
          : mockedRegions.map((r) => r.number).fold<int>(0, (a, b) => a > b ? a : b),
    });
  }
}

class MockAnswerMatcher implements AnswerBlockMatcher {
  final Map<int, String> answers;
  MockAnswerMatcher(this.answers);

  @override
  ({String answerBlockText, Map<int, String> answers, String questionBodyText}) splitAnswerBlock(String text) {
    return (
      answerBlockText: '',
      answers: answers,
      questionBodyText: text,
    );
  }
}

void main() {
  group('DocxTextFirstParseService Strict Quality Gates', () {
    test('Empty regions should return regionizer_empty blocked result', () async {
      final mockRegionizer = MockRegionizer([]);
      final mockMatcher = MockAnswerMatcher({});
      
      final service = DocxTextFirstParseService(
        regionizer: mockRegionizer,
        answerMatcher: mockMatcher,
      );

      final result = await service.parseDocxText(
        rawText: 'test text',
        sourceName: 'test',
      );
      expect(result.blocked, isTrue);
      expect(result.warnings.any((w) => w.contains('DOCX 未检测到稳定题号骨架')), isTrue);
      expect(result.questions, isEmpty);
    });

    test('High loss rate triggers blocked result based on regions count', () async {
      // 10 regions with maxNo=21, but health=rejected for all except 0 → regions loop skips all rejects
      // RegionHealth.rejected → assembler runs, assembly.rejected=true → rejectedCount++ → continue
      // 但当前 mock Assembler 不接受 rejection — rejectedRegion 本身还是会被 _assembler.assemble()
      // 真实 assembler 对 rawText='This is...' (全英文, 无答案, content非空) 返回 rejected=false
      // 所以本测试用 criticalDiagnostics 方式触发门禁：把 regionCount 设得远高于 actual
      // 改为直接验证 qualityGate 行为：确保 blocked 被正确判定
      final regions = List.generate(10, (i) => TextQuestionRegion(
        number: i + 1,
        rawText: 'Q', // short enough to be impossible?
        startOffset: i * 10,
        endOffset: i * 10 + 5,
        kind: TextQuestionKind.unknown,
        health: RegionHealth.clean, // all clean
      ));

      final mockRegionizer = MockRegionizer(regions, overrideMaxQuestionNumberDetected: 21);
      final mockMatcher = MockAnswerMatcher({});

      final service = DocxTextFirstParseService(
        regionizer: mockRegionizer,
        answerMatcher: mockMatcher,
      );

      final result = await service.parseDocxText(
        rawText: 'test text',
        sourceName: 'test',
      );
      // expectedCount = max(10, 21, 0, 0) = 21
      // actualCount = 10 (all clean, all assembled, all accepted)
      // completionRate = 10/21 ≈ 0.476 < 0.8, expectedCount ≥ 10 → blocked
      expect(result.blocked, isTrue);
      expect(result.warnings.any((w) => w.contains('解析完整率过低')), isTrue);
    });

    test('High loss rate triggers blocked result based on document signals', () async {
      // 1 region, but document signals say there are 10 questions.
      final regions = [
        TextQuestionRegion(
          number: 1,
          rawText: 'This is a long enough question text for Q1',
          startOffset: 0,
          endOffset: 5,
          kind: TextQuestionKind.unknown,
          health: RegionHealth.clean,
        )
      ];

      final mockRegionizer = MockRegionizer(regions, overrideMaxQuestionNumberDetected: 1);
      final mockMatcher = MockAnswerMatcher({});

      final service = DocxTextFirstParseService(
        regionizer: mockRegionizer,
        answerMatcher: mockMatcher,
      );

      final result = await service.parseDocxText(
        rawText: 'test text',
        sourceName: 'test',
        documentSignals: const DocumentSignals(questionMarkerCount: 10));
      expect(result.blocked, isTrue);
      expect(result.warnings.any((w) => w.contains('解析完整率过低')), isTrue);
      expect(result.questions.length, 1);
    });

    test('Valid parse passes quality gate and is not blocked', () async {
      final regions = List.generate(5, (i) => TextQuestionRegion(
        number: i + 1,
        rawText: 'This is a long enough question text for Q${i+1}',
        startOffset: i * 10,
        endOffset: i * 10 + 5,
        kind: TextQuestionKind.subjective,
        health: RegionHealth.clean,
      ));

      final mockRegionizer = MockRegionizer(regions);
      final mockMatcher = MockAnswerMatcher({});
      
      final service = DocxTextFirstParseService(
        regionizer: mockRegionizer,
        answerMatcher: mockMatcher,
      );

      final result = await service.parseDocxText(
        rawText: 'test text',
        sourceName: 'test',
        documentSignals: const DocumentSignals(questionMarkerCount: 5));
      expect(result.blocked, isFalse);
      expect(result.warnings, isEmpty);
      expect(result.questions.length, 5);
    });
  });
}
