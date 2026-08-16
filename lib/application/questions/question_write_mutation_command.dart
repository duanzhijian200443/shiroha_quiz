import '../backup/backup_restore_gate.dart';

/// Persistence seam for legacy question writes that are not part of the
/// typed import commit transaction.
abstract interface class QuestionWriteMutationPersistencePort {
  Future<void> saveQuestionsToBank({
    required String bankName,
    required String? folderName,
    required List<Map<String, dynamic>> questions,
  });

  Future<void> savePreviewQuestion(Map<String, dynamic> question);
}

/// Application authority for standalone question persistence.
final class QuestionWriteMutationCommand {
  const QuestionWriteMutationCommand(this._persistence);

  final QuestionWriteMutationPersistencePort _persistence;

  Future<void> saveQuestionsToBank({
    required String bankName,
    required String? folderName,
    required List<Map<String, dynamic>> questions,
  }) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _persistence.saveQuestionsToBank(
        bankName: bankName,
        folderName: folderName,
        questions: questions,
      ),
    );
  }

  Future<void> savePreviewQuestion(Map<String, dynamic> question) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _persistence.savePreviewQuestion(question),
    );
  }
}
