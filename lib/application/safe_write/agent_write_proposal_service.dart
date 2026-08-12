import '../../domain/question/question_draft_v2.dart';
import 'agent_write_persistence.dart';
import 'agent_write_proposal.dart';
import 'agent_write_proposed_answer_policy.dart';
import 'typed_answer_command.dart';

/// Transient W0 proposal service: staging admission, canonical fingerprint
/// deduplication, one-active-per-source-turn, the fill-only policy and an
/// optional pre-activation result-size gate.
///
/// All state is in-memory and disappears on process restart. Fingerprint
/// equality is canonical structural equality; the same semantic fingerprint
/// reuses the existing proposal identity and its current outcome, and
/// committed or rejected proposals are never reactivated by replay.
final class AgentWriteProposalService {
  AgentWriteProposalService(
    this._persistence, {
    AgentWriteReconciliationPort? reconciliation,
  }) : _reconciliation = reconciliation ?? _reconciliationOf(_persistence);

  /// The persistence adapter is the dedicated data adapter for the COMMIT
  /// path, so when it also provides the reconciliation port (as the W0
  /// repository does) no separate composition-root wiring is required.
  static AgentWriteReconciliationPort? _reconciliationOf(
    AgentWritePersistencePort persistence,
  ) {
    return switch (persistence) {
      AgentWriteReconciliationPort reconciliation => reconciliation,
      _ => null,
    };
  }

  static const AgentWriteProposedAnswerPolicy _answerPolicy =
      AgentWriteProposedAnswerPolicy();

  final AgentWritePersistencePort _persistence;
  final AgentWriteReconciliationPort? _reconciliation;

  final Map<String, AgentWriteProposal> _proposalsById = {};
  final Map<AgentWriteProposalFingerprint, String> _proposalIdByFingerprint =
      {};
  final Map<String, String> _activeProposalByTurn = {};
  final Map<String, Future<AgentWriteProposal>> _inFlightCommits = {};
  int _nextProposalId = 0;

  /// Stages one fill-missing-answer proposal for [admissionRequest].
  ///
  /// Admission runs first and only a granted target is ever read or decoded;
  /// the preview is built exclusively from the admitted snapshot and
  /// [proposedAnswer]. The fill-only policy refuses already-answered targets
  /// and payloads that are invalid for the target kind (kind-incompatible,
  /// unknown/duplicate choice identities, or structurally empty/whitespace-
  /// only/raw-fallback content). A different payload on the same source turn
  /// supersedes the older pending proposal; a semantic replay returns the
  /// existing proposal with its current outcome.
  ///
  /// When [resultSizeGate] is supplied, it runs immediately before any
  /// lifecycle mutation with the exact candidate proposal that would be
  /// activated (its real id, frozen preview and pending outcome). A false
  /// return aborts staging with [AgentWriteStageResultTooLargeException] and
  /// zero mutation: no supersession, no inserted/active proposal and no
  /// fingerprint entry. A semantic replay returns the existing proposal
  /// without invoking the gate because that path activates nothing.
  Future<AgentWriteStageResult> stageProposal({
    required AgentWriteAdmissionRequest admissionRequest,
    required QuestionAnswer proposedAnswer,
    bool Function(AgentWriteProposal candidate)? resultSizeGate,
    bool Function()? lifecycleMutationAllowed,
  }) async {
    if (!_answerPolicy.isStructurallyValidPayload(proposedAnswer)) {
      return const AgentWriteStageResultIneligible();
    }
    final admission = await _persistence.admitStagingTarget(admissionRequest);
    switch (admission) {
      case AgentWriteAdmissionDenied():
        return const AgentWriteStageResultDenied();
      case AgentWriteAdmissionUnavailable():
        return const AgentWriteStageResultUnavailable();
      case AgentWriteAdmissionGranted(:final target):
        if (target.draft.answer != null) {
          return const AgentWriteStageResultIneligible();
        }
        if (!_answerPolicy.isValidForDraft(proposedAnswer, target.draft)) {
          return const AgentWriteStageResultIneligible();
        }
        final fingerprint = AgentWriteProposalFingerprint(
          sourceConversationId: admissionRequest.sourceConversationId,
          sourceMessageId: admissionRequest.sourceMessageId,
          operationKind: AgentWriteOperationKind.fillMissingAnswer,
          scope: admissionRequest.scope,
          targetStorageId: target.storageId,
          bankName: target.bankName,
          expectedDraft: target.draft,
          proposedAnswer: proposedAnswer,
        );
        final existingId = _proposalIdByFingerprint[fingerprint];
        if (existingId != null) {
          return AgentWriteStageResultStaged(_proposalsById[existingId]!);
        }
        final proposal = _createProposal(
          admissionRequest: admissionRequest,
          target: target,
          fingerprint: fingerprint,
          proposedAnswer: proposedAnswer,
        );
        if (resultSizeGate != null && !resultSizeGate(proposal)) {
          throw const AgentWriteStageResultTooLargeException();
        }
        if (lifecycleMutationAllowed != null && !lifecycleMutationAllowed()) {
          throw const AgentWriteStageCancelledException();
        }
        _supersedePendingForTurn(
          admissionRequest.sourceConversationId,
          admissionRequest.sourceMessageId,
          proposal.id,
        );
        _proposalsById[proposal.id] = proposal;
        _proposalIdByFingerprint[fingerprint] = proposal.id;
        _activeProposalByTurn[_turnKey(
          admissionRequest.sourceConversationId,
          admissionRequest.sourceMessageId,
        )] = proposal.id;
        return AgentWriteStageResultStaged(proposal);
    }
  }

