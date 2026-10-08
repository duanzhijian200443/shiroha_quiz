/// A0-4 Shiroha Agent runtime: one orchestrated, provider-neutral turn over a
/// persisted C0 User Message.
library;

import 'dart:async';
import 'dart:convert';

import '../../core/observability/diagnostic_summary.dart';
import '../../core/observability/log_writer.dart';
import '../../core/observability/trace_context.dart';
import '../../domain/conversations/conversation.dart';
import '../../domain/conversations/conversation_message.dart';
import '../backup/backup_restore_gate.dart';
import '../conversations/conversation_repository.dart';
import '../conversations/conversation_service.dart';
import '../capabilities/capability.dart';
import '../study_query/study_capabilities.dart';
import '../safe_write/missing_answer_capability.dart';
import '../study_plan/study_plan_capability.dart';
import '../retrieval/retrieval_capability.dart';
import 'agent_tool_projection.dart';
import 'agent_turn_transcript.dart';
import 'agent_config.dart';
import 'agent_config_service.dart';
import 'agent_history.dart';
import 'agent_provider.dart';
import 'provider_round.dart';
import 'agent_retrieval_tool.dart';
import 'agent_runtime_limits.dart';
import 'agent_study_plan_tool_catalog.dart';
import 'agent_study_plan_tool_dispatcher.dart';
import 'agent_study_tool_catalog.dart';
import 'agent_study_tool_dispatcher.dart';
import 'agent_turn.dart';
import 'agent_write_proposal_tool_catalog.dart';
import 'agent_write_proposal_tool_dispatcher.dart';
import 'shiroha_system_prompt.dart';
import 'retrieval_egress_grant.dart';

part 'agent_turn_coordinator.dart';
part 'agent_round_engine.dart';
part 'agent_tool_executor.dart';
part 'agent_turn_policy.dart';
part 'agent_turn_finalizer.dart';
part 'provider_round_gateway.dart';

/// Provider construction remains in the existing composition root.
typedef AgentProviderFactory = AgentProviderPort Function(
    ResolvedAgentConfig resolvedConfig);

/// Retained Presentation-facing facade; concrete turn owners stay behind it.
final class ShirohaAgentRuntime {
  ShirohaAgentRuntime(
      {required ConversationService conversationService,
      required AgentRuntimeConfigResolver configResolver,
      required AgentProviderFactory providerFactory,
      required AgentStudyToolDispatcher toolDispatcher,
      AgentWriteProposalToolDispatcher? proposalDispatcher,
      AgentStudyPlanToolDispatcher? studyPlanDispatcher,
      AgentRetrievalToolDispatcher? retrievalDispatcher,
      AgentRuntimeLimits limits = const AgentRuntimeLimits()})
      : _coordinator = AgentTurnCoordinator(
            conversationService: conversationService,
            configResolver: configResolver,
            providerFactory: providerFactory,
            toolDispatcher: toolDispatcher,
            proposalDispatcher: proposalDispatcher,
            studyPlanDispatcher: studyPlanDispatcher,
            retrievalDispatcher: retrievalDispatcher,
            limits: limits);
  final AgentTurnCoordinator _coordinator;
  AgentTurnSession startTurn(
          {required String conversationId, required String userMessageId}) =>
      _coordinator.startTurn(
          conversationId: conversationId, userMessageId: userMessageId);
  AgentTurnSession startTurnWithRetrieval(
          {required String conversationId,
          required String userMessageId,
          required RetrievalEgressApproval approval}) =>
      _coordinator.startTurnWithRetrieval(
          conversationId: conversationId,
          userMessageId: userMessageId,
          approval: approval);
}
