import '../../domain/answers/answer_candidate.dart';

/// Terminal review outcome of one candidate within the transient session.
enum CandidateReviewOutcome {
  pendingFill,
  pendingReplace,
  confirmed,
  committed,
  rejected,
  noOp,
}

/// Safe typed failures of the shared review-decision core.
///
/// These categories are producer-neutral. P6 adapters map them onto their
/// frozen P6 failure taxonomy; AI adapters (future stages) map them onto the
/// P7 taxonomy. `replaceFlowRequired` means the candidate's write intent is
/// replace and the requested transition was not the armed-reconfirmation
/// path.
enum AnswerCandidateReviewFailure {
  unknownCandidate,
  staleSessionRevision,
  alreadyDecided,
  noOpTerminal,
  fillOnlyForMissingAnswers,
  replaceFlowRequired,
}

final class AnswerCandidateReviewException implements Exception {
  const AnswerCandidateReviewException(this.failure);

  final AnswerCandidateReviewFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      AnswerCandidateReviewFailure.unknownCandidate =>
        'The candidate is not part of this review session.',
      AnswerCandidateReviewFailure.staleSessionRevision =>
        'The review session changed after it was loaded.',
      AnswerCandidateReviewFailure.alreadyDecided =>
        'The candidate already reached a terminal review outcome.',
      AnswerCandidateReviewFailure.noOpTerminal =>
        'Equivalent candidates are terminal no-op outcomes.',
      AnswerCandidateReviewFailure.fillOnlyForMissingAnswers =>
        'Fill confirmation applies only to missing answers.',
      AnswerCandidateReviewFailure.replaceFlowRequired =>
        'Replacement requires explicit selection followed by explicit '
            'reconfirmation.',
    };
    return 'AnswerCandidateReviewException(${failure.name}): $detail';
  }
}

/// One exact confirmation request produced by the review session.
///
/// The confirmation carries the candidate plus the exact session revision;
/// persistence adapters revalidate both inside the linearized write
/// boundary.
final class AnswerCandidateConfirmation {
  const AnswerCandidateConfirmation({
    required this.candidate,
    required this.sessionRevision,
  });

  final AnswerCandidate candidate;
  final int sessionRevision;
}

/// Producer-neutral transient review-decision core.
///
/// One canonical transition implementation shared by every answer-candidate
/// producer (Supplemental today, AI in later P7 stages):
///
/// - missing answer: pending fill -> explicit confirm -> confirmed ->
///   committed;
/// - equivalent: noOp -> terminal, zero transaction;
/// - different: pending replacement -> explicit select/arm -> explicit
///   reconfirm -> confirmed -> committed;
/// - reject: -> rejected terminal, zero mutation.
///
/// The core never inspects the producer origin to decide fill/noOp/replace
/// semantics; eligibility that is producer-specific (for example the P6
/// match disposition) stays in the producer adapter. Every review decision
/// advances [sessionRevision] exactly once, and all state is immutable with
/// unmodifiable collections.
final class AnswerCandidateReviewSession {
  factory AnswerCandidateReviewSession({
    required List<AnswerCandidate> candidates,
  }) {
    final outcomes = <String, CandidateReviewOutcome>{};
    for (final candidate in candidates) {
      outcomes[candidate.candidateId] = switch (candidate.writeIntent) {
        CandidateWriteIntent.fill => CandidateReviewOutcome.pendingFill,
        CandidateWriteIntent.noOp => CandidateReviewOutcome.noOp,
        CandidateWriteIntent.replace => CandidateReviewOutcome.pendingReplace,
      };
    }
    return AnswerCandidateReviewSession._(
      candidates: List<AnswerCandidate>.unmodifiable(candidates),
      outcomes: Map<String, CandidateReviewOutcome>.unmodifiable(outcomes),
      armedReplaceIds: const <String>{},
      sessionRevision: 0,
    );
  }

  const AnswerCandidateReviewSession._({
    required this.candidates,
    required this.outcomes,
    required Set<String> armedReplaceIds,
    required this.sessionRevision,
  }) : _armedReplaceIds = armedReplaceIds;

  final List<AnswerCandidate> candidates;
  final Map<String, CandidateReviewOutcome> outcomes;
  final Set<String> _armedReplaceIds;
  final int sessionRevision;

  CandidateReviewOutcome outcomeOf(String candidateId) {
    return outcomes[candidateId] ?? CandidateReviewOutcome.rejected;
  }

  /// Resolves exactly one candidate or fails with a typed failure.
  AnswerCandidate candidateOf(String candidateId) {
    final matches = candidates
        .where((candidate) => candidate.candidateId == candidateId)
        .toList(growable: false);
    if (matches.length != 1) {
      throw AnswerCandidateReviewException(
        AnswerCandidateReviewFailure.unknownCandidate,
      );
    }
    return matches.single;
  }

