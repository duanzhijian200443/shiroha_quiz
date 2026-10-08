import '../agent/agent_feature_guidance.dart';
import '../agent/agent_retrieval_tool.dart';
import '../agent/agent_study_plan_tool_catalog.dart';
import '../agent/agent_study_plan_tool_dispatcher.dart';
import '../agent/agent_study_tool_catalog.dart';
import '../agent/agent_study_tool_dispatcher.dart';
import '../agent/agent_surface.dart';
import '../agent/agent_write_proposal_tool_catalog.dart';
import '../agent/agent_write_proposal_tool_dispatcher.dart';
import '../capabilities/capability.dart';
import '../retrieval/retrieval_capability.dart';
import '../retrieval/retrieval_service.dart';
import '../safe_write/agent_write_persistence.dart';
import '../safe_write/agent_write_proposal_service.dart';
import '../safe_write/missing_answer_capability.dart';
import '../study_plan/study_plan_capability.dart';
import '../study_plan/study_plan_draft_service.dart';
import '../study_query/study_capabilities.dart';
import '../study_query/study_query_service.dart';
import 'module_composition.dart';

const studyModuleId = ModuleId('study');
const retrievalModuleId = ModuleId('retrieval');
const missingAnswerModuleId = ModuleId('missing_answer');
const studyPlanModuleId = ModuleId('study_plan');

ModuleContribution studyModule(StudyQueryService service) => ModuleContribution(
      id: studyModuleId,
      registerCapabilities: (registrar) {
        for (final definition in StudyCapabilities.definitions(service)) {
          registrar.registerCapability(definition);
        }
      },
      registerAgent: (registrar) {
        for (final definition in AgentStudyToolCatalog.definitions) {
          registrar.registerAgentProjection((executor) {
            final projection =
                AgentStudyToolProjection(service: service, executor: executor);
            return RegisteredAgentProjection(
              capabilityId: StudyCapabilities.ids
                  .singleWhere((id) => id.value == definition.name),
              definition: definition,
              guidance: definition == AgentStudyToolCatalog.definitions.first
                  ? [studyGuidance]
                  : const [],
              dispatch: (call) => projection.dispatchWithReceipt(
                  definition.name, call.argumentsJson,
                  context: call.context),
            );
          });
        }
      },
      registerMcp: (registrar) {
        for (final id in StudyCapabilities.ids) {
          registrar.registerMcpProjection(
              ModuleMcpProjection(key: id.value, capabilityId: id));
        }
      },
    );

ModuleContribution retrievalModule(RetrievalService service) =>
    ModuleContribution(
      id: retrievalModuleId,
      registerCapabilities: (r) =>
          r.registerCapability(retrievalCapability(service)),
      registerAgent: (r) => r.registerAgentProjection((executor) {
        final projection = AgentRetrievalToolProjection(
            retrieval: service, executor: executor);
        return RegisteredAgentProjection(
          capabilityId: retrieveFileContent,
          exposureOrder: 3,
          definition: AgentRetrievalToolCatalog.definition,
          guidance: const [
            retrievalToolGuidance,
            retrievalAvailabilityGuidance
          ],
          effectiveFileIds: projection.effectiveFileIds,
          dispatch: (call) => projection.dispatchWithReceipt(
              argumentsJson: call.argumentsJson, context: call.context),
        );
      }),
    );

ModuleContribution missingAnswerModule(
        {required AgentWritePersistencePort persistence,
        required AgentWriteProposalService proposalService}) =>
    ModuleContribution(
      id: missingAnswerModuleId,
      registerCapabilities: (r) => r.registerCapability(missingAnswerCapability(
          persistence: persistence, proposalService: proposalService)),
      registerAgent: (r) => r.registerAgentProjection((executor) {
        final projection = AgentWriteProposalToolProjection(
            persistence: persistence,
            proposalService: proposalService,
            executor: executor);
        return RegisteredAgentProjection(
            capabilityId: proposeMissingAnswer,
            permission: CapabilityPermission.stage,
            exposureOrder: 1,
            definition: AgentWriteProposalToolCatalog.definition,
            guidance: [missingAnswerGuidance],
            dispatch: (call) => projection.dispatchWithReceipt(
                AgentWriteProposalToolCall(
                    argumentsJson: call.argumentsJson,
                    sourceConversationId: call.context.sourceConversationId!,
                    sourceMessageId: call.context.sourceMessageId!,
                    scope: call.context.scope),
                proposalMutationAllowed: () => call.context.executionAllowed,
                cancellationSignal: call.context.cancellationSignal,
                isCancelled: call.context.isCancelled,
                deadline: call.context.deadline));
      }),
    );

ModuleContribution studyPlanModule(StudyPlanDraftService service) =>
    ModuleContribution(
      id: studyPlanModuleId,
      registerCapabilities: (r) =>
          r.registerCapability(studyPlanCapability(service)),
      registerAgent: (r) => r.registerAgentProjection((executor) {
        final projection = AgentStudyPlanToolProjection(
            draftService: service, executor: executor);
        return RegisteredAgentProjection(
            capabilityId: proposeStudyPlan,
            permission: CapabilityPermission.stage,
            exposureOrder: 2,
            definition: AgentStudyPlanToolCatalog.definition,
            guidance: [studyPlanGuidance],
            dispatch: (call) => projection.dispatchWithReceipt(
                AgentStudyPlanToolCall(
                    argumentsJson: call.argumentsJson,
                    sourceConversationId: call.context.sourceConversationId!,
                    sourceMessageId: call.context.sourceMessageId!,
                    scope: call.context.scope),
                lifecycleMutationAllowed: () => call.context.executionAllowed,
                cancellationSignal: call.context.cancellationSignal,
                isCancelled: call.context.isCancelled,
                deadline: call.context.deadline));
      }),
    );

/// Already constructed services stay explicit at the composition root.
List<ModuleContribution> buildDefaultModules(
        {required StudyQueryService study,
        required RetrievalService retrieval,
        required AgentWritePersistencePort missingAnswerPersistence,
        required AgentWriteProposalService missingAnswerProposals,
        required StudyPlanDraftService studyPlan}) =>
    List.unmodifiable([
      studyModule(study),
      retrievalModule(retrieval),
      missingAnswerModule(
          persistence: missingAnswerPersistence,
          proposalService: missingAnswerProposals),
      studyPlanModule(studyPlan),
    ]);
