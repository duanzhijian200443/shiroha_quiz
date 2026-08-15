// SPL-1-U0 focused selection Application tests. Deterministic, offline:
// fake ports only, no database, no provider, no sleeps.
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_ports.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_pool_order.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_selection_service.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/study_plan/active_study_plan.dart';
import 'package:shiroha_quiz/domain/study_plan/study_plan_values.dart';

final class _FakePersistencePort implements StudyPlanPersistencePort {
  _FakePersistencePort(this.activePlan);

  ActiveStudyPlan? activePlan;
  bool throwUnavailable = false;
  bool throwUnexpected = false;

  @override
  Future<ActiveStudyPlan?> loadActivePlan() async {
    if (throwUnavailable) {
      throw const StudyPlanReadException(StudyPlanReadFailure.unavailable);
    }
    if (throwUnexpected) {
      throw StateError('unexpected');
    }
    return activePlan;
  }

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
  }) {
    throw UnimplementedError();
  }

  @override
  Future<StudyPlanPersistenceStopResult> stopActivePlan({
    required String expectedPlanId,
  }) {
    throw UnimplementedError();
  }
}

final class _FakePlanningPort implements StudyPlanPlanningPort {
  _FakePlanningPort(this.admission);

  StudyPlanPlanningAdmission admission;
  ConversationScope? lastScope;
  int calls = 0;

  @override
  Future<StudyPlanPlanningAdmission> loadPlanningContext({
    required ConversationScope sourceScope,
    required String bankName,
    required DateTime now,
  }) async {
    calls++;
    lastScope = sourceScope;
    return admission;
  }
}

final class _FakeCandidateQueryPort implements StudyPlanCandidateQueryPort {
  _FakeCandidateQueryPort(this.batch);

  StudyPlanCandidateBatch batch;
  int? lastMaxPerPool;
  String? lastBankName;
  int calls = 0;

  @override
  Future<StudyPlanCandidateBatch> loadCandidates({
    required String bankName,
    required int nowUnixSeconds,
    required int maxPerPool,
  }) async {
    calls++;
    lastMaxPerPool = maxPerPool;
    lastBankName = bankName;
    return batch;
  }
}

final class _Harness {
  _Harness({
    ActiveStudyPlan? plan,
    StudyPlanPlanningAdmission admission =
        const StudyPlanPlanningAdmitted(StudyPlanPlanningContext(
      bankName: 'Math',
      questionCount: 10,
      masteredCount: 2,
      dueCount: 3,
      weakCount: 1,
      newCount: 4,
    )),
    StudyPlanCandidateBatch batch = const StudyPlanCandidateBatch(
      due: <StudyPlanCandidate>[],
      weak: <StudyPlanCandidate>[],
      newPool: <StudyPlanCandidate>[],
    ),
    DateTime? now,
  }) {
    persistencePort = _FakePersistencePort(plan);
    planningPort = _FakePlanningPort(admission);
    candidateQueryPort = _FakeCandidateQueryPort(batch);
    service = StudyPlanSelectionService(
      persistencePort: persistencePort,
      planningPort: planningPort,
      candidateQueryPort: candidateQueryPort,
      poolOrder: const StudyPlanPoolOrder(),
      clock: () => now ?? DateTime.utc(2026, 8, 15, 10, 0),
    );
  }

  late final _FakePersistencePort persistencePort;
  late final _FakePlanningPort planningPort;
  late final _FakeCandidateQueryPort candidateQueryPort;
  late final StudyPlanSelectionService service;
}

StudyPlanCandidate _candidate(
  String storageId, {
  bool due = false,
  int? nextReviewAt,
  int lapses = 0,
  double difficulty = 5.0,
  StudyPlanQuestionClassification classification =
      StudyPlanQuestionClassification.review,
}) {
  return StudyPlanCandidate(
    storageId: storageId,
    bankName: 'Math',
    due: due,
    nextReviewAt: nextReviewAt,
    lapses: lapses,
    difficulty: difficulty,
    classification: classification,
  );
}

