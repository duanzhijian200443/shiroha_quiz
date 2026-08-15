import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_ports.dart';
import 'package:shiroha_quiz/data/repositories/study_plan_persistence_repository.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/study_plan/study_plan_values.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../application/study_query/study_query_test_support.dart';

void main() {
  setUpAll(initTestDatabaseFactory);

  late Database db;
  late StudyPlanPersistenceRepository repository;

  setUp(() async {
    await resetTestDatabase();
    db = await openTestDatabase();
    repository = StudyPlanPersistenceRepository();
  });

  tearDown(resetTestDatabase);

  Future<void> seedBank(String bankName, {int questionCount = 1}) async {
    for (var i = 0; i < questionCount; i++) {
      await db.insert('questions', <String, Object?>{
        'id': 'q_${bankName}_$i',
        'type': 0,
        'content': 'Question $i for $bankName',
        'options': '[]',
        'standard_answer': 'A',
        'created_at': 1000,
        'bank_name': bankName,
      });
      await db.insert('review_states', <String, Object?>{
        'question_id': 'q_${bankName}_$i',
        'state': 1,
        'next_review_time': 2000,
        'lapses': 0,
        'difficulty': 5.0,
        'stability': 2.0,
        'reps': 1,
      });
    }
  }

  Future<void> seedConversation({
    required String conversationId,
    required String scopeKind,
    String? projectId,
  }) async {
    await db.insert('conversations', <String, Object?>{
      'conversation_id': conversationId,
      'scope_kind': scopeKind,
      'project_id': projectId,
      'title': 'Conv $conversationId',
      'created_at': 1000,
      'updated_at': 1000,
    });
  }

  Future<void> seedMessage({
    required String messageId,
    required String conversationId,
    required String role,
    int sequence = 1,
  }) async {
    await db.insert('conversation_messages', <String, Object?>{
      'message_id': messageId,
      'conversation_id': conversationId,
      'sequence': sequence,
      'role': role,
      'content': 'Message $messageId',
      'created_at': 1000,
    });
  }

  Future<void> seedProject(String projectId) async {
    await db.insert('projects', <String, Object?>{
      'project_id': projectId,
      'display_name': 'Project $projectId',
      'created_at': 1000,
    });
  }

  Future<void> seedProjectBank(String projectId, String bankName) async {
    await db.insert('project_banks', <String, Object?>{
      'project_id': projectId,
      'bank_name': bankName,
    });
  }

  group('loadActivePlan', () {
    test('returns null when no active plan exists', () async {
      final plan = await repository.loadActivePlan();
      expect(plan, isNull);
    });

    test(
        'round-trips active plan with millisecond UTC timestamp and exact fields',
        () async {
      await seedBank('Math');
      await seedConversation(
        conversationId: 'conv_1',
        scopeKind: 'global',
      );
      await seedMessage(
        messageId: 'msg_1',
        conversationId: 'conv_1',
        role: 'user',
      );

      final adoptedAt = DateTime.utc(2026, 8, 15, 10, 30, 45, 123);
      final commitResult = await repository.commitAdoption(
        planId: 'plan_123',
        bankName: 'Math',
        goal: 'Complete algebra',
        dailyTarget: 30,
        priority: StudyPlanPriority.dueFirst,
        horizonDays: 14,
        sourceConversationId: 'conv_1',
        sourceUserMessageId: 'msg_1',
        sourceScope: ConversationScope.global(),
        adoptedAt: adoptedAt,
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );

      expect(commitResult, isA<StudyPlanPersistenceCommitSuccess>());

      final loaded = await repository.loadActivePlan();
      expect(loaded, isNotNull);
      expect(loaded!.planId, 'plan_123');
      expect(loaded.bankName, 'Math');
      expect(loaded.goal, 'Complete algebra');
      expect(loaded.dailyTarget, 30);
      expect(loaded.priority, StudyPlanPriority.dueFirst);
      expect(loaded.horizonDays, 14);
      expect(loaded.sourceConversationId, 'conv_1');
      expect(loaded.sourceUserMessageId, 'msg_1');
      expect(loaded.adoptedAt, adoptedAt);
      expect(loaded.adoptedAt.isUtc, isTrue);
    });
  });

  group('first adoption (no-active CAS)', () {
    test('succeeds for Global scope and persists exact singleton row',
        () async {
      await seedBank('Physics');
      await seedConversation(
        conversationId: 'c_global',
        scopeKind: 'global',
      );
      await seedMessage(
        messageId: 'm_user',
        conversationId: 'c_global',
        role: 'user',
      );

      final result = await repository.commitAdoption(
        planId: 'plan_physics',
        bankName: 'Physics',
        goal: 'Physics goal',
        dailyTarget: 40,
        priority: StudyPlanPriority.balanced,
        sourceConversationId: 'c_global',
        sourceUserMessageId: 'm_user',
        sourceScope: ConversationScope.global(),
        adoptedAt: DateTime.utc(2026, 8, 15),
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );

      expect(result, isA<StudyPlanPersistenceCommitSuccess>());
      final plan = (result as StudyPlanPersistenceCommitSuccess).activePlan;
      expect(plan.planId, 'plan_physics');
      expect(plan.bankName, 'Physics');

      final countRows =
          await db.rawQuery('SELECT COUNT(*) AS c FROM study_plans');
      expect(countRows.single['c'], 1);
    });

    test(
        'succeeds for LearningSpace scope with valid Project and project_banks',
        () async {
      await seedBank('Chemistry');
      await seedProject('proj_chem');
      await seedProjectBank('proj_chem', 'Chemistry');
      await seedConversation(
        conversationId: 'c_chem',
        scopeKind: 'learning_space',
        projectId: 'proj_chem',
      );
      await seedMessage(
        messageId: 'm_chem',
        conversationId: 'c_chem',
        role: 'user',
      );

      final result = await repository.commitAdoption(
        planId: 'plan_chem',
        bankName: 'Chemistry',
        dailyTarget: 25,
        priority: StudyPlanPriority.newFirst,
        sourceConversationId: 'c_chem',
        sourceUserMessageId: 'm_chem',
        sourceScope: ConversationScope.learningSpace('proj_chem'),
        adoptedAt: DateTime.utc(2026, 8, 15),
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );

      expect(result, isA<StudyPlanPersistenceCommitSuccess>());

      // Provenance non-ownership: deleting project or conversation does NOT delete plan
      await db.delete('projects',
          where: 'project_id = ?', whereArgs: ['proj_chem']);
      await db.delete('conversations',
          where: 'conversation_id = ?', whereArgs: ['c_chem']);

      final active = await repository.loadActivePlan();
      expect(active, isNotNull);
      expect(active!.planId, 'plan_chem');
    });

    test(
        'returns alreadyActive when a plan already exists and zero mutation occurs',
        () async {
      await seedBank('Math');
      await seedConversation(
        conversationId: 'c1',
        scopeKind: 'global',
      );
      await seedMessage(
        messageId: 'm1',
        conversationId: 'c1',
        role: 'user',
      );

      await repository.commitAdoption(
        planId: 'first_plan',
        bankName: 'Math',
        dailyTarget: 30,
        priority: StudyPlanPriority.balanced,
        sourceConversationId: 'c1',
        sourceUserMessageId: 'm1',
        sourceScope: ConversationScope.global(),
        adoptedAt: DateTime.utc(2026, 8, 15),
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );

      final secondResult = await repository.commitAdoption(
        planId: 'second_plan',
        bankName: 'Math',
        dailyTarget: 30,
        priority: StudyPlanPriority.balanced,
        sourceConversationId: 'c1',
        sourceUserMessageId: 'm1',
        sourceScope: ConversationScope.global(),
        adoptedAt: DateTime.utc(2026, 8, 15),
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );

      expect(secondResult, isA<StudyPlanPersistenceCommitAlreadyActive>());
      final active = await repository.loadActivePlan();
      expect(active!.planId, 'first_plan');
    });
  });

  group('replacement CAS', () {
    test(
        'succeeds when expectedActivePlanId matches and replacementConfirmed is true',
        () async {
      await seedBank('Math');
      await seedConversation(
        conversationId: 'c1',
        scopeKind: 'global',
      );
      await seedMessage(
        messageId: 'm1',
        conversationId: 'c1',
        role: 'user',
      );

      await repository.commitAdoption(
        planId: 'plan_old',
        bankName: 'Math',
        dailyTarget: 20,
        priority: StudyPlanPriority.balanced,
        sourceConversationId: 'c1',
        sourceUserMessageId: 'm1',
        sourceScope: ConversationScope.global(),
        adoptedAt: DateTime.utc(2026, 8, 15),
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );

      final replaceResult = await repository.commitAdoption(
        planId: 'plan_new',
        bankName: 'Math',
        dailyTarget: 40,
        priority: StudyPlanPriority.weakFirst,
        sourceConversationId: 'c1',
        sourceUserMessageId: 'm1',
        sourceScope: ConversationScope.global(),
        adoptedAt: DateTime.utc(2026, 8, 15, 12),
        expectedActivePlanId: 'plan_old',
        replacementConfirmed: true,
      );

      expect(replaceResult, isA<StudyPlanPersistenceCommitSuccess>());
      final active = await repository.loadActivePlan();
      expect(active!.planId, 'plan_new');
      expect(active.dailyTarget, 40);
      expect(active.priority, StudyPlanPriority.weakFirst);

      final countRows =
          await db.rawQuery('SELECT COUNT(*) AS c FROM study_plans');
      expect(countRows.single['c'], 1);
    });

    test('returns staleActivePlan when expectedActivePlanId does not match',
        () async {
      await seedBank('Math');
      await seedConversation(
        conversationId: 'c1',
        scopeKind: 'global',
      );
      await seedMessage(
        messageId: 'm1',
        conversationId: 'c1',
        role: 'user',
      );

      await repository.commitAdoption(
        planId: 'plan_actual',
        bankName: 'Math',
        dailyTarget: 20,
        priority: StudyPlanPriority.balanced,
        sourceConversationId: 'c1',
        sourceUserMessageId: 'm1',
        sourceScope: ConversationScope.global(),
        adoptedAt: DateTime.utc(2026, 8, 15),
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );

      final result = await repository.commitAdoption(
        planId: 'plan_failed',
        bankName: 'Math',
        dailyTarget: 40,
        priority: StudyPlanPriority.balanced,
        sourceConversationId: 'c1',
        sourceUserMessageId: 'm1',
        sourceScope: ConversationScope.global(),
        adoptedAt: DateTime.utc(2026, 8, 15),
        expectedActivePlanId: 'plan_wrong',
        replacementConfirmed: true,
      );

      expect(result, isA<StudyPlanPersistenceCommitStaleActivePlan>());
      final active = await repository.loadActivePlan();
      expect(active!.planId, 'plan_actual');
    });
  });

  group('stop CAS', () {
    test('succeeds when expectedPlanId matches and leaves zero rows', () async {
      await seedBank('Math');
      await seedConversation(conversationId: 'c1', scopeKind: 'global');
      await seedMessage(messageId: 'm1', conversationId: 'c1', role: 'user');

      await repository.commitAdoption(
        planId: 'plan_to_stop',
        bankName: 'Math',
        dailyTarget: 20,
        priority: StudyPlanPriority.balanced,
        sourceConversationId: 'c1',
        sourceUserMessageId: 'm1',
        sourceScope: ConversationScope.global(),
        adoptedAt: DateTime.utc(2026, 8, 15),
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );

      final stopResult = await repository.stopActivePlan(
        expectedPlanId: 'plan_to_stop',
      );
      expect(stopResult, isA<StudyPlanPersistenceStopSuccess>());

      final loaded = await repository.loadActivePlan();
      expect(loaded, isNull);
    });

    test('returns staleActivePlan when stopping a non-existent or wrong plan',
        () async {
      final stopResult = await repository.stopActivePlan(
        expectedPlanId: 'non_existent',
      );
      expect(stopResult, isA<StudyPlanPersistenceStopStaleActivePlan>());
    });
  });

  group('source-turn revalidations (zero mutation)', () {
    test('fails when source conversation is missing', () async {
      await seedBank('Math');

      final result = await repository.commitAdoption(
        planId: 'plan_1',
        bankName: 'Math',
        dailyTarget: 20,
        priority: StudyPlanPriority.balanced,
        sourceConversationId: 'missing_c',
        sourceUserMessageId: 'm1',
        sourceScope: ConversationScope.global(),
        adoptedAt: DateTime.utc(2026, 8, 15),
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );

      expect(result, isA<StudyPlanPersistenceCommitStaleScope>());
      expect(await repository.loadActivePlan(), isNull);
    });

    test('fails when source message is missing', () async {
      await seedBank('Math');
      await seedConversation(conversationId: 'c1', scopeKind: 'global');

      final result = await repository.commitAdoption(
        planId: 'plan_1',
        bankName: 'Math',
        dailyTarget: 20,
        priority: StudyPlanPriority.balanced,
        sourceConversationId: 'c1',
        sourceUserMessageId: 'missing_m',
        sourceScope: ConversationScope.global(),
        adoptedAt: DateTime.utc(2026, 8, 15),
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );

      expect(result, isA<StudyPlanPersistenceCommitStaleScope>());
      expect(await repository.loadActivePlan(), isNull);
    });

    test('fails when source message role is assistant', () async {
      await seedBank('Math');
      await seedConversation(conversationId: 'c1', scopeKind: 'global');
      await seedMessage(
          messageId: 'm_asst', conversationId: 'c1', role: 'assistant');

      final result = await repository.commitAdoption(
        planId: 'plan_1',
        bankName: 'Math',
        dailyTarget: 20,
        priority: StudyPlanPriority.balanced,
        sourceConversationId: 'c1',
        sourceUserMessageId: 'm_asst',
        sourceScope: ConversationScope.global(),
        adoptedAt: DateTime.utc(2026, 8, 15),
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );

      expect(result, isA<StudyPlanPersistenceCommitStaleScope>());
      expect(await repository.loadActivePlan(), isNull);
    });

    test('fails when conversation scope changed Global -> LearningSpace',
        () async {
      await seedBank('Math');
      await seedProject('p1');
      await seedConversation(
        conversationId: 'c1',
        scopeKind: 'learning_space',
        projectId: 'p1',
      );
      await seedMessage(messageId: 'm1', conversationId: 'c1', role: 'user');

      // Draft has Global scope, but conversation was changed to learning_space
      final result = await repository.commitAdoption(
        planId: 'plan_1',
        bankName: 'Math',
        dailyTarget: 20,
        priority: StudyPlanPriority.balanced,
        sourceConversationId: 'c1',
        sourceUserMessageId: 'm1',
        sourceScope: ConversationScope.global(),
        adoptedAt: DateTime.utc(2026, 8, 15),
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );

      expect(result, isA<StudyPlanPersistenceCommitStaleScope>());
      expect(await repository.loadActivePlan(), isNull);
    });

    test('fails when conversation scope changed LearningSpace p1 -> p2',
        () async {
      await seedBank('Math');
      await seedProject('p2');
      await seedConversation(
        conversationId: 'c1',
        scopeKind: 'learning_space',
        projectId: 'p2',
      );
      await seedMessage(messageId: 'm1', conversationId: 'c1', role: 'user');

      final result = await repository.commitAdoption(
        planId: 'plan_1',
        bankName: 'Math',
        dailyTarget: 20,
        priority: StudyPlanPriority.balanced,
        sourceConversationId: 'c1',
        sourceUserMessageId: 'm1',
        sourceScope: ConversationScope.learningSpace('p1'),
        adoptedAt: DateTime.utc(2026, 8, 15),
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );

      expect(result, isA<StudyPlanPersistenceCommitStaleScope>());
      expect(await repository.loadActivePlan(), isNull);
    });

    test('fails when LearningSpace project_banks relation is missing',
        () async {
      await seedBank('Math');
      await seedProject('p1');
      // Do NOT seed project_banks('p1', 'Math')
      await seedConversation(
        conversationId: 'c1',
        scopeKind: 'learning_space',
        projectId: 'p1',
      );
      await seedMessage(messageId: 'm1', conversationId: 'c1', role: 'user');

      final result = await repository.commitAdoption(
        planId: 'plan_1',
        bankName: 'Math',
        dailyTarget: 20,
        priority: StudyPlanPriority.balanced,
        sourceConversationId: 'c1',
        sourceUserMessageId: 'm1',
        sourceScope: ConversationScope.learningSpace('p1'),
        adoptedAt: DateTime.utc(2026, 8, 15),
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );

      expect(result, isA<StudyPlanPersistenceCommitStaleScope>());
      expect(await repository.loadActivePlan(), isNull);
    });

    test('fails when target bank has no questions', () async {
      // Empty bank
      await seedConversation(conversationId: 'c1', scopeKind: 'global');
      await seedMessage(messageId: 'm1', conversationId: 'c1', role: 'user');

      final result = await repository.commitAdoption(
        planId: 'plan_1',
        bankName: 'EmptyBank',
        dailyTarget: 20,
        priority: StudyPlanPriority.balanced,
        sourceConversationId: 'c1',
        sourceUserMessageId: 'm1',
        sourceScope: ConversationScope.global(),
        adoptedAt: DateTime.utc(2026, 8, 15),
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );

      expect(result, isA<StudyPlanPersistenceCommitTargetUnavailable>());
      expect(await repository.loadActivePlan(), isNull);
    });
  });

  group('NO review / question mutation invariant', () {
    test(
        'adopt, replace, and stop perform zero review_states and questions writes',
        () async {
      await seedBank('Math', questionCount: 3);
      await seedConversation(conversationId: 'c1', scopeKind: 'global');
      await seedMessage(messageId: 'm1', conversationId: 'c1', role: 'user');

      final initialQuestions = await db.query('questions', orderBy: 'id');
      final initialReviewStates =
          await db.query('review_states', orderBy: 'question_id');

      // 1. Adopt
      await repository.commitAdoption(
        planId: 'plan_1',
        bankName: 'Math',
        dailyTarget: 20,
        priority: StudyPlanPriority.balanced,
        sourceConversationId: 'c1',
        sourceUserMessageId: 'm1',
        sourceScope: ConversationScope.global(),
        adoptedAt: DateTime.utc(2026, 8, 15),
        expectedActivePlanId: null,
        replacementConfirmed: false,
      );

      expect(await db.query('questions', orderBy: 'id'), initialQuestions);
      expect(await db.query('review_states', orderBy: 'question_id'),
          initialReviewStates);

      // 2. Replace
      await repository.commitAdoption(
        planId: 'plan_2',
        bankName: 'Math',
        dailyTarget: 50,
        priority: StudyPlanPriority.dueFirst,
        sourceConversationId: 'c1',
        sourceUserMessageId: 'm1',
        sourceScope: ConversationScope.global(),
        adoptedAt: DateTime.utc(2026, 8, 15, 1),
        expectedActivePlanId: 'plan_1',
        replacementConfirmed: true,
      );

      expect(await db.query('questions', orderBy: 'id'), initialQuestions);
      expect(await db.query('review_states', orderBy: 'question_id'),
          initialReviewStates);

      // 3. Stop
      await repository.stopActivePlan(expectedPlanId: 'plan_2');

      expect(await db.query('questions', orderBy: 'id'), initialQuestions);
      expect(await db.query('review_states', orderBy: 'question_id'),
          initialReviewStates);
    });
  });
}
