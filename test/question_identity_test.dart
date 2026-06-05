import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/question_identity.dart';

void main() {
  group('QuestionIdentity', () {
    test('normalizes common question number variants', () {
      expect(QuestionIdentity.normalizeQuestionNumber('第 一 题'), '1');
      expect(QuestionIdentity.normalizeQuestionNumber('1）'), '1');
      expect(QuestionIdentity.normalizeQuestionNumber('1.'), '1');
      expect(QuestionIdentity.normalizeQuestionNumber('一'), '1');
      expect(QuestionIdentity.normalizeQuestionNumber('二'), '2');
    });

    test('builds stable identity from weak map data', () {
      final a = QuestionIdentity.fromMap({
        'q_num': '1）',
        'content': '  Solve   X  ',
        'type': '3',
      });

      final b = QuestionIdentity.fromMap({
        'q_num': '1',
        'content': 'Solve X',
        'type': 3,
      });

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('keeps different types distinct', () {
      final a = QuestionIdentity.fromMap({
        'q_num': '1',
        'content': 'same',
        'type': 0,
      });

      final b = QuestionIdentity.fromMap({
        'q_num': '1',
        'content': 'same',
        'type': 3,
      });

      expect(a, isNot(b));
    });

    test('protects against completely empty identities', () {
      final a = QuestionIdentity.fromMap({
        'q_num': null,
        'content': '   ',
        'type': null,
      });

      expect(a.hasQuestionNumber, isFalse);
      expect(a.hasContent, isFalse);
    });
  });
}
