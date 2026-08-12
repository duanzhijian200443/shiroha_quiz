import '../../domain/conversations/conversation.dart';
import '../../domain/question/question_draft_v2.dart';

/// Application-owned W0 staging admission and approved-commit persistence
/// contract.
///
/// Staging admission is **non-authoritative** for COMMIT: it only decides
/// whether preview-visible target content may be released to the proposal
/// layer. The dedicated commit transaction revalidates every source, scope,
/// relation, target and compare-and-set precondition before any write.
abstract interface class AgentWritePersistencePort {
  /// Authorizes one staging target for [request] and, only after all
  /// source/scope/relation/target checks succeed, returns the decoded typed
  /// target snapshot.
  ///
  /// Unauthorized and nonexistent targets return the same safe
  /// [AgentWriteAdmissionDenied] shape without target identity or content;
  /// an authorized but corrupt/unsafe typed target returns
  /// [AgentWriteAdmissionUnavailable] without payload or content.
  Future<AgentWriteAdmissionResult> admitStagingTarget(
    AgentWriteAdmissionRequest request,
  );

  /// Applies one approved fill-missing-answer proposal inside a single
  /// dedicated data-layer transaction.
  ///
  /// Revalidates the source Conversation, source User Message, scope,
  /// Learning Space Project/`project_banks` relation, target bank, typed
  /// sidecar, full structural compare-and-set, fill-only preconditions and
  /// then performs the atomic sidecar/V1 write through the shared typed
  /// persistence kernel. Any failed precondition throws
  /// [TypedAnswerMutationException] with zero writes.
  Future<void> commitApproved(AgentWriteCommitRequest request);
}

/// Source-scoped staging request for one W0 target.
final class AgentWriteAdmissionRequest {
  const AgentWriteAdmissionRequest({
    required this.sourceConversationId,
    required this.sourceMessageId,
    required this.scope,
    required this.targetStorageId,
  });

  final String sourceConversationId;
  final String sourceMessageId;

  /// The source Conversation scope the Agent runtime injected. It must equal
  /// the persisted Conversation scope.
  final ConversationScope scope;
  final String targetStorageId;
}

/// One authorized staging snapshot. Carries the decoded typed draft so the
/// proposal layer can build an exact preview; it is **not** a COMMIT grant.
final class AgentWriteAdmittedTarget {
  const AgentWriteAdmittedTarget({
    required this.storageId,
    required this.bankName,
    required this.draft,
  });

  final String storageId;
  final String bankName;
  final QuestionDraftV2 draft;
}

sealed class AgentWriteAdmissionResult {
  const AgentWriteAdmissionResult();
}

/// Authorization granted: [AgentWriteAdmissionGranted.target] may be used to
/// build preview-visible content. Non-authoritative for COMMIT; the commit
/// transaction revalidates all preconditions.
final class AgentWriteAdmissionGranted extends AgentWriteAdmissionResult {
  const AgentWriteAdmissionGranted(this.target);

  final AgentWriteAdmittedTarget target;
}

/// Safe non-enumerating denial shared by unauthorized, nonexistent and
/// ineligible (non-typed) targets. Carries no target identity or content.
final class AgentWriteAdmissionDenied extends AgentWriteAdmissionResult {
  const AgentWriteAdmissionDenied();
}

/// Authorized target whose typed sidecar is corrupt or unsafe. Distinct from
/// [AgentWriteAdmissionDenied] but never carries payload or content.
final class AgentWriteAdmissionUnavailable extends AgentWriteAdmissionResult {
  const AgentWriteAdmissionUnavailable();
}

/// Approved fill-missing-answer commit request.
///
/// [proposedAnswer] is non-nullable by contract: the fill-only policy
/// requires a structurally non-empty proposed answer and the dedicated
/// adapter defensively rechecks the expected answer is still null.
final class AgentWriteCommitRequest {
  const AgentWriteCommitRequest({
    required this.sourceConversationId,
    required this.sourceMessageId,
    required this.scope,
    required this.targetStorageId,
    required this.expectedBankName,
    required this.expectedDraft,
    required this.proposedAnswer,
  });

  final String sourceConversationId;
  final String sourceMessageId;
  final ConversationScope scope;
  final String targetStorageId;

  /// The admitted current `bank_name` frozen into the proposal.
  final String expectedBankName;

  /// The complete typed draft frozen into the proposal baseline.
  final QuestionDraftV2 expectedDraft;
  final QuestionAnswer proposedAnswer;
}

/// Application-owned permission-aware read used to reconcile one ambiguous
/// COMMIT outcome (for example a `transactionFailed` persistence failure
/// that may or may not have become durable).
///
/// The read revalidates the same source Conversation / User Message / scope /
/// Project / `project_banks` / target authority as staging and COMMIT and
/// never performs a formal write. Denied, unavailable and unconfirmable
/// results carry no target identity or content.
abstract interface class AgentWriteReconciliationPort {
  /// Reads whether an approved fill-missing-answer COMMIT became durable.
  ///
  /// Only the exact expected baseline and the exact post-image (expected
  /// baseline draft with only the proposed answer applied) are
  /// distinguished; any other confirmed draft is a conflict. Every failed
  /// authority/read precondition maps to [AgentWriteReconciliationUnavailable]
  /// so no target content can leak through the ambiguity.
  Future<AgentWriteReconciliationResult> reconcileAfterAmbiguousCommit(
    AgentWriteReconciliationRequest request,
  );
}

/// One fill-missing-answer ambiguous COMMIT to reconcile. Carries the same
/// frozen inputs as the failed [AgentWriteCommitRequest] so the read can
/// compare the exact baseline and post-image.
final class AgentWriteReconciliationRequest {
  const AgentWriteReconciliationRequest({
    required this.sourceConversationId,
    required this.sourceMessageId,
    required this.scope,
    required this.targetStorageId,
    required this.expectedBankName,
    required this.expectedDraft,
    required this.proposedAnswer,
  });

  final String sourceConversationId;
  final String sourceMessageId;
  final ConversationScope scope;
  final String targetStorageId;
  final String expectedBankName;
  final QuestionDraftV2 expectedDraft;
  final QuestionAnswer proposedAnswer;
}

sealed class AgentWriteReconciliationResult {
  const AgentWriteReconciliationResult();
}

/// The target now structurally equals the exact post-image: the ambiguous
/// COMMIT became durable.
final class AgentWriteReconciliationCommitted
    extends AgentWriteReconciliationResult {
  const AgentWriteReconciliationCommitted();
}

/// The target still structurally equals the exact baseline: the ambiguous
/// COMMIT did not become durable and only an explicit user retry may re-enter
/// COMMIT.
final class AgentWriteReconciliationBaseline
    extends AgentWriteReconciliationResult {
  const AgentWriteReconciliationBaseline();
}

/// The target is confirmed but differs from both the exact baseline and the
/// exact post-image.
final class AgentWriteReconciliationConflicted
    extends AgentWriteReconciliationResult {
  const AgentWriteReconciliationConflicted();
}

/// Denied, unavailable or unconfirmable read. Carries no target identity or
/// content; the ambiguous outcome stays unresolved and must not be retried
/// automatically.
final class AgentWriteReconciliationUnavailable
    extends AgentWriteReconciliationResult {
  const AgentWriteReconciliationUnavailable();
}
