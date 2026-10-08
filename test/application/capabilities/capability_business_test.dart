import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_runtime_limits.dart';
import 'package:shiroha_quiz/application/agent/agent_study_tool_dispatcher.dart';
import 'package:shiroha_quiz/application/agent/agent_study_plan_tool_dispatcher.dart';
import 'package:shiroha_quiz/application/agent/agent_write_proposal_tool_dispatcher.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_persistence.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_proposal.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_proposal_service.dart';
import 'package:shiroha_quiz/application/safe_write/missing_answer_capability.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_capability.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_draft_service.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_ports.dart';
import 'package:shiroha_quiz/application/study_query/study_capabilities.dart';
import 'package:shiroha_quiz/application/study_query/study_query_service.dart';
import 'package:shiroha_quiz/application/study_query/study_query_dtos.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/study_plan/study_plan_values.dart';
import 'package:shiroha_quiz/mcp/study_mcp_adapter.dart';

import 'capability_test_support.dart';

CapabilityContext _stageContext(
        {Iterable<CapabilityId> capabilities = const [
          proposeMissingAnswer,
          proposeStudyPlan
        ],
        Iterable<CapabilityPermission> permissions = const [
          CapabilityPermission.stage
        ],
        CapabilityPrincipal principal = CapabilityPrincipal.builtInAgent,
        ConversationScope? scope,
        bool Function()? budget}) =>
    CapabilityContext(
        principal: principal,
        capabilities: capabilities,
        permissions: permissions,
        scope: scope ?? ConversationScope.global(),
        authorizedScope: ConversationScope.global(),
        sourceConversationId: 'conversation',
        sourceMessageId: 'message',
        budgetAllowed: budget);

final class _WritePort implements AgentWritePersistencePort {
  int admissions = 0;
  int commits = 0;
  bool available = true;
  @override
  Future<AgentWriteAdmissionResult> admitStagingTarget(
      AgentWriteAdmissionRequest request) async {
    admissions++;
    if (!available) return const AgentWriteAdmissionDenied();
    return AgentWriteAdmissionGranted(AgentWriteAdmittedTarget(
        storageId: 'q1',
        bankName: 'Synthetic',
        draft: QuestionDraftV2(
            questionId: 'q1',
            kind: QuestionKind.shortAnswer,
            stem: RichContent(nodes: const [TextNode('Safe stem')]))));
  }

  @override
  Future<void> commitApproved(AgentWriteCommitRequest request) async {
    commits++;
  }
}

final class _PlanningPort implements StudyPlanPlanningPort {
  int reads = 0;
  bool available = true;
  @override
  Future<StudyPlanPlanningAdmission> loadPlanningContext(
      {required ConversationScope sourceScope,
      required String bankName,
      required DateTime now}) async {
    reads++;
    return available
        ? StudyPlanPlanningAdmitted(StudyPlanPlanningContext(
            bankName: bankName,
            questionCount: 10,
            masteredCount: 1,
            dueCount: 2,
            weakCount: 3,
            newCount: 4))
        : const StudyPlanPlanningUnavailable();
  }
}

StudyPlanDraftService _draftService(_PlanningPort port) =>
    StudyPlanDraftService(
        planningPort: port,
        draftIdFactory: () => 'draft-1',
        clock: () => DateTime.utc(2026, 8, 10));
MissingAnswerInput _answer() => MissingAnswerInput(
    targetStorageId: 'q1',
    payload: MissingAnswerPayload(contentNodes: const [TextNode('Answer')]));

