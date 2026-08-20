import '../../domain/backup/backup_manifest.dart';
import '../backup/backup_restore_gate.dart';
import '../observability/destructive_mutation_trace.dart';

enum QuestionBankDeleteFailure {
  examReferenced,
  unavailable,
  transactionFailed,
}

final class QuestionBankDeleteException implements Exception {
  const QuestionBankDeleteException(this.failure);

  final QuestionBankDeleteFailure failure;

  @override
  String toString() => 'QuestionBankDeleteException(${failure.name})';
}

/// Persistence seam for destructive question-bank mutations.
abstract interface class QuestionBankMutationPersistencePort {
  Future<void> deleteQuestionBank(String bankName);
}

/// Application authority for deleting a complete question bank.
final class QuestionBankMutationCommand {
  const QuestionBankMutationCommand(this._persistence);

  final QuestionBankMutationPersistencePort _persistence;

  Future<void> deleteQuestionBank(String bankName) async {
    try {
      await DestructiveMutationTrace.run<void>(
        kind: DestructiveMutationKind.questionBankDelete,
        action: () => BackupRestoreMutationGate.instance.runMutation(
          () => _persistence.deleteQuestionBank(bankName),
        ),
      );
    } on QuestionBankDeleteException {
      rethrow;
    } on BackupException {
      rethrow;
    } catch (_) {
      throw const QuestionBankDeleteException(
        QuestionBankDeleteFailure.transactionFailed,
      );
    }
  }
}
