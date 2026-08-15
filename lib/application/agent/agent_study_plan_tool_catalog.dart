/// Standalone SPL-1 StudyPlan proposal tool catalog (STAGE only).
///
/// The built-in Agent's read-only six-tool catalog (`AgentStudyToolCatalog`)
/// and MCP v0 remain untouched; this separate catalog carries exactly one
/// proposal tool (`propose_study_plan`) and exposes zero adoption, activation,
/// replacement, or stop operations. The model submits only the target bank name
/// and optional strategy parameters; the source Conversation, User Message, and
/// ConversationScope authority are injected exclusively by the trusted runtime.
library;

import 'agent_provider.dart';

final class AgentStudyPlanToolCatalog {
  const AgentStudyPlanToolCatalog();

  static const String toolName = 'propose_study_plan';

  static final AgentFunctionToolDefinition definition =
      AgentFunctionToolDefinition(
    name: toolName,
    description:
        'Propose staging a StudyPlan draft for user review and explicit adoption. '
        'The source Conversation, User Message, and scope authority are injected '
        'by the runtime; submit only the target bank name and optional strategy '
        'parameters (goal, daily target, priority, horizon days). Staging only: '
        'formal adoption is a separate Presentation action and this tool never '
        'activates or persists a plan.',
    inputSchema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'bank_name': <String, Object?>{
          'type': 'string',
          'minLength': 1,
          'maxLength': 200,
        },
        'goal': <String, Object?>{
          'type': 'string',
          'maxLength': 120,
        },
        'daily_target': <String, Object?>{
          'type': 'integer',
          'minimum': 1,
          'maximum': 200,
        },
        'priority': <String, Object?>{
          'type': 'string',
          'enum': <String>[
            'balanced',
            'due_first',
            'weak_first',
            'new_first',
          ],
        },
        'horizon_days': <String, Object?>{
          'type': 'integer',
          'minimum': 1,
          'maximum': 90,
        },
      },
      'required': <String>['bank_name'],
      'additionalProperties': false,
    },
  );
}
