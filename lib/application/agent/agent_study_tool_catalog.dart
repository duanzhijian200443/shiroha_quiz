/// Exactly-six read-only study tools exposed to the built-in Agent.
library;

import 'agent_provider.dart';

final class AgentStudyToolCatalog {
  const AgentStudyToolCatalog();

  static final List<AgentFunctionToolDefinition> definitions =
      List<AgentFunctionToolDefinition>.unmodifiable(
    <AgentFunctionToolDefinition>[
      AgentFunctionToolDefinition(
        name: 'list_question_banks',
        description:
            'List question banks with question, due, and mastered counts.',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'cursor': _nullableString,
            'limit': <String, Object?>{
              'type': 'integer',
              'minimum': 1,
              'maximum': 100,
              'default': 50,
            },
          },
        },
      ),
      AgentFunctionToolDefinition(
        name: 'get_study_overview',
        description:
            'Global or bank-scoped study overview counts for the timezone day.',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'bank_name': _nullableString,
            'timezone': <String, Object?>{'type': 'string'},
          },
          'required': <String>['timezone'],
        },
      ),
      AgentFunctionToolDefinition(
        name: 'get_due_review_summary',
        description:
            'Due-now and scheduled review counts with local-date buckets over '
            'a half-open window.',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'bank_name': _nullableString,
            'timezone': _nullableString,
            'from': <String, Object?>{
              'type': 'string',
              'pattern': _offsetBearingRfc3339Pattern,
            },
            'to': <String, Object?>{
              'type': 'string',
              'pattern': _offsetBearingRfc3339Pattern,
            },
          },
          'required': <String>['from', 'to'],
        },
      ),
      AgentFunctionToolDefinition(
        name: 'search_questions',
        description:
            'Search questions in one bank and return safe stem previews.',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'bank_name': <String, Object?>{'type': 'string'},
            'query': <String, Object?>{
              'type': 'string',
              'minLength': 1,
              'maxLength': 200,
            },
            'cursor': _nullableString,
            'limit': <String, Object?>{
              'type': 'integer',
              'minimum': 1,
              'maximum': 50,
            },
          },
          'required': <String>['bank_name', 'query'],
        },
      ),
      AgentFunctionToolDefinition(
        name: 'get_question_detail',
        description: 'Safe rich-content detail and due state for one question.',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'question_id': <String, Object?>{'type': 'string'},
          },
          'required': <String>['question_id'],
        },
      ),
      AgentFunctionToolDefinition(
        name: 'get_weak_questions',
        description: 'Weak-question summary with lapse and difficulty metrics.',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'bank_name': _nullableString,
            'cursor': _nullableString,
            'limit': <String, Object?>{
              'type': 'integer',
              'minimum': 1,
              'maximum': 50,
            },
          },
        },
      ),
    ],
  );

  static List<String> get toolNames => List<String>.unmodifiable(
        definitions.map((definition) => definition.name),
      );
}

const Map<String, Object?> _nullableString = <String, Object?>{
  'anyOf': <Map<String, Object?>>[
    <String, Object?>{'type': 'string'},
    <String, Object?>{'type': 'null'},
  ],
};

const String _offsetBearingRfc3339Pattern =
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$';
