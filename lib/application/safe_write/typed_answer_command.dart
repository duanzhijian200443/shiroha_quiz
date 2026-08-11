import '../../domain/question/question_draft_v2.dart';

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
    return _port.updateTypedAnswer(
      storageId: storageId,
      expectedDraft: expectedDraft,
      newAnswer: newAnswer,
    );
  }
}
