/// A0-4 provider-neutral Agent turn seam.
///
/// The session is transient: events stream visible progress, and [result]
/// carries the terminal outcome. Nothing here is persisted; Conversation
/// Domain stays free of turn/Agent state.
library;

import '../../core/observability/diagnostic_summary.dart';
import '../../domain/conversations/conversation_message.dart';
import 'agent_provider.dart';
import 'retrieval_egress_grant.dart';

/// Terminal outcome of one Agent turn.
sealed class AgentTurnResult {
  const AgentTurnResult();
}

/// The turn completed and exactly one Assistant Message was persisted.
final class AgentTurnSuccess extends AgentTurnResult {
  const AgentTurnSuccess({required this.assistantMessage});

  final ConversationMessage assistantMessage;
}

/// A persisted Assistant reply for the target turn already exists; the
/// runtime did not regenerate it.
final class AgentTurnAlreadyCompleted extends AgentTurnResult {
  const AgentTurnAlreadyCompleted({required this.assistantMessage});

  final ConversationMessage assistantMessage;
}

/// The turn failed with one fixed, safe, deterministic category.
final class AgentTurnFailed extends AgentTurnResult {
  const AgentTurnFailed(this.failure, {this.summary});

  final AgentTurnFailure failure;

  /// OBS-1 safe structured diagnostic snapshot for this failed turn. Optional
  /// so hand-built sessions may omit it; production turns always provide it.
  final DiagnosticSummary? summary;
}

/// Fixed safe Agent turn failure taxonomy.
///
/// UI must never see provider bodies, stacks, paths, keys, or reasoning;
/// only these categories cross the runtime seam.
enum AgentTurnFailure {
  invalidTarget,
  alreadyRunning,
  conversationUnavailable,
  scopeUnavailable,
  agentUnconfigured,
  profileUnavailable,
  unsupportedModel,
  unsupportedCapability,
  authentication,
  rateLimited,
  temporarilyUnavailable,
  timeout,
  cancelled,
  toolLimitExceeded,
  historyLimitExceeded,
  providerMalformed,
  persistenceFailed,
  internalError,
}

/// One transient Agent turn event.
sealed class AgentTurnEvent {
  const AgentTurnEvent();
}

/// A visible text fragment emitted by the Provider in emission order.
final class AgentTurnTextDelta extends AgentTurnEvent {
  const AgentTurnTextDelta(this.text);

  final String text;
}

/// Native Web search lifecycle progress.
final class AgentTurnWebSearchEvent extends AgentTurnEvent {
  const AgentTurnWebSearchEvent(this.phase);

  final AgentProviderWebSearchPhase phase;

  bool get isSearching => phase == AgentProviderWebSearchPhase.searching;
}

/// A local study tool invocation started.
final class AgentTurnToolCall extends AgentTurnEvent {
  const AgentTurnToolCall({required this.callId, required this.name});

  final String callId;
  final String name;
}

/// A W0 proposal was staged (or a semantic replay returned the existing
/// proposal with its current outcome). Carries typed proposal data only;
/// the UI never parses model prose.
final class AgentTurnProposalStaged extends AgentTurnEvent {
  const AgentTurnProposalStaged({
    required this.proposalId,
    required this.outcome,
    required this.preview,
  });

  final String proposalId;
  final String outcome;

  /// Structured preview from the Application-owned tool contract
  /// (`bank_name`/stem/options/proposed_answer); never LLM-authored prose.
  final Map<String, Object?> preview;
}

/// A StudyPlan proposal draft was staged (or a semantic replay returned the
/// existing draft with its current outcome). Carries typed preview data only;
/// the UI never parses model prose.
final class AgentTurnStudyPlanDraftStaged extends AgentTurnEvent {
  const AgentTurnStudyPlanDraftStaged({
    required this.draftId,
    required this.outcome,
    required this.preview,
  });

  final String draftId;
  final String outcome;

  /// Structured preview from the Application-owned tool contract
  /// (bank_name/goal/daily_target/priority/horizon_days/counts/estimated_days);
  /// never LLM-authored prose.
  final Map<String, Object?> preview;
}

/// The turn completed and the final visible Assistant text was persisted.
final class AgentTurnCompleted extends AgentTurnEvent {
  const AgentTurnCompleted(this.assistantMessage);

  final ConversationMessage assistantMessage;
}

/// The turn failed with a safe category.
final class AgentTurnFailedEvent extends AgentTurnEvent {
  const AgentTurnFailedEvent(this.failure);

  final AgentTurnFailure failure;
}

/// Consumer-facing handle for one in-flight Agent turn.
final class AgentTurnSession {
  const AgentTurnSession({
    required this.events,
    required this.result,
    required this.cancel,
    this.diagnosticId,
  });

  /// Transient progress events (text deltas, web phases, tool calls, and the
  /// terminal completed/failed event).
  final Stream<AgentTurnEvent> events;

  /// Terminal outcome; never throws.
  final Future<AgentTurnResult> result;

  /// Requests user cancellation of this turn.
  final void Function() cancel;

  /// OBS-1 stable diagnostic id (`diagnosticId == correlationId`) for this
  /// turn; present from turn creation onward on every production session.
  /// One Agent Turn has exactly one diagnostic id; success and failure
  /// belong to the same correlation.
  final String? diagnosticId;
}

/// Presentation-facing start seam for a turn bound to a persisted User
/// Message. Production passes [ShirohaAgentRuntime.startTurn]; widget tests can
/// provide a deterministic session without constructing provider adapters.
typedef AgentTurnStarter = AgentTurnSession Function({
  required String conversationId,
  required String userMessageId,
});

typedef AgentRetrievalTurnStarter = AgentTurnSession Function({
  required String conversationId,
  required String userMessageId,
  required RetrievalEgressApproval approval,
});