ActiveStudyPlan _plan({
  String planId = 'plan_1',
  String bankName = 'Math',
  String? goal,
  int dailyTarget = 40,
  StudyPlanPriority priority = StudyPlanPriority.dueFirst,
  int? horizonDays,
  DateTime? adoptedAt,
}) {
  return ActiveStudyPlan(
    planId: planId,
    bankName: bankName,
    goal: goal,
    dailyTarget: dailyTarget,
    priority: priority,
    horizonDays: horizonDays,
    adoptedAt: adoptedAt ?? DateTime.utc(2026, 8, 1, 10, 0),
  );
}

void main() {
  group('no active plan', () {
    test('returns NoActivePlan and never queries candidates', () async {
      final h = _Harness(plan: null);
      final state = await h.service.loadFocusedState();
      expect(state, isA<StudyPlanFocusedNoActivePlan>());
      expect(h.candidateQueryPort.calls, 0);
      expect(h.planningPort.calls, 0);
    });
  });

  group('planUnavailable', () {
    test('unavailable planning admission maps to PlanUnavailable', () async {
      final plan = _plan();
      final h = _Harness(
        plan: plan,
        admission: const StudyPlanPlanningUnavailable(),
      );
      final state = await h.service.loadFocusedState();
      expect(state, isA<StudyPlanFocusedPlanUnavailable>());
      final unavailable = state as StudyPlanFocusedPlanUnavailable;
      expect(unavailable.activePlan.planId, plan.planId);
      expect(h.candidateQueryPort.calls, 0);
    });

    test('planning admission uses current GLOBAL scope, not project', () async {
      final h = _Harness(plan: _plan());
      await h.service.loadFocusedState();
      expect(h.planningPort.lastScope!.kind, ConversationScopeKind.global);
      expect(h.planningPort.lastScope!.projectId, isNull);
    });
  });

  group('noCandidates', () {
    test('empty pools map to NoCandidates with advisory', () async {
      final h = _Harness(plan: _plan());
      final state = await h.service.loadFocusedState();
      expect(state, isA<StudyPlanFocusedNoCandidates>());
      final noCandidates = state as StudyPlanFocusedNoCandidates;
      expect(noCandidates.activePlan.planId, 'plan_1');
      expect(noCandidates.advisory.masteryReached, isFalse);
      expect(noCandidates.advisory.horizonElapsed, isFalse);
    });
  });

  group('sequential priorities exact order', () {
    test('due_first: due -> weak -> new', () async {
      final h = _Harness(
        plan: _plan(priority: StudyPlanPriority.dueFirst, dailyTarget: 10),
        batch: const StudyPlanCandidateBatch(
          due: <StudyPlanCandidate>[
            StudyPlanCandidate(
              storageId: 'd1',
              bankName: 'Math',
              due: true,
              nextReviewAt: 10,
              lapses: 0,
              difficulty: 5.0,
              classification: StudyPlanQuestionClassification.review,
            ),
            StudyPlanCandidate(
              storageId: 'd2',
              bankName: 'Math',
              due: true,
              nextReviewAt: 20,
              lapses: 0,
              difficulty: 5.0,
              classification: StudyPlanQuestionClassification.review,
            ),
          ],
          weak: <StudyPlanCandidate>[
            StudyPlanCandidate(
              storageId: 'w1',
              bankName: 'Math',
              due: false,
              nextReviewAt: 999,
              lapses: 2,
              difficulty: 8.0,
              classification: StudyPlanQuestionClassification.review,
            ),
          ],
          newPool: <StudyPlanCandidate>[
            StudyPlanCandidate(
              storageId: 'n1',
              bankName: 'Math',
              due: false,
              nextReviewAt: 0,
              lapses: 0,
              difficulty: 5.0,
              classification: StudyPlanQuestionClassification.newQuestion,
            ),
            StudyPlanCandidate(
              storageId: 'n2',
              bankName: 'Math',
              due: false,
              nextReviewAt: 0,
              lapses: 0,
              difficulty: 5.0,
              classification: StudyPlanQuestionClassification.newQuestion,
            ),
          ],
        ),
      );
      final state = await h.service.loadFocusedState();
      expect(state, isA<StudyPlanFocusedReady>());
      expect(
        (state as StudyPlanFocusedReady).selectedStorageIds,
        <String>['d1', 'd2', 'w1', 'n1', 'n2'],
      );
    });

    test('weak_first: weak -> due -> new', () async {
      final h = _Harness(
        plan: _plan(priority: StudyPlanPriority.weakFirst, dailyTarget: 10),
        batch: const StudyPlanCandidateBatch(
          due: <StudyPlanCandidate>[
            StudyPlanCandidate(
              storageId: 'd1',
              bankName: 'Math',
              due: true,
              nextReviewAt: 10,
              lapses: 0,
              difficulty: 5.0,
              classification: StudyPlanQuestionClassification.review,
            ),
          ],
          weak: <StudyPlanCandidate>[
            StudyPlanCandidate(
              storageId: 'w1',
              bankName: 'Math',
              due: false,
              nextReviewAt: 999,
              lapses: 2,
              difficulty: 8.0,
              classification: StudyPlanQuestionClassification.review,
            ),
          ],
          newPool: <StudyPlanCandidate>[
            StudyPlanCandidate(
              storageId: 'n1',
              bankName: 'Math',
              due: false,
              nextReviewAt: 0,
              lapses: 0,
              difficulty: 5.0,
              classification: StudyPlanQuestionClassification.newQuestion,
            ),
          ],
        ),
      );
      final state = await h.service.loadFocusedState();
      expect((state as StudyPlanFocusedReady).selectedStorageIds,
          <String>['w1', 'd1', 'n1']);
    });

    test('new_first: new -> due -> weak', () async {
      final h = _Harness(
        plan: _plan(priority: StudyPlanPriority.newFirst, dailyTarget: 10),
        batch: const StudyPlanCandidateBatch(
          due: <StudyPlanCandidate>[
            StudyPlanCandidate(
              storageId: 'd1',
              bankName: 'Math',
              due: true,
              nextReviewAt: 10,
              lapses: 0,
              difficulty: 5.0,
              classification: StudyPlanQuestionClassification.review,
            ),
          ],
          weak: <StudyPlanCandidate>[
            StudyPlanCandidate(
              storageId: 'w1',
              bankName: 'Math',
              due: false,
              nextReviewAt: 999,
              lapses: 2,
              difficulty: 8.0,
              classification: StudyPlanQuestionClassification.review,
            ),
          ],
          newPool: <StudyPlanCandidate>[
            StudyPlanCandidate(
              storageId: 'n1',
              bankName: 'Math',
              due: false,
              nextReviewAt: 0,
              lapses: 0,
              difficulty: 5.0,
              classification: StudyPlanQuestionClassification.newQuestion,
            ),
          ],
        ),
      );
      final state = await h.service.loadFocusedState();
      expect((state as StudyPlanFocusedReady).selectedStorageIds,
          <String>['n1', 'd1', 'w1']);
    });
  });

  group('balanced priority', () {
    test('exact round-robin due -> weak -> new with cursors', () async {
      final h = _Harness(
        plan: _plan(priority: StudyPlanPriority.balanced, dailyTarget: 10),
        batch: const StudyPlanCandidateBatch(
          due: <StudyPlanCandidate>[
            StudyPlanCandidate(
              storageId: 'd1',
              bankName: 'Math',
              due: true,
              nextReviewAt: 10,
              lapses: 0,
              difficulty: 5.0,
              classification: StudyPlanQuestionClassification.review,
            ),
            StudyPlanCandidate(
              storageId: 'd2',
              bankName: 'Math',
              due: true,
              nextReviewAt: 20,
              lapses: 0,
              difficulty: 5.0,
              classification: StudyPlanQuestionClassification.review,
            ),
          ],
          weak: <StudyPlanCandidate>[
            StudyPlanCandidate(
              storageId: 'w1',
              bankName: 'Math',
              due: false,
              nextReviewAt: 999,
              lapses: 2,
              difficulty: 8.0,
              classification: StudyPlanQuestionClassification.review,
            ),
          ],
          newPool: <StudyPlanCandidate>[
            StudyPlanCandidate(
              storageId: 'n1',
              bankName: 'Math',
              due: false,
              nextReviewAt: 0,
              lapses: 0,
              difficulty: 5.0,
              classification: StudyPlanQuestionClassification.newQuestion,
            ),
          ],
        ),
      );
      final state = await h.service.loadFocusedState();
      expect((state as StudyPlanFocusedReady).selectedStorageIds,
          <String>['d1', 'w1', 'n1', 'd2']);
    });

    test('exhausted pools are skipped; stops when all exhausted', () async {
      final h = _Harness(
        plan: _plan(priority: StudyPlanPriority.balanced, dailyTarget: 10),
        batch: const StudyPlanCandidateBatch(
          due: <StudyPlanCandidate>[
            StudyPlanCandidate(
              storageId: 'd1',
              bankName: 'Math',
              due: true,
              nextReviewAt: 10,
              lapses: 0,
              difficulty: 5.0,
              classification: StudyPlanQuestionClassification.review,
            ),
          ],
          weak: <StudyPlanCandidate>[],
          newPool: <StudyPlanCandidate>[
            StudyPlanCandidate(
              storageId: 'n1',
              bankName: 'Math',
              due: false,
              nextReviewAt: 0,
              lapses: 0,
              difficulty: 5.0,
              classification: StudyPlanQuestionClassification.newQuestion,
            ),
          ],
        ),
      );
      final state = await h.service.loadFocusedState();
      expect((state as StudyPlanFocusedReady).selectedStorageIds,
          <String>['d1', 'n1']);
    });
  });

  group('dedup and caps', () {
    test('cross-pool overlap dedup: first occurrence wins', () async {
      final overlap = _candidate('shared', due: true, nextReviewAt: 5);
      final h = _Harness(
        plan: _plan(priority: StudyPlanPriority.dueFirst, dailyTarget: 10),
        batch: StudyPlanCandidateBatch(
          due: <StudyPlanCandidate>[
            overlap,
            _candidate('d2', due: true, nextReviewAt: 20)
          ],
          weak: <StudyPlanCandidate>[overlap],
          newPool: <StudyPlanCandidate>[],
        ),
      );
      final state = await h.service.loadFocusedState();
      expect((state as StudyPlanFocusedReady).selectedStorageIds,
          <String>['shared', 'd2']);
    });

    test('state0 overlap (due AND new) is selected exactly once', () async {
      final state0 = _candidate(
        'state0',
        due: true,
        nextReviewAt: 0,
        classification: StudyPlanQuestionClassification.newQuestion,
      );
      final h = _Harness(
        plan: _plan(priority: StudyPlanPriority.balanced, dailyTarget: 10),
        batch: StudyPlanCandidateBatch(
          due: <StudyPlanCandidate>[state0],
          weak: <StudyPlanCandidate>[],
          newPool: <StudyPlanCandidate>[state0, _candidate('n2')],
        ),
      );
      final state = await h.service.loadFocusedState();
      final ids = (state as StudyPlanFocusedReady).selectedStorageIds;
      expect(ids.where((id) => id == 'state0'), hasLength(1));
      expect(ids, <String>['state0', 'n2']);
    });

    test('dailyTarget caps the final selected count', () async {
      final due = <StudyPlanCandidate>[
        for (var i = 0; i < 5; i++)
          _candidate('d$i', due: true, nextReviewAt: i),
      ];
      final h = _Harness(
        plan: _plan(priority: StudyPlanPriority.dueFirst, dailyTarget: 2),
        batch: StudyPlanCandidateBatch(
            due: due, weak: const [], newPool: const []),
      );
      final state = await h.service.loadFocusedState();
      expect((state as StudyPlanFocusedReady).selectedStorageIds,
          <String>['d0', 'd1']);
    });

    test('candidate read uses maxPerPool == 200, not dailyTarget', () async {
      final h = _Harness(
        plan: _plan(dailyTarget: 7),
        batch: const StudyPlanCandidateBatch(
          due: <StudyPlanCandidate>[],
          weak: <StudyPlanCandidate>[],
          newPool: <StudyPlanCandidate>[],
        ),
      );
      await h.service.loadFocusedState();
      expect(h.candidateQueryPort.lastMaxPerPool, 200);
    });
  });

  group('advisory states', () {
    test('masteryReached still selects a due candidate', () async {
      final h = _Harness(
        plan: _plan(priority: StudyPlanPriority.dueFirst, dailyTarget: 10),
        admission: const StudyPlanPlanningAdmitted(StudyPlanPlanningContext(
          bankName: 'Math',
          questionCount: 5,
          masteredCount: 5,
          dueCount: 1,
          weakCount: 0,
          newCount: 0,
        )),
        batch: StudyPlanCandidateBatch(
          due: <StudyPlanCandidate>[
            _candidate('due_mastered', due: true, nextReviewAt: 3),
          ],
          weak: const <StudyPlanCandidate>[],
          newPool: const <StudyPlanCandidate>[],
        ),
      );
      final state = await h.service.loadFocusedState();
      expect(state, isA<StudyPlanFocusedReady>());
      final ready = state as StudyPlanFocusedReady;
      expect(ready.selectedStorageIds, <String>['due_mastered']);
      expect(ready.advisory.masteryReached, isTrue);
    });

    test('horizonElapsed advisory still selects candidates', () async {
      final now = DateTime.utc(2026, 8, 15, 10, 0);
      final h = _Harness(
        plan: _plan(
          priority: StudyPlanPriority.dueFirst,
          dailyTarget: 10,
          horizonDays: 5,
          adoptedAt: DateTime.utc(2026, 8, 1, 10, 0),
        ),
        batch: StudyPlanCandidateBatch(
          due: <StudyPlanCandidate>[
            _candidate('d1', due: true, nextReviewAt: 3),
          ],
          weak: const <StudyPlanCandidate>[],
          newPool: const <StudyPlanCandidate>[],
        ),
        now: now,
      );
      final state = await h.service.loadFocusedState();
      expect(state, isA<StudyPlanFocusedReady>());
      final ready = state as StudyPlanFocusedReady;
      expect(ready.selectedStorageIds, <String>['d1']);
      expect(ready.advisory.horizonElapsed, isTrue);
    });

    test('horizon not elapsed stays advisory false', () async {
      final now = DateTime.utc(2026, 8, 15, 10, 0);
      final h = _Harness(
        plan: _plan(horizonDays: 90, adoptedAt: DateTime.utc(2026, 8, 10)),
        batch: const StudyPlanCandidateBatch(
          due: <StudyPlanCandidate>[],
          weak: <StudyPlanCandidate>[],
          newPool: <StudyPlanCandidate>[],
        ),
        now: now,
      );
      final state = await h.service.loadFocusedState();
      expect((state as StudyPlanFocusedNoCandidates).advisory.horizonElapsed,
          isFalse);
    });
  });

  group('fresh recomputation', () {
    test(
        'a changed candidate source between snapshot and Start changes the '
        'selection', () async {
      final h = _Harness(
        plan: _plan(priority: StudyPlanPriority.dueFirst, dailyTarget: 10),
        batch: StudyPlanCandidateBatch(
          due: <StudyPlanCandidate>[
            _candidate('old_due', due: true, nextReviewAt: 1),
          ],
          weak: const <StudyPlanCandidate>[],
          newPool: const <StudyPlanCandidate>[],
        ),
      );
      final first = await h.service.loadFocusedState();
      expect((first as StudyPlanFocusedReady).selectedStorageIds,
          <String>['old_due']);

      // The live review state changed before Start: the next call MUST NOT
      // reuse the snapshot selection.
      h.candidateQueryPort.batch = StudyPlanCandidateBatch(
        due: <StudyPlanCandidate>[
          _candidate('new_due', due: true, nextReviewAt: 2),
        ],
        weak: const <StudyPlanCandidate>[],
        newPool: const <StudyPlanCandidate>[],
      );
      final second = await h.service.loadFocusedState();
      expect((second as StudyPlanFocusedReady).selectedStorageIds,
          <String>['new_due']);
      expect(h.candidateQueryPort.calls, 2);
    });
  });

  group('infrastructure failure', () {
    test('bounded read failure maps to temporarilyUnavailable', () async {
      final h = _Harness(plan: _plan());
      h.persistencePort.throwUnavailable = true;
      final state = await h.service.loadFocusedState();
      expect(state, isA<StudyPlanFocusedFailure>());
      expect(
        (state as StudyPlanFocusedFailure).kind,
        StudyPlanFocusedFailureKind.temporarilyUnavailable,
      );
    });

    test('unexpected failure maps to internalError, never raw text', () async {
      final h = _Harness(plan: _plan());
      h.persistencePort.throwUnexpected = true;
      final state = await h.service.loadFocusedState();
      expect(state, isA<StudyPlanFocusedFailure>());
      expect(
        (state as StudyPlanFocusedFailure).kind,
        StudyPlanFocusedFailureKind.internalError,
      );
    });
  });
}
