import 'agent_surface.dart';

String _missingAnswer() {
  final buffer = StringBuffer();
  buffer
    ..writeln(
      '- You may request a DRAFT/STAGE proposal for a missing typed '
      'answer with propose_missing_answer.',
    )
    ..writeln(
      '- You cannot approve, commit, replace, clear, or delete answers.',
    )
    ..writeln('- Natural-language agreement is not approval.')
    ..writeln(
      '- Never claim that a proposal was committed or formally written.',
    );

  return buffer.toString();
}

String _studyPlan() {
  final buffer = StringBuffer();
  buffer
    ..writeln(
      '- When the user asks for a study plan, you may inspect learning '
      'state with study tools and stage a proposal with propose_study_plan.',
    )
    ..writeln(
      '- Calling propose_study_plan only stages a draft for review; '
      'it does not adopt, activate, or persist the plan.',
    )
    ..writeln(
      '- Tell the user to review the proposal card and tap the action '
      'button to explicitly adopt the plan.',
    )
    ..writeln('- Natural-language agreement is not formal adoption.')
    ..writeln(
      '- Never claim that a study plan was saved or activated before '
      'formal confirmation.',
    )
    ..writeln(
      '- Do not repeatedly regenerate an identical StudyPlan proposal '
      'unless requested or required.',
    );

  return buffer.toString();
}

String _study() {
  final buffer = StringBuffer();
  buffer
    ..writeln('- Use local study tools when study data is needed.')
    ..writeln(
      '- Prefer aggregate study tools before per-question detail tools.',
    );
  return buffer.toString();
}

final missingAnswerGuidance =
    AgentPromptGuidance(AgentGuidanceSlot.permission, _missingAnswer());
final studyPlanGuidance =
    AgentPromptGuidance(AgentGuidanceSlot.permission, _studyPlan());
final studyGuidance =
    AgentPromptGuidance(AgentGuidanceSlot.studyTools, _study());
const retrievalToolGuidance = AgentPromptGuidance(AgentGuidanceSlot.fileTool,
    '- When the answer depends on an attached file, use retrieve_file_content before study tools.\n');
const retrievalAvailabilityGuidance = AgentPromptGuidance(
    AgentGuidanceSlot.fileAvailability,
    '- Approved file text is available only through retrieve_file_content for this turn.\n- Never claim to read content outside the approved tool result.\n');
