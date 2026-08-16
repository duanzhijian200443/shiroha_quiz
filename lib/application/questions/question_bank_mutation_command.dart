import '../backup/backup_restore_gate.dart';

/// Persistence seam for destructive question-bank mutations.
abstract interface class QuestionBankMutationPersistencePort {
  Future<void> deleteQuestionBank(String bankName);
}

/// Application authority for deleting a complete question bank.
final class QuestionBankMutationCommand {
  const QuestionBankMutationCommand(this._persistence);

  final QuestionBankMutationPersistencePort _persistence;

  Future<void> deleteQuestionBank(String bankName) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _persistence.deleteQuestionBank(bankName),
    );
  }
}
