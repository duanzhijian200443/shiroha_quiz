import '../backup/backup_restore_gate.dart';

/// Persistence seam for the remaining legacy-question mutations.
///
/// The data repository implements this port, while Presentation only sees the
/// application command. The command owns the full B0 mutation lifetime so a
/// restore cannot begin between the UI action and the durable write.
abstract interface class QuestionMutationPersistencePort {
  Future<void> deleteQuestion(String id);

  Future<void> updateQuestion(Map<String, dynamic> question);
}

/// Application authority for legacy question delete/update operations.
final class QuestionMutationCommand {
  const QuestionMutationCommand(this._persistence);

  final QuestionMutationPersistencePort _persistence;

  Future<void> deleteQuestion(String id) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _persistence.deleteQuestion(id),
    );
  }

  Future<void> updateQuestion(Map<String, dynamic> question) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _persistence.updateQuestion(question),
    );
  }
}
