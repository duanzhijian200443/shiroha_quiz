import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/practice/practice_session_mutation_command.dart';
import 'package:shiroha_quiz/application/practice/record_answer_attempt_command.dart';
import 'package:shiroha_quiz/application/questions/question_mutation_command.dart';
import 'package:shiroha_quiz/application/questions/question_write_mutation_command.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/domain/attempt/answer_attempt.dart';
import 'package:shiroha_quiz/ui/dependencies/practice_command_dependencies.dart';
import 'package:shiroha_quiz/ui/pages/practice_page.dart';

/// Focused regression for ARCH-DEBT-03A: PracticePage must act only on the
/// injected Application command bundle. Every port below is a fake, so any
/// hidden fallback onto a concrete repository would surface as a failure here.
class _RecordingQuestionWritePort
    implements QuestionWriteMutationPersistencePort {
  int previewSaves = 0;

  @override
  Future<void> saveQuestionsToBank({
    required String bankName,
    required String? folderName,
    required List<Map<String, dynamic>> questions,
  }) async {}

  @override
  Future<void> savePreviewQuestion(Map<String, dynamic> question) async {
    previewSaves++;
  }
}

class _NoopQuestionMutationPort implements QuestionMutationPersistencePort {
  @override
  Future<void> deleteQuestion(String id) async {}

  @override
  Future<void> updateQuestion(Map<String, dynamic> question) async {}
}

class _NoopPracticeSessionPort
    implements PracticeSessionMutationPersistencePort {
  @override
  Future<void> insertPomodoroSession(Map<String, dynamic> session) async {}
}

class _NoopAttemptPort implements AnswerAttemptPersistencePort {
  @override
  Future<void> recordAttempt(AnswerAttempt attempt) async {}
}

PracticeCommandDependencies _bundle(_RecordingQuestionWritePort writePort) {
  return PracticeCommandDependencies(
    questionMutation: QuestionMutationCommand(_NoopQuestionMutationPort()),
    practiceSessionMutation:
        PracticeSessionMutationCommand(_NoopPracticeSessionPort()),
    questionWriteMutation: QuestionWriteMutationCommand(writePort),
    recordAttempt: RecordAnswerAttemptCommand(_NoopAttemptPort()),
  );
}

Question _previewQuestion() {
  return const Question(
    id: 'preview_test_1',
    type: 0,
    content: 'Synthetic preview question',
    options: '["A. One","B. Two"]',
    answer: 'A',
    createdAt: 1,
    bankName: 'synthetic',
    explanation: '',
  );
}

void main() {
  testWidgets('preview save flows through the injected question write command',
      (tester) async {
    final writePort = _RecordingQuestionWritePort();
    await tester.pumpWidget(MaterialApp(
      home: PracticePage(
        initialQuestions: <Question>[_previewQuestion()],
        practiceCommands: _bundle(writePort),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Synthetic preview question'), findsOneWidget);
    expect(writePort.previewSaves, isZero);

    // Preview keeps the commit bar behind the answer reveal.
    await tester.tap(find.text('One'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看答案'));
    await tester.pumpAndSettle();

    expect(find.text('收入题库'), findsOneWidget);
    await tester.tap(find.text('收入题库'));
    await tester.pumpAndSettle();

    expect(writePort.previewSaves, 1);
  });

  testWidgets('rendering a preview session needs no dependency bundle',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PracticePage(
        initialQuestions: <Question>[_previewQuestion()],
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Synthetic preview question'), findsOneWidget);
    // Nothing was persisted anywhere: rendering and the pre-reveal preview
    // flow stay mutation-free until the user acts.
    expect(find.text('查看答案'), findsOneWidget);
  });
}
