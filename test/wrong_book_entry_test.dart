import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/wrong_book_entry.dart';
import 'dart:convert';

void main() {
  group('WrongBookEntry', () {
    test('handles empty map safely with default values', () {
      final entry = WrongBookEntry.fromRow({});

      expect(entry.id, '');
      expect(entry.type, 0);
      expect(entry.content, '');
      expect(entry.bankName, '');
      expect(entry.options, isEmpty);
      expect(entry.answer, '');
      expect(entry.explanation, '');
      expect(entry.lapses, 0);
      expect(entry.difficulty, 0.0);
      expect(entry.stability, 0.0);
      expect(entry.lastLapseTime, 0);
      expect(entry.hasAnswerOrExplanation, isFalse);
    });

    test('parses lapses, difficulty, stability from various types', () {
      final entry = WrongBookEntry.fromRow({
        'lapses': '3',
        'difficulty': 1.5,
        'stability': '0.75',
        'last_lapse_time': 1600000,
      });

      expect(entry.lapses, 3);
      expect(entry.difficulty, 1.5);
      expect(entry.stability, 0.75);
      expect(entry.lastLapseTime, 1600000);
    });

    test('parses options from JSON array', () {
      final entry = WrongBookEntry.fromRow({
        'options': '["A. Option 1", "B. Option 2"]',
      });
      expect(entry.options, ['A. Option 1', 'B. Option 2']);
    });

    test('parses options from double JSON encoded string', () {
      final inner = jsonEncode(['A. Opt1', 'B. Opt2']);
      final outer = jsonEncode(inner);

      final entry = WrongBookEntry.fromRow({
        'options': outer,
      });
      expect(entry.options, ['A. Opt1', 'B. Opt2']);
    });

    test('parses options from plain string fallback', () {
      final entry = WrongBookEntry.fromRow({
        'options': 'Just a plain string without json',
      });
      expect(entry.options, ['Just a plain string without json']);
    });

    test('returns unmodifiable options list', () {
      final entry = WrongBookEntry.fromRow({
        'options': '["Opt"]',
      });
      expect(() => (entry.options as List).clear(), throwsUnsupportedError);
    });

    test('splits standard_answer into answer and explanation', () {
      final entry = WrongBookEntry.fromRow({
        'standard_answer': 'A|||This is because...',
      });
      expect(entry.answer, 'A');
      expect(entry.explanation, 'This is because...');
      expect(entry.hasAnswerOrExplanation, isTrue);
    });

    test('preserves multiple ||| in explanation', () {
      final entry = WrongBookEntry.fromRow({
        'standard_answer': 'B|||First point.|||Second point.',
      });
      expect(entry.answer, 'B');
      expect(entry.explanation, 'First point.|||Second point.');
    });

    test('handles standard_answer with no explanation', () {
      final entry = WrongBookEntry.fromRow({
        'standard_answer': 'C',
      });
      expect(entry.answer, 'C');
      expect(entry.explanation, '');
      expect(entry.hasAnswerOrExplanation, isTrue);
    });

    test('generates map for QuestionEditScreen compatibility', () {
      final entry = WrongBookEntry.fromRow({
        'id': 'q1',
        'type': 1,
        'content': 'Test question',
        'options': '["A", "B"]',
        'standard_answer': 'A|||Exp',
        'bank_name': 'Test Bank',
      });

      final map = entry.toQuestionEditMap();
      expect(map['id'], 'q1');
      expect(map['type'], 1);
      expect(map['content'], 'Test question');
      expect(map['options'], '["A", "B"]');
      expect(map['standard_answer'], 'A|||Exp');
      expect(map['bank_name'], 'Test Bank');
    });
  });
}
