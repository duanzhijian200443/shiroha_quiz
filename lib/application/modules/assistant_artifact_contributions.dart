import 'module_composition.dart';

const missingAnswerArtifactUi = ModuleUiContribution(
    key: 'missing_answer_artifact', slot: ModuleUiSlot.assistantArtifact);
const studyPlanArtifactUi = ModuleUiContribution(
    key: 'study_plan_artifact', slot: ModuleUiSlot.assistantArtifact);

/// Compatibility composition for existing Assistant constructor callers.
const retainedAssistantArtifactContributions = [
  missingAnswerArtifactUi,
  studyPlanArtifactUi,
];
