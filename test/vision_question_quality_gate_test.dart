import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/vision_question_quality_gate.dart';

void main() {
  group('VisionQuestionQualityGate', () {
    const gate = VisionQuestionQualityGate();

    test('marks answer leakage, missing answer, type mismatch, and q_num drift',
        () {
      final result = gate.evaluate(
        [
          {
            'q_num': '22',
            'type': 3,
            'content': '设二次型，求标准形。',
            'standard_answer': '标准形为...',
            'options': [],
            '_import_review': {
              'source': 'vision',
              'riskHints': ['vision_only'],
            },
          },
          {
            'q_num': '19',
            'type': 0,
            'content': '解：（Ⅰ）求矩阵 A=...',
            'standard_answer': '',
            'explanation': '',
            'options': [],
            '_import_review': {
              'source': 'vision',
              'riskHints': ['vision_only'],
            },
          },
        ],
        sourceName: 'vision_pdf_page',
      );

      final riskyMeta =
          result.questions[1]['_import_review'] as Map<String, dynamic>;
      final riskyHints = riskyMeta['riskHints'] as List;

      expect(riskyHints, contains('vision_only'));
      expect(riskyHints, contains('answer_leaked_to_content'));
      expect(riskyHints, contains('missing_answer_or_explanation'));
      expect(riskyHints, contains('type_options_mismatch'));
      expect(riskyHints, contains('q_num_drift'));
      expect(result.diagnostics['issueCounts']['q_num_drift'], 1);
    });

    test(
        'marks duplicate q_num only when repeated number has different content',
        () {
      final result = gate.evaluate(
        [
          {
            'q_num': '5',
            'type': 3,
            'content': 'First stem content.',
            'standard_answer': 'A',
          },
          {
            'q_num': '5',
            'type': 3,
            'content': 'Different stem content.',
            'standard_answer': 'B',
          },
        ],
        sourceName: 'vision_image_file',
      );

      final meta =
          result.questions[1]['_import_review'] as Map<String, dynamic>;
      expect(meta['riskHints'], contains('duplicate_q_num'));
      expect(result.diagnostics['issueCounts']['duplicate_q_num'], 1);
    });

    test('marks low quality batch when risky ratio is high', () {
      final result = gate.evaluate(
        [
          {
            'q_num': '1',
            'type': 3,
            'content': 'Good stem.',
            'standard_answer': 'A',
          },
          {
            'q_num': '2',
            'type': 3,
            'content': '分析：可得最终答案。',
            'standard_answer': '',
            'explanation': '',
          },
        ],
        sourceName: 'vision_pdf_page',
      );

      expect(result.diagnostics['lowQuality'], true);
      expect(result.warnings.single, contains('视觉结构质量偏低'));
      for (final question in result.questions) {
        final meta = question['_import_review'] as Map<String, dynamic>;
        expect(meta['riskHints'], contains('low_quality_vision_parse'));
      }
    });

    test('drops explanation for choice and fill questions before review', () {
      final result = gate.evaluate(
        [
          {
            'q_num': '11',
            'type': 2,
            'content': '已知级数收敛域为 (a,+∞)，则 a=____。',
            'standard_answer': '-1',
            'explanation': '这段解析不应进入填空题。',
            'raw_explanation': 'raw explanation',
            'options': ['A. noise'],
            'source': 'glm_ocr_intermediate',
          },
        ],
        sourceName: 'glm_ocr_intermediate',
      );

      final question = result.questions.single;
      final meta = question['_import_review'] as Map<String, dynamic>;

      expect(question['explanation'], '');
      expect(question['raw_explanation'], isNull);
      expect(question['options'], isEmpty);
      expect(
        meta['riskHints'],
        contains('dropped_non_subjective_explanation'),
      );
      expect(meta['riskHints'], contains('cleared_non_choice_options'));
      expect(
        meta['riskHints'],
        isNot(contains('missing_answer_or_explanation')),
      );
    });
  });
}
