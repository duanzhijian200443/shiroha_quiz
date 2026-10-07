library;

import '../../domain/study_plan/study_plan_draft.dart';
import '../../domain/study_plan/study_plan_values.dart';
import '../capabilities/capability.dart';
import 'study_plan_draft_service.dart';
import 'study_plan_ports.dart';

final class ProposeStudyPlanInput {
  const ProposeStudyPlanInput(
      {required this.bankName,
      this.goal,
      this.dailyTarget,
      this.priority,
      this.horizonDays});
  final String bankName;
  final String? goal;
  final int? dailyTarget;
  final StudyPlanPriority? priority;
  final int? horizonDays;
}

const proposeStudyPlan =
    CapabilityId<ProposeStudyPlanInput, StudyPlanDraft>('propose_study_plan');

CapabilityDefinition<ProposeStudyPlanInput, StudyPlanDraft> studyPlanCapability(
        StudyPlanDraftService service) =>
    CapabilityDefinition(
      id: proposeStudyPlan,
      permission: CapabilityPermission.stage,
      permittedEffects: const [
        CapabilityEffect.none,
        CapabilityEffect.proposalStaged
      ],
      semantics: CapabilityExecutionSemantics.transientStage,
      authorize: (_, context) async =>
          context.principal == CapabilityPrincipal.builtInAgent &&
          context.sourceConversationId != null &&
          context.sourceMessageId != null,
      handler: CapabilityHandler((input, context, confirmed) async {
        final StudyPlanStageResult result;
        try {
          result = await service.stage(
              sourceConversationId: context.sourceConversationId!,
              sourceMessageId: context.sourceMessageId!,
              sourceScope: context.scope,
              bankName: input.bankName,
              goal: input.goal,
              dailyTarget: input.dailyTarget,
              priority: input.priority,
              horizonDays: input.horizonDays,
              lifecycleMutationAllowed: () => context.executionAllowed);
        } on StudyPlanException catch (error) {
          // StudyPlanDraftService throws this read failure before activation.
          if (error.failure == StudyPlanFailure.temporarilyUnavailable) {
            return CapabilityEvidence.zeroEffectFailure(
                CapabilityFailure.temporarilyUnavailable);
          }
          rethrow;
        }
        final CapabilityEvidence<StudyPlanDraft> evidence = switch (result) {
          StudyPlanStageResultStaged(:final draft) =>
            CapabilityEvidence.completed(draft, CapabilityEffect.proposalStaged,
                reconciliation: TransientReconciliationReference(
                    owner: service, artifactId: draft.draftId)),
          StudyPlanStageResultUnavailable() =>
            CapabilityEvidence.zeroEffectFailure(
                CapabilityFailure.targetUnavailable),
          StudyPlanStageResultCancelled() =>
            CapabilityEvidence.zeroEffectFailure(CapabilityFailure.cancelled),
          StudyPlanStageResultInvalid() ||
          StudyPlanStageResultBusy() ||
          StudyPlanStageResultStale() =>
            CapabilityEvidence.zeroEffectFailure(CapabilityFailure.invalidPlan),
        };
        if (evidence.effect case final effect?) {
          confirmed.confirm(effect, reference: evidence.reconciliation);
        }
        return evidence;
      }),
    );

StudyPlanDraft? reconcileStudyPlan(
    StudyPlanDraftService service, TransientReconciliationReference reference) {
  if (!reference.belongsTo(service)) return null;
  try {
    return service.draftById(reference.artifactId);
  } on ArgumentError {
    return null;
  }
}
