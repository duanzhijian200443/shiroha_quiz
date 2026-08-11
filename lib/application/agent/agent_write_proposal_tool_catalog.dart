/// Standalone W0 proposal tool catalog (DRAFT/STAGE only).
///
/// The built-in Agent's read-only six-tool catalog (`AgentStudyToolCatalog`)
/// stays untouched; this separate catalog carries exactly one proposal tool
/// and exposes no approve or commit operation. The model submits only the
/// target storage identity and the proposed answer; the source Conversation
/// and User Message identity is injected by the runtime.
library;

import 'agent_provider.dart';

final class AgentWriteProposalToolCatalog {
  const AgentWriteProposalToolCatalog();

  static const String toolName = 'propose_missing_answer';

  static final AgentFunctionToolDefinition definition =
      AgentFunctionToolDefinition(
    name: toolName,
    description:
        'Propose filling the missing typed answer of one question. The '
        'source Conversation and User Message are injected by the runtime; '
        'submit only the target storage identity and the proposed answer '
        '(1-based option numbers or structural content nodes). Staging only: '
        'approval is a separate Presentation action and this tool never '
        'commits.',
    inputSchema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'target': <String, Object?>{'type': 'string'},
        'answer': <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'option_numbers': <String, Object?>{
              'type': 'array',
              'items': <String, Object?>{'type': 'integer', 'minimum': 1},
              'minItems': 1,
              'maxItems': 32,
            },
            'content': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'nodes': <String, Object?>{
                  'type': 'array',
                  'items': <String, Object?>{
                    'type': 'object',
                    'properties': <String, Object?>{
                      'type': <String, Object?>{'type': 'string'},
                      'text': <String, Object?>{'type': 'string'},
                      'latex': <String, Object?>{'type': 'string'},
                    },
                  },
                  'minItems': 1,
                  'maxItems': 64,
                },
              },
              'required': <String>['nodes'],
            },
          },
        },
      },
      'required': <String>['target', 'answer'],
    },
  );
}
