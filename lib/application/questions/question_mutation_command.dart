import '../../domain/backup/backup_manifest.dart';
import '../backup/backup_restore_gate.dart';
import '../observability/destructive_mutation_trace.dart';

enum QuestionDeleteFailure {
  examReferenced,
  unavailable,
  transactionFailed,
}

final class QuestionDeleteException implements Exception {
  const QuestionDeleteException(this.failure);

  final QuestionDeleteFailure failure;

  @override
  String toString() => 'QuestionDeleteException(${failure.name})';
}

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

  Future<void> deleteQuestion(String id) async {
    try {
      await DestructiveMutationTrace.run<void>(
        kind: DestructiveMutationKind.questionDelete,
        action: () => BackupRestoreMutationGate.instance.runMutation(
          () => _persistence.deleteQuestion(id),
        ),
      );
    } on QuestionDeleteException {
      rethrow;
    } on BackupException {
      rethrow;
    } catch (_) {
      throw const QuestionDeleteException(
        QuestionDeleteFailure.transactionFailed,
      );
    }
  }

  Future<void> updateQuestion(Map<String, dynamic> question) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _persistence.updateQuestion(question),
    );
  }
}