  /// Approves [proposalId]: the atomic in-memory lifecycle gate wins exactly
  /// once (`pending -> committing`); concurrent approvals share one in-flight
  /// commit. Reapproval reports the existing committed outcome; an approval
  /// attempt on a rejected or superseded proposal performs zero writes.
  Future<AgentWriteProposal> approveProposal(String proposalId) async {
    final proposal = _requireProposal(proposalId);
    switch (proposal.outcome) {
      case AgentWriteProposalOutcome.pending:
        final committing = _setOutcome(
          proposalId,
          AgentWriteProposalOutcome.committing,
        );
        final inFlight = _inFlightCommits[proposalId];
        if (inFlight != null) return inFlight;
        final future = _runCommit(committing);
        _inFlightCommits[proposalId] = future;
        return future.whenComplete(() {
          _inFlightCommits.remove(proposalId);
        });
      case AgentWriteProposalOutcome.committing:
        final inFlight = _inFlightCommits[proposalId];
        if (inFlight != null) return inFlight;
        return Future.value(proposal);
      case AgentWriteProposalOutcome.committed ||
            AgentWriteProposalOutcome.rejected ||
            AgentWriteProposalOutcome.superseded ||
            AgentWriteProposalOutcome.stale ||
            AgentWriteProposalOutcome.invalid ||
            AgentWriteProposalOutcome.unknownOutcome:
        // Terminal or non-approvable outcomes report as-is with zero writes.
        return Future.value(proposal);
    }
  }

  /// Reads the current transient state of [proposalId] (for example after a
  /// supersession), or throws [ArgumentError] for an unknown id.
  AgentWriteProposal proposalById(String proposalId) {
    return _requireProposal(proposalId);
  }

  /// Rejects [proposalId]: `pending -> rejected` wins only while the proposal
  /// is still pending. Once committing has won, a later Reject reports the
  /// committing outcome and never cancels the authoritative COMMIT; a
  /// committed proposal reports its committed outcome.
  AgentWriteProposal rejectProposal(String proposalId) {
    final proposal = _requireProposal(proposalId);
    switch (proposal.outcome) {
      case AgentWriteProposalOutcome.pending:
        return _setOutcome(proposalId, AgentWriteProposalOutcome.rejected);
      case AgentWriteProposalOutcome.committing ||
            AgentWriteProposalOutcome.committed ||
            AgentWriteProposalOutcome.rejected ||
            AgentWriteProposalOutcome.superseded ||
            AgentWriteProposalOutcome.stale ||
            AgentWriteProposalOutcome.invalid ||
            AgentWriteProposalOutcome.unknownOutcome:
        return proposal;
    }
  }

