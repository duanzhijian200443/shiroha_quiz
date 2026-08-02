import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/question/question_region.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/text_question_region_bridge.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_regionizer.dart';

void main() {
  const bridge = TextQuestionRegionBridge();

  group('TextQuestionRegionBridge producer boundary and content', () {
    test('bridges real normalized producer output as coarse content', () {
      const rawText = '\r\n1.  设函数 f(x)，求值。\r\n\r\n\r\n2.  求矩阵 A 的逆。\r\n';
      final producer = const TextQuestionRegionizer().split(
        rawText,
        const <int, String>{},
      );

      expect(producer.regions, hasLength(2));
      final legacy = producer.regions.first;
      final result = bridge.convert(
        legacy,
        sourceRef: SourceRef.at(
          sourceId: 'source_a',
          displayLabel: 'paper.txt',
          point: SourcePoint.block(
            pageNumber: 1,
            blockId: 'legacy_text',
            readingOrder: 0,
          ),
        ),
      );

      expect(result.questionNumber, legacy.number);
      final stem = result.fragmentsFor(QuestionRegionField.stem).single;
      expect((stem.part as SourceContentPart).content.nodes, hasLength(1));
      expect((stem.part as SourceContentPart).content.nodes.single,
          isA<TextNode>());
      expect(
        ((stem.part as SourceContentPart).content.nodes.single as TextNode)
            .text,
        legacy.rawText,
      );
      expect(stem.slice, isNull);
      expect(stem.sourceRef.start, isNull);
      expect(
        result.issues,
        contains(
          ImportIssue(
            code: 'legacy_provenance_coarse',
            severity: ImportIssueSeverity.warning,
            field: ImportIssueField.source,
            sourceRef: stem.sourceRef,
          ),
        ),
      );
    });

    test('builds coarse stem and answer fragments from legacy content', () {
      final sourceRef = SourceRef.at(
        sourceId: 'source_a',
        displayLabel: 'paper.txt',
        point: SourcePoint.block(
          pageNumber: 1,
          blockId: 'block_1',
          readingOrder: 0,
        ),
      );
      final result = bridge.convert(
        TextQuestionRegion(
          number: 2,
          rawText: 'stem text',
          startOffset: 0,
          endOffset: 9,
          answerText: '  42 ',
          kind: TextQuestionKind.choice,
          health: RegionHealth.clean,
        ),
        sourceRef: sourceRef,
      );

      final stems = result.fragmentsFor(QuestionRegionField.stem);
      expect(stems, hasLength(1));
      expect(stems.single.sourceRef.start, isNull);
      expect(
        ((stems.single.part as SourceContentPart).content.nodes.single
                as TextNode)
            .text,
        'stem text',
      );
      final answers = result.fragmentsFor(QuestionRegionField.answer);
      expect(answers, hasLength(1));
      final answerPart = answers.single.part as SourceContentPart;
      expect(
        (answerPart.content.nodes.single as TextNode).text,
        '42',
      );
      expect(answerPart.sourceRef.start, isNull);
      expect(answerPart.sourceRef.end, isNull);
      expect(answerPart.sourceRef.sourceId, 'source_a');
      expect(answerPart.sourceRef.displayLabel, 'paper.txt');
      expect(
        result.issues,
        contains(
          ImportIssue(
            code: 'legacy_provenance_coarse',
            severity: ImportIssueSeverity.warning,
            field: ImportIssueField.source,
            sourceRef: answerPart.sourceRef,
          ),
        ),
      );
      expect(result.readiness, QuestionRegionReadiness.needsReview);
    });
  });

  group('TextQuestionRegionBridge kind and health', () {
    test('maps every legacy kind to its frozen hint', () {
      const cases = <(TextQuestionKind, QuestionRegionKindHint)>[
        (TextQuestionKind.choice, QuestionRegionKindHint.singleChoice),
        (TextQuestionKind.multiChoice, QuestionRegionKindHint.multipleChoice),
        (TextQuestionKind.trueFalse, QuestionRegionKindHint.trueFalse),
        (TextQuestionKind.fillBlank, QuestionRegionKindHint.fillBlank),
        (TextQuestionKind.subjective, QuestionRegionKindHint.shortAnswer),
        (TextQuestionKind.unknown, QuestionRegionKindHint.unknown),
      ];

      for (final (kind, expected) in cases) {
        final result = bridge.convert(
          TextQuestionRegion(
            number: 1,
            rawText: 'stem',
            startOffset: 0,
            endOffset: 4,
            kind: kind,
            health: RegionHealth.clean,
          ),
          sourceRef: _sourceRef(),
        );
        expect(result.kindHint, expected, reason: kind.name);
      }
    });

    test('maps health to warnings and errors', () {
      final repairable = bridge.convert(
        TextQuestionRegion(
          number: 1,
          rawText: 'stem',
          startOffset: 0,
          endOffset: 4,
          kind: TextQuestionKind.unknown,
          health: RegionHealth.repairable,
        ),
        sourceRef: _sourceRef(),
      );
      expect(
        repairable.issues,
        contains(
          ImportIssue(
            code: 'legacy_region_repairable',
            severity: ImportIssueSeverity.warning,
            sourceRef: _sourceRef(),
          ),
        ),
      );
      expect(repairable.readiness, QuestionRegionReadiness.needsReview);

      final rejected = bridge.convert(
        TextQuestionRegion(
          number: 1,
          rawText: 'stem',
          startOffset: 0,
          endOffset: 4,
          kind: TextQuestionKind.unknown,
          health: RegionHealth.rejected,
        ),
        sourceRef: _sourceRef(),
      );
      expect(
        rejected.issues,
        contains(
          ImportIssue(
            code: 'legacy_region_rejected',
            severity: ImportIssueSeverity.error,
            sourceRef: _sourceRef(),
          ),
        ),
      );
      expect(rejected.readiness, QuestionRegionReadiness.rejected);
    });
  });

  group('TextQuestionRegionBridge diagnostics and readiness', () {
    test('maps real legacy Chinese diagnostics to frozen codes', () {
      final result = bridge.convert(
        TextQuestionRegion(
          number: 1,
          rawText: 'stem',
          startOffset: 0,
          endOffset: 4,
          kind: TextQuestionKind.unknown,
          health: RegionHealth.clean,
          diagnostics: const <String>[
            '缺少 A 选项',
            '缺少 B 选项',
            r'疑似未闭合行内公式 \(',
            r'疑似未闭合块级公式 \[',
            '题号存在跳跃: 从 1 跳到 3',
            'mystery_diagnostic',
            'another_mystery',
          ],
        ),
        sourceRef: _sourceRef(),
      );

      final codes = result.issues.map((issue) => issue.code).toList();
      expect(
        codes,
        containsAll(<String>[
          'missing_option_a',
          'missing_option_b',
          'unclosed_inline_math',
          'unclosed_block_math',
          'question_number_gap',
          'legacy_region_diagnostic',
        ]),
      );
      expect(
        codes.where((code) => code == 'legacy_region_diagnostic'),
        hasLength(1),
      );
      expect(
        result.issues
            .where((issue) => issue.code == 'missing_option_a')
            .single
            .field,
        ImportIssueField.options,
      );
      expect(
        result.issues
            .where((issue) => issue.code == 'missing_option_b')
            .single
            .field,
        ImportIssueField.options,
      );
      expect(
        result.issues
            .where((issue) => issue.code == 'unclosed_inline_math')
            .single
            .field,
        ImportIssueField.stem,
      );
      expect(
        result.issues
            .where((issue) => issue.code == 'unclosed_block_math')
            .single
            .field,
        ImportIssueField.stem,
      );
      expect(
        result.issues
            .where((issue) => issue.code == 'question_number_gap')
            .single
            .field,
        ImportIssueField.question,
      );
      expect(
        result.issues
            .where((issue) => issue.code == 'legacy_region_diagnostic')
            .single
            .field,
        isNull,
      );
      expect(
        codes.any(
          (code) =>
              code.contains('缺少') ||
              code.contains('未闭合') ||
              code.contains('题号') ||
              code.contains('跳跃') ||
              code.contains('mystery'),
        ),
        isFalse,
      );
    });

    test('marks empty stems as missing and never ready', () {
      final result = bridge.convert(
        TextQuestionRegion(
          number: 4,
          rawText: '',
          startOffset: 0,
          endOffset: 1,
          kind: TextQuestionKind.unknown,
          health: RegionHealth.clean,
        ),
        sourceRef: _sourceRef(),
      );

      expect(
        result.issues,
        contains(
          ImportIssue(
            code: 'missing_stem',
            severity: ImportIssueSeverity.warning,
            field: ImportIssueField.stem,
            sourceRef: result.fragments.single.sourceRef,
          ),
        ),
      );
      expect(result.readiness, QuestionRegionReadiness.needsReview);
    });

    test('does not mutate legacy inputs and is repeatable', () {
      final diagnostics = <String>['missing_option_a', 'mystery'];
      final region = TextQuestionRegion(
        number: 7,
        rawText: 'stem',
        startOffset: 0,
        endOffset: 4,
        answerText: 'answer',
        kind: TextQuestionKind.subjective,
        health: RegionHealth.repairable,
        diagnostics: diagnostics,
      );
      final sourceRef = _sourceRef();

      final first = bridge.convert(region, sourceRef: sourceRef);
      final second = bridge.convert(region, sourceRef: sourceRef);

      expect(region.diagnostics, diagnostics);
      expect(region.answerText, 'answer');
      expect(second, first);
    });
  });
}

SourceRef _sourceRef() {
  return SourceRef.document(sourceId: 'source_a');
}
