import '../../domain/generated_question/generated_question_contract.dart';
import '../capabilities/capability.dart';
import '../generated_question/generated_question_service.dart';
import 'module_composition.dart';

const generatedQuestionModuleId = ModuleId('generated_question');
const readGeneratedProposal =
    CapabilityId<GeneratedProposalRead, GeneratedQuestionProposal>(
        'read_generated_proposal');

final class GeneratedProposalRead {
  const GeneratedProposalRead(this.proposalId, this.authority);
  final String proposalId;
  final GeneratedLocalContext authority;
}

/// Internal read registration only. Staging/review/formal approval stay behind
/// explicit trusted Application commands. No Agent/MCP projection is added.
ModuleContribution generatedQuestionModule(GeneratedQuestionService service) =>
    ModuleContribution(
      id: generatedQuestionModuleId,
      registerUi: (r) => r.registerUiContribution(const ModuleUiContribution(
          key: 'generated_proposal_review',
          slot: ModuleUiSlot.workspaceAction)),
      registerCapabilities: (r) => r.registerCapability(CapabilityDefinition<
          GeneratedProposalRead, GeneratedQuestionProposal>(
        id: readGeneratedProposal,
        permission: CapabilityPermission.read,
        permittedEffects: const [CapabilityEffect.none],
        semantics: CapabilityExecutionSemantics.repeatableRead,
        authorize: (input, context) async =>
            input.authority.isCurrent() && context.authorizationCurrent != null,
        release: (input, context) async => input.authority.isCurrent(),
        handler:
            CapabilityHandler<GeneratedProposalRead, GeneratedQuestionProposal>(
                (input, context, evidence) async {
          try {
            final p = await service.persistence
                .read(input.proposalId, input.authority);
            return CapabilityEvidence.completed(p, CapabilityEffect.none);
          } on GeneratedQuestionException catch (e) {
            return CapabilityEvidence.zeroEffectFailure(
                e.failure == GeneratedFailure.unauthorized
                    ? CapabilityFailure.accessDenied
                    : e.failure == GeneratedFailure.proposalUnavailable
                        ? CapabilityFailure.notFound
                        : CapabilityFailure.dataCorrupt);
          }
        }),
      )),
    );
