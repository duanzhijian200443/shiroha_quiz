import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_command_service.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_draft_service.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_ports.dart';
import 'package:shiroha_quiz/core/observability/log_record.dart';
import 'package:shiroha_quiz/core/observability/log_writer.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/study_plan/active_study_plan.dart';
import 'package:shiroha_quiz/domain/study_plan/study_plan_values.dart';

final class _FakePlanningPort implements StudyPlanPlanningPort {
  StudyPlanPlanningAdmission admission =
      StudyPlanPlanningAdmitted(StudyPlanPlanningContext(
    bankName: 'Math',
    questionCount: 10,
    masteredCount: 2,
    dueCount: 3,
    weakCount: 1,
    newCount: 4,
  ));

  @override
  Future<StudyPlanPlanningAdmission> loadPlanningContext({
    required ConversationScope sourceScope,
    required String bankName,
    required DateTime now,
  }) async {
    return admission;
  }
}

final class _FakePersistencePort implements StudyPlanPersistencePort {
  ActiveStudyPlan? currentActivePlan;
  int commitCalls = 0;
  int stopCalls = 0;
  Completer<StudyPlanPersistenceCommitResult>? commitCompleter;
  StudyPlanPersistenceCommitResult nextCommitResult =
      const StudyPlanPersistenceCommitStaleScope();
  StudyPlanPersistenceStopResult nextStopResult =
      const StudyPlanPersistenceStopSuccess();
  bool throwOnCommit = false;

  @override
  Future<ActiveStudyPlan?> loadActivePlan() async => currentActivePlan;

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
    if (throwOnCommit) {
      throw Exception('Unexpected DB error');
    }
    if (commitCompleter != null) {
      return commitCompleter!.future;
    }
    return nextCommitResult;
  }

  @override
  Future<StudyPlanPersistenceStopResult> stopActivePlan({
    required String expectedPlanId,
  }) async {
    stopCalls++;
    return nextStopResult;
  }
}

final class _Harness {
  _Harness({
    String Function()? planIdFactory,
    DateTime Function()? clock,
  }) {
    planningPort = _FakePlanningPort();
    persistencePort = _FakePersistencePort();
    draftService = StudyPlanDraftService(
      planningPort: planningPort,
      draftIdFactory: () => 'draft_${++_draftSeq}',
      clock: () => currentTime,
    );
    commandService = StudyPlanCommandService(
      draftService: draftService,
      persistencePort: persistencePort,
      planIdFactory: planIdFactory ?? () => 'plan_${++_planSeq}',
      clock: clock ?? () => currentTime,
    );
  }

  late final _FakePlanningPort planningPort;
  late final _FakePersistencePort persistencePort;
  late final StudyPlanDraftService draftService;
  late final StudyPlanCommandService commandService;

  int _draftSeq = 0;
  int _planSeq = 0;
  DateTime currentTime = DateTime.utc(2026, 8, 15, 10, 0);

  Future<String> stageDraft({
    String conversationId = 'conv_1',
    String messageId = 'msg_1',
    String bankName = 'Math',
    int dailyTarget = 40,
    StudyPlanPriority priority = StudyPlanPriority.balanced,
  }) async {
    final result = await draftService.stage(
      sourceConversationId: conversationId,
      sourceMessageId: messageId,
      sourceScope: ConversationScope.global(),
      bankName: bankName,
      dailyTarget: dailyTarget,
      priority: priority,
    );
    expect(result, isA<StudyPlanStageResultStaged>());
    return (result as StudyPlanStageResultStaged).draft.draftId;
  }
}

