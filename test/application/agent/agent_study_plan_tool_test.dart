import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_study_plan_tool_catalog.dart';
import 'package:shiroha_quiz/application/agent/agent_study_plan_tool_dispatcher.dart';
import 'package:shiroha_quiz/application/agent/agent_study_tool_catalog.dart';
import 'package:shiroha_quiz/application/agent/shiroha_system_prompt.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_command_service.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_draft_service.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_ports.dart';
import 'package:shiroha_quiz/domain/study_plan/active_study_plan.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/study_plan/study_plan_values.dart';
import 'package:shiroha_quiz/mcp/study_mcp_adapter.dart';

final class _RecordingPersistencePort implements StudyPlanPersistencePort {
  int commitCalls = 0;
  ActiveStudyPlan? activePlan;

  @override
  Future<ActiveStudyPlan?> loadActivePlan() async => activePlan;

  @override
  Future<StudyPlanPersistenceCommitResult> commitAdoption({
    required String planId,
    required String bankName,
    String? goal,
    required int dailyTarget,
    required StudyPlanPriority priority,
    int? horizonDays,
    String? sourceConversationId,
    String? sourceUserMessageId,
    required ConversationScope sourceScope,
    required DateTime adoptedAt,
    String? expectedActivePlanId,
    required bool replacementConfirmed,
  }) async {
    commitCalls++;
    return const StudyPlanPersistenceCommitFailed();
  }

  @override
  Future<StudyPlanPersistenceStopResult> stopActivePlan({
    required String expectedPlanId,
  }) async {
    return const StudyPlanPersistenceStopStaleActivePlan();
  }
}

final class _FakePlanningPort implements StudyPlanPlanningPort {
  bool admit = true;
  bool throwUnavailable = false;
  ConversationScope? lastScope;
  String? lastBankName;

  @override
  Future<StudyPlanPlanningAdmission> loadPlanningContext({
    required ConversationScope sourceScope,
    required String bankName,
    required DateTime now,
  }) async {
    lastScope = sourceScope;
    lastBankName = bankName;
    if (throwUnavailable) {
      throw const StudyPlanReadException(StudyPlanReadFailure.unavailable);
    }
    if (!admit) {
      return const StudyPlanPlanningUnavailable();
    }
    return StudyPlanPlanningAdmitted(
      StudyPlanPlanningContext(
        bankName: bankName,
        questionCount: 50,
        masteredCount: 10,
        dueCount: 15,
        weakCount: 5,
        newCount: 20,
      ),
    );
  }
}

