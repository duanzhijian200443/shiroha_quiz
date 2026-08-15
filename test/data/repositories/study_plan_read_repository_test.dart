// SPL-1-D0 repository tests: planning admission (scope-aware,
// non-enumerating), canonical aggregate semantics, deterministic candidate
// pools (including the frozen state=0 due overlap and mastered-not-excluded
// cases), and bounded candidate reads. All databases are synthetic
// in-memory sqflite FFI handles; no question content or V2 sidecar payloads
// are loaded for selection.
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_ports.dart';
import 'package:shiroha_quiz/data/repositories/study_plan_read_repository.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/study_plan/study_plan_values.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../application/study_query/study_query_test_support.dart';

const String _projectId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
final DateTime _now = DateTime.fromMillisecondsSinceEpoch(200 * 1000);

Future<void> _seedAdmissionBank(Database db) async {
  // Math: q_a state=0 next=0 (due overlap), q_b reviewed due, q_c weak,
  // q_d mastered due, q_e mastered weak, q_f future review.
  await insertLegacyQuestion(db, id: 'q_a', createdAt: 10, bankName: bankMath);
  await insertLegacyQuestion(db, id: 'q_b', createdAt: 20, bankName: bankMath);
  await insertLegacyQuestion(db, id: 'q_c', createdAt: 30, bankName: bankMath);
  await insertLegacyQuestion(db, id: 'q_d', createdAt: 40, bankName: bankMath);
  await insertLegacyQuestion(db, id: 'q_e', createdAt: 50, bankName: bankMath);
  await insertLegacyQuestion(db, id: 'q_f', createdAt: 60, bankName: bankMath);
  await insertReviewState(db, questionId: 'q_a', state: 0, nextReviewTime: 0);
  await insertReviewState(db,
      questionId: 'q_b', state: 1, nextReviewTime: 100, difficulty: 5.0);
  await insertReviewState(db,
      questionId: 'q_c', state: 2, nextReviewTime: 500, lapses: 2);
  await insertReviewState(db,
      questionId: 'q_d', state: 3, nextReviewTime: 100, difficulty: 5.0);
  await insertReviewState(db,
      questionId: 'q_e',
      state: 3,
      nextReviewTime: 500,
      lapses: 1,
      difficulty: 8.0);
  await insertReviewState(db, questionId: 'q_f', state: 1, nextReviewTime: 400);

  // Physics: one never-reviewed question, outside the project relation.
  await insertLegacyQuestion(db,
      id: 'p_1', createdAt: 5, bankName: bankPhysics);
  await insertReviewState(db, questionId: 'p_1', state: 0);

  // Project relation: Math admitted, EmptyBank related but with no questions.
  await insertJ0MetadataRows(db);
  await db.insert('project_banks', <String, Object?>{
    'project_id': _projectId,
    'bank_name': 'EmptyBank',
  });
}

Future<void> _seedTimeBank(Database db) async {
  // New-pool ordering must not depend on created_at.
  await insertLegacyQuestion(db,
      id: 'zz', createdAt: 1000, bankName: 'TimeBank');
  await insertLegacyQuestion(db,
      id: 'aa', createdAt: 100, bankName: 'TimeBank');
  await insertReviewState(db, questionId: 'zz', state: 0);
  await insertReviewState(db, questionId: 'aa', state: 0);
}

Future<void> _seedBigBank(Database db, {required int count}) async {
  for (var i = 0; i < count; i++) {
    final id = 'big_${i.toString().padLeft(4, '0')}';
    await insertLegacyQuestion(db, id: id, createdAt: i, bankName: 'BigBank');
    await insertReviewState(db, questionId: id, state: 0);
  }
}

