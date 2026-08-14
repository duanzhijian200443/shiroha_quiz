import '../../domain/answers/answer_candidate.dart';
import '../../domain/supplemental_answers/answer_match_record.dart';
import '../../domain/supplemental_answers/supplemental_answer_scope.dart';
import '../answers/answer_candidate_review_session.dart';
import 'supplemental_answer_matcher.dart';
import 'target_question_snapshot_service.dart';

/// The producer-neutral review outcome enum re-exported from the shared
/// review-decision core so existing P6 importers keep compiling.
export '../answers/answer_candidate_review_session.dart'
    show CandidateReviewOutcome;

/// Safe failure taxonomy of the transient P6 review lifecycle.
enum SupplementalAnswerReviewFailure {
  unknownCandidate,
  staleSessionRevision,
  ambiguousNotCommittable,
  unmatchedNotCommittable,
  invalidNotCommittable,
  conflictRequiresReplaceReconfirmation,
  fillOnlyForMissingAnswers,
  noOpTerminal,
  alreadyDecided,
}

final class SupplementalAnswerReviewException implements Exception {
  const SupplementalAnswerReviewException(this.failure);

  final SupplementalAnswerReviewFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      SupplementalAnswerReviewFailure.unknownCandidate =>
        'The candidate is not part of this review session.',
      SupplementalAnswerReviewFailure.staleSessionRevision =>
        'The review session changed after it was loaded.',
      SupplementalAnswerReviewFailure.ambiguousNotCommittable =>
        'Ambiguous matches are never committable.',
      SupplementalAnswerReviewFailure.unmatchedNotCommittable =>
        'Unmatched fragments are never committable.',
      SupplementalAnswerReviewFailure.invalidNotCommittable =>
        'Invalid candidates are never committable.',
      SupplementalAnswerReviewFailure.conflictRequiresReplaceReconfirmation =>
        'Conflicts require per-question replace reconfirmation.',
      SupplementalAnswerReviewFailure.fillOnlyForMissingAnswers =>
        'Fill confirmation applies only to missing answers.',
      SupplementalAnswerReviewFailure.noOpTerminal =>
        'Equivalent candidates are terminal no-op outcomes.',
      SupplementalAnswerReviewFailure.alreadyDecided =>
        'The candidate already reached a terminal review outcome.',
    };
    return 'SupplementalAnswerReviewException(${failure.name}): $detail';
  }
}

/// One exact confirmation request produced by the P6 review session.
///
/// The confirmation carries the candidate plus the exact session revision;
/// C0 revalidates both inside the linearized write boundary.
final class SupplementalAnswerConfirmation {
  const SupplementalAnswerConfirmation({
    required this.candidate,
    required this.sessionRevision,
  });

  final AnswerCandidate candidate;
  final int sessionRevision;
}

/// P6-facing adapter over the shared producer-neutral review-decision core.
///
/// The canonical transition state machine lives in
/// [AnswerCandidateReviewSession]; this adapter keeps the P6 surface
/// (`request` / `snapshot` / `matchResult` / `records` / `outcomes` /
/// `sessionRevision` / `outcomeOf` / `confirmFill` / `selectForReplace` /
/// `confirmReplace` / `reject` / `markCommitted`) and enforces the P6
/// eligibility rules that are producer-specific: matched/fill only for fill
/// confirmation, conflict/replace only for the replacement flow, and
/// ambiguous/unmatched/invalid never committable.
///
/// Everything is transient and lost on process exit. `sessionRevision`
/// increments on every review decision, and confirmations must carry the
/// exact revision to protect against stale review state.
final class SupplementalAnswerReviewSession {
  factory SupplementalAnswerReviewSession({
    required SupplementalAnswerMatchRequest request,
    required TargetQuestionSnapshot snapshot,
    required SupplementalMatchResult matchResult,
  }) {
    return SupplementalAnswerReviewSession._(
      request: request,
      snapshot: snapshot,
      matchResult: matchResult,
      core: AnswerCandidateReviewSession(
        candidates: <AnswerCandidate>[
          for (final record in matchResult.records)
            if (record.candidate case final candidate?) candidate,
        ],
      ),
    );
  }

  const SupplementalAnswerReviewSession._({
    required this.request,
    required this.snapshot,
    required this.matchResult,
    required this.core,
  });

  final SupplementalAnswerMatchRequest request;
  final TargetQuestionSnapshot snapshot;
  final SupplementalMatchResult matchResult;
  final AnswerCandidateReviewSession core;

  List<AnswerMatchRecord> get records => matchResult.records;

  Map<String, CandidateReviewOutcome> get outcomes => core.outcomes;

  int get sessionRevision => core.sessionRevision;

  CandidateReviewOutcome outcomeOf(String candidateId) {
    return core.outcomeOf(candidateId);
  }

  /// Confirms one fill candidate. Only `matched` records with a `fill` write
  /// intent are committable through this path. Returns the next session plus
  /// the exact confirmation bound to the new session revision.
  ({
    SupplementalAnswerReviewSession session,
    SupplementalAnswerConfirmation confirmation,
  }) confirmFill(String candidateId) {
    final candidate = _candidate(candidateId);
    if (candidate.writeIntent != CandidateWriteIntent.fill) {
      throw SupplementalAnswerReviewException(
        switch (candidate.writeIntent) {
          CandidateWriteIntent.replace => SupplementalAnswerReviewFailure
              .conflictRequiresReplaceReconfirmation,
          CandidateWriteIntent.noOp =>
            SupplementalAnswerReviewFailure.noOpTerminal,
          CandidateWriteIntent.fill =>
            SupplementalAnswerReviewFailure.fillOnlyForMissingAnswers,
        },
      );
    }
    final record = _recordFor(candidateId);
    if (record.disposition != AnswerMatchDisposition.matched) {
      throw SupplementalAnswerReviewException(
        _notCommittableFailure(record.disposition),
      );
    }
    final decided = _run(() => core.confirmFill(candidateId));
    return (
      session: _wrap(decided.session),
      confirmation: SupplementalAnswerConfirmation(
        candidate: decided.confirmation.candidate,
        sessionRevision: decided.confirmation.sessionRevision,
      ),
    );
  }