void main() {
  test('actual Study handlers authorize direct calls before all query ports',
      () async {
    final questions = CapabilityQuestionPort();
    final metrics = CapabilityMetricsPort();
    final executor = CapabilityExecutor(ApplicationCapabilityRegistry(
        StudyCapabilities.definitions(StudyQueryService(
            questionQuery: questions,
            metricsQuery: metrics,
            clock: const CapabilityClock()))));
    for (final context in [
      CapabilityContext(
          principal: CapabilityPrincipal.builtInAgent,
          capabilities: const [],
          permissions: const [CapabilityPermission.read],
          scope: ConversationScope.global(),
          authorizedScope: ConversationScope.global()),
      CapabilityContext(
          principal: CapabilityPrincipal.builtInAgent,
          capabilities: StudyCapabilities.ids,
          permissions: const [CapabilityPermission.read],
          scope: ConversationScope.learningSpace('project'),
          authorizedScope: ConversationScope.learningSpace('project')),
    ]) {
      final result = await executor.execute(StudyCapabilities.getQuestionDetail,
          const GetQuestionDetailInput(questionId: 'q1'), context);
      expect(result.failure, CapabilityFailure.accessDenied);
      expect(result.receipt.status, CapabilityExecutionStatus.notStarted);
    }
    expect(questions.calls, isEmpty);
    expect(metrics.calls, isEmpty);
    final allowed = await executor.execute(
        StudyCapabilities.getQuestionDetail,
        const GetQuestionDetailInput(questionId: 'q1'),
        studyCapabilityContext(CapabilityPrincipal.builtInAgent));
    expect(allowed.output!.questionId, 'q1');
    expect(allowed.receipt.knownEffect, CapabilityEffect.none);
    expect(questions.calls, ['detail']);
  });

  test(
      'direct W0 and SPL reject READ-only, hidden capability, wrong scope and MCP before services',
      () async {
    final write = _WritePort();
    final plans = _PlanningPort();
    final executor = CapabilityExecutor(ApplicationCapabilityRegistry([
      missingAnswerCapability(
          persistence: write,
          proposalService: AgentWriteProposalService(write)),
      studyPlanCapability(_draftService(plans)),
    ]));
    for (final context in [
      _stageContext(permissions: const [CapabilityPermission.read]),
      _stageContext(capabilities: const []),
      _stageContext(scope: ConversationScope.learningSpace('other')),
      _stageContext(principal: CapabilityPrincipal.mcpStudyV0),
    ]) {
      for (final result in [
        await executor.execute(proposeMissingAnswer, _answer(), context),
        await executor.execute(proposeStudyPlan,
            const ProposeStudyPlanInput(bankName: 'Synthetic'), context)
      ]) {
        expect(result.failure, CapabilityFailure.accessDenied);
        expect(result.receipt.status, CapabilityExecutionStatus.notStarted);
      }
    }
    expect(write.admissions, 0);
    expect(plans.reads, 0);
    expect(write.commits, 0);
  });

  test(
      'W0 stage receipt reconciles only against the same owning lifecycle; formal commit untouched',
      () async {
    final port = _WritePort();
    final service = AgentWriteProposalService(port);
    final executor = CapabilityExecutor(ApplicationCapabilityRegistry([
      missingAnswerCapability(persistence: port, proposalService: service)
    ]));
    final result = await executor.execute(
        proposeMissingAnswer, _answer(), _stageContext());
    expect(result.receipt.status, CapabilityExecutionStatus.completed);
    expect(result.receipt.knownEffect, CapabilityEffect.proposalStaged);
    expect(result.receipt.authorization.conversationId, 'conversation');
    final ref = result.receipt.reconciliation!;
    expect(reconcileMissingAnswer(service, ref)!.id, result.output!.id);
    expect(
        reconcileMissingAnswer(AgentWriteProposalService(port), ref), isNull);
    expect(port.admissions, 2);
    expect(port.commits, 0);
    expect(executor.registry.definition(proposeMissingAnswer)!.semantics,
        CapabilityExecutionSemantics.transientStage);
  });

  test(
      'W0 encoding failure after successful staging preserves receipt and performs no automatic repeat',
      () async {
    final port = _WritePort();
    final service = AgentWriteProposalService(port);
    final executor = CapabilityExecutor(ApplicationCapabilityRegistry([
      missingAnswerCapability(persistence: port, proposalService: service)
    ]));
    // Direct typed STAGE has no Provider byte gate. Later explicit semantic
    // replay observes the existing lifecycle, and its final encoding can fail.
    final staged = await executor.execute(
        proposeMissingAnswer, _answer(), _stageContext());
    final dispatcher = AgentWriteProposalToolDispatcher(
        persistence: port,
        proposalService: service,
        executor: executor,
        limits: const AgentRuntimeLimits(maxToolResultUtf8Bytes: 1));
    final response = await dispatcher.dispatchWithReceipt(
        AgentWriteProposalToolCall(
            argumentsJson:
                '{"target":"q1","answer":{"content":{"nodes":[{"type":"text","text":"Answer"}]}}}',
            sourceConversationId: 'conversation',
            sourceMessageId: 'message',
            scope: ConversationScope.global()));
    expect(jsonDecode(response.json)['error']['code'], 'internal_error');
    expect(response.receipt.failure, CapabilityFailure.encodingFailed);
    expect(response.receipt.status, CapabilityExecutionStatus.completed);
    expect(response.receipt.knownEffect, CapabilityEffect.proposalStaged);
    expect(response.receipt.reconciliation!.artifactId, staged.output!.id);
    expect(service.proposalById(staged.output!.id).outcome,
        AgentWriteProposalOutcome.pending);
    expect(port.admissions, 4); // two explicit calls; no executor retry.
    expect(port.commits, 0);
  });

  test(
      'SPL encoding failure retains stage, same-process reference, no adoption or repeat',
      () async {
    final port = _PlanningPort();
    final service = _draftService(port);
    final dispatcher = AgentStudyPlanToolDispatcher(
        draftService: service,
        limits: const AgentRuntimeLimits(maxToolResultUtf8Bytes: 1));
    final response = await dispatcher.dispatchWithReceipt(
        AgentStudyPlanToolCall(
            argumentsJson: '{"bank_name":"Synthetic"}',
            sourceConversationId: 'conversation',
            sourceMessageId: 'message',
            scope: ConversationScope.global()));
    expect(jsonDecode(response.json)['error']['code'], 'internal_error');
    expect(response.receipt.status, CapabilityExecutionStatus.completed);
    expect(response.receipt.knownEffect, CapabilityEffect.proposalStaged);
    expect(response.receipt.failure, CapabilityFailure.encodingFailed);
    final ref = response.receipt.reconciliation!;
    expect(reconcileStudyPlan(service, ref)!.outcome,
        StudyPlanDraftOutcome.pending);
    expect(reconcileStudyPlan(_draftService(port), ref), isNull);
    expect(port.reads, 1);
    expect(studyPlanCapability(service).semantics,
        CapabilityExecutionSemantics.transientStage);
  });

  test(
      'service non-enumerating denials carry authoritative zero-effect evidence',
      () async {
    final write = _WritePort()..available = false;
    final plans = _PlanningPort()..available = false;
    final executor = CapabilityExecutor(ApplicationCapabilityRegistry([
      missingAnswerCapability(
          persistence: write,
          proposalService: AgentWriteProposalService(write)),
      studyPlanCapability(_draftService(plans)),
    ]));
    for (final result in [
      await executor.execute(proposeMissingAnswer, _answer(), _stageContext()),
      await executor.execute(proposeStudyPlan,
          const ProposeStudyPlanInput(bankName: 'Synthetic'), _stageContext())
    ]) {
      expect(result.output, isNull);
      expect(
          result.receipt.status, CapabilityExecutionStatus.failedWithoutEffect);
      expect(result.receipt.knownEffect, CapabilityEffect.none);
      expect(result.receipt.reconciliation, isNull);
    }
  });

  test(
      'six Agent/MCP projections share typed handlers and exact success body parity',
      () async {
    final questions = CapabilityQuestionPort();
    final metrics = CapabilityMetricsPort();
    final service = StudyQueryService(
        questionQuery: questions,
        metricsQuery: metrics,
        clock: const CapabilityClock());
    final definitions = StudyCapabilities.definitions(service);
    var entries = 0;
    // Instrument the typed handler boundary, not legacy JSON.
    CapabilityDefinition<I, O> counted<I, O>(CapabilityDefinition<I, O> d) =>
        CapabilityDefinition<I, O>(
            id: d.id,
            permission: d.permission,
            permittedEffects: d.permittedEffects,
            semantics: d.semantics,
            authorize: d.authorize,
            handler: CapabilityHandler<I, O>((input, context, evidence) {
              entries++;
              return d.handler.invoke(input, context, evidence);
            }));
    final executor = CapabilityExecutor(ApplicationCapabilityRegistry([
      counted<ListQuestionBanksInput, BankListPage>(definitions[0]
          as CapabilityDefinition<ListQuestionBanksInput, BankListPage>),
      counted<GetStudyOverviewInput, StudyOverview>(definitions[1]
          as CapabilityDefinition<GetStudyOverviewInput, StudyOverview>),
      counted<GetDueReviewSummaryInput, DueReviewSummary>(definitions[2]
          as CapabilityDefinition<GetDueReviewSummaryInput, DueReviewSummary>),
      counted<SearchQuestionsInput, QuestionSearchPage>(definitions[3]
          as CapabilityDefinition<SearchQuestionsInput, QuestionSearchPage>),
      counted<GetQuestionDetailInput, QuestionDetail>(definitions[4]
          as CapabilityDefinition<GetQuestionDetailInput, QuestionDetail>),
      counted<GetWeakQuestionsInput, WeakQuestionPage>(definitions[5]
          as CapabilityDefinition<GetWeakQuestionsInput, WeakQuestionPage>),
    ]));
    final agent =
        AgentStudyToolDispatcher(service: service, executor: executor);
    final mcp = StudyMcpAdapter(
        service: service, executor: executor, clock: const CapabilityClock());
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
    for (final entry in calls.entries) {
      final legacy =
          jsonDecode(await agent.dispatch(entry.key, jsonEncode(entry.value)))
              as Map<String, dynamic>;
      final wire = await mcp.callTool(entry.key, entry.value);
      expect(legacy['ok'], isTrue);
      final body = Map<String, Object?>.of(wire.envelope)
        ..remove('schema_version')
        ..remove('generated_at');
      expect(body.containsKey('data') ? body['data'] : body, legacy['result']);
      expect(wire.isError, isFalse);
    }
    expect(entries, 12);
    expect(StudyMcpAdapter.toolNames, calls.keys.toList());
    expect(
        definitions.every((d) =>
            d.permission == CapabilityPermission.read &&
            d.permittedEffects.single == CapabilityEffect.none),
        isTrue);
  });
}
