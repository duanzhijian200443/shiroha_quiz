import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/question_identity.dart';

void main() {
  group('QuestionIdentity', () {
    group('tryParseExplicitQuestionNumber', () {
      test('accepts explicit ASCII, full-width, wrapped, and markdown forms',
          () {
        final accepted = <Object, int>{
          1: 1,
          '1': 1,
          '01': 1,
          '1.': 1,
          '1．': 1,
          '1、': 1,
          '(1)': 1,
          '（1）': 1,
          '（１）': 1,
          '第 1 题': 1,
          '## （１）': 1,
        };

        for (final entry in accepted.entries) {
          expect(
            QuestionIdentity.tryParseExplicitQuestionNumber(entry.key),
            entry.value,
            reason: 'expected explicit marker ${entry.key} to parse',
          );
        }
      });

      test('rejects non-question markers and embedded numbers', () {
        final rejected = <Object?>[
          null,
          '',
          '   ',
          '3.14',
          '2025. 全国考试',
          '第 5 页',
          '100 分',
          '(Ⅰ)',
          '（Ⅱ）',
          '某对象在 1 个条件下求值',
          '1. 某对象满足条件，求值。',
          '题 1 与题 2',
        ];

        for (final value in rejected) {
          expect(
            QuestionIdentity.tryParseExplicitQuestionNumber(value),
            isNull,
            reason: 'expected $value to be rejected',
          );
        }
      });
    });

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
