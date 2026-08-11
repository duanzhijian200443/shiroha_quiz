import '../../domain/content/content_node.dart';
import '../../domain/question/question_draft_v2.dart';
import 'agent_write_persistence.dart';
import 'agent_write_proposal.dart';
import 'typed_answer_command.dart';

/// Transient W0 proposal service: staging admission, canonical fingerprint
/// deduplication, one-active-per-source-turn and the fill-only policy.
///
/// All state is in-memory and disappears on process restart. Fingerprint
/// equality is canonical structural equality; the same semantic fingerprint
/// reuses the existing proposal identity and its current outcome, and
/// committed or rejected proposals are never reactivated by replay.
final class AgentWriteProposalService {
  AgentWriteProposalService(this._persistence);

  final AgentWritePersistencePort _persistence;

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
  /// and structurally invalid payloads. A different payload on the same
  /// source turn supersedes the older pending proposal; a semantic replay
  /// returns the existing proposal with its current outcome.
  Future<AgentWriteStageResult> stageProposal({
    required AgentWriteAdmissionRequest admissionRequest,
    required QuestionAnswer proposedAnswer,
  }) async {
    if (!_isStructurallyValidPayload(proposedAnswer)) {
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
        if (!_isValidChoiceAnswer(proposedAnswer, target.draft)) {
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
          return AgentWriteStageResultStaged(
            _proposalsById[existingId]!,
          );
        }
        final proposal = _createProposal(
          admissionRequest: admissionRequest,
          target: target,
          fingerprint: fingerprint,
          proposedAnswer: proposedAnswer,
        );
        _supersedePendingForTurn(
          admissionRequest.sourceConversationId,
          admissionRequest.sourceMessageId,
          proposal.id,
        );
        _proposalsById[proposal.id] = proposal;
        _proposalIdByFingerprint[fingerprint] = proposal.id;
        _activeProposalByTurn[_turnKey(admissionRequest.sourceConversationId,
            admissionRequest.sourceMessageId)] = proposal.id;
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
        final committing =
            _setOutcome(proposalId, AgentWriteProposalOutcome.committing);
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
      final outcome = switch (error.failure) {
        TypedAnswerMutationFailure.notFound ||
        TypedAnswerMutationFailure.notTyped ||
        TypedAnswerMutationFailure.corruptPayload ||
        TypedAnswerMutationFailure.invalidAnswer ||
        TypedAnswerMutationFailure.unsafePayload =>
          AgentWriteProposalOutcome.invalid,
        TypedAnswerMutationFailure.stale => AgentWriteProposalOutcome.stale,
        TypedAnswerMutationFailure.transactionFailed =>
          AgentWriteProposalOutcome.unknownOutcome,
      };
      return _setOutcome(proposal.id, outcome);
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

  String _turnKey(String conversationId, String messageId) {
    return '$conversationId\u0000$messageId';
  }

  /// Fill-only payload policy: a proposed content answer must be structurally
  /// non-empty without raw fallback or whitespace-only payload; a proposed
  /// choice answer must be non-empty and duplicate-free.
  bool _isStructurallyValidPayload(QuestionAnswer proposed) {
    switch (proposed) {
      case ChoiceAnswer(:final optionIds):
        return optionIds.isNotEmpty &&
            optionIds.toSet().length == optionIds.length;
      case ContentAnswer(:final content):
        if (content.nodes.isEmpty) return false;
        var hasVisibleNode = false;
        for (final node in content.nodes) {
          switch (node) {
            case TextNode(:final text):
              if (text.trim().isNotEmpty) hasVisibleNode = true;
            case InlineMathNode() || BlockMathNode():
              hasVisibleNode = true;
            case RawFallbackNode():
              return false;
          }
        }
        return hasVisibleNode;
    }
  }

  /// Choice identities must be unique and exist in the admitted options.
  bool _isValidChoiceAnswer(
    QuestionAnswer proposed,
    QuestionDraftV2 admittedDraft,
  ) {
    if (proposed case ChoiceAnswer(:final optionIds)) {
      final optionIdsInDraft = <String>{
        for (final option in admittedDraft.options) option.optionId,
      };
      return optionIds.toSet().length == optionIds.length &&
          optionIds.every(optionIdsInDraft.contains);
    }
    return true;
  }
}
