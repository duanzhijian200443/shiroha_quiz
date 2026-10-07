library;

import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/question/question_draft_v2.dart';
import '../capabilities/capability.dart';
import 'agent_write_persistence.dart';
import 'agent_write_proposal.dart';
import 'agent_write_proposal_service.dart';

final class MissingAnswerInput {
  MissingAnswerInput({required this.targetStorageId, required this.payload});
  final String targetStorageId;
  final MissingAnswerPayload payload;
}

final class MissingAnswerPayload {
  MissingAnswerPayload(
      {Iterable<int>? optionNumbers, Iterable<ContentNode>? contentNodes})
      : optionNumbers =
            optionNumbers == null ? null : List.unmodifiable(optionNumbers),
        contentNodes =
            contentNodes == null ? null : List.unmodifiable(contentNodes);
  final List<int>? optionNumbers;
  final List<ContentNode>? contentNodes;
}

const proposeMissingAnswer =
    CapabilityId<MissingAnswerInput, AgentWriteProposal>(
        'propose_missing_answer');

CapabilityDefinition<MissingAnswerInput, AgentWriteProposal>
    missingAnswerCapability(
            {required AgentWritePersistencePort persistence,
            required AgentWriteProposalService proposalService}) =>
        _MissingAnswerHandler(persistence, proposalService).definition;

final class _MissingAnswerHandler {
  const _MissingAnswerHandler(this._persistence, this._proposalService);
  final AgentWritePersistencePort _persistence;
  final AgentWriteProposalService _proposalService;
  CapabilityDefinition<MissingAnswerInput, AgentWriteProposal> get definition =>
      CapabilityDefinition(
        id: proposeMissingAnswer,
        permission: CapabilityPermission.stage,
        permittedEffects: const [
          CapabilityEffect.none,
          CapabilityEffect.proposalStaged
        ],
        semantics: CapabilityExecutionSemantics.transientStage,
        admit: (input) {
          final numbers = input.payload.optionNumbers;
          final nodes = input.payload.contentNodes;
          if (input.targetStorageId.trim().isEmpty ||
              input.targetStorageId.runes.length > 128 ||
              (numbers == null) == (nodes == null) ||
              numbers != null &&
                  (numbers.isEmpty ||
                      numbers.length > 32 ||
                      numbers.any((n) => n < 1) ||
                      numbers.toSet().length != numbers.length) ||
              nodes != null && (nodes.isEmpty || nodes.length > 64)) {
            return CapabilityFailure.invalidRequest;
          }
          if (nodes != null &&
              nodes.any((node) => switch (node) {
                    TextNode(:final text) => text.runes.length > 2048,
                    InlineMathNode(:final latex) ||
                    BlockMathNode(:final latex) =>
                      latex.runes.length > 1024,
                    _ => true,
                  })) {
            return CapabilityFailure.invalidRequest;
          }
          return null;
        },
        authorize: (_, context) async =>
            context.principal == CapabilityPrincipal.builtInAgent &&
            context.sourceConversationId != null &&
            context.sourceMessageId != null,
        handler: CapabilityHandler((input, context, confirmed) async {
          try {
            final result = await _handle(input, context);
            if (result.effect case final effect?) {
              confirmed.confirm(effect, reference: result.reconciliation);
            }
            return result;
          } on AgentWriteStageResultTooLargeException {
            return CapabilityEvidence.zeroEffectFailure(
                CapabilityFailure.internalError);
          } on AgentWriteStageCancelledException {
            // Owning W0 activation gate explicitly proves zero lifecycle mutation.
            return CapabilityEvidence.zeroEffectFailure(
                CapabilityFailure.cancelled);
          }
        }),
      );
  Future<CapabilityEvidence<AgentWriteProposal>> _handle(
    MissingAnswerInput parsed,
    CapabilityContext context,
  ) async {
    final request = AgentWriteAdmissionRequest(
      sourceConversationId: context.sourceConversationId!,
      sourceMessageId: context.sourceMessageId!,
      scope: context.scope,
      targetStorageId: parsed.targetStorageId,
    );
    final admission = await _persistence.admitStagingTarget(request);
    if (admission is! AgentWriteAdmissionGranted) {
      // Unauthorized, nonexistent and unreadable targets share one safe
      // non-enumerating tool response without target identity or content.
      return CapabilityEvidence.zeroEffectFailure(CapabilityFailure.notFound);
    }
    final target = admission.target;
    final QuestionAnswer answer;
    final numbers = parsed.payload.optionNumbers;
    if (numbers != null) {
      if (numbers.any((number) => number > target.draft.options.length)) {
        return CapabilityEvidence.zeroEffectFailure(
            CapabilityFailure.ineligible);
      }
      answer = ChoiceAnswer(
        optionIds: <String>[
          for (final number in numbers)
            target.draft.options[number - 1].optionId,
        ],
      );
    } else {
      answer = ContentAnswer(
        content: RichContent(nodes: parsed.payload.contentNodes!),
      );
    }
    final staged = await _proposalService.stageProposal(
      admissionRequest: request,
      proposedAnswer: answer,
      resultSizeGate: context.proposalResultFits == null
          ? null
          : (candidate) => context.proposalResultFits!(candidate),
      lifecycleMutationAllowed: () => context.executionAllowed,
    );
    switch (staged) {
      case AgentWriteStageResultStaged(:final proposal):
        return CapabilityEvidence.completed(
            proposal, CapabilityEffect.proposalStaged,
            reconciliation: TransientReconciliationReference(
                owner: _proposalService, artifactId: proposal.id));
      case AgentWriteStageResultDenied() || AgentWriteStageResultUnavailable():
        return CapabilityEvidence.zeroEffectFailure(CapabilityFailure.notFound);
      case AgentWriteStageResultIneligible():
        return CapabilityEvidence.zeroEffectFailure(
            CapabilityFailure.ineligible);
    }
  }
}

AgentWriteProposal? reconcileMissingAnswer(AgentWriteProposalService service,
    TransientReconciliationReference reference) {
  if (!reference.belongsTo(service)) return null;
  try {
    return service.proposalById(reference.artifactId);
  } on ArgumentError {
    return null;
  }
}
