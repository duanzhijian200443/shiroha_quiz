// SPL-1-V0 focused acceptance.
//
// ACCEPTANCE-FIRST: proves the complete SPL-1 v0 critical chain with REAL
// production seams on REAL synthetic SQLite (schema v22). No production code
// is modified; no live provider, network, MCP, browser, real user database,
// or filesystem assets are used. All sentinel strings are fictional.
//
// Chain under acceptance:
//
//   propose_study_plan (real dispatcher/draft service, runtime-owned source)
//   -> transient StudyPlanDraft (zero durable mutation)
//   -> explicit adoptDraft command (durable ActiveStudyPlan, CAS)
//   -> transient-vs-durable restart boundary
//   -> LearningSpace provenance != ownership
//   -> live deterministic selection (real StudyPlanSelectionService)
//   -> fresh session recomputation
//   -> non-preview Practice materialization + normal Review/FSRS mutation
//   -> typed + legacy exact-order materialization
//   -> planUnavailable persistence
//   -> replacement/stop CAS
//   -> advisory mastery/horizon states
//   -> frozen Agent/MCP/schema acceptance
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_study_plan_tool_catalog.dart';
import 'package:shiroha_quiz/application/agent/agent_study_plan_tool_dispatcher.dart';
import 'package:shiroha_quiz/application/agent/agent_study_tool_catalog.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_command_service.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_draft_service.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_pool_order.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_selection_service.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/review_engine_service.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/settings_repository.dart';
import 'package:shiroha_quiz/data/repositories/study_plan_persistence_repository.dart';
import 'package:shiroha_quiz/data/repositories/study_plan_read_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/study_plan/active_study_plan.dart';
import 'package:shiroha_quiz/domain/study_plan/study_plan_values.dart';
import 'package:shiroha_quiz/mcp/study_mcp_adapter.dart';
import 'package:shiroha_quiz/services/study_plan/study_plan_practice_session_launcher.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _bankName = 'v0_synthetic_bank';
const _typedStorageIdA = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a01';

final _v0Clock = DateTime.utc(2026, 8, 15, 10, 0);
const _mapper = QuestionV2PersistenceMapper();

