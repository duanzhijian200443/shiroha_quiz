import '../backup/backup_restore_gate.dart';

/// Persistence seam for the legacy subject-tree bank/folder writes.
abstract interface class QuestionBankFolderMutationPersistencePort {
  Future<void> addCustomFolder(String folderName);

  Future<void> updateBankFolder(String bankName, String folderName);
}

/// Application authority for subject-tree folder mutations.
final class QuestionBankFolderMutationCommand {
  const QuestionBankFolderMutationCommand(this._persistence);

  final QuestionBankFolderMutationPersistencePort _persistence;

  Future<void> addCustomFolder(String folderName) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _persistence.addCustomFolder(folderName),
    );
  }

  Future<void> updateBankFolder(String bankName, String folderName) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _persistence.updateBankFolder(bankName, folderName),
    );
  }
}