  AgentWriteProposal _requireProposal(String proposalId) {
    final proposal = _proposalsById[proposalId];
    if (proposal == null) {
      throw ArgumentError.value(proposalId, 'proposalId', 'Unknown proposal.');
    }
    return proposal;
  }

  AgentWriteProposal _createProposal({
    required AgentWriteAdmissionRequest admissionRequest,
    required AgentWriteAdmittedTarget target,
    required AgentWriteProposalFingerprint fingerprint,
    required QuestionAnswer proposedAnswer,
  }) {
    final id = 'proposal_${_nextProposalId++}';
    return AgentWriteProposal(
      id: id,
      fingerprint: fingerprint,
      sourceConversationId: admissionRequest.sourceConversationId,
      sourceMessageId: admissionRequest.sourceMessageId,
      scope: admissionRequest.scope,
      targetStorageId: target.storageId,
      bankName: target.bankName,
      expectedDraft: target.draft,
      proposedAnswer: proposedAnswer,
      preview: AgentWriteProposalPreview(
        bankName: target.bankName,
        stem: target.draft.stem,
        options: target.draft.options,
        proposedAnswer: proposedAnswer,
      ),
      outcome: AgentWriteProposalOutcome.pending,
      createdAt: DateTime.now().toUtc(),
    );
  }

  /// Supersedes the older pending proposal of the same source turn so each
  /// source User turn has at most one active/pending write proposal. Only a
  /// pending predecessor is superseded; committing/terminal outcomes stay
  /// untouched.
  void _supersedePendingForTurn(
    String conversationId,
    String messageId,
    String newProposalId,
  ) {
    final turnKey = _turnKey(conversationId, messageId);
    final previousId = _activeProposalByTurn[turnKey];
    if (previousId == null || previousId == newProposalId) return;
    final previous = _proposalsById[previousId];
    if (previous != null &&
        previous.outcome == AgentWriteProposalOutcome.pending) {
      _setOutcome(previousId, AgentWriteProposalOutcome.superseded);
    }
  }

  Future<AgentWriteProposal> _runCommit(AgentWriteProposal proposal) async {
    try {
      await _persistence.commitApproved(
        AgentWriteCommitRequest(
          sourceConversationId: proposal.sourceConversationId,
          sourceMessageId: proposal.sourceMessageId,
          scope: proposal.scope,
          targetStorageId: proposal.targetStorageId,
          expectedBankName: proposal.bankName,
          expectedDraft: proposal.expectedDraft,
          proposedAnswer: proposal.proposedAnswer,
        ),
      );
      return _setOutcome(proposal.id, AgentWriteProposalOutcome.committed);
    } on TypedAnswerMutationException catch (error) {
      return _applyCommitFailure(error, proposal);
    }
  }

  Future<AgentWriteProposal> _applyCommitFailure(
    TypedAnswerMutationException error,
    AgentWriteProposal proposal,
  ) async {
    return switch (error.failure) {
      TypedAnswerMutationFailure.notFound ||
      TypedAnswerMutationFailure.notTyped ||
      TypedAnswerMutationFailure.corruptPayload ||
      TypedAnswerMutationFailure.invalidAnswer ||
      TypedAnswerMutationFailure.unsafePayload =>
        _setOutcome(proposal.id, AgentWriteProposalOutcome.invalid),
      TypedAnswerMutationFailure.stale =>
        _setOutcome(proposal.id, AgentWriteProposalOutcome.stale),
      TypedAnswerMutationFailure.transactionFailed =>
        await _reconcileAndApplyAmbiguousOutcome(proposal),
    };
  }

