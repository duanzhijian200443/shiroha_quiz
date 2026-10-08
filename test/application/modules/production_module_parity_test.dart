import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_retrieval_tool.dart';
import 'package:shiroha_quiz/application/agent/agent_study_tool_dispatcher.dart';
import 'package:shiroha_quiz/application/agent/agent_study_plan_tool_dispatcher.dart';
import 'package:shiroha_quiz/application/agent/agent_write_proposal_tool_dispatcher.dart';
import 'package:shiroha_quiz/application/agent/agent_surface.dart';
import 'package:shiroha_quiz/application/agent/shiroha_system_prompt.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/modules/module_composition.dart';
import 'package:shiroha_quiz/application/modules/production_modules.dart';
import 'package:shiroha_quiz/application/retrieval/retrieval_ports.dart';
import 'package:shiroha_quiz/application/retrieval/retrieval_service.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_proposal_service.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_draft_service.dart';
import 'package:shiroha_quiz/application/study_query/study_query_service.dart';
import 'package:shiroha_quiz/application/study_query/study_capabilities.dart';
import 'package:shiroha_quiz/application/conversations/conversation_repository.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/mcp/study_mcp_module_surface.dart';
import 'package:shiroha_quiz/services/retrieval/deterministic_source_chunker.dart';
import '../capabilities/capability_test_support.dart';
import 'fixtures/accepted_system_prompt.dart';
import 'module_service_fakes.dart';