  /// First step of the per-question replace review for one conflict.
  SupplementalAnswerReviewSession selectForReplace(String candidateId) {
    final candidate = _candidate(candidateId);
    final record = _recordFor(candidateId);
    if (record.disposition != AnswerMatchDisposition.conflict ||
        candidate.writeIntent != CandidateWriteIntent.replace) {
      throw SupplementalAnswerReviewException(
        SupplementalAnswerReviewFailure.conflictRequiresReplaceReconfirmation,
      );
    }
    return _wrap(_run(() => core.selectForReplace(candidateId)));
  }

  /// Second, explicit per-question reconfirmation of a conflict replace.
  /// Only the selected/armed replacement may be confirmed; a direct
  /// `confirmReplace` on an unselected replacement fails safely.
  /// Returns the next session plus the exact confirmation.
  ({
    SupplementalAnswerReviewSession session,
    SupplementalAnswerConfirmation confirmation,
  }) confirmReplace(String candidateId) {
    final candidate = _candidate(candidateId);
    if (candidate.writeIntent != CandidateWriteIntent.replace) {
      throw SupplementalAnswerReviewException(
        SupplementalAnswerReviewFailure.conflictRequiresReplaceReconfirmation,
      );
    }
    final decided = _run(() => core.confirmReplace(candidateId));
    return (
      session: _wrap(decided.session),
      confirmation: SupplementalAnswerConfirmation(
        candidate: decided.confirmation.candidate,
        sessionRevision: decided.confirmation.sessionRevision,
      ),
    );
  }

  /// Explicit rejection: terminal with zero mutation.
  SupplementalAnswerReviewSession reject(String candidateId) {
    _candidate(candidateId);
    return _wrap(_run(() => core.reject(candidateId)));
  }

  /// Marks one confirmed candidate as committed after C0 succeeded.
  SupplementalAnswerReviewSession markCommitted(String candidateId) {
    _candidate(candidateId);
    return _wrap(_run(() => core.markCommitted(candidateId)));
  }

  AnswerCandidate _candidate(String candidateId) {
    final record = matchResult.records
        .where((record) => record.candidate?.candidateId == candidateId)
        .toList(growable: false);
    if (record.length != 1) {
      throw SupplementalAnswerReviewException(
        SupplementalAnswerReviewFailure.unknownCandidate,
      );
    }
    return record.single.candidate!;
  }

  AnswerMatchRecord _recordFor(String candidateId) {
    return matchResult.records.singleWhere(
      (record) => record.candidate?.candidateId == candidateId,
    );
  }

  /// Runs one core transition and maps its typed failures onto the P6
  /// taxonomy; no raw core exception can escape the adapter.
  T _run<T>(T Function() action) {
    try {
      return action();
    } on AnswerCandidateReviewException catch (error) {
      throw SupplementalAnswerReviewException(
        _mapReviewFailure(error.failure),
      );
    }
  }

  static SupplementalAnswerReviewFailure _mapReviewFailure(
    AnswerCandidateReviewFailure failure,
  ) {
    return switch (failure) {
      AnswerCandidateReviewFailure.unknownCandidate =>
        SupplementalAnswerReviewFailure.unknownCandidate,
      AnswerCandidateReviewFailure.staleSessionRevision =>
        SupplementalAnswerReviewFailure.staleSessionRevision,
      AnswerCandidateReviewFailure.alreadyDecided =>
        SupplementalAnswerReviewFailure.alreadyDecided,
      AnswerCandidateReviewFailure.noOpTerminal =>
        SupplementalAnswerReviewFailure.noOpTerminal,
      AnswerCandidateReviewFailure.fillOnlyForMissingAnswers =>
        SupplementalAnswerReviewFailure.fillOnlyForMissingAnswers,
      AnswerCandidateReviewFailure.replaceFlowRequired =>
        SupplementalAnswerReviewFailure.conflictRequiresReplaceReconfirmation,
      // Unreachable in P6 flows: the confirmation-validation seam is used by
      // the AI commit boundary, not by the P6 adapter. Mapped to the safest
      // P6 "requires explicit confirmation" category for exhaustiveness.
      AnswerCandidateReviewFailure.notConfirmed =>
        SupplementalAnswerReviewFailure.conflictRequiresReplaceReconfirmation,
    };
  }

  SupplementalAnswerReviewSession _wrap(AnswerCandidateReviewSession core) {
    return SupplementalAnswerReviewSession._(
      request: request,
      snapshot: snapshot,
      matchResult: matchResult,
      core: core,
    );
  }

  SupplementalAnswerReviewFailure _notCommittableFailure(
    AnswerMatchDisposition disposition,
  ) {
    return switch (disposition) {
      AnswerMatchDisposition.ambiguous =>
        SupplementalAnswerReviewFailure.ambiguousNotCommittable,
      AnswerMatchDisposition.unmatched =>
        SupplementalAnswerReviewFailure.unmatchedNotCommittable,
      AnswerMatchDisposition.invalid =>
        SupplementalAnswerReviewFailure.invalidNotCommittable,
      AnswerMatchDisposition.matched ||
      AnswerMatchDisposition.conflict =>
        SupplementalAnswerReviewFailure.fillOnlyForMissingAnswers,
    };
  }
}
