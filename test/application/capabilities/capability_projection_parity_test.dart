import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_runtime_limits.dart';
import 'package:shiroha_quiz/application/agent/agent_study_tool_catalog.dart';
import 'package:shiroha_quiz/application/agent/agent_study_tool_dispatcher.dart';
import 'package:shiroha_quiz/application/agent/agent_retrieval_tool.dart';
import 'package:shiroha_quiz/application/agent/agent_write_proposal_tool_catalog.dart';
import 'package:shiroha_quiz/application/agent/agent_study_plan_tool_catalog.dart';
import 'package:shiroha_quiz/application/study_query/study_query_service.dart';
import 'package:shiroha_quiz/mcp/study_mcp_adapter.dart';

import 'capability_test_support.dart';

void main() {
  test(
      'all nine Provider names/descriptions/input schemas match the master contract snapshot',
      () {
    final definitions = [
      ...AgentStudyToolCatalog.definitions,
      AgentRetrievalToolCatalog.definition,
      AgentWriteProposalToolCatalog.definition,
      AgentStudyPlanToolCatalog.definition
    ];
    expect(
        [
          for (final d in definitions)
            {
              'name': d.name,
              'description': d.description,
              'input_schema': d.inputSchema
            }
        ],
        jsonDecode(File(
                'test/application/capabilities/fixtures/agent_tool_contracts.json')
            .readAsStringSync()));
    expect(definitions, hasLength(9));
    expect(StudyMcpAdapter.toolNames, AgentStudyToolCatalog.toolNames);
    expect(StudyMcpAdapter.toolNames, hasLength(6));
  });

  final calls = <String, Map<String, Object?>>{
    'list_question_banks': {},
    'get_study_overview': {'timezone': 'UTC'},
    'get_due_review_summary': {
      'from': '2026-08-09T00:00:00Z',
      'to': '2026-08-11T00:00:00Z'
    },
    'search_questions': {'bank_name': 'Synthetic', 'query': 'safe'},
    'get_question_detail': {'question_id': 'q1'},
    'get_weak_questions': {},
  };
  for (final call in calls.entries) {
    test(
        '${call.key}: invalid JSON and argument byte limit reject before query; result bound stays fixed',
        () async {
      final questions = CapabilityQuestionPort();
      final metrics = CapabilityMetricsPort();
      final service = StudyQueryService(
          questionQuery: questions,
          metricsQuery: metrics,
          clock: const CapabilityClock());
      final dispatcher = AgentStudyToolDispatcher(service: service);
      for (final input in ['{', '[]', 'null', ' ' * (16 * 1024 + 1)]) {
        final result = jsonDecode(await dispatcher.dispatch(call.key, input));
        expect(result, {
          'ok': false,
          'error': {
            'code': 'invalid_request',
            'message': 'The request is invalid.',
            'retryable': false
          }
        });
      }
      expect(questions.calls, isEmpty);
      expect(metrics.calls, isEmpty);
      // Original study schemas permit unknown fields. They remain ignored;
      // they cannot elevate Application capability/permission authority.
      final allowed = {...call.value, 'permission': 'COMMIT', 'approved': true};
      expect(
          jsonDecode(
              await dispatcher.dispatch(call.key, jsonEncode(allowed)))['ok'],
          isTrue);
      final bounded = AgentStudyToolDispatcher(
          service: service,
          limits: const AgentRuntimeLimits(maxToolResultUtf8Bytes: 1));
      expect(
          jsonDecode(await bounded.dispatch(call.key, jsonEncode(call.value)))[
              'error']['code'],
          'internal_error');
    });
  }

  test('six study invalid business inputs retain Agent/MCP error-code parity',
      () async {
    final service = StudyQueryService(
        questionQuery: CapabilityQuestionPort(),
        metricsQuery: CapabilityMetricsPort(),
        clock: const CapabilityClock());
    final agent = AgentStudyToolDispatcher(service: service);
    final mcp =
        StudyMcpAdapter(service: service, clock: const CapabilityClock());
    final invalid = <String, Map<String, Object?>>{
      'list_question_banks': {'limit': 101},
      'get_study_overview': {},
      'get_due_review_summary': {
        'from': '2026-08-10T00:00:00Z',
        'to': '2026-08-09T00:00:00Z'
      },
      'search_questions': {'bank_name': 'Synthetic'},
      'get_question_detail': {},
      'get_weak_questions': {'limit': 51},
    };
    for (final entry in invalid.entries) {
      final a =
          jsonDecode(await agent.dispatch(entry.key, jsonEncode(entry.value)));
      final b = await mcp.callTool(entry.key, entry.value);
      expect(a['error'], b.envelope['error']);
      expect(a['error']['code'], 'invalid_request');
    }
  });
}
