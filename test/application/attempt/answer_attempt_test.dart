import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/practice/record_answer_attempt_command.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/answer_attempt_repository.dart';
import 'package:shiroha_quiz/domain/attempt/answer_attempt.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    tempDir = await Directory.systemTemp.createTemp('attempt_test_');
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('AnswerAttemptPayload', () {
    test('choice payload creates valid json and passes validation', () {
      final json = AnswerAttemptPayload.choice(
        optionIds: <String>['opt_1', 'opt_2'],
      );
      expect(() => AnswerAttemptPayload.validatePayloadJson(json),
          returnsNormally);
    });

    test('choice payload rejects empty or blank optionIds', () {
      expect(
        () => AnswerAttemptPayload.choice(optionIds: <String>[]),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => AnswerAttemptPayload.choice(optionIds: <String>[' ']),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('legacy choice payload creates valid json and passes validation', () {
      final json = AnswerAttemptPayload.legacyChoice(labels: <String>['A']);
      expect(() => AnswerAttemptPayload.validatePayloadJson(json),
          returnsNormally);
    });

    test('legacy choice payload rejects empty labels', () {
      expect(
        () => AnswerAttemptPayload.legacyChoice(labels: <String>[]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('text payload creates valid json and passes validation', () {
      final json = AnswerAttemptPayload.text(text: 'My answer');
      expect(() => AnswerAttemptPayload.validatePayloadJson(json),
          returnsNormally);
    });

    test('text payload rejects blank text', () {
      expect(
        () => AnswerAttemptPayload.text(text: '   '),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('validatePayloadJson rejects malformed json', () {
      expect(
        () => AnswerAttemptPayload.validatePayloadJson('not a json'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => AnswerAttemptPayload.validatePayloadJson('{"kind": "unknown"}'),
        throwsA(isA<FormatException>()),
      );
    });

    test(
        'validatePayloadJson and validateForModality reject unknown or invalid versions',
        () {
      expect(
        () => AnswerAttemptPayload.validatePayloadJson(
            '{"version": 999, "kind": "choice", "option_ids": ["opt_1"]}'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => AnswerAttemptPayload.validatePayloadJson(
            '{"version": 0, "kind": "choice", "option_ids": ["opt_1"]}'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => AnswerAttemptPayload.validatePayloadJson(
            '{"version": -1, "kind": "choice", "option_ids": ["opt_1"]}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('validateForModality enforces modality-kind invariant matching', () {
      final choicePayload =
          AnswerAttemptPayload.choice(optionIds: <String>['opt_1']);
      final legacyChoicePayload =
          AnswerAttemptPayload.legacyChoice(labels: <String>['A']);
      final textPayload = AnswerAttemptPayload.text(text: 'My answer');

      // Valid combinations
      expect(
        () => AnswerAttemptPayload.validateForModality(
            AnswerAttemptModality.choice, choicePayload),
        returnsNormally,
      );
      expect(
        () => AnswerAttemptPayload.validateForModality(
            AnswerAttemptModality.choice, legacyChoicePayload),
        returnsNormally,
      );
      expect(
        () => AnswerAttemptPayload.validateForModality(
            AnswerAttemptModality.text, textPayload),
        returnsNormally,
      );

      // Mismatched combinations
      expect(
        () => AnswerAttemptPayload.validateForModality(
            AnswerAttemptModality.choice, textPayload),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => AnswerAttemptPayload.validateForModality(
            AnswerAttemptModality.text, choicePayload),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => AnswerAttemptPayload.validateForModality(
            AnswerAttemptModality.text, legacyChoicePayload),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('AnswerAttempt domain and repository', () {
    test('records and retrieves attempts correctly', () async {
      final dbPath = p.join(tempDir.path, 'attempt_repo.db');
      await DatabaseHelper.instance.openPathForTesting(dbPath);

      final repo = AnswerAttemptRepository();
      final command = RecordAnswerAttemptCommand(repo);

      final attempt1 = AnswerAttempt(
        attemptId: 'att-1',
        questionId: 'q-100',
        sessionKind: AnswerAttemptSessionKind.normal,
        modality: AnswerAttemptModality.choice,
        answerPayloadJson: AnswerAttemptPayload.choice(optionIds: ['opt_a']),
        correctness: false,
        answeredAt: 1700000000,
        durationMs: 4500,
      );

      final attempt2 = AnswerAttempt(
        attemptId: 'att-2',
        questionId: 'q-100',
        sessionKind: AnswerAttemptSessionKind.normal,
        modality: AnswerAttemptModality.choice,
        answerPayloadJson: AnswerAttemptPayload.choice(optionIds: ['opt_b']),
        correctness: true,
        answeredAt: 1700000100,
        durationMs: 3200,
      );

      final attempt3 = AnswerAttempt(
        attemptId: 'att-3',
        questionId: 'q-200',
        sessionKind: AnswerAttemptSessionKind.focused,
        modality: AnswerAttemptModality.text,
        answerPayloadJson: AnswerAttemptPayload.text(text: 'Essay answer'),
        correctness: null,
        answeredAt: 1700000200,
        durationMs: 12000,
      );

      await command.recordAttempt(attempt1);
      await command.recordAttempt(attempt2);
      await command.recordAttempt(attempt3);

      final attemptsQ100 = await repo.getAttemptsForQuestion('q-100');
      expect(attemptsQ100, hasLength(2));
      expect(attemptsQ100[0], equals(attempt1));
      expect(attemptsQ100[1], equals(attempt2));

      final attemptsQ200 = await repo.getAttemptsForQuestion('q-200');
      expect(attemptsQ200, hasLength(1));
      expect(attemptsQ200[0], equals(attempt3));

      expect(await repo.countIncorrectQuestions(), 1);

      await repo.clearAllData();
      expect(await repo.getAttemptsForQuestion('q-100'), isEmpty);
      expect(await repo.getAttemptsForQuestion('q-200'), isEmpty);
      expect(await repo.countIncorrectQuestions(), 0);
    });

    test('command and repository enforce payload validation before persistence',
        () async {
      final dbPath = p.join(tempDir.path, 'attempt_validation.db');
      await DatabaseHelper.instance.openPathForTesting(dbPath);

      final repo = AnswerAttemptRepository();
      final command = RecordAnswerAttemptCommand(repo);

      // Mismatched modality and payload
      final badAttempt = AnswerAttempt(
        attemptId: 'att-bad-modal',
        questionId: 'q-bad',
        sessionKind: AnswerAttemptSessionKind.normal,
        modality: AnswerAttemptModality.choice,
        answerPayloadJson: AnswerAttemptPayload.text(text: 'text answer'),
        correctness: null,
        answeredAt: 1700000000,
      );

      expect(
        () => command.recordAttempt(badAttempt),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => repo.recordAttempt(badAttempt),
        throwsA(isA<FormatException>()),
      );

      // Malformed JSON
      final malformedAttempt = AnswerAttempt(
        attemptId: 'att-bad-json',
        questionId: 'q-bad',
        sessionKind: AnswerAttemptSessionKind.normal,
        modality: AnswerAttemptModality.text,
        answerPayloadJson: '{invalid json}',
        correctness: null,
        answeredAt: 1700000000,
      );

      expect(
        () => command.recordAttempt(malformedAttempt),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => repo.recordAttempt(malformedAttempt),
        throwsA(isA<FormatException>()),
      );

      // Verify zero attempts written
      expect(await repo.getAttemptsForQuestion('q-bad'), isEmpty);
    });
  });
}
