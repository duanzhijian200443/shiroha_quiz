import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_study_tool_catalog.dart';
import 'package:shiroha_quiz/application/agent/shiroha_system_prompt.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/mcp/study_mcp_adapter.dart';

void main() {
  test('all DM-P0 destructive authorities enter the shared trace seam', () {
    const authorities = <String, String>{
      'lib/application/questions/question_mutation_command.dart':
          'DestructiveMutationKind.questionDelete',
      'lib/application/questions/question_bank_mutation_command.dart':
          'DestructiveMutationKind.questionBankDelete',
      'lib/services/file_library/library_file_deletion_service.dart':
          'DestructiveMutationKind.libraryFileDelete',
      'lib/application/projects/project_service.dart':
          'DestructiveMutationKind.projectDelete',
      'lib/application/conversations/conversation_service.dart':
          'DestructiveMutationKind.conversationDelete',
      'lib/core/review_engine_service.dart':
          'DestructiveMutationKind.reviewStateReset',
      'lib/application/study_plan/study_plan_command_service.dart':
          'DestructiveMutationKind.studyPlanStop',
      'lib/application/exam/exam_mutation_command.dart':
          'DestructiveMutationKind.examPaperDelete',
    };

    for (final entry in authorities.entries) {
      final source = File(entry.key).readAsStringSync();
      expect(source, contains('DestructiveMutationTrace.run'));
      expect(source, contains(entry.value));
    }
    expect(
      File('lib/core/review_engine_service.dart').readAsStringSync(),
      contains('DestructiveMutationKind.questionDataClearAll'),
    );
  });

  test('MCP v0 remains exactly six read-only study tools', () {
    expect(StudyMcpAdapter.toolNames, hasLength(6));
    expect(AgentStudyToolCatalog.definitions, hasLength(6));
    expect(
      AgentStudyToolCatalog.definitions.map((tool) => tool.name),
      unorderedEquals(StudyMcpAdapter.toolNames),
    );
    expect(
      StudyMcpAdapter.toolNames.any(
        (name) => name.contains('delete') || name.contains('destructive'),
      ),
      isFalse,
    );
  });

  test('Agent declares destructive boundary without exposing runtime authority',
      () {
    final prompt = const ShirohaSystemPrompt().build(
      scope: ConversationScope.global(),
      proposalCapabilityEnabled: true,
    );

    expect(
      prompt,
      contains(
        'DESTRUCTIVE: Destructive operations must never be performed '
        'autonomously.',
      ),
    );
    expect(prompt, contains('Natural-language agreement is not approval.'));
    expect(prompt, isNot(contains('delete_question')));
    expect(prompt, isNot(contains('delete_library_file')));
  });
}
