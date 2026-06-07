import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_part.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_text_signal_detector.dart';

void main() {
  group('DocumentTextSignalDetector Tests', () {
    test('Question Marker Detection', () {
      final validMarkers = [
        '第1题',
        '第 1 题',
        '1.',
        '1、',
        '1)',
        '（1）',
        '(1)',
        '一、',
        ' 第1题 ', // with spaces
      ];

      for (final marker in validMarkers) {
        expect(
          DocumentTextSignalDetector.hasQuestionMarker(marker),
          true,
          reason: 'Failed on valid marker: $marker',
        );
      }

      final invalidMarkers = [
        '这第一题是...',
        '100',
        '题号：1',
        'a.b.c',
        '11a',
      ];

      for (final marker in invalidMarkers) {
        expect(
          DocumentTextSignalDetector.hasQuestionMarker(marker),
          false,
          reason: 'Falsely matched invalid marker: $marker',
        );
      }
    });

    test('Answer/Explanation Marker Detection', () {
      final validAnswers = [
        '答案',
        '答案：',
        '参考答案',
        '参考答案：',
        '解析',
        '解析：',
        '详解',
        '解：',
        '  参考答案  ', // with spaces
      ];

      for (final ans in validAnswers) {
        expect(
          DocumentTextSignalDetector.hasAnswerMarker(ans),
          true,
          reason: 'Failed on valid answer marker: $ans',
        );
      }

      final invalidAnswers = [
        '我的答案是这个',
        '这是对答案的解析',
        '解出方程的步骤是',
      ];

      for (final ans in invalidAnswers) {
        expect(
          DocumentTextSignalDetector.hasAnswerMarker(ans),
          false,
          reason: 'Falsely matched invalid answer marker: $ans',
        );
      }
    });

    test('Formula-Like Signal Detection', () {
      final validFormulas = [
        r'\frac{1}{2}',
        r'\sqrt{x}',
        r'\begin{matrix}',
        r'\sum_{i=1}^n',
        r'\int f(x)dx',
        'λ',
        '这是一个矩阵方程',
        'x^2 + y^2 = r^2',
      ];

      for (final formula in validFormulas) {
        expect(
          DocumentTextSignalDetector.hasFormulaLikeSignal(formula),
          true,
          reason: 'Failed on valid formula: $formula',
        );
      }

      final invalidFormulas = [
        '普通的文本，不含任何公式',
        'x + y = z',
      ];

      for (final formula in invalidFormulas) {
        expect(
          DocumentTextSignalDetector.hasFormulaLikeSignal(formula),
          false,
          reason: 'Falsely matched invalid formula: $formula',
        );
      }
    });

    test('detectRole returns correct TextRole', () {
      expect(
        DocumentTextSignalDetector.detectRole('### 标题', markdownTag: 'h3'),
        TextRole.heading,
      );
      expect(
        DocumentTextSignalDetector.detectRole('答案：A'),
        TextRole.answerBlock,
      );
      expect(
        DocumentTextSignalDetector.detectRole('普通的题目题干内容'),
        TextRole.paragraph,
      );
    });

    test('looksLikeTailAnswerBlock detection', () {
      expect(
        DocumentTextSignalDetector.looksLikeTailAnswerBlock(
            '参考答案表：\n1. A  2. B'),
        true,
      );
      expect(
        DocumentTextSignalDetector.looksLikeTailAnswerBlock('没有答案的普通段落'),
        false,
      );
    });
  });
}
