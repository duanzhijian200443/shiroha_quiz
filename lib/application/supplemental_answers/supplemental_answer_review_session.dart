import '../../domain/supplemental_answers/answer_candidate.dart';
import '../../domain/supplemental_answers/answer_match_record.dart';
import '../../domain/supplemental_answers/supplemental_answer_scope.dart';
import 'supplemental_answer_matcher.dart';
import 'target_question_snapshot_service.dart';

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

/// Terminal review outcome of one candidate within the transient session.
enum CandidateReviewOutcome {
  pendingFill,
  pendingReplace,
  confirmed,
  committed,
  rejected,
  noOp,
}

/// One exact confirmation request produced by the review session.
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

/// Transient P6 review session.
///
/// The session owns the canonical candidate lifecycle:
///
/// - missing answer: matched/fill -> select -> explicit confirm -> commit;
/// - equivalent: noOp -> terminal, zero transaction;
/// - different: conflict -> per-question replace review -> per-question
///   explicit reconfirm -> commit;
/// - ambiguous/unmatched/invalid: review-only terminal, never committable.
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
    final outcomes = <String, CandidateReviewOutcome>{};
    for (final record in matchResult.records) {
      final candidate = record.candidate;
      if (candidate == null) continue;
      outcomes[candidate.candidateId] = switch (candidate.writeIntent) {
        CandidateWriteIntent.fill => CandidateReviewOutcome.pendingFill,
        CandidateWriteIntent.noOp => CandidateReviewOutcome.noOp,
        CandidateWriteIntent.replace => CandidateReviewOutcome.pendingReplace,
      };
    }
    return SupplementalAnswerReviewSession._(
      request: request,
      snapshot: snapshot,
      matchResult: matchResult,
      outcomes: outcomes,
      sessionRevision: 0,
    );
  }

  const SupplementalAnswerReviewSession._({
    required this.request,
    required this.snapshot,
    required this.matchResult,
    required this.outcomes,
    required this.sessionRevision,
  });

  final SupplementalAnswerMatchRequest request;
  final TargetQuestionSnapshot snapshot;
  final SupplementalMatchResult matchResult;
  final Map<String, CandidateReviewOutcome> outcomes;
  final int sessionRevision;

  List<AnswerMatchRecord> get records => matchResult.records;

  CandidateReviewOutcome outcomeOf(String candidateId) {
    return outcomes[candidateId] ?? CandidateReviewOutcome.rejected;
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
    _checkRevisionFreeDecision(candidateId);
    final record = _recordFor(candidateId);
    if (record.disposition != AnswerMatchDisposition.matched) {
      throw SupplementalAnswerReviewException(
        _notCommittableFailure(record.disposition),
      );
    }
    return _confirm(candidateId, CandidateReviewOutcome.confirmed);
  }

  /// First step of the per-question replace review for one conflict.
  SupplementalAnswerReviewSession selectForReplace(String candidateId) {
    final candidate = _candidate(candidateId);
    _checkRevisionFreeDecision(candidateId);
    final record = _recordFor(candidateId);
    if (record.disposition != AnswerMatchDisposition.conflict ||
        candidate.writeIntent != CandidateWriteIntent.replace) {
      throw SupplementalAnswerReviewException(
        SupplementalAnswerReviewFailure.conflictRequiresReplaceReconfirmation,
      );
    }
    return _copyWithOutcome(candidateId, CandidateReviewOutcome.pendingReplace);
  }

  /// Second, explicit per-question reconfirmation of a conflict replace.
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
    final current = outcomes[candidateId];
    if (current != CandidateReviewOutcome.pendingReplace) {
      throw SupplementalAnswerReviewException(
        current == CandidateReviewOutcome.confirmed ||
                current == CandidateReviewOutcome.committed
            ? SupplementalAnswerReviewFailure.alreadyDecided
            : SupplementalAnswerReviewFailure
                .conflictRequiresReplaceReconfirmation,
      );
    }
    return _confirm(candidateId, CandidateReviewOutcome.confirmed);
  }

  /// Explicit rejection: terminal with zero mutation.
  SupplementalAnswerReviewSession reject(String candidateId) {
    _candidate(candidateId);
    _checkRevisionFreeDecision(candidateId);
    return _copyWithOutcome(candidateId, CandidateReviewOutcome.rejected);
  }

  /// Marks one confirmed candidate as committed after C0 succeeded.
  SupplementalAnswerReviewSession markCommitted(String candidateId) {
    _candidate(candidateId);
    if (outcomes[candidateId] != CandidateReviewOutcome.confirmed) {
      throw SupplementalAnswerReviewException(
        SupplementalAnswerReviewFailure.alreadyDecided,
      );
    }
    return _copyWithOutcome(candidateId, CandidateReviewOutcome.committed);
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

  void _checkRevisionFreeDecision(String candidateId) {
    final current = outcomes[candidateId];
    if (current != null &&
        current != CandidateReviewOutcome.pendingFill &&
        current != CandidateReviewOutcome.pendingReplace) {
      throw SupplementalAnswerReviewException(
        SupplementalAnswerReviewFailure.alreadyDecided,
      );
    }
  }

  ({
    SupplementalAnswerReviewSession session,
    SupplementalAnswerConfirmation confirmation,
  }) _confirm(
    String candidateId,
    CandidateReviewOutcome outcome,
  ) {
    final candidate = _candidate(candidateId);
    final next = _copyWithOutcome(candidateId, outcome);
    return (
      session: next,
      confirmation: SupplementalAnswerConfirmation(
        candidate: candidate,
        sessionRevision: next.sessionRevision,
      ),
    );
  }

  SupplementalAnswerReviewSession _copyWithOutcome(
    String candidateId,
    CandidateReviewOutcome outcome,
  ) {
    return SupplementalAnswerReviewSession._(
      request: request,
      snapshot: snapshot,
      matchResult: matchResult,
      outcomes: <String, CandidateReviewOutcome>{
        ...outcomes,
        candidateId: outcome,
      },
      sessionRevision: sessionRevision + 1,
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
