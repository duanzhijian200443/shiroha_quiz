import '../../domain/attempt/answer_attempt.dart';
import '../backup/backup_restore_gate.dart';

/// Persistence seam for appending answer attempts.
abstract interface class AnswerAttemptPersistencePort {
  /// Appends one answer attempt fact.
  Future<void> recordAttempt(AnswerAttempt attempt);
}

/// Application authority for recording one durable answer attempt fact.
final class RecordAnswerAttemptCommand {
  const RecordAnswerAttemptCommand(this._persistence);

  final AnswerAttemptPersistencePort _persistence;

  Future<void> recordAttempt(AnswerAttempt attempt) {
    AnswerAttemptPayload.validateForModality(
      attempt.modality,
      attempt.answerPayloadJson,
    );
    return BackupRestoreMutationGate.instance.runMutation(
      () => _persistence.recordAttempt(attempt),
    );
  }
}