void main() {
  tearDown(() {
    LogWriter.setRecordHandler(null);
  });

  test(
      '1. parameter validation: invalid replacement pairs fail with invalidPlan',
      () async {
    final h = _Harness();
    final draftId = await h.stageDraft();

    // expected != null, but replacementConfirmed == false
    final res1 = await h.commandService.adoptDraft(
      draftId: draftId,
      expectedActivePlanId: 'old_plan',
      replacementConfirmed: false,
    );
    expect(res1, isA<StudyPlanAdoptResultInvalidPlan>());

    // expected == null, but replacementConfirmed == true
    final res2 = await h.commandService.adoptDraft(
      draftId: draftId,
      expectedActivePlanId: null,
      replacementConfirmed: true,
    );
    expect(res2, isA<StudyPlanAdoptResultInvalidPlan>());

    // Unknown draft id
    final res3 = await h.commandService.adoptDraft(
      draftId: 'unknown_draft',
      expectedActivePlanId: null,
      replacementConfirmed: false,
    );
    expect(res3, isA<StudyPlanAdoptResultInvalidPlan>());
  });

  test(
      '2. successful adoption: commits, marks draft committed, and returns active plan',
      () async {
    final h = _Harness();
    final draftId = await h.stageDraft();

    final expectedPlan = ActiveStudyPlan(
      planId: 'plan_1',
      bankName: 'Math',
      dailyTarget: 40,
      priority: StudyPlanPriority.balanced,
      sourceConversationId: 'conv_1',
      sourceUserMessageId: 'msg_1',
      adoptedAt: h.currentTime,
    );
    h.persistencePort.nextCommitResult =
        StudyPlanPersistenceCommitSuccess(expectedPlan);

    final result = await h.commandService.adoptDraft(
      draftId: draftId,
      expectedActivePlanId: null,
      replacementConfirmed: false,
    );

    expect(result, isA<StudyPlanAdoptResultSuccess>());
    final active = (result as StudyPlanAdoptResultSuccess).activePlan;
    expect(active.planId, 'plan_1');
    expect(active.bankName, 'Math');

    // Draft is now committed
    expect(h.draftService.draftById(draftId).outcome,
        StudyPlanDraftOutcome.committed);
    expect(h.persistencePort.commitCalls, 1);
  });

  test(
      '3. duplicate adoption clicks: only first caller enters persistence, second gets busy',
      () async {
    final h = _Harness();
    final draftId = await h.stageDraft();

    final completer = Completer<StudyPlanPersistenceCommitResult>();
    h.persistencePort.commitCompleter = completer;

    // First call starts and acquires gate
    final future1 = h.commandService.adoptDraft(
      draftId: draftId,
      expectedActivePlanId: null,
      replacementConfirmed: false,
    );

    // Second call for same draft while first is in flight
    final future2 = h.commandService.adoptDraft(
      draftId: draftId,
      expectedActivePlanId: null,
      replacementConfirmed: false,
    );

    final res2 = await future2;
    expect(res2, isA<StudyPlanAdoptResultBusy>());
    expect(h.persistencePort.commitCalls, 1);

    // Complete the first call
    final expectedPlan = ActiveStudyPlan(
      planId: 'plan_1',
      bankName: 'Math',
      dailyTarget: 40,
      priority: StudyPlanPriority.balanced,
      sourceConversationId: 'conv_1',
      sourceUserMessageId: 'msg_1',
      adoptedAt: h.currentTime,
    );
    completer.complete(StudyPlanPersistenceCommitSuccess(expectedPlan));

    final res1 = await future1;
    expect(res1, isA<StudyPlanAdoptResultSuccess>());
  });

  test('4. rejected draft cannot be adopted', () async {
    final h = _Harness();
    final draftId = await h.stageDraft();

    h.draftService.rejectDraft(draftId);

    final result = await h.commandService.adoptDraft(
      draftId: draftId,
      expectedActivePlanId: null,
      replacementConfirmed: false,
    );

    expect(result, isA<StudyPlanAdoptResultRejected>());
    expect(h.persistencePort.commitCalls, 0);
  });

  test('5. superseded draft cannot be adopted', () async {
    final h = _Harness();
    final draftId1 = await h.stageDraft(dailyTarget: 30);
    // Stage new proposal on same turn supersedes draftId1
    await h.stageDraft(dailyTarget: 50);

    expect(h.draftService.draftById(draftId1).outcome,
        StudyPlanDraftOutcome.superseded);

    final result = await h.commandService.adoptDraft(
      draftId: draftId1,
      expectedActivePlanId: null,
      replacementConfirmed: false,
    );

    expect(result, isA<StudyPlanAdoptResultSuperseded>());
    expect(h.persistencePort.commitCalls, 0);
  });

  test('6. zero-mutation persistence failure rolls back draft to pending',
      () async {
    final h = _Harness();
    final draftId = await h.stageDraft();

    h.persistencePort.nextCommitResult =
        const StudyPlanPersistenceCommitStaleScope();

    final result = await h.commandService.adoptDraft(
      draftId: draftId,
      expectedActivePlanId: null,
      replacementConfirmed: false,
    );

    expect(result, isA<StudyPlanAdoptResultStaleScope>());
    // Rolled back to pending so user can retry or take action later
    expect(h.draftService.draftById(draftId).outcome,
        StudyPlanDraftOutcome.pending);
  });

  test(
      '7. persistence exception rolls back draft to pending and returns failed',
      () async {
    final h = _Harness();
    final draftId = await h.stageDraft();

    h.persistencePort.throwOnCommit = true;

    final result = await h.commandService.adoptDraft(
      draftId: draftId,
      expectedActivePlanId: null,
      replacementConfirmed: false,
    );

    expect(result, isA<StudyPlanAdoptResultFailed>());
    expect(h.draftService.draftById(draftId).outcome,
        StudyPlanDraftOutcome.pending);
  });

  test(
      '8. CAS alreadyActive failure rolls back draft to pending and returns alreadyActive',
      () async {
    final h = _Harness();
    final draftId = await h.stageDraft();

    h.persistencePort.nextCommitResult =
        const StudyPlanPersistenceCommitAlreadyActive();

    final result = await h.commandService.adoptDraft(
      draftId: draftId,
      expectedActivePlanId: null,
      replacementConfirmed: false,
    );

    expect(result, isA<StudyPlanAdoptResultAlreadyActive>());
    expect(h.draftService.draftById(draftId).outcome,
        StudyPlanDraftOutcome.pending);
  });

  test(
      '9. CAS staleActivePlan failure rolls back draft to pending and returns staleActivePlan',
      () async {
    final h = _Harness();
    final draftId = await h.stageDraft();

    h.persistencePort.nextCommitResult =
        const StudyPlanPersistenceCommitStaleActivePlan();

    final result = await h.commandService.adoptDraft(
      draftId: draftId,
      expectedActivePlanId: 'old_plan',
      replacementConfirmed: true,
    );

    expect(result, isA<StudyPlanAdoptResultStaleActivePlan>());
    expect(h.draftService.draftById(draftId).outcome,
        StudyPlanDraftOutcome.pending);
  });

  test('10. stop command delegates and maps typed outcomes', () async {
    final h = _Harness();

    h.persistencePort.nextStopResult = const StudyPlanPersistenceStopSuccess();
    final res1 =
        await h.commandService.stopActivePlan(expectedPlanId: 'plan_1');
    expect(res1, isA<StudyPlanStopResultSuccess>());
    expect(h.persistencePort.stopCalls, 1);

    h.persistencePort.nextStopResult =
        const StudyPlanPersistenceStopStaleActivePlan();
    final res2 =
        await h.commandService.stopActivePlan(expectedPlanId: 'plan_1');
    expect(res2, isA<StudyPlanStopResultStaleActivePlan>());
  });

  test('stale stop emits a bounded destructive stale_target rejection',
      () async {
    final records = <LogRecord>[];
    LogWriter.setRecordHandler(records.add);
    final h = _Harness();
    h.persistencePort.nextStopResult =
        const StudyPlanPersistenceStopStaleActivePlan();

    final result = await h.commandService.stopActivePlan(
      expectedPlanId: 'plan_1',
    );

    expect(result, isA<StudyPlanStopResultStaleActivePlan>());
    final terminal = records.singleWhere(
      (record) => record.message == 'destructive_rejected',
    );
    expect(terminal.data['failureCode'], 'stale_target');
    expect(terminal.data['durationMs'], greaterThanOrEqualTo(0));
  });

  test(
      '11. throwing planIdFactory rolls back draft to pending and returns failed',
      () async {
    final h = _Harness(
      planIdFactory: () => throw StateError('ID generator crashed'),
    );
    final draftId = await h.stageDraft();

    final result = await h.commandService.adoptDraft(
      draftId: draftId,
      expectedActivePlanId: null,
      replacementConfirmed: false,
    );

    expect(result, isA<StudyPlanAdoptResultFailed>());
    expect(h.draftService.draftById(draftId).outcome,
        StudyPlanDraftOutcome.pending);
    expect(h.persistencePort.commitCalls, 0);
  });

  test('12. throwing clock rolls back draft to pending and returns failed',
      () async {
    final h = _Harness(
      clock: () => throw StateError('Clock unavailable'),
    );
    final draftId = await h.stageDraft();

    final result = await h.commandService.adoptDraft(
      draftId: draftId,
      expectedActivePlanId: null,
      replacementConfirmed: false,
    );

    expect(result, isA<StudyPlanAdoptResultFailed>());
    expect(h.draftService.draftById(draftId).outcome,
        StudyPlanDraftOutcome.pending);
    expect(h.persistencePort.commitCalls, 0);
  });

  test(
      '13. replacement reusing expectedActivePlanId rolls back to pending with zero persistence call',
      () async {
    final h = _Harness(
      planIdFactory: () => 'reused_plan_id',
    );
    final draftId = await h.stageDraft();

    final result = await h.commandService.adoptDraft(
      draftId: draftId,
      expectedActivePlanId: 'reused_plan_id',
      replacementConfirmed: true,
    );

    expect(result, isA<StudyPlanAdoptResultInvalidPlan>());
    expect(h.draftService.draftById(draftId).outcome,
        StudyPlanDraftOutcome.pending);
    expect(h.persistencePort.commitCalls, 0);
  });

  test(
      '14. ABA prevention: old expectedActivePlanId cannot be revived or reused',
      () async {
    final ids = <String>['plan_A', 'plan_B', 'plan_C'];
    var seq = 0;
    final h = _Harness(planIdFactory: () => ids[seq++]);
    final draftId1 = await h.stageDraft();

    h.persistencePort.nextCommitResult = StudyPlanPersistenceCommitSuccess(
      ActiveStudyPlan(
        planId: 'plan_A',
        bankName: 'Math',
        dailyTarget: 40,
        priority: StudyPlanPriority.balanced,
        sourceConversationId: 'conv_1',
        sourceUserMessageId: 'msg_1',
        adoptedAt: h.currentTime,
      ),
    );

    // Adopt plan_A
    final resA = await h.commandService.adoptDraft(
      draftId: draftId1,
      expectedActivePlanId: null,
      replacementConfirmed: false,
    );
    expect(resA, isA<StudyPlanAdoptResultSuccess>());

    // Replace plan_A -> plan_B
    final draftId2 = await h.stageDraft(dailyTarget: 50);
    h.persistencePort.nextCommitResult = StudyPlanPersistenceCommitSuccess(
      ActiveStudyPlan(
        planId: 'plan_B',
        bankName: 'Math',
        dailyTarget: 50,
        priority: StudyPlanPriority.balanced,
        sourceConversationId: 'conv_1',
        sourceUserMessageId: 'msg_1',
        adoptedAt: h.currentTime,
      ),
    );
    final resB = await h.commandService.adoptDraft(
      draftId: draftId2,
      expectedActivePlanId: 'plan_A',
      replacementConfirmed: true,
    );
    expect(resB, isA<StudyPlanAdoptResultSuccess>());

    // An attempt to adopt using stale plan_A baseline after it was replaced to plan_B:
    // Persistence port rejects with staleActivePlan
    final draftId3 = await h.stageDraft(dailyTarget: 60);
    h.persistencePort.nextCommitResult =
        const StudyPlanPersistenceCommitStaleActivePlan();
    final resStale = await h.commandService.adoptDraft(
      draftId: draftId3,
      expectedActivePlanId: 'plan_A',
      replacementConfirmed: true,
    );
    expect(resStale, isA<StudyPlanAdoptResultStaleActivePlan>());
    expect(h.draftService.draftById(draftId3).outcome,
        StudyPlanDraftOutcome.pending);
  });
}
