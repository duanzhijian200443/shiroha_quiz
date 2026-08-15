/// Deterministic SPL-1 preview builder.
///
/// The preview is built by Application code exclusively from the normalized
/// plan fields and the admitted planning context. LLM-authored prose is
/// never the authoritative preview. The result is a bounded typed value;
/// provider encoding is a later SPL-1-I0 concern and never happens here.
library;

import '../../domain/study_plan/study_plan_values.dart';

final class StudyPlanPreviewBuilder {
  const StudyPlanPreviewBuilder();

  /// Builds the deterministic preview value.
  ///
  /// [estimatedDays] is advisory progress guidance only
  /// (`ceil(unmastered / dailyTarget)`, zero when nothing is unmastered);
  /// it is never scheduling authority and never mutates review state.
  StudyPlanPreview build({
    required StudyPlanInput plan,
    required StudyPlanPlanningContext context,
  }) {
    final unmastered = context.questionCount - context.masteredCount;
    final estimatedDays =
        unmastered <= 0 ? 0 : (unmastered / plan.dailyTarget).ceil();
    return StudyPlanPreview(
      bankName: plan.bankName,
      goal: plan.goal,
      dailyTarget: plan.dailyTarget,
      priority: plan.priority,
      horizonDays: plan.horizonDays,
      questionCount: context.questionCount,
      masteredCount: context.masteredCount,
      dueCount: context.dueCount,
      weakCount: context.weakCount,
      newCount: context.newCount,
      estimatedDays: estimatedDays,
    );
  }
}
