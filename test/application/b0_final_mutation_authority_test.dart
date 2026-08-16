import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/latex_migration/latex_migration_mutation_command.dart';
import 'package:shiroha_quiz/application/practice/practice_session_mutation_command.dart';
import 'package:shiroha_quiz/application/questions/question_bank_folder_mutation_command.dart';
import 'package:shiroha_quiz/application/questions/question_bank_mutation_command.dart';
import 'package:shiroha_quiz/application/questions/question_write_mutation_command.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';

final class _PomodoroPersistence
    implements PracticeSessionMutationPersistencePort {
  int calls = 0;
  Completer<void>? blocker;

  @override
  Future<void> insertPomodoroSession(Map<String, dynamic> session) async {
    calls++;
    await blocker?.future;
  }
}

final class _BankPersistence implements QuestionBankMutationPersistencePort {
  int calls = 0;

  @override
  Future<void> deleteQuestionBank(String bankName) async {
    calls++;
  }
}

final class _FolderPersistence
    implements QuestionBankFolderMutationPersistencePort {
  int createCalls = 0;
  int moveCalls = 0;

  @override
  Future<void> addCustomFolder(String folderName) async {
    createCalls++;
  }

  @override
  Future<void> updateBankFolder(String bankName, String folderName) async {
    moveCalls++;
  }
}

final class _QuestionWritePersistence
    implements QuestionWriteMutationPersistencePort {
  int bankCalls = 0;
  int previewCalls = 0;

  @override
  Future<void> saveQuestionsToBank({
    required String bankName,
    required String? folderName,
    required List<Map<String, dynamic>> questions,
  }) async {
    bankCalls++;
  }

  @override
  Future<void> savePreviewQuestion(Map<String, dynamic> question) async {
    previewCalls++;
  }
}

Matcher _restoreBlocked() => throwsA(
      isA<BackupException>().having(
        (error) => error.failure,
        'failure',
        BackupFailure.restoreBlocked,
      ),
    );

void main() {
  setUp(BackupRestoreMutationGate.resetForTesting);
  tearDown(BackupRestoreMutationGate.resetForTesting);

  test('durable legacy writes are blocked in maintenance', () async {
    final pomodoro = _PomodoroPersistence();
    final bank = _BankPersistence();
    final folder = _FolderPersistence();
    final questionWrite = _QuestionWritePersistence();

    await BackupRestoreMutationGate.instance.enterQuiescence();

    await expectLater(
      PracticeSessionMutationCommand(pomodoro).insertPomodoroSession(
        <String, dynamic>{'id': 'session-1'},
      ),
      _restoreBlocked(),
    );
    await expectLater(
      QuestionBankMutationCommand(bank).deleteQuestionBank('bank-1'),
      _restoreBlocked(),
    );
    await expectLater(
      QuestionBankFolderMutationCommand(folder).addCustomFolder('folder-1'),
      _restoreBlocked(),
    );
    await expectLater(
      QuestionBankFolderMutationCommand(folder).updateBankFolder(
        'bank-1',
        'folder-1',
      ),
      _restoreBlocked(),
    );
    await expectLater(
      QuestionWriteMutationCommand(questionWrite).saveQuestionsToBank(
        bankName: 'bank-1',
        folderName: null,
        questions: const <Map<String, dynamic>>[
          <String, dynamic>{'content': 'synthetic'},
        ],
      ),
      _restoreBlocked(),
    );
    await expectLater(
      QuestionWriteMutationCommand(questionWrite).savePreviewQuestion(
        <String, dynamic>{'content': 'synthetic'},
      ),
      _restoreBlocked(),
    );

    expect(pomodoro.calls, 0);
    expect(bank.calls, 0);
    expect(folder.createCalls, 0);
    expect(folder.moveCalls, 0);
    expect(questionWrite.bankCalls, 0);
    expect(questionWrite.previewCalls, 0);
    BackupRestoreMutationGate.instance.exitQuiescence();
  });

  test('an active migration holds the lease through its terminal future',
      () async {
    final release = Completer<void>();
    final migration = const LatexMigrationMutationCommand().run(
      () => release.future,
    );

    await Future<void>.delayed(Duration.zero);
    expect(BackupRestoreMutationGate.instance.activeMutationCount, 1);

    final drained = BackupRestoreMutationGate.instance.enterQuiescence();
    var drainCompleted = false;
    unawaited(drained.then((_) => drainCompleted = true));
    await Future<void>.delayed(Duration.zero);
    expect(drainCompleted, isFalse);
    await expectLater(
      const LatexMigrationMutationCommand().run(() async {}),
      _restoreBlocked(),
    );

    release.complete();
    await migration;
    await drained;
    expect(drainCompleted, isTrue);
    expect(BackupRestoreMutationGate.instance.activeMutationCount, 0);
    BackupRestoreMutationGate.instance.exitQuiescence();
  });

  test('migration success and failure both release the lease', () async {
    await const LatexMigrationMutationCommand().run(() async {});
    expect(BackupRestoreMutationGate.instance.activeMutationCount, 0);

    await expectLater(
      const LatexMigrationMutationCommand().run(() async {
        throw StateError('synthetic migration failure');
      }),
      throwsA(isA<StateError>()),
    );
    expect(BackupRestoreMutationGate.instance.activeMutationCount, 0);
  });
}
