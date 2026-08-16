import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/questions/question_mutation_command.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';

final class _RecordingQuestionPersistence
    implements QuestionMutationPersistencePort {
  int deleteCalls = 0;
  int updateCalls = 0;
  Object? failure;

  @override
  Future<void> deleteQuestion(String id) async {
    deleteCalls++;
    final error = failure;
    if (error != null) throw error;
  }

  @override
  Future<void> updateQuestion(Map<String, dynamic> question) async {
    updateCalls++;
    final error = failure;
    if (error != null) throw error;
  }
}

void main() {
  setUp(BackupRestoreMutationGate.resetForTesting);
  tearDown(BackupRestoreMutationGate.resetForTesting);

  test('maintenance blocks question delete and update before persistence',
      () async {
    final persistence = _RecordingQuestionPersistence();
    final command = QuestionMutationCommand(persistence);
    await BackupRestoreMutationGate.instance.enterQuiescence();

    await expectLater(
      command.deleteQuestion('question-1'),
      throwsA(isA<BackupException>().having(
        (error) => error.failure,
        'failure',
        BackupFailure.restoreBlocked,
      )),
    );
    await expectLater(
      command.updateQuestion(<String, dynamic>{'id': 'question-1'}),
      throwsA(isA<BackupException>().having(
        (error) => error.failure,
        'failure',
        BackupFailure.restoreBlocked,
      )),
    );

    expect(persistence.deleteCalls, 0);
    expect(persistence.updateCalls, 0);
    BackupRestoreMutationGate.instance.exitQuiescence();
  });

  test('question mutation failure releases its lease', () async {
    final persistence = _RecordingQuestionPersistence()
      ..failure = StateError('synthetic persistence failure');
    final command = QuestionMutationCommand(persistence);

    await expectLater(
      command.deleteQuestion('question-1'),
      throwsA(isA<StateError>()),
    );
    expect(BackupRestoreMutationGate.instance.activeMutationCount, 0);
  });
}
