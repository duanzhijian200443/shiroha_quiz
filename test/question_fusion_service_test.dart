import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/question_fragment.dart';
import 'package:shiroha_quiz/services/import_pipeline/question_fusion_service.dart';

void main() {
  group('QuestionFusionService', () {
    test('stemOnly + answerOnly 按题号合并', () {
      final fragments = [
        QuestionFragment.fromMap({
          'q_num': '1',
          'content': 'This is a question without answer.',
        }, source: QuestionFragmentSource.text, originalIndex: 0),
        QuestionFragment.fromMap({
          'q_num': '1',
          'standard_answer': 'B',
        }, source: QuestionFragmentSource.text, originalIndex: 1),
      ];

      final res = const QuestionFusionService().fuse(fragments);
      expect(res.questions.length, 1);
      expect(
          res.questions.first['content'], 'This is a question without answer.');
      expect(res.questions.first['standard_answer'], 'B');
    });

    test('text full + vision full 同题号时，content 取更长，answer 冲突记录 diagnostics',
        () {
      final fragments = [
        QuestionFragment.fromMap({
          'q_num': '2',
          'content': 'Short content text.',
          'standard_answer': 'A',
        }, source: QuestionFragmentSource.text, originalIndex: 0),
        QuestionFragment.fromMap({
          'q_num': '2',
          'content': 'This is a much longer content from vision.',
          'standard_answer': 'B',
        }, source: QuestionFragmentSource.vision, originalIndex: 1),
      ];

      final res = const QuestionFusionService().fuse(fragments);
      expect(res.questions.length, 1);
      expect(res.questions.first['content'],
          'This is a much longer content from vision.');
      expect(res.questions.first['standard_answer'], 'A'); // 保留文本答案
      expect(res.diagnostics.length, 1);
      expect(res.diagnostics.first, contains('答案冲突，保留文本答案: A (忽略: B)'));
    });

    test('vision 不覆盖已有 text answer', () {
      final fragments = [
        QuestionFragment.fromMap({
          'q_num': '3',
          'content': 'Text stem',
          'standard_answer': 'C',
        }, source: QuestionFragmentSource.text, originalIndex: 0),
        QuestionFragment.fromMap({
          'q_num': '3',
          'content': 'Vision stem',
          'standard_answer': 'D', // 即使vision答案更长，也要保留text
        }, source: QuestionFragmentSource.vision, originalIndex: 1),
      ];

      final res = const QuestionFusionService().fuse(fragments);
      expect(res.questions.first['standard_answer'], 'C');
    });

    test('无题号 orphan 保留', () {
      final fragments = [
        QuestionFragment.fromMap({
          'content': 'Orphan question',
          'standard_answer': 'A',
        }, source: QuestionFragmentSource.text, originalIndex: 0),
      ];

      final res = const QuestionFusionService().fuse(fragments);
      expect(res.questions.length, 1);
      expect(res.orphanCount, 1);
    });

    test('输出顺序按题号排序', () {
      final fragments = [
        QuestionFragment.fromMap(
            {'q_num': '10', 'content': 'q10 contains long enough text stem'},
            source: QuestionFragmentSource.text, originalIndex: 0),
        QuestionFragment.fromMap(
            {'q_num': '2', 'content': 'q2 contains long enough text stem'},
            source: QuestionFragmentSource.text, originalIndex: 1),
        QuestionFragment.fromMap({'content': 'orphan without question number'},
            source: QuestionFragmentSource.text, originalIndex: 2),
        QuestionFragment.fromMap(
            {'q_num': '1', 'content': 'q1 contains long enough text stem'},
            source: QuestionFragmentSource.text, originalIndex: 3),
      ];

      final res = const QuestionFusionService().fuse(fragments);
      expect(res.questions.length, 4);
      expect(res.questions[0]['content'], 'q1 contains long enough text stem');
      expect(res.questions[1]['content'], 'q2 contains long enough text stem');
      expect(res.questions[2]['content'], 'q10 contains long enough text stem');
      expect(res.questions[3]['content'], 'orphan without question number');
    });

    test('explanation 取更长版本', () {
      final fragments = [
        QuestionFragment.fromMap({
          'q_num': '1',
          'content': 'Valid text stem for test.',
          'explanation': 'Short text exp',
        }, source: QuestionFragmentSource.text, originalIndex: 0),
        QuestionFragment.fromMap({
          'q_num': '1',
          'explanation': 'This is a much longer explanation from vision.',
        }, source: QuestionFragmentSource.vision, originalIndex: 1),
      ];

      final res = const QuestionFusionService().fuse(fragments);
      expect(res.questions.first['explanation'],
          'This is a much longer explanation from vision.');
    });
    test('partialQuestion only fills empty fields', () {
      final fragments = [
        QuestionFragment.fromMap({
          'q_num': '7',
          'content': 'Complete stem should stay.',
          'explanation': 'Complete explanation should stay.',
        }, source: QuestionFragmentSource.text, originalIndex: 0),
        QuestionFragment.fromMap({
          'q_num': '7',
          'content': 'patch',
          'explanation': 'Patch explanation',
          'type': 'single_choice',
        }, source: QuestionFragmentSource.vision, originalIndex: 1),
      ];

      final res = const QuestionFusionService().fuse(fragments);

      expect(res.questions.single['content'], 'Complete stem should stay.');
      expect(
        res.questions.single['explanation'],
        'Complete explanation should stay.',
      );
      expect(res.questions.single['type'], 'single_choice');
    });

    test('same-source answer conflict records diagnostics', () {
      final fragments = [
        QuestionFragment.fromMap({
          'q_num': '8',
          'content': 'Stem',
          'standard_answer': 'A',
        }, source: QuestionFragmentSource.vision, originalIndex: 0),
        QuestionFragment.fromMap({
          'q_num': '8',
          'standard_answer': 'BC',
        }, source: QuestionFragmentSource.vision, originalIndex: 1),
      ];

      final res = const QuestionFusionService().fuse(fragments);

      expect(res.questions.single['standard_answer'], 'BC');
      expect(res.diagnostics.single, contains('同源答案冲突'));
    });

    group('Import Review Metadata in Fusion', () {
      test('Single text fragment adds source=text metadata', () {
        final fragments = [
          QuestionFragment.fromMap(
              {'content': 'Text only question is long enough'},
              source: QuestionFragmentSource.text, originalIndex: 0),
        ];
        final res = const QuestionFusionService().fuse(fragments);
        final meta =
            res.questions.single['_import_review'] as Map<String, dynamic>;
        expect(meta['source'], 'text');
        expect(meta['sources'], ['text']);
        expect(meta['riskHints'], isEmpty);
      });

      test('Single vision fragment adds source=vision and vision_only hint',
          () {
        final fragments = [
          QuestionFragment.fromMap(
              {'content': 'Vision only question is long enough'},
              source: QuestionFragmentSource.vision, originalIndex: 0),
        ];
        final res = const QuestionFusionService().fuse(fragments);
        final meta =
            res.questions.single['_import_review'] as Map<String, dynamic>;
        expect(meta['source'], 'vision');
        expect(meta['sources'], ['vision']);
        expect(meta['riskHints'], contains('vision_only'));
      });

      test(
          'Fused text and vision adds source=fused and fused_from_text_vision hint',
          () {
        final fragments = [
          QuestionFragment.fromMap(
              {'q_num': '1', 'content': 'Text stem is long enough'},
              source: QuestionFragmentSource.text, originalIndex: 0),
          QuestionFragment.fromMap({
            'q_num': '1',
            'content': 'Vision stem is longer so it gets fused properly'
          }, source: QuestionFragmentSource.vision, originalIndex: 1),
        ];
        final res = const QuestionFusionService().fuse(fragments);
        final meta =
            res.questions.single['_import_review'] as Map<String, dynamic>;
        expect(meta['source'], 'fused');
        expect(meta['sources'], containsAll(['text', 'vision']));
        expect(meta['riskHints'], contains('fused_from_text_vision'));
      });

      test('Answer conflict adds answer_conflict hint', () {
        final fragments = [
          QuestionFragment.fromMap({
            'q_num': '1',
            'content': 'Stem is long enough here',
            'standard_answer': 'A'
          }, source: QuestionFragmentSource.text, originalIndex: 0),
          QuestionFragment.fromMap({'q_num': '1', 'standard_answer': 'B'},
              source: QuestionFragmentSource.vision, originalIndex: 1),
        ];
        final res = const QuestionFusionService().fuse(fragments);
        final meta =
            res.questions.single['_import_review'] as Map<String, dynamic>;
        expect(meta['riskHints'], contains('answer_conflict'));
      });

      test('Fragment kinds add specific risk hints', () {
        final fragments = [
          QuestionFragment.fromMap({}, // Empty map yields orphan
              source: QuestionFragmentSource.text,
              originalIndex: 0),
          QuestionFragment.fromMap({'standard_answer': 'A'}, // answerOnly
              source: QuestionFragmentSource.text,
              originalIndex: 1),
          QuestionFragment.fromMap(
              {'q_num': '3', 'content': 'short'}, // partialQuestion
              source: QuestionFragmentSource.text,
              originalIndex: 2),
        ];
        final res = const QuestionFusionService().fuse(fragments);

        final orphanQuestion = res.questions.firstWhere(
          (q) {
            final meta = q['_import_review'] as Map<String, dynamic>?;
            return meta != null &&
                (meta['fragmentKinds'] as List).contains('orphan');
          },
        );
        final orphanMeta =
            orphanQuestion['_import_review'] as Map<String, dynamic>;
        expect(orphanMeta['riskHints'], contains('orphan_fragment'));

        final answerOnlyMeta = res.questions.firstWhere(
                (q) => q['standard_answer'] == 'A')['_import_review']
            as Map<String, dynamic>;
        expect(answerOnlyMeta['riskHints'], contains('answer_only_fragment'));

        final partialMeta = res.questions
                .firstWhere((q) => q['content'] == 'short')['_import_review']
            as Map<String, dynamic>;
        expect(partialMeta['riskHints'], contains('partial_question'));
      });
    });
  });
}
