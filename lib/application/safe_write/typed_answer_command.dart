import '../../domain/question/question_draft_v2.dart';
import '../backup/backup_restore_gate.dart';

/// Application seam for typed manual answer mutations (replace / clear /
/// valid no-op) shared by Presentation and future W0 proposal flows.
///
/// The generic mutation semantics deliberately live here and in the shared
/// persistence kernel: this command never narrows manual repair to a
/// fill-missing-answer behavior. W0's fill-only policy belongs to the
/// proposal layer, not to this command or its port.
abstract interface class TypedAnswerPersistencePort {
  /// Applies one answer-only typed mutation for [storageId] when the current
  /// persisted draft structurally equals [expectedDraft].
  ///
  /// [newAnswer] may be a replacement, a content answer, or null (clear).
  /// Implementations enforce the full structural compare-and-set, choice
  /// validation, privacy admission and atomic sidecar/V1 projection update
  /// inside one caller-owned transaction.
  Future<void> updateTypedAnswer({
    required String storageId,
    required QuestionDraftV2 expectedDraft,
    required QuestionAnswer? newAnswer,
  });
}

/// Shared typed-answer use case: forwards one exact answer mutation to the
/// [TypedAnswerPersistencePort]. Keeps Presentation and future proposal
/// flows on the same application seam instead of reaching repositories.
final class TypedAnswerCommand {
  const TypedAnswerCommand(this._port);

  final TypedAnswerPersistencePort _port;

  Future<void> updateTypedAnswer({
    required String storageId,
    required QuestionDraftV2 expectedDraft,
    required QuestionAnswer? newAnswer,
  }) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _port.updateTypedAnswer(
        storageId: storageId,
        expectedDraft: expectedDraft,
        newAnswer: newAnswer,
      ),
    );
  }
}

/// Application-owned failure taxonomy for typed answer mutations.
///
/// This is the single authoritative typed mutation failure contract shared by
/// the persistence port, the command, and future Presentation/Agent callers.
/// It never exposes SQL, raw payloads, paths, storage identity, provider, or
/// internal exception detail; data adapters map persistence-specific failures
/// onto this contract at the boundary.
enum TypedAnswerMutationFailure {
  notFound,
  notTyped,
  stale,
  corruptPayload,
  invalidAnswer,
  unsafePayload,
  transactionFailed,
}

/// Raised when a typed manual answer mutation cannot be applied atomically.
/// The exception retains no raw cause, message, SQL, payload, path, storage
/// id, bank, or user content.
final class TypedAnswerMutationException implements Exception {
  const TypedAnswerMutationException(this.failure);

  final TypedAnswerMutationFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      TypedAnswerMutationFailure.notFound =>
        'The typed question cannot be found.',
      TypedAnswerMutationFailure.notTyped =>
        'The question is not stored as a typed question.',
      TypedAnswerMutationFailure.stale =>
        'The question changed after it was loaded.',
      TypedAnswerMutationFailure.corruptPayload =>
        'The typed question payload cannot be read safely.',
      TypedAnswerMutationFailure.invalidAnswer =>
        'The answer does not match the typed question options.',
      TypedAnswerMutationFailure.unsafePayload =>
        'The typed answer contains unsafe content.',
      TypedAnswerMutationFailure.transactionFailed =>
        'The typed answer cannot be saved atomically.',
    };
    return 'TypedAnswerMutationException(${failure.name}): $detail';
  }
}