  /// Reconciles one ambiguous COMMIT through exactly one permission-aware
  /// read. The read never writes: an exact post-image reports committed, an
  /// exact baseline returns the proposal to its approvable pending state only
  /// while it remains the active proposal for its source turn (the explicit
  /// Presentation Approve action is the only retry entry and performs at most
  /// one new commit attempt per user action). A newer proposal staged while
  /// this one was committing keeps the older proposal superseded; any other
  /// confirmed draft reports stale, and a denied/unavailable/unconfirmable
  /// read keeps unknownOutcome with zero automatic retry.
  Future<AgentWriteProposal> _reconcileAndApplyAmbiguousOutcome(
    AgentWriteProposal proposal,
  ) async {
    final reconciliation = _reconciliation;
    if (reconciliation == null) {
      return _setOutcome(
        proposal.id,
        AgentWriteProposalOutcome.unknownOutcome,
      );
    }
    try {
      final result = await reconciliation.reconcileAfterAmbiguousCommit(
        AgentWriteReconciliationRequest(
          sourceConversationId: proposal.sourceConversationId,
          sourceMessageId: proposal.sourceMessageId,
          scope: proposal.scope,
          targetStorageId: proposal.targetStorageId,
          expectedBankName: proposal.bankName,
          expectedDraft: proposal.expectedDraft,
          proposedAnswer: proposal.proposedAnswer,
        ),
      );
      // No await may separate this active-identity check from the final
      // lifecycle write. Staging a replacement either happens before this
      // synchronous gate (and the old proposal stays superseded) or after it
      // (and supersedes the restored pending proposal).
      final outcome = switch (result) {
        AgentWriteReconciliationCommitted() =>
          AgentWriteProposalOutcome.committed,
        AgentWriteReconciliationBaseline() => _isActiveProposalForTurn(proposal)
            ? AgentWriteProposalOutcome.pending
            : AgentWriteProposalOutcome.superseded,
        AgentWriteReconciliationConflicted() => AgentWriteProposalOutcome.stale,
        AgentWriteReconciliationUnavailable() =>
          AgentWriteProposalOutcome.unknownOutcome,
      };
      return _setOutcome(proposal.id, outcome);
    } catch (_) {
      // A failed reconciliation read must never crash the lifecycle or
      // trigger an automatic retry; the outcome stays unconfirmable.
      return _setOutcome(
        proposal.id,
        AgentWriteProposalOutcome.unknownOutcome,
      );
    }
  }

  AgentWriteProposal _setOutcome(
    String proposalId,
    AgentWriteProposalOutcome outcome,
  ) {
    final updated = _proposalsById[proposalId]!.withOutcome(outcome);
    _proposalsById[proposalId] = updated;
    return updated;
  }

  bool _isActiveProposalForTurn(AgentWriteProposal proposal) {
    return _activeProposalByTurn[_turnKey(
          proposal.sourceConversationId,
          proposal.sourceMessageId,
        )] ==
        proposal.id;
  }

  String _turnKey(String conversationId, String messageId) {
    return '$conversationId\u0000$messageId';
  }
}

/// Thrown by [AgentWriteProposalService.stageProposal] when the supplied
/// pre-activation [resultSizeGate] rejects the exact candidate proposal.
///
/// Guarantees zero lifecycle mutation: the candidate was never inserted,
/// activated or superseded, and no fingerprint entry was created for it.
final class AgentWriteStageResultTooLargeException implements Exception {
  const AgentWriteStageResultTooLargeException();
}

/// Staging became cancelled or expired before its synchronous lifecycle
/// mutation gate. The candidate was never inserted, activated, fingerprinted
/// or allowed to supersede an existing proposal.
final class AgentWriteStageCancelledException implements Exception {
  const AgentWriteStageCancelledException();
}