final _typedDraftA = QuestionDraftV2(
  questionId: 'q_typed_a',
  kind: QuestionKind.singleChoice,
  stem: RichContent(nodes: <ContentNode>[TextNode('Typed V0 stem.')]),
  options: <QuestionOption>[
    QuestionOption(
      optionId: 'opt_a',
      label: 'A',
      content: RichContent(nodes: <ContentNode>[TextNode('typed-opt-a')]),
    ),
    QuestionOption(
      optionId: 'opt_b',
      label: 'B',
      content: RichContent(nodes: <ContentNode>[TextNode('typed-opt-b')]),
    ),
  ],
  answer: ChoiceAnswer(optionIds: <String>['opt_a']),
  explanation:
      RichContent(nodes: <ContentNode>[TextNode('Typed V0 explanation.')]),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    await DatabaseHelper.instance.database;
  });

  tearDown(() async {
    SettingsRepository.instance.clearCache();
    await DatabaseHelper.resetRuntimeProfileForTesting();
    await DatabaseHelper.deleteDatabaseFile();
  });

  group('A. propose does NOT adopt', () {
    test(
        'real proposal path stages exactly one pending draft with bounded '
        'preview and performs ZERO durable mutation; model cannot spoof '
        'source authority', () async {
      final db = await _db();
      await _seedConversation(db,
          conversationId: 'conv_v0_a', messageId: 'msg_v0_a');
      await _seedLegacyQuestion(db, id: 'v0_legacy_a');
      await _insertReviewState(db, 'v0_legacy_a',
          state: 2, nextReviewTime: _nowUnix - 60);

      final draftService = _draftService();
      final dispatcher = AgentStudyPlanToolDispatcher(
        draftService: draftService,
      );
      final before = await _DurabilitySnapshot.capture();

      final result = await dispatcher.dispatch(AgentStudyPlanToolCall(
        argumentsJson: jsonEncode(<String, Object?>{
          'bank_name': _bankName,
          'goal': 'V0 goal',
          'daily_target': 5,
          'priority': 'balanced',
          'horizon_days': 7,
        }),
        sourceConversationId: 'conv_v0_a',
        sourceMessageId: 'msg_v0_a',
        scope: ConversationScope.global(),
      ));

      final decoded = jsonDecode(result) as Map<String, dynamic>;
      expect(decoded['ok'], isTrue);
      final toolResult = decoded['result'] as Map<String, dynamic>;
      expect(toolResult['status'], 'staged');
      expect(toolResult['outcome'], 'pending');
      final draftId = toolResult['draft_id'] as String;

      // Exactly one pending draft; bounded deterministic preview only.
      final draft = draftService.draftById(draftId);
      expect(draft.outcome, StudyPlanDraftOutcome.pending);
      expect(draft.sourceConversationId, 'conv_v0_a');
      expect(draft.sourceMessageId, 'msg_v0_a');
      expect(draft.sourceScope.kind, ConversationScopeKind.global);
      expect(draft.bankName, _bankName);
      expect(draft.dailyTarget, 5);
      expect(draft.priority, StudyPlanPriority.balanced);
      expect(draft.horizonDays, 7);
      expect(draft.goal, 'V0 goal');
      final preview = toolResult['preview'] as Map<String, dynamic>;
      expect(preview['question_count'], 1);
      expect(preview['mastered_count'], 0);
      expect(preview['due_count'], 1);
      expect(preview['estimated_days'], 1);

      // Calling propose_study_plan is NOT adoption: zero durable mutation.
      expect(await before.unchanged(), isTrue,
          reason: 'proposal must perform zero durable mutation');
      expect(await _studyPlansRows(db), isEmpty);

      // Model cannot control source identity/scope: spoofed authority keys
      // are rejected with zero staging.
      final spoofed = await dispatcher.dispatch(AgentStudyPlanToolCall(
        argumentsJson: jsonEncode(<String, Object?>{
          'bank_name': _bankName,
          'source_conversation_id': 'evil_conv',
          'expected_active_plan_id': 'evil_plan',
        }),
        sourceConversationId: 'conv_v0_a',
        sourceMessageId: 'msg_v0_a',
        scope: ConversationScope.global(),
      ));
      final spoofedDecoded = jsonDecode(spoofed) as Map<String, dynamic>;
      expect(spoofedDecoded['ok'], isFalse);
      expect(
        (spoofedDecoded['error'] as Map<String, dynamic>)['code'],
        'invalid_plan',
      );
      expect(await _studyPlansRows(db), isEmpty);
      expect(
        () => draftService.draftById('draft_never_staged'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('B. provider egress boundary', () {
    test(
        'successful proposal tool result exposes only the canonical '
        'allowlist', () async {
      final db = await _db();
      await _seedConversation(db,
          conversationId: 'conv_v0_b', messageId: 'msg_v0_b');
      await _seedLegacyQuestion(db, id: 'v0_legacy_b', content: 'Secret stem.');

      final draftService = _draftService();
      final dispatcher = AgentStudyPlanToolDispatcher(
        draftService: draftService,
      );
      final result = await dispatcher.dispatch(AgentStudyPlanToolCall(
        argumentsJson: jsonEncode(<String, Object?>{
          'bank_name': _bankName,
          'goal': 'egress goal',
          'daily_target': 3,
          'priority': 'due_first',
        }),
        sourceConversationId: 'conv_v0_b',
        sourceMessageId: 'msg_v0_b',
        scope: ConversationScope.global(),
      ));

      final decoded = jsonDecode(result) as Map<String, dynamic>;
      final keys = <String>[];
      _collectKeys(decoded, keys);
      expect(
        keys.toSet(),
        <String>{
          'ok',
          'result',
          'status',
          'draft_id',
          'outcome',
          'preview',
          'bank_name',
          'goal',
          'daily_target',
          'priority',
          'horizon_days',
          'question_count',
          'mastered_count',
          'due_count',
          'weak_count',
          'new_count',
          'estimated_days',
        },
        reason: 'only canonical allowlisted tool-result fields may leave',
      );

      // Never: source identity, scope/project authority, plan identity,
      // SQL/rows, question content/answers/explanations, credentials,
      // reasoning, stack traces.
      expect(result.contains('conv_v0_b'), isFalse);
      expect(result.contains('msg_v0_b'), isFalse);
      expect(result.contains('project'), isFalse);
      expect(result.contains('SELECT'), isFalse);
      expect(result.contains('Secret stem.'), isFalse);
      expect(result.contains('reasoning'), isFalse);
      expect(result.contains('stack'), isFalse);
      expect(result.contains('expected'), isFalse);
      expect(result.contains('plan_id'), isFalse);
      expect(decoded['ok'], isTrue);
    });
  });

  group('C. formal adoption', () {
    test(
        'explicit Application command creates exactly one durable plan with '
        'canonical fields; schema stays v22; review state untouched; no '
        'question IDs or provider payload persisted', () async {
      final db = await _db();
      await _seedConversation(db,
          conversationId: 'conv_v0_c', messageId: 'msg_v0_c');
      await _seedLegacyQuestion(db, id: 'v0_legacy_c');
      await _insertReviewState(db, 'v0_legacy_c',
          state: 2, nextReviewTime: _nowUnix - 60);

      final draftService = _draftService();
      final commandService = _commandService(draftService);
      final staged = await draftService.stage(
        sourceConversationId: 'conv_v0_c',
        sourceMessageId: 'msg_v0_c',
        sourceScope: ConversationScope.global(),
        bankName: _bankName,
        goal: 'Adoption goal',
        dailyTarget: 6,
        priority: StudyPlanPriority.newFirst,
        horizonDays: 14,
      );
      expect(staged, isA<StudyPlanStageResultStaged>());
      final draftId = (staged as StudyPlanStageResultStaged).draft.draftId;

      // Zero durable mutation before the explicit command.
      expect(await _studyPlansRows(db), isEmpty);

      final result = await commandService.adoptDraft(
        draftId: draftId,
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );
      expect(result, isA<StudyPlanAdoptResultSuccess>());
      final activePlan = (result as StudyPlanAdoptResultSuccess).activePlan;

      final rows = await _studyPlansRows(db);
      expect(rows, hasLength(1));
      final row = rows.single;
      expect(row['plan_id'], activePlan.planId);
      expect(row['bank_name'], _bankName);
      expect(row['goal'], 'Adoption goal');
      expect(row['daily_target'], 6);
      expect(row['priority'], 'new_first');
      expect(row['horizon_days'], 14);
      expect(row['source_conversation_id'], 'conv_v0_c');
      expect(row['source_user_message_id'], 'msg_v0_c');
      expect((row['adopted_at'] as num).toInt(), greaterThanOrEqualTo(0));

      // Schema remains v22 and no new migration ran.
      expect(await _userVersion(db), 22);

      // No question IDs are persisted inside the plan; no provider payload /
      // reasoning is persisted.
      final planColumns = row.keys.toSet();
      expect(
        planColumns,
        <String>{
          'plan_id',
          'singleton_key',
          'bank_name',
          'goal',
          'daily_target',
          'priority',
          'horizon_days',
          'source_conversation_id',
          'source_user_message_id',
          'adopted_at',
        },
        reason: 'the plan row must never carry question IDs or payloads',
      );
      final reviewStates = await db.query('review_states');
      expect(reviewStates.single['reps'], 0,
          reason: 'adoption changes ZERO review state');
      expect(await db.query('review_logs'), isEmpty);
    });
  });

  group('D. transient vs durable restart', () {
    test(
        'a fresh draft service forgets the draft (transient), while the '
        'durable ActiveStudyPlan survives', () async {
      final db = await _db();
      await _seedConversation(db,
          conversationId: 'conv_v0_d', messageId: 'msg_v0_d');
      await _seedLegacyQuestion(db, id: 'v0_legacy_d');
      await _insertReviewState(db, 'v0_legacy_d',
          state: 2, nextReviewTime: _nowUnix - 60);

      final draftService = _draftService();
      final commandService = _commandService(draftService);
      final staged = await draftService.stage(
        sourceConversationId: 'conv_v0_d',
        sourceMessageId: 'msg_v0_d',
        sourceScope: ConversationScope.global(),
        bankName: _bankName,
        dailyTarget: 4,
      );
      final draftId = (staged as StudyPlanStageResultStaged).draft.draftId;
      expect(
        await commandService.adoptDraft(
          draftId: draftId,
          expectedActivePlanId: null,
          replacementConfirmed: false,
        ),
        isA<StudyPlanAdoptResultSuccess>(),
      );

      // Application restart: a brand-new transient draft service has no
      // memory of the old draft id.
      final freshDraftService = _draftService(prefix: 'fresh');
      expect(
        () => freshDraftService.draftById(draftId),
        throwsA(isA<ArgumentError>()),
        reason: 'drafts are transient; restart must forget them',
      );

      // The durable authority still returns the ActiveStudyPlan.
      final reloaded = await StudyPlanPersistenceRepository().loadActivePlan();
      expect(reloaded, isNotNull);
      expect(reloaded!.bankName, _bankName);
      expect(reloaded.dailyTarget, 4);
    });
  });

  group('E. LearningSpace ownership boundary (provenance != ownership)', () {
    test(
        'after adoption, removing the original Project-bank membership does '
        'NOT affect the durable plan; U0 selection uses current GLOBAL bank '
        'admission', () async {
      final db = await _db();
      const projectId = 'proj_v0_e';
      await db.insert('projects', <String, Object?>{
        'project_id': projectId,
        'display_name': 'V0 Project',
        'created_at': _nowUnix,
      });
      await db.insert('project_banks', <String, Object?>{
        'project_id': projectId,
        'bank_name': _bankName,
      });
      await _seedConversation(db,
          conversationId: 'conv_v0_e',
          messageId: 'msg_v0_e',
          projectId: projectId);
      await _seedLegacyQuestion(db, id: 'v0_legacy_e');
      await _insertReviewState(db, 'v0_legacy_e',
          state: 2, nextReviewTime: _nowUnix - 60);

      final draftService = _draftService();
      final commandService = _commandService(draftService);
      final staged = await draftService.stage(
        sourceConversationId: 'conv_v0_e',
        sourceMessageId: 'msg_v0_e',
        sourceScope: ConversationScope.learningSpace(projectId),
        bankName: _bankName,
        dailyTarget: 4,
      );
      expect(staged, isA<StudyPlanStageResultStaged>());
      final adopt = await commandService.adoptDraft(
        draftId: (staged as StudyPlanStageResultStaged).draft.draftId,
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );
      expect(adopt, isA<StudyPlanAdoptResultSuccess>());

      // Remove the original Project relationship WITHOUT deleting the bank.
      await db.delete(
        'project_banks',
        where: 'project_id = ? AND bank_name = ?',
        whereArgs: <Object?>[projectId, _bankName],
      );

      // The durable ActiveStudyPlan remains.
      final plan = await StudyPlanPersistenceRepository().loadActivePlan();
      expect(plan, isNotNull);
      expect(plan!.bankName, _bankName);

      // U0 selection must NOT re-require the old project_banks relation: it
      // operates on the bank through current GLOBAL admission.
      final selection = _selectionService();
      final state = await selection.loadFocusedState();
      expect(state, isA<StudyPlanFocusedReady>(),
          reason: 'provenance is not ownership; global admission must admit '
              'the still-existing bank');
      expect(
        (state as StudyPlanFocusedReady).selectedStorageIds,
        <String>['v0_legacy_e'],
      );
    });
  });

  group('F. live dynamic selection (overlap / mastery / bounded)', () {
    test(
        'real selection over overlapping due/weak/new pools: state0 due/new '
        'overlap selected once, mastered state=3 not excluded, count <= '
        'dailyTarget, deterministic order, bounded candidate read', () async {
      final db = await _db();
      await _seedConversation(db,
          conversationId: 'conv_v0_f', messageId: 'msg_v0_f');
      // state=0 + next_review_time=0 => due AND new simultaneously.
      await _seedLegacyQuestion(db, id: 'q_state0', content: 'state0 stem');
      await _insertReviewState(db, 'q_state0', state: 0, nextReviewTime: 0);
      // mastered state=3 that is currently due: must NOT be excluded.
      await _seedLegacyQuestion(db, id: 'q_mastered_due', content: 'm due');
      await _insertReviewState(db, 'q_mastered_due',
          state: 3, nextReviewTime: _nowUnix - 100);
      // mastered state=3 that is weak (lapses > 0).
      await _seedLegacyQuestion(db, id: 'q_mastered_weak', content: 'm weak');
      await _insertReviewState(db, 'q_mastered_weak',
          state: 3, nextReviewTime: _nowUnix + 1000, lapses: 1, difficulty: 8);
      // due + weak.
      await _seedLegacyQuestion(db, id: 'q_weak_due', content: 'weak due');
      await _insertReviewState(db, 'q_weak_due',
          state: 2, nextReviewTime: _nowUnix - 50, lapses: 2, difficulty: 9);
      // pure new (state=0, future review => new but not due).
      await _seedLegacyQuestion(db, id: 'q_new_future', content: 'new future');
      await _insertReviewState(db, 'q_new_future',
          state: 0, nextReviewTime: _nowUnix + 5000);
      // extra due rows.
      await _seedLegacyQuestion(db, id: 'q_due_1', content: 'due one');
      await _insertReviewState(db, 'q_due_1',
          state: 2, nextReviewTime: _nowUnix - 10);
      await _seedLegacyQuestion(db, id: 'q_due_2', content: 'due two');
      await _insertReviewState(db, 'q_due_2',
          state: 2, nextReviewTime: _nowUnix - 20);

      final plan = ActiveStudyPlan(
        planId: 'plan_f',
        bankName: _bankName,
        dailyTarget: 6,
        priority: StudyPlanPriority.balanced,
        adoptedAt: _v0Clock.subtract(const Duration(days: 1)),
      );
      await _persistenceRepository().commitAdoption(
        planId: plan.planId,
        bankName: plan.bankName,
        goal: plan.goal,
        dailyTarget: plan.dailyTarget,
        priority: plan.priority,
        horizonDays: plan.horizonDays,
        sourceConversationId: 'conv_v0_f',
        sourceUserMessageId: 'msg_v0_f',
        sourceScope: ConversationScope.global(),
        adoptedAt: plan.adoptedAt,
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );

      final selection = _selectionService();
      final state = await selection.loadFocusedState();
      expect(state, isA<StudyPlanFocusedReady>());
      final ids = (state as StudyPlanFocusedReady).selectedStorageIds;

      // Balanced must never exceed dailyTarget.
      expect(ids.length, lessThanOrEqualTo(6));
      expect(ids.length, 6,
          reason: 'balanced round-robin fills up to dailyTarget when '
              'candidates exist');
      // state0 belongs to due AND new but is selected exactly once.
      expect(ids.where((id) => id == 'q_state0'), hasLength(1));
      // mastered/state3 is NOT excluded merely because mastered: the due one
      // must be selected (due semantics) and the weak one via weak semantics.
      expect(ids, contains('q_mastered_due'));
      expect(ids, contains('q_mastered_weak'));
      expect(ids.toSet().length, ids.length);

      // Deterministic order: a second run returns the identical selection.
      final second = await selection.loadFocusedState();
      expect(
        (second as StudyPlanFocusedReady).selectedStorageIds,
        ids,
      );

      // Frozen candidate-read bound: 200 per pool, enforced by the real
      // repository.
      expect(StudyPlanReadRepository.maxPerPoolLimit, 200);
      expect(
        () => StudyPlanReadRepository().loadCandidates(
          bankName: _bankName,
          nowUnixSeconds: _nowUnix,
          maxPerPool: 201,
        ),
        throwsArgumentError,
      );
      final bounded = await StudyPlanReadRepository().loadCandidates(
          bankName: _bankName, nowUnixSeconds: _nowUnix, maxPerPool: 200);
      expect(bounded.due.length, lessThanOrEqualTo(200));
      expect(bounded.weak.length, lessThanOrEqualTo(200));
      expect(bounded.newPool.length, lessThanOrEqualTo(200));
    });
  });

  group('G. fresh session recomputation', () {
    test(
        'session-start selection reflects live state, not the earlier '
        'snapshot; no selected-ID persistence exists', () async {
      final db = await _db();
      await _seedConversation(db,
          conversationId: 'conv_v0_g', messageId: 'msg_v0_g');
      await _seedLegacyQuestion(db, id: 'g_due_early', content: 'early');
      await _seedLegacyQuestion(db, id: 'g_due_late', content: 'late');
      await _insertReviewState(db, 'g_due_early',
          state: 2, nextReviewTime: _nowUnix - 200);
      await _insertReviewState(db, 'g_due_late',
          state: 2, nextReviewTime: _nowUnix - 100);

      final plan = ActiveStudyPlan(
        planId: 'plan_g',
        bankName: _bankName,
        dailyTarget: 10,
        priority: StudyPlanPriority.dueFirst,
        adoptedAt: _v0Clock.subtract(const Duration(days: 1)),
      );
      await _persistenceRepository().commitAdoption(
        planId: plan.planId,
        bankName: plan.bankName,
        dailyTarget: plan.dailyTarget,
        priority: plan.priority,
        sourceConversationId: 'conv_v0_g',
        sourceUserMessageId: 'msg_v0_g',
        sourceScope: ConversationScope.global(),
        adoptedAt: plan.adoptedAt,
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );

      final selection = _selectionService();
      final s1 = await selection.loadFocusedState();
      expect(
        (s1 as StudyPlanFocusedReady).selectedStorageIds,
        <String>['g_due_early', 'g_due_late'],
      );

      // Live review state changes before the next session starts.
      await db.update(
        'review_states',
        <String, Object?>{'next_review_time': _nowUnix + 9999},
        where: 'question_id = ?',
        whereArgs: <Object?>['g_due_early'],
      );
      final s2 = await selection.loadFocusedState();
      expect(
        (s2 as StudyPlanFocusedReady).selectedStorageIds,
        <String>['g_due_late'],
        reason: 'session-start selection must reflect current live state',
      );

      // No persisted selected question IDs: the plan row carries none and no
      // table stores the selection.
      final planRow = (await _studyPlansRows(db)).single;
      expect(planRow.containsKey('question_id'), isFalse);
      expect(planRow.containsKey('selected_ids'), isFalse);
      expect(
        (await db.query('questions')).map((row) => row['id']).toSet(),
        <String>{'g_due_early', 'g_due_late'},
      );
    });
  });

  group('H. practice normal review path (non-preview)', () {
    test(
        'exact ordered selection flows through the real launcher into the '
        'engine queue and a normal review submission mutates review state '
        'and logs through the EXISTING engine path', () async {
      final db = await _db();
      await _seedConversation(db, conversationId: 'conv_h', messageId: 'msg_h');
      await _seedLegacyQuestion(db, id: 'h_a', content: 'H A stem.');
      await _seedLegacyQuestion(db, id: 'h_b', content: 'H B stem.');
      await _seedLegacyQuestion(db, id: 'h_c', content: 'H C stem.');
      for (final id in <String>['h_a', 'h_b', 'h_c']) {
        await _insertReviewState(db, id,
            state: 2, nextReviewTime: _nowUnix - 60);
      }

      // Real selection (due_first) yields [h_a, h_b, h_c] in storageId order
      // (identical next_review_time => storageId ASC).
      final plan = ActiveStudyPlan(
        planId: 'plan_h',
        bankName: _bankName,
        dailyTarget: 10,
        priority: StudyPlanPriority.dueFirst,
        adoptedAt: _v0Clock.subtract(const Duration(days: 1)),
      );
      await _persistenceRepository().commitAdoption(
        planId: plan.planId,
        bankName: plan.bankName,
        dailyTarget: plan.dailyTarget,
        priority: plan.priority,
        sourceConversationId: 'conv_h',
        sourceUserMessageId: 'msg_h',
        sourceScope: ConversationScope.global(),
        adoptedAt: plan.adoptedAt,
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );
      final ids = ((await _selectionService().loadFocusedState())
              as StudyPlanFocusedReady)
          .selectedStorageIds;
      expect(ids, <String>['h_a', 'h_b', 'h_c']);

      // Real launcher -> real materialization -> engine prepared queue.
      final launcher = StudyPlanPracticeSessionLauncher();
      final launch = await launcher.launch(ids);
      expect(launch, isA<StudyPlanPracticeLaunchSuccess>());

      final engine = ReviewEngineService();
      // Exact selected order preserved in the queue.
      expect(engine.popNextQuestion()!.storageId, 'h_a');
      expect(engine.popNextQuestion()!.storageId, 'h_b');
      final third = engine.popNextQuestion()!;
      expect(third.storageId, 'h_c');

      // Existing Again/requeue semantics stay existing semantics.
      engine.requeueQuestion(third);
      expect(engine.popNextQuestion()!.storageId, 'h_c');
      expect(engine.popNextQuestion(), isNull);

      // Normal review submission through the EXISTING engine path mutates
      // review state and writes a review log (FSRS path).
      await engine.submitReview('h_a', 4);
      final states = await db.query(
        'review_states',
        where: 'question_id = ?',
        whereArgs: <Object?>['h_a'],
      );
      expect(states.single['reps'], 1);
      expect(states.single['state'], 2);
      expect((states.single['last_review_time'] as num).toInt(),
          greaterThanOrEqualTo(_nowUnix - 1));
      final logs = await db.query(
        'review_logs',
        where: 'question_id = ?',
        whereArgs: <Object?>['h_a'],
      );
      expect(logs.single['grade'], 4);

      // PracticePage.initialQuestions is NOT involved: the seam used is the
      // prepared-session queue injection (proved by the queue above and the
      // practice_page_v2_test.dart widget regression).
      expect(ids, isNotEmpty);
    });
  });

  group('I. typed + legacy materialization', () {
    test(
        'mixed typed V2 + legacy session preserves exact input order; '
        'corrupt V2 sidecar fails the WHOLE preparation boundedly with no '
        'V1 fallback and no partial queue', () async {
      final db = await _db();
      await _seedLegacyQuestion(db, id: 'i_legacy', content: 'Legacy stem.');
      await _insertTypedQuestion(db, _typedDraftA, storageId: _typedStorageIdA);

      final launcher = StudyPlanPracticeSessionLauncher();
      final success =
          await launcher.launch(<String>['i_legacy', _typedStorageIdA]);
      expect(success, isA<StudyPlanPracticeLaunchSuccess>());
      final engine = ReviewEngineService();
      final first = engine.popNextQuestion()!;
      expect(first.storageId, 'i_legacy');
      expect(first, isA<LegacyPersistedQuestion>());
      final second = engine.popNextQuestion()!;
      expect(second.storageId, _typedStorageIdA);
      expect(second, isA<TypedPersistedQuestion>());
      expect(engine.popNextQuestion(), isNull);

      // Corrupt the typed sidecar: whole preparation fails boundedly.
      await db.update(
        'question_v2_payloads',
        <String, Object?>{'payload_json': '{corrupt'},
        where: 'question_id = ?',
        whereArgs: <Object?>[_typedStorageIdA],
      );
      final failed = await launcher.launch(<String>[
        'i_legacy',
        _typedStorageIdA,
      ]);
      expect(failed, isA<StudyPlanPracticeLaunchFailed>(),
          reason: 'corrupt V2 must fail the whole preparation, never fall '
              'back to V1, never produce a partial queue');

      // A valid launch afterwards shows the failed attempt left no residue.
      final clean = await launcher.launch(<String>['i_legacy']);
      expect(clean, isA<StudyPlanPracticeLaunchSuccess>());
      expect(engine.popNextQuestion()!.storageId, 'i_legacy');
      expect(engine.popNextQuestion(), isNull);
    });
  });

  group('J. planUnavailable', () {
    test(
        'bank disappearance maps to PlanUnavailable; the durable plan is '
        'never auto-deleted, auto-stopped, or substituted', () async {
      final db = await _db();
      await _seedConversation(db,
          conversationId: 'conv_v0_j', messageId: 'msg_v0_j');
      await _seedLegacyQuestion(db, id: 'v0_legacy_j');
      await _insertReviewState(db, 'v0_legacy_j',
          state: 2, nextReviewTime: _nowUnix - 60);

      final draftService = _draftService();
      final commandService = _commandService(draftService);
      final staged = await draftService.stage(
        sourceConversationId: 'conv_v0_j',
        sourceMessageId: 'msg_v0_j',
        sourceScope: ConversationScope.global(),
        bankName: _bankName,
        dailyTarget: 4,
      );
      final adopt = await commandService.adoptDraft(
        draftId: (staged as StudyPlanStageResultStaged).draft.draftId,
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );
      expect(adopt, isA<StudyPlanAdoptResultSuccess>());

      // Make the active bank unavailable WITHOUT deleting the plan row.
      await db.delete('questions',
          where: 'bank_name = ?', whereArgs: <Object?>[_bankName]);

      final selection = _selectionService();
      final state = await selection.loadFocusedState();
      expect(state, isA<StudyPlanFocusedPlanUnavailable>());

      // The durable plan still exists; no auto-delete / auto-stop.
      final plan = await StudyPlanPersistenceRepository().loadActivePlan();
      expect(plan, isNotNull);
      expect(plan!.bankName, _bankName);
      expect(await _studyPlansRows(db), hasLength(1));
    });
  });

  group('K. replacement CAS / ABA', () {
    test(
        'replacement with the exact old planId replaces; a stale baseline '
        'never mutates the new plan', () async {
      final db = await _db();
      await _seedConversation(db,
          conversationId: 'conv_v0_k', messageId: 'msg_v0_k');
      await _insertMessage(db,
          conversationId: 'conv_v0_k', messageId: 'msg_v0_k2');
      await _seedLegacyQuestion(db, id: 'v0_legacy_k');
      await _insertReviewState(db, 'v0_legacy_k',
          state: 2, nextReviewTime: _nowUnix - 60);

      final draftService = _draftService();
      final commandService = _commandService(draftService);

      // Plan A (no-active adoption).
      final stagedA = await draftService.stage(
        sourceConversationId: 'conv_v0_k',
        sourceMessageId: 'msg_v0_k',
        sourceScope: ConversationScope.global(),
        bankName: _bankName,
        dailyTarget: 3,
      );
      final adoptA = await commandService.adoptDraft(
        draftId: (stagedA as StudyPlanStageResultStaged).draft.draftId,
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );
      expect(adoptA, isA<StudyPlanAdoptResultSuccess>());
      final planA = (adoptA as StudyPlanAdoptResultSuccess).activePlan;

      // Replacement B bound to the exact observed A planId.
      final stagedB = await draftService.stage(
        sourceConversationId: 'conv_v0_k',
        sourceMessageId: 'msg_v0_k2',
        sourceScope: ConversationScope.global(),
        bankName: _bankName,
        dailyTarget: 8,
      );
      final adoptB = await commandService.adoptDraft(
        draftId: (stagedB as StudyPlanStageResultStaged).draft.draftId,
        expectedActivePlanId: planA.planId,
        replacementConfirmed: true,
      );
      expect(adoptB, isA<StudyPlanAdoptResultSuccess>());
      final planB = (adoptB as StudyPlanAdoptResultSuccess).activePlan;
      expect(planB.planId, isNot(planA.planId),
          reason: 'fresh/non-reused identity contract within the acceptance '
              'fixture');
      expect((await _studyPlansRows(db)).single['plan_id'], planB.planId);

      // Stale command using the old A baseline: zero mutation of B.
      final stagedC = await draftService.stage(
        sourceConversationId: 'conv_v0_k',
        sourceMessageId: 'msg_v0_k2',
        sourceScope: ConversationScope.global(),
        bankName: _bankName,
        dailyTarget: 5,
      );
      final stale = await commandService.adoptDraft(
        draftId: (stagedC as StudyPlanStageResultStaged).draft.draftId,
        expectedActivePlanId: planA.planId,
        replacementConfirmed: true,
      );
      expect(stale, isA<StudyPlanAdoptResultStaleActivePlan>());
      expect((await _studyPlansRows(db)).single['plan_id'], planB.planId,
          reason: 'an old expectedActivePlanId must never revive or mutate '
              'the current plan');
      expect((await _studyPlansRows(db)).single['daily_target'], 8);
    });
  });

  group('L. stop CAS', () {
    test(
        'stale stop performs zero mutation; exact stop succeeds and leaves '
        'zero ActiveStudyPlan with no review/question mutation', () async {
      final db = await _db();
      await _seedConversation(db,
          conversationId: 'conv_v0_l', messageId: 'msg_v0_l');
      await _insertMessage(db,
          conversationId: 'conv_v0_l', messageId: 'msg_v0_l2');
      await _seedLegacyQuestion(db, id: 'v0_legacy_l');
      await _insertReviewState(db, 'v0_legacy_l',
          state: 2, nextReviewTime: _nowUnix - 60);

      final draftService = _draftService();
      final commandService = _commandService(draftService);
      final stagedA = await draftService.stage(
        sourceConversationId: 'conv_v0_l',
        sourceMessageId: 'msg_v0_l',
        sourceScope: ConversationScope.global(),
        bankName: _bankName,
        dailyTarget: 3,
      );
      final adoptA = await commandService.adoptDraft(
        draftId: (stagedA as StudyPlanStageResultStaged).draft.draftId,
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );
      final planA = (adoptA as StudyPlanAdoptResultSuccess).activePlan;
      final stagedB = await draftService.stage(
        sourceConversationId: 'conv_v0_l',
        sourceMessageId: 'msg_v0_l2',
        sourceScope: ConversationScope.global(),
        bankName: _bankName,
        dailyTarget: 9,
      );
      final adoptB = await commandService.adoptDraft(
        draftId: (stagedB as StudyPlanStageResultStaged).draft.draftId,
        expectedActivePlanId: planA.planId,
        replacementConfirmed: true,
      );
      final planB = (adoptB as StudyPlanAdoptResultSuccess).activePlan;

      final reviewBefore = await db.query('review_states');
      final logsBefore = await db.query('review_logs');

      // Stale stop with old A: zero mutation.
      final staleStop = await commandService.stopActivePlan(
        expectedPlanId: planA.planId,
      );
      expect(staleStop, isA<StudyPlanStopResultStaleActivePlan>());
      expect((await _studyPlansRows(db)).single['plan_id'], planB.planId);

      // Exact stop with B: success, zero plan rows left.
      final stop = await commandService.stopActivePlan(
        expectedPlanId: planB.planId,
      );
      expect(stop, isA<StudyPlanStopResultSuccess>());
      expect(await _studyPlansRows(db), isEmpty);
      expect(await StudyPlanPersistenceRepository().loadActivePlan(), isNull);

      // Stop performed ZERO review/question mutation.
      expect(await db.query('review_states'), reviewBefore);
      expect(await db.query('review_logs'), logsBefore);
      expect((await db.query('questions')).length, 1);
    });
  });

  group('M. advisory states', () {
    test(
        'masteryReached does not empty the queue: a mastered-but-due '
        'candidate is still selected', () async {
      final db = await _db();
      await _seedConversation(db,
          conversationId: 'conv_v0_m', messageId: 'msg_v0_m');
      // All questions mastered (masteredCount == questionCount) but one is
      // currently due: selection must still produce a session.
      await _seedLegacyQuestion(db, id: 'm_mastered_due', content: 'due');
      await _insertReviewState(db, 'm_mastered_due',
          state: 3, nextReviewTime: _nowUnix - 60);
      await _seedLegacyQuestion(db, id: 'm_mastered_future', content: 'later');
      await _insertReviewState(db, 'm_mastered_future',
          state: 3, nextReviewTime: _nowUnix + 1000);

      final plan = ActiveStudyPlan(
        planId: 'plan_m1',
        bankName: _bankName,
        dailyTarget: 5,
        priority: StudyPlanPriority.dueFirst,
        adoptedAt: _v0Clock.subtract(const Duration(days: 1)),
      );
      await _persistenceRepository().commitAdoption(
        planId: plan.planId,
        bankName: plan.bankName,
        dailyTarget: plan.dailyTarget,
        priority: plan.priority,
        sourceConversationId: 'conv_v0_m',
        sourceUserMessageId: 'msg_v0_m',
        sourceScope: ConversationScope.global(),
        adoptedAt: plan.adoptedAt,
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );

      final state = await _selectionService().loadFocusedState();
      expect(state, isA<StudyPlanFocusedReady>());
      final ready = state as StudyPlanFocusedReady;
      expect(ready.advisory.masteryReached, isTrue);
      expect(ready.selectedStorageIds, <String>['m_mastered_due'],
          reason: 'masteryReached is advisory only and never empties the '
              'queue');
    });

    test(
        'horizonElapsed is advisory only: candidates are still selected and '
        'the plan is not expired/stopped', () async {
      final db = await _db();
      await _seedConversation(db,
          conversationId: 'conv_v0_m2', messageId: 'msg_v0_m2');
      await _seedLegacyQuestion(db, id: 'm2_due', content: 'due');
      await _insertReviewState(db, 'm2_due',
          state: 2, nextReviewTime: _nowUnix - 60);

      // horizonDays=1 with adoptedAt 10 days before the injected clock:
      // horizonElapsed must be true.
      final plan = ActiveStudyPlan(
        planId: 'plan_m2',
        bankName: _bankName,
        dailyTarget: 5,
        priority: StudyPlanPriority.dueFirst,
        horizonDays: 1,
        adoptedAt: _v0Clock.subtract(const Duration(days: 10)),
      );
      await _persistenceRepository().commitAdoption(
        planId: plan.planId,
        bankName: plan.bankName,
        dailyTarget: plan.dailyTarget,
        priority: plan.priority,
        horizonDays: plan.horizonDays,
        sourceConversationId: 'conv_v0_m2',
        sourceUserMessageId: 'msg_v0_m2',
        sourceScope: ConversationScope.global(),
        adoptedAt: plan.adoptedAt,
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );

      final state = await _selectionService().loadFocusedState();
      expect(state, isA<StudyPlanFocusedReady>());
      final ready = state as StudyPlanFocusedReady;
      expect(ready.advisory.horizonElapsed, isTrue);
      expect(ready.selectedStorageIds, <String>['m2_due'],
          reason: 'horizonElapsed is advisory only; training stays active');
      expect(
        await StudyPlanPersistenceRepository().loadActivePlan(),
        isNotNull,
        reason: 'horizonElapsed never auto-stops/deletes the plan',
      );
    });
  });

  group('frozen catalogs and schema', () {
    test(
        'Agent READ catalog exactly six; MCP v0 exactly six; '
        'propose_study_plan not in MCP; schema v22', () async {
      expect(AgentStudyToolCatalog.definitions, hasLength(6));
      expect(AgentStudyToolCatalog.toolNames, hasLength(6));
      expect(StudyMcpAdapter.toolNames, hasLength(6));
      expect(
        StudyMcpAdapter.toolNames,
        isNot(contains(AgentStudyPlanToolCatalog.toolName)),
      );
      expect(AgentStudyPlanToolCatalog.toolName, 'propose_study_plan');
      expect(AgentStudyToolCatalog.toolNames,
          isNot(contains('propose_study_plan')));
      expect(await _userVersion(await _db()), 22);
    });
  });
}

// ---------------------------------------------------------------------------
// Environment helpers (synthetic SQLite through the real singleton)
// ---------------------------------------------------------------------------

Future<Database> _db() => DatabaseHelper.instance.database;

int get _nowUnix => _v0Clock.millisecondsSinceEpoch ~/ 1000;

int _draftSeq = 0;
int _planSeq = 0;

StudyPlanDraftService _draftService({String prefix = 'draft'}) {
  return StudyPlanDraftService(
    planningPort: StudyPlanReadRepository(),
    draftIdFactory: () => '${prefix}_${++_draftSeq}',
    clock: () => _v0Clock,
  );
}

StudyPlanCommandService _commandService(StudyPlanDraftService draftService) {
  return StudyPlanCommandService(
    draftService: draftService,
    persistencePort: StudyPlanPersistenceRepository(),
    planIdFactory: () => 'plan_${++_planSeq}',
    clock: () => _v0Clock,
  );
}

StudyPlanSelectionService _selectionService() {
  return StudyPlanSelectionService(
    persistencePort: StudyPlanPersistenceRepository(),
    planningPort: StudyPlanReadRepository(),
    candidateQueryPort: StudyPlanReadRepository(),
    poolOrder: const StudyPlanPoolOrder(),
    clock: () => _v0Clock,
  );
}

StudyPlanPersistenceRepository _persistenceRepository() =>
    StudyPlanPersistenceRepository();

Future<void> _seedConversation(
  Database db, {
  required String conversationId,
  required String messageId,
  String? projectId,
}) async {
  await db.insert('conversations', <String, Object?>{
    'conversation_id': conversationId,
    'scope_kind': projectId == null ? 'global' : 'learning_space',
    'project_id': projectId,
    'title': 'V0 Synthetic',
    'created_at': _nowUnix,
    'updated_at': _nowUnix,
  });
  await db.insert('conversation_messages', <String, Object?>{
    'message_id': messageId,
    'conversation_id': conversationId,
    'sequence': 1,
    'role': 'user',
    'content': 'synthetic user message',
    'created_at': _nowUnix,
  });
}

Future<void> _insertMessage(
  Database db, {
  required String conversationId,
  required String messageId,
}) async {
  await db.insert('conversation_messages', <String, Object?>{
    'message_id': messageId,
    'conversation_id': conversationId,
    'sequence': 2,
    'role': 'user',
    'content': 'synthetic follow-up user message',
    'created_at': _nowUnix,
  });
}

Future<void> _seedLegacyQuestion(
  Database db, {
  required String id,
  String content = 'Legacy V0 stem.',
  String bank = _bankName,
}) async {
  await db.insert('questions', <String, Object?>{
    'id': id,
    'type': 0,
    'content': content,
    'options': '["A. opt-a", "B. opt-b"]',
    'standard_answer': 'A|||',
    'created_at': _nowUnix,
    'bank_name': bank,
  });
}

Future<void> _insertTypedQuestion(
  Database db,
  QuestionDraftV2 draft, {
  required String storageId,
}) async {
  final frozen = _mapper.freezeForWrite(
    storageId: storageId,
    bankName: _bankName,
    createdAt: _nowUnix,
    draft: draft,
  );
  await db.insert('questions', frozen.questionRow);
  await db.insert('question_v2_payloads', frozen.payloadRow);
}

Future<void> _insertReviewState(
  Database db,
  String questionId, {
  int state = 0,
  int? nextReviewTime,
  int lapses = 0,
  double difficulty = 5.0,
}) async {
  await db.insert('review_states', <String, Object?>{
    'question_id': questionId,
    'state': state,
    'difficulty': difficulty,
    'stability': 0.0,
    'last_review_time': 0,
    'next_review_time': nextReviewTime,
    'reps': 0,
    'lapses': lapses,
    'last_lapse_time': 0,
  });
}

Future<List<Map<String, Object?>>> _studyPlansRows(Database db) =>
    db.query('study_plans');

Future<int> _userVersion(Database db) async {
  final rows = await db.rawQuery('PRAGMA user_version');
  return (rows.single['user_version'] as num).toInt();
}

void _collectKeys(Object? value, List<String> keys) {
  if (value is Map<String, dynamic>) {
    for (final entry in value.entries) {
      keys.add(entry.key);
      _collectKeys(entry.value, keys);
    }
  } else if (value is List) {
    for (final item in value) {
      _collectKeys(item, keys);
    }
  }
}

/// Snapshot of every durability-relevant table for byte-equivalent change
/// detection across proposal/adoption/stop.
final class _DurabilitySnapshot {
  _DurabilitySnapshot({required this.tables});

  final Map<String, List<Map<String, Object?>>> tables;

  static Future<_DurabilitySnapshot> capture() async {
    final db = await _db();
    final tables = <String, List<Map<String, Object?>>>{};
    for (final name in const <String>[
      'questions',
      'question_v2_payloads',
      'review_states',
      'review_logs',
      'study_plans',
      'conversations',
      'conversation_messages',
      'projects',
      'project_banks',
    ]) {
      tables[name] = await db.query(name);
    }
    return _DurabilitySnapshot(tables: tables);
  }

  Future<bool> unchanged() async {
    final db = await _db();
    for (final entry in tables.entries) {
      final now = await db.query(entry.key);
      if (_rowsEqual(now, entry.value)) continue;
      return false;
    }
    return true;
  }

  static bool _rowsEqual(
    List<Map<String, Object?>> a,
    List<Map<String, Object?>> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final ra = a[i];
      final rb = b[i];
      if (ra.length != rb.length) return false;
      for (final key in ra.keys) {
        if (ra[key] != rb[key]) return false;
      }
    }
    return true;
  }
}