void main() {
  late StudyQueryService study;
  late ModuleWritePort write;
  late AgentWriteProposalService proposals;
  late StudyPlanDraftService plans;
  late List<ModuleContribution> modules;
  setUp(() {
    study = StudyQueryService(
        questionQuery: CapabilityQuestionPort(),
        metricsQuery: CapabilityMetricsPort(),
        clock: const CapabilityClock());
    write = ModuleWritePort();
    proposals = AgentWriteProposalService(write);
    plans = StudyPlanDraftService(
        planningPort: ModulePlanningPort(),
        draftIdFactory: () => 'draft-1',
        clock: () => DateTime.utc(2026, 8, 10));
    modules = buildDefaultModules(
        study: study,
        retrieval: RetrievalService(
            scopeResolver: ModuleScope(),
            artifactSource: ModuleSource(),
            index: ModuleIndex(RetrievalBuildEffect.unchanged),
            chunker: const DeterministicSourceChunker()),
        missingAnswerPersistence: write,
        missingAnswerProposals: proposals,
        studyPlan: plans);
  });
  ModuleComposition compose([ModuleId? disabled]) =>
      const ModuleComposer().compose(modules.where((m) => m.id != disabled));
  CapabilityContext context(RegisteredAgentProjection projection) =>
      CapabilityContext(
          principal: CapabilityPrincipal.builtInAgent,
          capabilities: [projection.capabilityId],
          permissions: [projection.permission],
          scope: ConversationScope.global(),
          authorizedScope: ConversationScope.global(),
          sourceConversationId: 'conversation',
          sourceMessageId: 'message');
  test(
      'production list is explicit, deterministic, nine Agent tools and six MCP reads',
      () {
    final result = compose();
    expect(result.moduleOrder.map((m) => m.value),
        ['missing_answer', 'retrieval', 'study', 'study_plan']);
    expect(result.capabilities.definitions, hasLength(9));
    expect(result.agentSurface.projections, hasLength(9));
    expect(result.mcpSurface.map((p) => p.key),
        StudyCapabilities.ids.map((id) => id.value));
    expect(result.uiContributions, isEmpty);
    final acceptedList = jsonDecode(
        File('test/application/capabilities/fixtures/agent_tool_contracts.json')
            .readAsStringSync()) as List;
    final accepted = {for (final d in acceptedList) d['name']: d};
    final actual = {
      for (final p in result.agentSurface.exposed(fileAccess: true))
        p.definition.name: {
          'name': p.definition.name,
          'description': p.definition.description,
          'input_schema': p.definition.inputSchema
        }
    };
    expect(actual, accepted);
    expect(
        result.agentSurface
            .exposed(fileAccess: true)
            .map((p) => p.definition.name),
        [
          ...StudyCapabilities.ids.map((id) => id.value),
          'propose_missing_answer',
          'propose_study_plan',
          'retrieve_file_content'
        ]);
  });
  test('production module permutations preserve all registry orders', () {
    final a = compose();
    final b = const ModuleComposer().compose(modules.reversed);
    expect(b.moduleOrder, a.moduleOrder);
    expect(b.capabilities.definitions.map((d) => d.id),
        a.capabilities.definitions.map((d) => d.id));
    expect(b.agentSurface.projections.map((p) => p.definition.name),
        a.agentSurface.projections.map((p) => p.definition.name));
    expect(b.mcpSurface.map((p) => p.key), a.mcpSurface.map((p) => p.key));
    expect(b.uiContributions, a.uiContributions);
  });
  for (final disabled in <ModuleId?>[
    null,
    retrievalModuleId,
    missingAnswerModuleId,
    studyPlanModuleId
  ]) {
    for (final fileAccess in [false, true]) {
      test(
          'accepted prompt exact parity: disabled=${disabled?.value}, grant=$fileAccess',
          () {
        final result = compose(disabled);
        final retrieval = fileAccess && disabled != retrievalModuleId;
        for (final scope in [
          ConversationScope.global(),
          ConversationScope.learningSpace('project'),
          ConversationScope.unavailableLearningSpace()
        ]) {
          final files = [
            ConversationFileRef(
                fileId: 'file-1',
                displayName: 'Synthetic\nfile.txt',
                mimeType: 'text/plain',
                sizeBytes: 20)
          ];
          final expected = const AcceptedSystemPrompt().build(
              scope: scope,
              proposalCapabilityEnabled: disabled != missingAnswerModuleId,
              studyPlanCapabilityEnabled: disabled != studyPlanModuleId,
              retrievalCapabilityEnabled: retrieval,
              retrievableFileIds: const {'file-1'},
              files: files);
          final actual = const ShirohaSystemPrompt().build(
              scope: scope,
              proposalCapabilityEnabled: false,
              retrievalCapabilityEnabled: retrieval,
              registeredGuidance:
                  result.agentSurface.guidance(fileAccess: retrieval),
              retrievableFileIds: const {'file-1'},
              files: files);
          expect(actual, expected);
        }
      });
    }
  }
  test(
      'disabled modules remove only their capabilities/projections/guidance; storage is not a callback',
      () {
    for (final disabled in [
      retrievalModuleId,
      missingAnswerModuleId,
      studyPlanModuleId,
      studyModuleId
    ]) {
      final result = compose(disabled);
      final removed = disabled == studyModuleId
          ? StudyCapabilities.ids.map((id) => id.value).toSet()
          : {
              switch (disabled) {
                retrievalModuleId => 'retrieve_file_content',
                missingAnswerModuleId => 'propose_missing_answer',
                _ => 'propose_study_plan'
              }
            };
      expect(
          result.capabilities.definitions
              .any((d) => removed.contains(d.id.value)),
          isFalse);
      expect(
          result.agentSurface.projections
              .any((p) => removed.contains(p.definition.name)),
          isFalse);
      final text = const ShirohaSystemPrompt().build(
          scope: ConversationScope.global(),
          proposalCapabilityEnabled: false,
          registeredGuidance: result.agentSurface.guidance(fileAccess: true));
      for (final name in removed) {
        expect(text, isNot(contains(name)));
      }
      if (disabled == studyModuleId) {
        expect(text, isNot(contains('Use local study tools')));
        expect(result.mcpSurface, isEmpty);
        expect(buildStudyMcpServerFromComposition(result, study), isNull);
      } else {
        expect(result.mcpSurface, hasLength(6));
      }
    }
    expect(write.commits, 0);
  });
  test(
      'Agent registration preserves Study output and malformed input error parity',
      () async {
    final result = compose();
    final legacy = AgentStudyToolDispatcher(service: study);
    final inputs = {
      'list_question_banks': '{}',
      'get_study_overview': '{"timezone":"UTC"}',
      'get_due_review_summary':
          '{"from":"2026-08-09T00:00:00Z","to":"2026-08-11T00:00:00Z","timezone":"UTC"}',
      'search_questions': '{"bank_name":"Synthetic","query":"Safe"}',
      'get_question_detail': '{"question_id":"q1"}',
      'get_weak_questions': '{}'
    };
    for (final entry in inputs.entries) {
      final p = result.agentSurface.projections
          .singleWhere((p) => p.definition.name == entry.key);
      for (final input in [entry.value, '{', '[]']) {
        final actual = await p.dispatch(AgentProjectionInvocation(
            argumentsJson: input, context: context(p)));
        expect(jsonDecode(actual.json),
            jsonDecode(await legacy.dispatch(entry.key, input)));
        expect(actual.receipt.capabilityId, p.capabilityId);
      }
    }
  });
  test(
      'registered W0/SPL retain transient staging and legacy success/error envelopes',
      () async {
    final result = compose();
    final answer = result.agentSurface.projections
        .singleWhere((p) => p.definition.name == 'propose_missing_answer');
    final plan = result.agentSurface.projections
        .singleWhere((p) => p.definition.name == 'propose_study_plan');
    final legacyAnswer = AgentWriteProposalToolDispatcher(
        persistence: write, proposalService: proposals);
    final legacyPlan = AgentStudyPlanToolDispatcher(draftService: plans);
    for (final input in ['{', '{}']) {
      expect(
          (await answer.dispatch(AgentProjectionInvocation(
                  argumentsJson: input, context: context(answer))))
              .json,
          await legacyAnswer.dispatch(AgentWriteProposalToolCall(
              argumentsJson: input,
              sourceConversationId: 'conversation',
              sourceMessageId: 'message',
              scope: ConversationScope.global())));
      expect(
          (await plan.dispatch(AgentProjectionInvocation(
                  argumentsJson: input, context: context(plan))))
              .json,
          await legacyPlan.dispatch(AgentStudyPlanToolCall(
              argumentsJson: input,
              sourceConversationId: 'conversation',
              sourceMessageId: 'message',
              scope: ConversationScope.global())));
    }
    final staged = await plan.dispatch(AgentProjectionInvocation(
        argumentsJson:
            '{"bank_name":"Synthetic","daily_target":5,"priority":"balanced"}',
        context: context(plan)));
    expect(staged.receipt.knownEffect, CapabilityEffect.proposalStaged);
    expect(staged.receipt.reconciliation!.belongsTo(plans), isTrue);
    expect(write.commits, 0);
  });
  test('registered retrieval denies before querying when grant is missing',
      () async {
    final p =
        compose().agentSurface.projections.singleWhere((p) => p.requiresEgress);
    final response = await p.dispatch(
        AgentProjectionInvocation(argumentsJson: '{}', context: context(p)));
    expect(jsonDecode(response.json)['error']['code'], 'access_denied');
    expect(response.receipt.status, CapabilityExecutionStatus.notStarted);
    expect(p.definition.name, AgentRetrievalToolCatalog.toolName);
  });
  test('MCP converter retains exact-six schema/annotation/wire authority',
      () async {
    final server = buildStudyMcpServerFromComposition(compose(), study)!;
    expect(server.toolNames, StudyCapabilities.ids.map((id) => id.value));
    expect(server.isConnected, isFalse);
    await server.close();
  });
}
