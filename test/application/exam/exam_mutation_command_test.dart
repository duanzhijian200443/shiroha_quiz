import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/exam/exam_mutation_command.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';

Matcher _restoreBlocked() => throwsA(
      isA<BackupException>().having(
        (error) => error.failure,
        'failure',
        BackupFailure.restoreBlocked,
      ),
    );

final class _ExamPersistence implements ExamMutationPersistencePort {
  int createCalls = 0;
  int deleteCalls = 0;
  int submitCalls = 0;
  int updateCalls = 0;
  int finishCalls = 0;

  Completer<void>? writeBlocker;

  Future<void> _blockIfNeeded() async {
    await writeBlocker?.future;
  }

  @override
  Future<String> createExamPaper(
    String title,
    int sourceType,
    List<Map<String, dynamic>> questions,
  ) async {
    createCalls++;
    await _blockIfNeeded();
    return 'paper-1';
  }

  @override
  Future<void> deleteExamPaper(String id) async {
    deleteCalls++;
    await _blockIfNeeded();
  }

  @override
  Future<List<Map<String, dynamic>>> submitExamPaper(
    String paperId,
    Map<int, dynamic> userAnswers,
    List<Map<String, dynamic>> questions,
  ) async {
    submitCalls++;
    await _blockIfNeeded();
    return const <Map<String, dynamic>>[];
  }

  @override
  Future<void> updateExamAiScore(
    String paperId,
    String questionId,
    String aiFeedback,
    double scoreRatio,
  ) async {
    updateCalls++;
    await _blockIfNeeded();
  }

  @override
  Future<void> finishExamGrading(String paperId) async {
    finishCalls++;
    await _blockIfNeeded();
  }
}

void main() {
  setUp(BackupRestoreMutationGate.resetForTesting);
  tearDown(BackupRestoreMutationGate.resetForTesting);

  test('all direct Exam mutations are blocked before persistence', () async {
    final persistence = _ExamPersistence();
    final command = ExamMutationCommand(persistence);

    await BackupRestoreMutationGate.instance.enterQuiescence();

    await expectLater(
      command.createExamPaper(
        'Synthetic exam',
        0,
        const <Map<String, dynamic>>[],
      ),
      _restoreBlocked(),
    );
    await expectLater(command.deleteExamPaper('paper-1'), _restoreBlocked());
    await expectLater(
      command.submitExamPaper('paper-1', const <int, dynamic>{}, const []),
      _restoreBlocked(),
    );
    await expectLater(
      command.updateExamAiScore('paper-1', 'question-1', 'feedback', 0.5),
      _restoreBlocked(),
    );
    await expectLater(command.finishExamGrading('paper-1'), _restoreBlocked());
    await expectLater(
      command.gradeSubjectiveAnswers(
        paperId: 'paper-1',
        tasks: const <ExamSubjectiveTask>[],
        judge: (_) async => const ExamSubjectiveGrade(
          feedback: 'feedback',
          scoreRatio: 0.5,
        ),
      ),
      _restoreBlocked(),
    );

    expect(persistence.createCalls, 0);
    expect(persistence.deleteCalls, 0);
    expect(persistence.submitCalls, 0);
    expect(persistence.updateCalls, 0);
    expect(persistence.finishCalls, 0);
    BackupRestoreMutationGate.instance.exitQuiescence();
  });

  test('subjective grading holds lease across judge and terminal writes',
      () async {
    final persistence = _ExamPersistence();
    final judgeRelease = Completer<ExamSubjectiveGrade?>();
    final command = ExamMutationCommand(persistence);
    var judgeCalls = 0;

    final pending = command.gradeSubjectiveAnswers(
      paperId: 'paper-1',
      tasks: const <ExamSubjectiveTask>[
        ExamSubjectiveTask(
          questionId: 'question-1',
          question: 'Question',
          standardAnswer: 'Answer',
          userAnswer: 'User answer',
        ),
      ],
      judge: (_) {
        judgeCalls++;
        return judgeRelease.future;
      },
    );

    await Future<void>.delayed(Duration.zero);
    expect(judgeCalls, 1);
    expect(BackupRestoreMutationGate.instance.activeMutationCount, 1);

    final drained = BackupRestoreMutationGate.instance.enterQuiescence();
    var drainCompleted = false;
    unawaited(drained.then((_) => drainCompleted = true));
    await Future<void>.delayed(Duration.zero);
    expect(drainCompleted, isFalse);

    judgeRelease.complete(const ExamSubjectiveGrade(
      feedback: 'Correct: 80',
      scoreRatio: 0.8,
    ));
    await pending;
    await drained;

    expect(persistence.updateCalls, 1);
    expect(persistence.finishCalls, 1);
    expect(BackupRestoreMutationGate.instance.activeMutationCount, 0);
    BackupRestoreMutationGate.instance.exitQuiescence();
  });

  test('subjective grading failure releases the lease', () async {
    final command = ExamMutationCommand(_ExamPersistence());

    await expectLater(
      command.gradeSubjectiveAnswers(
        paperId: 'paper-1',
        tasks: const <ExamSubjectiveTask>[
          ExamSubjectiveTask(
            questionId: 'question-1',
            question: 'Question',
            standardAnswer: 'Answer',
            userAnswer: 'User answer',
          ),
        ],
        judge: (_) async => throw StateError('synthetic judge failure'),
      ),
      throwsA(isA<StateError>()),
    );
    expect(BackupRestoreMutationGate.instance.activeMutationCount, 0);
  });
}
