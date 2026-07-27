import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/subjective_answer_extractor.dart';

void main() {
  const extractor = SubjectiveAnswerExtractor();

  SubjectiveAnswerExtractionResult extract(String explanation) {
    return extractor.extract(
      questionNumber: 17,
      content: 'Synthetic calculation question',
      standardAnswer: '',
      explanation: explanation,
    );
  }

  test('extracts explicit answer labels and keeps formula structure', () {
    final labelled = extract('计算过程省略。\n答案为：\\(x=\\frac{1}{2}\\)');
    final fill = extract('由条件可得，应填 \\(3\\sqrt{2}\\)。');

    expect(labelled.matched, isTrue);
    expect(labelled.answer, r'\(x=\frac{1}{2}\)');
    expect(fill.matched, isTrue);
    expect(fill.answer, r'\(3\sqrt{2}\)');
  });

  test('does not guess from the last sentence or arbitrary equation', () {
    for (final explanation in const [
      '先化简得到 x=2。\n然后检查定义域。',
      '第一步展开。\n最后完成计算。',
      '这里只给出推导过程，没有明确答案标签。',
    ]) {
      expect(extract(explanation).matched, isFalse, reason: explanation);
    }
  });

  test('does not copy the whole explanation or unsafe placeholders', () {
    const whole = '答案：答案：这是一整段很长的解析，包含多步推导和说明，不应整体复制。';
    expect(extract(whole).matched, isFalse);
    expect(extract('答案：命题得证').matched, isFalse);
    expect(extract('答案：见解析').matched, isFalse);
  });

  test('rejects nested examples and multiline truncation', () {
    for (final explanation in const [
      '先看例题：答案为 1。\n本题继续推导，尚无明确结论。',
      '答案为：\\begin{cases}\nx=1\\\\y=2\n\\end{cases}',
    ]) {
      expect(extract(explanation).matched, isFalse, reason: explanation);
    }
  });

  test('explicit trailing method is excluded from the extracted answer', () {
    final result = extract('答案为 42。另一种解法：继续展开。');

    expect(result.matched, isTrue);
    expect(result.answer, '42');
    expect(result.answer, isNot(contains('另一种解法')));
  });
}