void main() {
  group('Section 37: Tool Catalog & Schema contract', () {
    test('1. AgentStudyPlanToolCatalog contains exactly propose_study_plan',
        () {
      expect(AgentStudyPlanToolCatalog.toolName, 'propose_study_plan');
      expect(AgentStudyPlanToolCatalog.definition.name, 'propose_study_plan');
    });

    test('2. AgentStudyToolCatalog remains exactly six read tools', () {
      expect(AgentStudyToolCatalog.definitions, hasLength(6));
      final names =
          AgentStudyToolCatalog.definitions.map((d) => d.name).toSet();
      expect(
        names,
        equals(<String>{
          'list_question_banks',
          'get_study_overview',
          'get_due_review_summary',
          'search_questions',
          'get_question_detail',
          'get_weak_questions',
        }),
      );
    });

    test('3. propose_study_plan is NOT in AgentStudyToolCatalog', () {
      final names =
          AgentStudyToolCatalog.definitions.map((d) => d.name).toSet();
      expect(names.contains('propose_study_plan'), isFalse);
    });

    test('4. propose_study_plan is NOT in MCP tool catalog', () {
      final mcpNames = StudyMcpAdapter.toolNames.toSet();
      expect(mcpNames, hasLength(6));
      expect(mcpNames.contains('propose_study_plan'), isFalse);
    });

    test(
        '5. tool schema: strict bounds, required bank_name, additionalProperties false',
        () {
      final schema = AgentStudyPlanToolCatalog.definition.inputSchema;
      expect(schema['type'], 'object');
      expect(schema['required'], equals(<String>['bank_name']));
      expect(schema['additionalProperties'], isFalse);

      final properties = schema['properties'] as Map<String, Object?>;
      expect(
        properties.keys.toSet(),
        equals(<String>{
          'bank_name',
          'goal',
          'daily_target',
          'priority',
          'horizon_days',
        }),
      );

      // Verify priority enum
      final priorityProp = properties['priority'] as Map<String, Object?>;
      expect(
        priorityProp['enum'],
        equals(<String>['balanced', 'due_first', 'weak_first', 'new_first']),
      );

      // Verify no model authority fields in schema
      for (final forbidden in <String>[
        'sourceConversationId',
        'sourceMessageId',
        'sourceScope',
        'projectId',
        'draftId',
        'planId',
        'expectedActivePlanId',
        'replacementConfirmed',
      ]) {
        expect(properties.containsKey(forbidden), isFalse);
      }
    });
  });

  group('Section 38: Runtime source authority injection', () {
    test('Global scope: dispatcher uses trusted runtime source parameters',
        () async {
      final planningPort = _FakePlanningPort();
      final draftService = StudyPlanDraftService(
        planningPort: planningPort,
        draftIdFactory: () => 'draft_test_1',
        clock: () => DateTime.utc(2026, 8, 15),
      );
      final dispatcher =
          AgentStudyPlanToolDispatcher(draftService: draftService);

      final call = AgentStudyPlanToolCall(
        argumentsJson: jsonEncode(<String, Object?>{
          'bank_name': 'Math',
          'daily_target': 30,
          'priority': 'due_first',
        }),
        sourceConversationId: 'conv_runtime_A',
        sourceMessageId: 'msg_runtime_M',
        scope: ConversationScope.global(),
      );

      final resultJson = await dispatcher.dispatch(call);
      final decoded = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(decoded['ok'], isTrue);

      final draft = draftService.draftById('draft_test_1');
      expect(draft.sourceConversationId, 'conv_runtime_A');
      expect(draft.sourceMessageId, 'msg_runtime_M');
      expect(draft.sourceScope, ConversationScope.global());
      expect(planningPort.lastScope, ConversationScope.global());
      expect(planningPort.lastBankName, 'Math');
    });

    test('LearningSpace scope: dispatcher passes exact Project scope',
        () async {
      final planningPort = _FakePlanningPort();
      final draftService = StudyPlanDraftService(
        planningPort: planningPort,
        draftIdFactory: () => 'draft_test_2',
        clock: () => DateTime.utc(2026, 8, 15),
      );
      final dispatcher =
          AgentStudyPlanToolDispatcher(draftService: draftService);

      final call = AgentStudyPlanToolCall(
        argumentsJson: jsonEncode(<String, Object?>{
          'bank_name': 'Physics',
          'goal': 'Learn mechanics',
        }),
        sourceConversationId: 'conv_runtime_B',
        sourceMessageId: 'msg_runtime_N',
        scope: ConversationScope.learningSpace('proj_x'),
      );

      final resultJson = await dispatcher.dispatch(call);
      final decoded = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(decoded['ok'], isTrue);

      final draft = draftService.draftById('draft_test_2');
      expect(draft.sourceConversationId, 'conv_runtime_B');
      expect(draft.sourceMessageId, 'msg_runtime_N');
      expect(draft.sourceScope, ConversationScope.learningSpace('proj_x'));
      expect(planningPort.lastScope, ConversationScope.learningSpace('proj_x'));
    });

    test('Model input cannot spoof authority keys (rejected as invalid_plan)',
        () async {
      final planningPort = _FakePlanningPort();
      final draftService = StudyPlanDraftService(
        planningPort: planningPort,
        draftIdFactory: () => 'draft_test_3',
        clock: () => DateTime.utc(2026, 8, 15),
      );
      final dispatcher =
          AgentStudyPlanToolDispatcher(draftService: draftService);

      final call = AgentStudyPlanToolCall(
        argumentsJson: jsonEncode(<String, Object?>{
          'bank_name': 'Math',
          'source_conversation_id': 'spoofed_conv',
          'draft_id': 'spoofed_draft',
          'plan_id': 'spoofed_plan',
        }),
        sourceConversationId: 'conv_real',
        sourceMessageId: 'msg_real',
        scope: ConversationScope.global(),
      );

      final resultJson = await dispatcher.dispatch(call);
      final decoded = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(decoded['ok'], isFalse);
      expect(decoded['error']['code'], 'invalid_plan');
    });
  });

  group('Section 39: Staging outcomes', () {
    late _FakePlanningPort planningPort;
    late StudyPlanDraftService draftService;
    late AgentStudyPlanToolDispatcher dispatcher;

    setUp(() {
      planningPort = _FakePlanningPort();
      var seq = 0;
      draftService = StudyPlanDraftService(
        planningPort: planningPort,
        draftIdFactory: () => 'draft_${++seq}',
        clock: () => DateTime.utc(2026, 8, 15),
      );
      dispatcher = AgentStudyPlanToolDispatcher(draftService: draftService);
    });

    test('valid proposal -> staged with allowlisted deterministic preview',
        () async {
      final call = AgentStudyPlanToolCall(
        argumentsJson: jsonEncode(<String, Object?>{
          'bank_name': 'Math',
          'daily_target': 25,
          'priority': 'balanced',
          'horizon_days': 14,
        }),
        sourceConversationId: 'conv_1',
        sourceMessageId: 'msg_1',
        scope: ConversationScope.global(),
      );

      final resultJson = await dispatcher.dispatch(call);
      final decoded = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(decoded['ok'], isTrue);
      final result = decoded['result'] as Map<String, dynamic>;
      expect(result['status'], 'staged');
      expect(result['draft_id'], 'draft_1');
      expect(result['outcome'], 'pending');

      final preview = result['preview'] as Map<String, dynamic>;
      expect(preview['bank_name'], 'Math');
      expect(preview['daily_target'], 25);
      expect(preview['priority'], 'balanced');
      expect(preview['horizon_days'], 14);
      expect(preview['question_count'], 50);
      expect(preview['mastered_count'], 10);
      expect(preview['due_count'], 15);
      expect(preview['weak_count'], 5);
      expect(preview['new_count'], 20);
      expect(preview['estimated_days'], 2); // ceil((50-10)/25) = 2
    });

    test(
        'same semantic proposal replay reuses draft identity and current outcome',
        () async {
      final call = AgentStudyPlanToolCall(
        argumentsJson: jsonEncode(<String, Object?>{
          'bank_name': 'Math',
          'daily_target': 25,
        }),
        sourceConversationId: 'conv_1',
        sourceMessageId: 'msg_1',
        scope: ConversationScope.global(),
      );

      final res1 = await dispatcher.dispatch(call);
      final draftId1 = jsonDecode(res1)['result']['draft_id'];

      final res2 = await dispatcher.dispatch(call);
      final draftId2 = jsonDecode(res2)['result']['draft_id'];

      expect(draftId1, draftId2);
    });

    test('revised proposal on same source turn supersedes old pending draft',
        () async {
      final call1 = AgentStudyPlanToolCall(
        argumentsJson: jsonEncode(<String, Object?>{
          'bank_name': 'Math',
          'daily_target': 25,
        }),
        sourceConversationId: 'conv_1',
        sourceMessageId: 'msg_1',
        scope: ConversationScope.global(),
      );

      final call2 = AgentStudyPlanToolCall(
        argumentsJson: jsonEncode(<String, Object?>{
          'bank_name': 'Math',
          'daily_target': 50,
        }),
        sourceConversationId: 'conv_1',
        sourceMessageId: 'msg_1',
        scope: ConversationScope.global(),
      );

      final res1 = await dispatcher.dispatch(call1);
      final draftId1 = jsonDecode(res1)['result']['draft_id'];
      expect(draftService.draftById(draftId1).outcome,
          StudyPlanDraftOutcome.pending);

      final res2 = await dispatcher.dispatch(call2);
      final draftId2 = jsonDecode(res2)['result']['draft_id'];
      expect(draftId2, isNot(draftId1));

      // Old draft is superseded
      expect(draftService.draftById(draftId1).outcome,
          StudyPlanDraftOutcome.superseded);
      expect(draftService.draftById(draftId2).outcome,
          StudyPlanDraftOutcome.pending);
    });

    test('proposal while committing is a bounded busy/invalid result',
        () async {
      final call1 = AgentStudyPlanToolCall(
        argumentsJson: jsonEncode(<String, Object?>{
          'bank_name': 'Math',
          'daily_target': 25,
        }),
        sourceConversationId: 'conv_1',
        sourceMessageId: 'msg_1',
        scope: ConversationScope.global(),
      );

      final res1 = await dispatcher.dispatch(call1);
      final draftId1 = jsonDecode(res1)['result']['draft_id'];

      // Move to committing
      draftService.tryBeginCommit(draftId1);

      // Attempt second proposal while committing
      final call2 = AgentStudyPlanToolCall(
        argumentsJson: jsonEncode(<String, Object?>{
          'bank_name': 'Math',
          'daily_target': 50,
        }),
        sourceConversationId: 'conv_1',
        sourceMessageId: 'msg_1',
        scope: ConversationScope.global(),
      );

      final res2 = await dispatcher.dispatch(call2);
      final decoded = jsonDecode(res2);
      expect(decoded['ok'], isFalse);
      expect(decoded['error']['code'], 'invalid_plan');
    });

    test('unavailable planning target returns bounded target_unavailable',
        () async {
      planningPort.admit = false;

      final call = AgentStudyPlanToolCall(
        argumentsJson: jsonEncode(<String, Object?>{
          'bank_name': 'UnknownBank',
        }),
        sourceConversationId: 'conv_1',
        sourceMessageId: 'msg_1',
        scope: ConversationScope.global(),
      );

      final res = await dispatcher.dispatch(call);
      final decoded = jsonDecode(res);
      expect(decoded['ok'], isFalse);
      expect(decoded['error']['code'], 'target_unavailable');
    });

    test('infrastructure failure maps to temporarily_unavailable', () async {
      planningPort.throwUnavailable = true;

      final call = AgentStudyPlanToolCall(
        argumentsJson: jsonEncode(<String, Object?>{
          'bank_name': 'Math',
        }),
        sourceConversationId: 'conv_1',
        sourceMessageId: 'msg_1',
        scope: ConversationScope.global(),
      );

      final res = await dispatcher.dispatch(call);
      final decoded = jsonDecode(res);
      expect(decoded['ok'], isFalse);
      expect(decoded['error']['code'], 'temporarily_unavailable');
    });
  });

  group('Section 41: Tool result privacy allowlist / denylist', () {
    test(
        'tool result contains only allowlisted keys and no sensitive authority/data',
        () async {
      final planningPort = _FakePlanningPort();
      final draftService = StudyPlanDraftService(
        planningPort: planningPort,
        draftIdFactory: () => 'draft_privacy_test',
        clock: () => DateTime.utc(2026, 8, 15),
      );
      final dispatcher =
          AgentStudyPlanToolDispatcher(draftService: draftService);

      final call = AgentStudyPlanToolCall(
        argumentsJson: jsonEncode(<String, Object?>{
          'bank_name': 'Math',
          'goal': 'Score 100',
          'daily_target': 30,
          'priority': 'weak_first',
          'horizon_days': 7,
        }),
        sourceConversationId: 'conv_secret_123',
        sourceMessageId: 'msg_secret_456',
        scope: ConversationScope.learningSpace('proj_secret_789'),
      );

      final resultJson = await dispatcher.dispatch(call);
      final decoded = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(decoded['ok'], isTrue);

      final rawOutput = resultJson.toLowerCase();

      // Denylist checks
      for (final forbidden in <String>[
        'conv_secret_123',
        'msg_secret_456',
        'proj_secret_789',
        'sourceconversationid',
        'sourcemessageid',
        'sourcescope',
        'projectid',
        'expectedactiveplanid',
        'planid',
        'sql',
        'reasoning_content',
        'stack',
        'api_key',
        'token',
      ]) {
        expect(rawOutput.contains(forbidden), isFalse,
            reason: 'Output should not contain $forbidden');
      }
    });
  });

  group('Section 42: System prompt distinctions', () {
    test(
        'system prompt teaches propose vs adopt and prohibits claiming activation',
        () {
      const promptBuilder = ShirohaSystemPrompt();
      final prompt = promptBuilder.build(
        scope: ConversationScope.global(),
        proposalCapabilityEnabled: false,
        studyPlanCapabilityEnabled: true,
      );

      expect(prompt, contains('propose_study_plan'));
      expect(
          prompt,
          contains(
              'Calling propose_study_plan only stages a draft for review'));
      expect(prompt, contains('does not adopt, activate, or persist the plan'));
      expect(prompt,
          contains('Natural-language agreement is not formal adoption'));
      expect(prompt,
          contains('Never claim that a study plan was saved or activated'));
    });
  });

  group('Section 40: Tool staging performs zero durable writes', () {
    test('successful propose_study_plan call leaves no ActiveStudyPlan',
        () async {
      final planningPort = _FakePlanningPort();
      final draftService = StudyPlanDraftService(
        planningPort: planningPort,
        draftIdFactory: () => 'draft_nodurable',
        clock: () => DateTime.utc(2026, 8, 15),
      );
      final persistence = _RecordingPersistencePort();
      final commandService = StudyPlanCommandService(
        draftService: draftService,
        persistencePort: persistence,
        planIdFactory: () => 'plan_nodurable',
        clock: () => DateTime.utc(2026, 8, 15),
      );
      final dispatcher =
          AgentStudyPlanToolDispatcher(draftService: draftService);

      final call = AgentStudyPlanToolCall(
        argumentsJson: jsonEncode(<String, Object?>{
          'bank_name': 'Math',
          'daily_target': 30,
        }),
        sourceConversationId: 'conv_1',
        sourceMessageId: 'msg_1',
        scope: ConversationScope.global(),
      );

      final resultJson = await dispatcher.dispatch(call);
      final decoded = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(decoded['ok'], isTrue);
      expect(decoded['result']['status'], 'staged');

      // The tool call stages a transient draft only: no durable plan exists,
      // no persistence command was issued, and no adoption can be reached.
      final active = await commandService.loadActivePlan();
      expect(active, isNull);
      expect(persistence.commitCalls, 0);

      // A second staging call also persists nothing (replay keeps the draft).
      final replayJson = await dispatcher.dispatch(call);
      final replay = jsonDecode(replayJson) as Map<String, dynamic>;
      expect(replay['ok'], isTrue);
      expect(await commandService.loadActivePlan(), isNull);
      expect(persistence.commitCalls, 0);
    });
  });

  group('Section 50: Transient draft authority does not survive restart', () {
    test('fresh service cannot revive an old transient draft from text',
        () async {
      final planningPort = _FakePlanningPort();
      final draftService = StudyPlanDraftService(
        planningPort: planningPort,
        draftIdFactory: () => 'draft_transient',
        clock: () => DateTime.utc(2026, 8, 15),
      );
      final dispatcher =
          AgentStudyPlanToolDispatcher(draftService: draftService);

      final call = AgentStudyPlanToolCall(
        argumentsJson: jsonEncode(<String, Object?>{
          'bank_name': 'Math',
          'daily_target': 30,
        }),
        sourceConversationId: 'conv_1',
        sourceMessageId: 'msg_1',
        scope: ConversationScope.global(),
      );
      final staged = await dispatcher.dispatch(call);
      final draftId =
          (jsonDecode(staged) as Map<String, dynamic>)['result']['draft_id'];
      expect(draftService.draftById(draftId).outcome,
          StudyPlanDraftOutcome.pending);

      // A fresh service instance models a process restart: the old draft id
      // is unknown, so historical text alone cannot re-acquire adoption
      // authority.
      final freshService = StudyPlanDraftService(
        planningPort: planningPort,
        draftIdFactory: () => 'draft_fresh',
        clock: () => DateTime.utc(2026, 8, 15),
      );
      expect(() => freshService.draftById(draftId), throwsArgumentError);
    });
  });
}
