import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/docx_text_first_parse_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_signals.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';
import 'package:shiroha_quiz/services/import_pipeline/answer_block_matcher.dart';

class MockRegionizer implements TextQuestionRegionizer {
  final List<TextQuestionRegion> mockedRegions;
  MockRegionizer(this.mockedRegions);

  @override
  RegionizerResult split(String rawText, Map<int, String> matchedAnswers) {
    return RegionizerResult(mockedRegions, {});
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
      // expected: 10 regions, actual: 1 fast path (since we mock health = clean for 1 and rejected for 9)
      final regions = List.generate(10, (i) => TextQuestionRegion(
        number: i + 1,
        rawText: 'This is a long enough question text for Q${i+1}',
        startOffset: i * 10,
        endOffset: i * 10 + 5,
        kind: TextQuestionKind.unknown,
        health: i == 0 ? RegionHealth.clean : RegionHealth.rejected,
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
      );
      expect(result.blocked, isTrue);
      expect(result.warnings.any((w) => w.contains('解析丢失率过高')), isTrue);
      // expected = 10, actual = 1 < 8, so blocked
      expect(result.questions.length, 1);
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

      final mockRegionizer = MockRegionizer(regions);
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
      expect(result.warnings.any((w) => w.contains('解析丢失率过高')), isTrue);
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
