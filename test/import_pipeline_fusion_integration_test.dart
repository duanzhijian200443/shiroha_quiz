import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_fusion_coordinator.dart';

void main() {
  const coordinator = ImportQuestionFusionCoordinator();

  group('ImportQuestionFusionCoordinator', () {
    test('merges text and vision fragments with the same question number', () {
      final result = coordinator.fuseTextAndVision(
        sourceName: 'sample.md',
        textQuestions: [
          {
            'q_num': '1',
            'content': 'Which option is correct?',
            'standard_answer': 'A',
          },
        ],
        visionQuestions: [
          {
            'q_num': '1',
            'explanation': 'Vision captured a supporting diagram.',
          },
        ],
      );

      expect(result.questions, hasLength(1));
      expect(result.questions.single['content'], 'Which option is correct?');
      expect(result.questions.single['standard_answer'], 'A');
      expect(
        result.questions.single['explanation'],
        'Vision captured a supporting diagram.',
      );
      expect(result.diagnostics['sample.md']['fusionMergedCount'], 1);
    });

    test('keeps text answer and exposes diagnostics on answer conflict', () {
      final result = coordinator.fuseTextAndVision(
        sourceName: 'conflict.docx',
        textQuestions: [
          {
            'q_num': '2',
            'content': 'Text stem',
            'standard_answer': 'C',
          },
        ],
        visionQuestions: [
          {
            'q_num': '2',
            'content': 'Text stem with image context',
            'standard_answer': 'D',
          },
        ],
      );

      expect(result.questions.single['standard_answer'], 'C');
      expect(result.warnings, isNotEmpty);
      expect(result.warnings.single, contains('答案冲突'));
      expect(result.warnings.single, contains('保留文本答案'));
    });

    test('uses longer vision content and explanation as supplements', () {
      final result = coordinator.fuseTextAndVision(
        sourceName: 'supplement.zip',
        textQuestions: [
          {
            'q_num': '3',
            'content': 'Short stem.',
          },
        ],
        visionQuestions: [
          {
            'q_num': '3',
            'content': 'Short stem with the full chart description.',
            'explanation': 'The chart shows the missing comparison.',
          },
        ],
      );

      expect(
        result.questions.single['content'],
        'Short stem with the full chart description.',
      );
      expect(
        result.questions.single['explanation'],
        'The chart shows the missing comparison.',
      );
    });

    test('folds answer-only fragments into matching stem-only fragments', () {
      final result = coordinator.fuseTextAndVision(
        sourceName: 'answers.txt',
        textQuestions: [
          {
            'q_num': '4',
            'content': 'A stem that appears without an answer.',
          },
        ],
        visionQuestions: [
          {
            'q_num': '4',
            'content': 'B',
          },
        ],
      );

      expect(result.questions, hasLength(1));
      expect(result.questions.single['content'],
          'A stem that appears without an answer.');
      expect(result.questions.single['standard_answer'], 'B');
    });

    test('preserves orphan fragments at the end and records diagnostics', () {
      final result = coordinator.fuseTextAndVision(
        sourceName: 'orphan.md',
        textQuestions: [
          {
            'q_num': '1',
            'content': 'Numbered stem',
          },
        ],
        visionQuestions: [
          {
            'content': 'Detached visual note',
            'standard_answer': 'A',
          },
        ],
      );

      expect(result.questions, hasLength(2));
      expect(result.questions.last['content'], 'Detached visual note');
      expect(result.warnings.any((w) => w.contains('孤立题目片段已保留')), true);
      expect(result.diagnostics['orphan.md']['fusionOrphanCount'], 1);
    });

    test('repairs bare LaTeX after fusion', () {
      final result = coordinator.fuseTextAndVision(
        sourceName: 'formula.docx',
        textQuestions: [
          {
            'q_num': '5',
            'content': r'Compute \frac{1}{2}',
          },
        ],
        visionQuestions: [
          {
            'q_num': '5',
            'explanation': r'Use \sqrt{x}',
          },
        ],
      );

      expect(result.questions.single['content'], r'Compute \(\frac{1}{2}\)');
      expect(result.questions.single['explanation'], r'Use \(\sqrt{x}\)');
    });

    test('ignores Chinese placeholder answers before selecting vision answer',
        () {
      for (final placeholder in ['无', '未提供', '未见答案', '暂无']) {
        final result = coordinator.fuseTextAndVision(
          sourceName: 'placeholder.md',
          textQuestions: [
            {
              'q_num': '6',
              'content': 'Question with placeholder answer.',
              'standard_answer': placeholder,
            },
          ],
          visionQuestions: [
            {
              'q_num': '6',
              'standard_answer': 'B',
            },
          ],
        );

        expect(
          result.questions.single['standard_answer'],
          'B',
          reason: 'placeholder "$placeholder" must not override Vision answer',
        );
      }
    });
  });
}
