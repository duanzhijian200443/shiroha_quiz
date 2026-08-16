import '../../domain/answers/answer_candidate.dart';
import '../backup/backup_restore_gate.dart';
import 'answer_candidate_review_session.dart';

/// Safe typed failures of the P7-C0 confirmation/commit boundary.
///
/// Semantics stay inside the frozen P7 taxonomy: forged/uncommittable
/// confirmations map to `candidateNotCommittable`, terminal decided
/// candidates to `candidateAlreadyDecided`, durable target drift to
/// `staleTarget`, database/transaction failure to `persistenceFailed`, and
/// unexpected local failure to `internalError`. No new public taxonomy is
/// introduced for the transient session revision.
enum AiAnswerCommitFailure {
  candidateNotCommittable,
  candidateAlreadyDecided,
  staleTarget,
  persistenceFailed,
  internalError,
}

final class AiAnswerCommitException implements Exception {
  const AiAnswerCommitException(this.failure);

  final AiAnswerCommitFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      AiAnswerCommitFailure.candidateNotCommittable =>
        'The answer candidate is not committable.',
      AiAnswerCommitFailure.candidateAlreadyDecided =>
        'The answer candidate already reached a terminal outcome.',
      AiAnswerCommitFailure.staleTarget =>
        'The durable target changed after confirmation.',
      AiAnswerCommitFailure.persistenceFailed =>
        'The answer could not be persisted.',
      AiAnswerCommitFailure.internalError =>
        'Answer commit encountered an internal error.',
    };
    return 'AiAnswerCommitException(${failure.name}): $detail';
  }
}

/// Narrow P7 persistence port.
///
/// Implementations open exactly one caller-owned SQLite transaction that
/// revalidates the durable typed target (bank, complete draft, write-intent
/// precondition) and then reuses the existing
/// `TypedAnswerPersistenceKernel` in the same transaction. Only
/// `candidate.answer` may enter formal persistence.
abstract interface class AiAnswerCommitPersistencePort {
  Future<void> commitAnswer(AnswerCandidate candidate);
}

/// P7-C0 Application confirmation/commit command.
///
/// The command owns the deterministic local confirmation boundary: every
/// review-state/revision validation happens here, before any durable
/// transaction opens. The committed session is derived locally BEFORE
/// persistence; it is returned only after persistence succeeds, so a
/// write-success-then-local-failure ambiguous window cannot exist and a
/// failed persistence never looks like success (the caller keeps its
/// confirmed session and may retry safely).
final class AiAnswerCommitCommand {
  const AiAnswerCommitCommand({required this.persistencePort});

  final AiAnswerCommitPersistencePort persistencePort;

  Future<AnswerCandidateReviewSession> commit({
    required AnswerCandidateReviewSession session,
    required AnswerCandidateConfirmation confirmation,
  }) async {
    BackupRestoreMutationGate.instance.ensureMutationAllowed();

    // 1. Deterministic local review-state validation (no transaction yet):
    //    exact revision, exact canonical candidate, confirmed outcome.
    final AnswerCandidate candidate;
    try {
      candidate = session.requireValidConfirmation(confirmation).candidate;
    } on AnswerCandidateReviewException catch (error) {
      throw AiAnswerCommitException(_mapReviewFailure(error.failure));
    }

    // 2. Producer gate: only AI-origin candidates commit through this path.
    if (candidate.origin is! AiAnswerOrigin) {
      throw const AiAnswerCommitException(
        AiAnswerCommitFailure.candidateNotCommittable,
      );
    }

    // 3. Precompute the committed session locally; returned only after
    //    persistence succeeds.
    final AnswerCandidateReviewSession committed;
    try {
      committed = session.markCommitted(candidate.candidateId);
    } on AnswerCandidateReviewException catch (error) {
      throw AiAnswerCommitException(_mapReviewFailure(error.failure));
    }

    // 4. Durable transactional revalidation + answer-only mutation.
    try {
      await persistencePort.commitAnswer(candidate);
    } on AiAnswerCommitException {
      rethrow;
    } catch (_) {
      throw const AiAnswerCommitException(
        AiAnswerCommitFailure.internalError,
      );
    }

    return committed;
  }

  AiAnswerCommitFailure _mapReviewFailure(
    AnswerCandidateReviewFailure failure,
  ) {
    return switch (failure) {
      AnswerCandidateReviewFailure.unknownCandidate ||
      AnswerCandidateReviewFailure.staleSessionRevision ||
      AnswerCandidateReviewFailure.noOpTerminal ||
      AnswerCandidateReviewFailure.fillOnlyForMissingAnswers ||
      AnswerCandidateReviewFailure.replaceFlowRequired ||
      AnswerCandidateReviewFailure.notConfirmed =>
        AiAnswerCommitFailure.candidateNotCommittable,
      AnswerCandidateReviewFailure.alreadyDecided =>
        AiAnswerCommitFailure.candidateAlreadyDecided,
    };
  }
}