  /// Confirms one pending fill. Only `fill` write-intent candidates that are
  /// still undecided are committable through this path.
  ({
    AnswerCandidateReviewSession session,
    AnswerCandidateConfirmation confirmation,
  }) confirmFill(String candidateId) {
    final candidate = candidateOf(candidateId);
    if (candidate.writeIntent != CandidateWriteIntent.fill) {
      throw AnswerCandidateReviewException(
        switch (candidate.writeIntent) {
          CandidateWriteIntent.replace =>
            AnswerCandidateReviewFailure.replaceFlowRequired,
          CandidateWriteIntent.noOp =>
            AnswerCandidateReviewFailure.noOpTerminal,
          CandidateWriteIntent.fill =>
            AnswerCandidateReviewFailure.fillOnlyForMissingAnswers,
        },
      );
    }
    _checkUndecided(candidateId);
    return _confirm(candidateId, CandidateReviewOutcome.confirmed);
  }

  /// First, explicit step of the per-question replace review: arms the
  /// replacement. The armed state is distinct from the initial
  /// `pendingReplace` outcome so a direct [confirmReplace] can never bypass
  /// this selection.
  AnswerCandidateReviewSession selectForReplace(String candidateId) {
    final candidate = candidateOf(candidateId);
    if (candidate.writeIntent != CandidateWriteIntent.replace) {
      throw AnswerCandidateReviewException(
        AnswerCandidateReviewFailure.replaceFlowRequired,
      );
    }
    if (outcomes[candidateId] != CandidateReviewOutcome.pendingReplace ||
        _armedReplaceIds.contains(candidateId)) {
      throw AnswerCandidateReviewException(
        AnswerCandidateReviewFailure.alreadyDecided,
      );
    }
    return _copyWithOutcome(
      candidateId,
      CandidateReviewOutcome.pendingReplace,
      armed: <String>{..._armedReplaceIds, candidateId},
    );
  }

  /// Second, explicit per-question reconfirmation of an armed replacement.
  /// Only the selected/armed replacement may be confirmed.
  ({
    AnswerCandidateReviewSession session,
    AnswerCandidateConfirmation confirmation,
  }) confirmReplace(String candidateId) {
    final candidate = candidateOf(candidateId);
    if (candidate.writeIntent != CandidateWriteIntent.replace) {
      throw AnswerCandidateReviewException(
        AnswerCandidateReviewFailure.replaceFlowRequired,
      );
    }
    final current = outcomes[candidateId];
    if (current == CandidateReviewOutcome.confirmed ||
        current == CandidateReviewOutcome.committed) {
      throw AnswerCandidateReviewException(
        AnswerCandidateReviewFailure.alreadyDecided,
      );
    }
    if (current != CandidateReviewOutcome.pendingReplace ||
        !_armedReplaceIds.contains(candidateId)) {
      throw AnswerCandidateReviewException(
        AnswerCandidateReviewFailure.replaceFlowRequired,
      );
    }
    return _confirm(candidateId, CandidateReviewOutcome.confirmed);
  }

  /// Explicit rejection: terminal with zero mutation.
  AnswerCandidateReviewSession reject(String candidateId) {
    candidateOf(candidateId);
    _checkUndecided(candidateId);
    return _copyWithOutcome(candidateId, CandidateReviewOutcome.rejected);
  }

  /// Marks one confirmed candidate as committed after persistence succeeded.
  AnswerCandidateReviewSession markCommitted(String candidateId) {
    candidateOf(candidateId);
    if (outcomes[candidateId] != CandidateReviewOutcome.confirmed) {
      throw AnswerCandidateReviewException(
        AnswerCandidateReviewFailure.alreadyDecided,
      );
    }
    return _copyWithOutcome(candidateId, CandidateReviewOutcome.committed);
  }

  void _checkUndecided(String candidateId) {
    final current = outcomes[candidateId];
    if (current != null &&
        current != CandidateReviewOutcome.pendingFill &&
        current != CandidateReviewOutcome.pendingReplace) {
      throw AnswerCandidateReviewException(
        AnswerCandidateReviewFailure.alreadyDecided,
      );
    }
  }

  ({
    AnswerCandidateReviewSession session,
    AnswerCandidateConfirmation confirmation,
  }) _confirm(
    String candidateId,
    CandidateReviewOutcome outcome,
  ) {
    final next = _copyWithOutcome(candidateId, outcome);
    return (
      session: next,
      confirmation: AnswerCandidateConfirmation(
        candidate: candidateOf(candidateId),
        sessionRevision: next.sessionRevision,
      ),
    );
  }

  AnswerCandidateReviewSession _copyWithOutcome(
    String candidateId,
    CandidateReviewOutcome outcome, {
    Set<String>? armed,
  }) {
    return AnswerCandidateReviewSession._(
      candidates: candidates,
      outcomes: Map<String, CandidateReviewOutcome>.unmodifiable(
        <String, CandidateReviewOutcome>{...outcomes, candidateId: outcome},
      ),
      armedReplaceIds: Set<String>.unmodifiable(armed ?? _armedReplaceIds),
      sessionRevision: sessionRevision + 1,
    );
  }
}
