import '../../domain/conversations/conversation.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/question/question_draft_v2.dart';

/// The only W0 v0 operation semantics.
enum AgentWriteOperationKind { fillMissingAnswer }

/// Transient proposal lifecycle outcome. The exact spelling is an
/// implementation detail; the behavior meanings are frozen by the W0
/// contract (pending / committing / committed / rejected / superseded /
/// stale / invalid / unknown-outcome).
enum AgentWriteProposalOutcome {
  pending,
  committing,
  committed,
  rejected,
  superseded,
  stale,
  invalid,
  unknownOutcome,
}

/// Deterministic semantic fingerprint of one proposal.
///
/// Equality is canonical structural equality over the frozen inputs:
/// source Conversation identity, source User Message identity, operation
/// semantics, source scope/Project identity, target storage identity,
/// admitted bank name, canonical expected typed draft and canonical proposed
/// typed answer. Proposal id, createdAt, preview copy/layout, provider
/// tool-call id and internal lifecycle state are never fingerprint inputs.
final class AgentWriteProposalFingerprint {
  const AgentWriteProposalFingerprint({
    required this.sourceConversationId,
    required this.sourceMessageId,
    required this.operationKind,
    required this.scope,
    required this.targetStorageId,
    required this.bankName,
    required this.expectedDraft,
    required this.proposedAnswer,
  });

  final String sourceConversationId;
  final String sourceMessageId;
  final AgentWriteOperationKind operationKind;
  final ConversationScope scope;
  final String targetStorageId;
  final String bankName;
  final QuestionDraftV2 expectedDraft;
  final QuestionAnswer proposedAnswer;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AgentWriteProposalFingerprint &&
            sourceConversationId == other.sourceConversationId &&
            sourceMessageId == other.sourceMessageId &&
            operationKind == other.operationKind &&
            scope == other.scope &&
            targetStorageId == other.targetStorageId &&
            bankName == other.bankName &&
            expectedDraft == other.expectedDraft &&
            proposedAnswer == other.proposedAnswer;
  }

  @override
  int get hashCode => Object.hash(
        sourceConversationId,
        sourceMessageId,
        operationKind,
        scope,
        targetStorageId,
        bankName,
        expectedDraft,
        proposedAnswer,
      );
}

/// Typed preview built by Application code **only** from the admitted target
/// snapshot and the proposed typed answer. Under the fill-only policy the
/// answer-before is always null, so the preview states "no answer ->
/// proposed answer" and that no other question field or review state changes.
/// LLM-authored prose is never the authoritative preview.
final class AgentWriteProposalPreview {
  const AgentWriteProposalPreview({
    required this.bankName,
    required this.stem,
    required this.options,
    required this.proposedAnswer,
  });

  final String bankName;
  final RichContent stem;
  final List<QuestionOption> options;
  final QuestionAnswer proposedAnswer;
}

/// One transient, immutable W0 proposal. Proposals disappear on process
/// restart and are never written to SQLite or stored as Conversation
/// Messages.
final class AgentWriteProposal {
  const AgentWriteProposal({
    required this.id,
    required this.fingerprint,
    required this.sourceConversationId,
    required this.sourceMessageId,
    required this.scope,
    required this.targetStorageId,
    required this.bankName,
    required this.expectedDraft,
    required this.proposedAnswer,
    required this.preview,
    required this.outcome,
    required this.createdAt,
  });

  final String id;
  final AgentWriteProposalFingerprint fingerprint;
  final String sourceConversationId;
  final String sourceMessageId;
  final ConversationScope scope;
  final String targetStorageId;
  final String bankName;
  final QuestionDraftV2 expectedDraft;
  final QuestionAnswer proposedAnswer;
  final AgentWriteProposalPreview preview;
  final AgentWriteProposalOutcome outcome;

  /// Display/order support only; never part of approval, fingerprint or CAS.
  final DateTime createdAt;

  AgentWriteProposal withOutcome(AgentWriteProposalOutcome value) {
    return AgentWriteProposal(
      id: id,
      fingerprint: fingerprint,
      sourceConversationId: sourceConversationId,
      sourceMessageId: sourceMessageId,
      scope: scope,
      targetStorageId: targetStorageId,
      bankName: bankName,
      expectedDraft: expectedDraft,
      proposedAnswer: proposedAnswer,
      preview: preview,
      outcome: value,
      createdAt: createdAt,
    );
  }
}

sealed class AgentWriteStageResult {
  const AgentWriteStageResult();
}

/// A proposal was staged (or a semantic replay returned the existing
/// proposal with its current outcome).
final class AgentWriteStageResultStaged extends AgentWriteStageResult {
  const AgentWriteStageResultStaged(this.proposal);

  final AgentWriteProposal proposal;
}

/// Staging was refused by the safe non-enumerating admission boundary.
final class AgentWriteStageResultDenied extends AgentWriteStageResult {
  const AgentWriteStageResultDenied();
}

/// The admitted target sidecar is corrupt or unsafe; no content is returned.
final class AgentWriteStageResultUnavailable extends AgentWriteStageResult {
  const AgentWriteStageResultUnavailable();
}

/// The fill-only policy refused staging: the target is already answered or
/// the proposed answer is not structurally non-empty/valid.
final class AgentWriteStageResultIneligible extends AgentWriteStageResult {
  const AgentWriteStageResultIneligible();
}
