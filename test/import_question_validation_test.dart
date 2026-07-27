import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/import_question_validation.dart';

void main() {
  test('meaningful options ignore empty and whitespace entries', () {
    expect(hasAtLeastTwoMeaningfulOptions(['A', 'B']), isTrue);
    expect(hasAtLeastTwoMeaningfulOptions(['', '   ']), isFalse);
    expect(hasAtLeastTwoMeaningfulOptions(['Content A', '   ']), isFalse);
  });

  test('answer placeholders are not meaningful', () {
    for (final value in const [
      '',
      '   ',
      '无',
      '暂无',
      '未知',
      '未提供',
      '未给出',
      '见解析',
      '详见解析',
      '答案见解析',
    ]) {
      expect(isMeaningfulAnswer(value), isFalse, reason: value);
    }
    expect(isMeaningfulAnswer('A'), isTrue);
  });

  test('choice answer parser accepts only complete supported formats', () {
    const cases = {
      'A': ['A'],
      '(A)': ['A'],
      'A,B': ['A', 'B'],
      'A、C': ['A', 'C'],
      'AC': ['A', 'C'],
      '答案：B': ['B'],
      'Answer: B': ['B'],
      'Option A': ['A'],
    };

    for (final entry in cases.entries) {
      final result = parseChoiceAnswerLabels(entry.key);
      expect(result.parsed, isTrue, reason: entry.key);
      expect(result.labels, entry.value, reason: entry.key);
    }

    final unsupported =
        parseChoiceAnswerLabels('The answer is described in the source');
    expect(unsupported.parsed, isFalse);
    expect(unsupported.labels, isEmpty);

    for (final answer in const ['TRUE', 'FALSE', 'CORRECT', 'Answer']) {
      final result = parseChoiceAnswerLabels(answer);
      expect(result.parsed, isFalse, reason: answer);
      expect(result.labels, isEmpty, reason: answer);
    }
  });
}