void main() {
  setUpAll(initTestDatabaseFactory);

  setUp(() async {
    await resetTestDatabase();
    final db = await openTestDatabase();
    await _seedAdmissionBank(db);
    await _seedTimeBank(db);
  });

  tearDown(resetTestDatabase);

  group('planning admission', () {
    test('Global real bank is admitted with canonical aggregate counts',
        () async {
      final repository = StudyPlanReadRepository();
      final admission = await repository.loadPlanningContext(
        sourceScope: ConversationScope.global(),
        bankName: bankMath,
        now: _now,
      );
      expect(admission, isA<StudyPlanPlanningAdmitted>());
      final context = (admission as StudyPlanPlanningAdmitted).context;
      expect(context.bankName, bankMath);
      expect(context.questionCount, 6);
      expect(context.masteredCount, 2); // state = 3
      expect(context.dueCount, 3); // next_review_time <= now, no state filter
      expect(context.weakCount, 2); // lapses > 0
      expect(context.newCount, 1); // state = 0
    });

    test('Global missing bank is unavailable', () async {
      final admission = await StudyPlanReadRepository().loadPlanningContext(
        sourceScope: ConversationScope.global(),
        bankName: 'MissingBank',
        now: _now,
      );
      expect(admission, isA<StudyPlanPlanningUnavailable>());
    });

    test('Global empty bank (no questions) is unavailable', () async {
      final admission = await StudyPlanReadRepository().loadPlanningContext(
        sourceScope: ConversationScope.global(),
        bankName: 'EmptyBank',
        now: _now,
      );
      expect(admission, isA<StudyPlanPlanningUnavailable>());
    });

    test('LearningSpace member bank is admitted', () async {
      final admission = await StudyPlanReadRepository().loadPlanningContext(
        sourceScope: ConversationScope.learningSpace(_projectId),
        bankName: bankMath,
        now: _now,
      );
      expect(admission, isA<StudyPlanPlanningAdmitted>());
    });

    test(
        'LearningSpace bank outside the project is unavailable with the '
        'same bounded shape as a missing bank', () async {
      final repository = StudyPlanReadRepository();
      final outside = await repository.loadPlanningContext(
        sourceScope: ConversationScope.learningSpace(_projectId),
        bankName: bankPhysics,
        now: _now,
      );
      final missing = await repository.loadPlanningContext(
        sourceScope: ConversationScope.learningSpace(_projectId),
        bankName: 'MissingBank',
        now: _now,
      );
      expect(outside, isA<StudyPlanPlanningUnavailable>());
      expect(missing, isA<StudyPlanPlanningUnavailable>());
      expect(outside.runtimeType, missing.runtimeType);
    });

    test('unavailable LearningSpace scope is denied', () async {
      final admission = await StudyPlanReadRepository().loadPlanningContext(
        sourceScope: ConversationScope.unavailableLearningSpace(),
        bankName: bankMath,
        now: _now,
      );
      expect(admission, isA<StudyPlanPlanningUnavailable>());
    });
  });

  group('candidate pools', () {
    test(
        'state=0 with next_review_time=0 is due and new; reviewed due '
        'questions are review classification', () async {
      final batch = await StudyPlanReadRepository().loadCandidates(
        bankName: bankMath,
        nowUnixSeconds: 200,
        maxPerPool: 200,
      );
      final byId = <String, StudyPlanCandidate>{
        for (final candidate in [...batch.due, ...batch.weak, ...batch.newPool])
          candidate.storageId: candidate,
      };
      final a = byId['q_a']!;
      expect(a.due, isTrue);
      expect(a.classification, StudyPlanQuestionClassification.newQuestion);
      final b = byId['q_b']!;
      expect(b.due, isTrue);
      expect(b.classification, StudyPlanQuestionClassification.review);
    });

    test('weak pool contains lapses > 0 candidates including a mastered one',
        () async {
      final batch = await StudyPlanReadRepository().loadCandidates(
        bankName: bankMath,
        nowUnixSeconds: 200,
        maxPerPool: 200,
      );
      final weakIds = batch.weak.map((c) => c.storageId).toList();
      expect(weakIds, containsAll(<String>['q_c', 'q_e']));
      final e = batch.weak.singleWhere((c) => c.storageId == 'q_e');
      expect(e.classification, StudyPlanQuestionClassification.review);
      expect(e.due, isFalse);
    });

    test(
        'mastered state=3 with next_review_time <= now stays selectable '
        'through due semantics (not automatically excluded)', () async {
      final batch = await StudyPlanReadRepository().loadCandidates(
        bankName: bankMath,
        nowUnixSeconds: 200,
        maxPerPool: 200,
      );
      final dueIds = batch.due.map((c) => c.storageId).toList();
      expect(dueIds, contains('q_d'));
      final d = batch.due.singleWhere((c) => c.storageId == 'q_d');
      expect(d.due, isTrue);
      expect(d.classification, StudyPlanQuestionClassification.review);
    });

    test('future review is not due', () async {
      final batch = await StudyPlanReadRepository().loadCandidates(
        bankName: bankMath,
        nowUnixSeconds: 200,
        maxPerPool: 200,
      );
      expect(batch.due.map((c) => c.storageId), isNot(contains('q_f')));
      expect(batch.weak.map((c) => c.storageId), isNot(contains('q_f')));
      expect(batch.newPool.map((c) => c.storageId), isNot(contains('q_f')));
    });

    test(
        'deterministic pool ordering: due next ASC then id ASC, weak lapses '
        'DESC difficulty DESC id ASC, new id ASC', () async {
      final batch = await StudyPlanReadRepository().loadCandidates(
        bankName: bankMath,
        nowUnixSeconds: 200,
        maxPerPool: 200,
      );
      expect(
        batch.due.map((c) => c.storageId).toList(),
        <String>['q_a', 'q_b', 'q_d'],
      );
      expect(
        batch.weak.map((c) => c.storageId).toList(),
        <String>['q_c', 'q_e'],
      );
      expect(batch.newPool.map((c) => c.storageId).toList(), <String>['q_a']);
    });

    test('new-pool ordering never depends on questions.created_at', () async {
      final batch = await StudyPlanReadRepository().loadCandidates(
        bankName: 'TimeBank',
        nowUnixSeconds: 200,
        maxPerPool: 200,
      );
      expect(
        batch.newPool.map((c) => c.storageId).toList(),
        <String>['aa', 'zz'],
      );
    });

    test(
        'candidate reads are bounded: maxPerPool caps each pool and the '
        'top-200 of each pool always satisfies dailyTarget <= 200', () async {
      await _seedBigBank(await openTestDatabase(), count: 250);
      final batch = await StudyPlanReadRepository().loadCandidates(
        bankName: 'BigBank',
        nowUnixSeconds: 200,
        maxPerPool: 200,
      );
      expect(batch.due.length, 200);
      expect(batch.newPool.length, 200);
      expect(batch.weak, isEmpty);
      expect(
        batch.due.length + batch.weak.length + batch.newPool.length,
        lessThanOrEqualTo(600),
      );
      // Distinct union is bounded by per-pool caps.
      final distinct = <String>{
        for (final candidate in [...batch.due, ...batch.weak, ...batch.newPool])
          candidate.storageId,
      };
      expect(distinct.length, lessThanOrEqualTo(200));
    });

    test('maxPerPool bounds are enforced', () async {
      final repository = StudyPlanReadRepository();
      expect(
        () => repository.loadCandidates(
          bankName: bankMath,
          nowUnixSeconds: 200,
          maxPerPool: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => repository.loadCandidates(
          bankName: bankMath,
          nowUnixSeconds: 200,
          maxPerPool: 201,
        ),
        throwsArgumentError,
      );
    });
  });
}
