// T0 repository seam tests: keyset pagination parameters, LIKE escaping,
// typed-aware detail resolution, and the fixed boundary failure mapping.
//
// All databases are synthetic in-memory sqflite FFI handles.
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/data/repositories/review_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';

import '../../application/study_query/study_query_test_support.dart';

Future<void> _seedBanks() async {
  final db = await openTestDatabase();
  await db.insert('bank_folders', <String, Object?>{
    'bank_name': bankMath,
    'folder_name': 'Algebra',
  });
  await insertTypedQuestion(
    db,
    draft: makeDraft(
      'repo_typed',
      stem: textContent('Repo typed alpha'),
      options: <QuestionOption>[optionA()],
      answer: ChoiceAnswer(optionIds: <String>['A']),
    ),
    storageId: idTyped1,
    createdAt: 100,
    bankName: bankMath,
  );
  await insertLegacyQuestion(
    db,
    id: 'repo_legacy',
    createdAt: 90,
    bankName: bankMath,
    content: 'Repo legacy beta 100%_done',
    type: 0,
    options: '["A. one"]',
    answer: 'A',
    explanation: null,
  );
  await insertLegacyQuestion(
    db,
    id: 'repo_other',
    createdAt: 80,
    bankName: bankPhysics,
    content: 'Physics gamma',
    type: 3,
    options: '[]',
    answer: 'gamma',
    explanation: null,
  );
  await insertReviewState(
    db,
    questionId: idTyped1,
    state: 3,
    nextReviewTime: 300,
    lapses: 2,
    lastLapseTime: 300,
  );
  await insertReviewState(
    db,
    questionId: 'repo_legacy',
    state: 1,
    nextReviewTime: 100,
    lapses: 1,
    lastLapseTime: 100,
  );
  await insertReviewState(db, questionId: 'repo_other', state: 0);
}

void main() {
  setUpAll(initTestDatabaseFactory);

  setUp(() async {
    await resetTestDatabase();
    await _seedBanks();
  });

  tearDown(resetTestDatabase);

  group('bank list seam', () {
    test('counts, folder fallback, and keyset continuation', () async {
      final repository = QuestionRepository();
      final first = await repository.listStudyQuestionBanks(
        nowUnixSeconds: 200,
        limit: 1,
      );
      expect(first.items, hasLength(1));
      expect(first.items.single.bankName, bankMath);
      expect(first.items.single.folderName, 'Algebra');
      expect(first.items.single.questionCount, 2);
      expect(first.items.single.dueCount, 1);
      expect(first.items.single.masteredCount, 1);
      expect(first.hasMore, isTrue);

      final second = await repository.listStudyQuestionBanks(
        nowUnixSeconds: 200,
        limit: 1,
        afterBankName: first.items.single.bankName,
      );
      expect(second.items.single.bankName, bankPhysics);
      expect(second.items.single.folderName, uncategorizedFolder);
      expect(second.hasMore, isFalse);
    });
  });

  group('search seam', () {
    test('LIKE wildcards match literally and keyset continues', () async {
      final repository = QuestionRepository();
      final page = await repository.searchStudyQuestions(
        bankName: bankMath,
        query: '100%_done',
        nowUnixSeconds: 200,
        limit: 1,
      );
      expect(page.items.map((item) => item.questionId).toList(),
          <String>['repo_legacy']);
      expect(page.hasMore, isFalse);

      final alpha = await repository.searchStudyQuestions(
        bankName: bankMath,
        query: 'alpha',
        nowUnixSeconds: 200,
        limit: 5,
      );
      expect(alpha.items.map((item) => item.questionId).toList(),
          <String>[idTyped1]);
      expect(alpha.items.single, isA<TypedStudyQuestionRead>());

      final first = await repository.searchStudyQuestions(
        bankName: bankMath,
        query: 'Repo',
        nowUnixSeconds: 200,
        limit: 1,
      );
      expect(first.items.single.questionId, idTyped1);
      expect(first.hasMore, isTrue);
      final second = await repository.searchStudyQuestions(
        bankName: bankMath,
        query: 'Repo',
        nowUnixSeconds: 200,
        limit: 1,
        afterCreatedAt: first.items.single.createdAt,
        afterId: first.items.single.questionId,
      );
      expect(second.items.single.questionId, 'repo_legacy');
      expect(second.hasMore, isFalse);
    });

    test('state=0 with next_review_time=0 is due', () async {
      final read = await QuestionRepository().searchStudyQuestions(
        bankName: bankPhysics,
        query: 'gamma',
        nowUnixSeconds: 200,
        limit: 5,
      );
      expect(read.items.single.questionId, 'repo_other');
      expect(read.items.single.review.due, isTrue);
    });

    test('no review_states row is not due', () async {
      final db = await openTestDatabase();
      await insertLegacyQuestion(
        db,
        id: 'repo_unreviewed',
        createdAt: 70,
        bankName: bankPhysics,
        content: 'Unreviewed delta',
        type: 3,
        options: '[]',
        answer: 'delta',
        explanation: null,
      );
      final read = await QuestionRepository().searchStudyQuestions(
        bankName: bankPhysics,
        query: 'delta',
        nowUnixSeconds: 200,
        limit: 5,
      );
      expect(read.items.single.questionId, 'repo_unreviewed');
      expect(read.items.single.review.due, isFalse);
    });
  });

  group('detail seam', () {
    test('missing question resolves to null', () async {
      final read = await QuestionRepository().getStudyQuestionDetail(
        'missing',
        nowUnixSeconds: 200,
      );
      expect(read, isNull);
    });

    test('corrupt sidecar hard-fails without V1 fallback', () async {
      final db = await openTestDatabase();
      await insertTypedQuestion(
        db,
        draft: makeDraft(
          'repo_corrupt',
          stem: textContent('Corrupt seam'),
          options: <QuestionOption>[optionA()],
          answer: ChoiceAnswer(optionIds: <String>['A']),
        ),
        storageId: idCorrupt,
        createdAt: 10,
        bankName: bankCorrupt,
      );
      await corruptSidecar(db, storageId: idCorrupt);

      StudyQueryRepositoryException? caught;
      try {
        await QuestionRepository().getStudyQuestionDetail(
          idCorrupt,
          nowUnixSeconds: 200,
        );
      } on StudyQueryRepositoryException catch (error) {
        caught = error;
      }
      expect(caught, isNotNull);
      expect(
        caught!.failure,
        StudyQueryRepositoryFailure.corruptPayload,
      );
      expect(caught.toString(), isNot(contains('oops')));
    });
  });

  group('weak seam', () {
    test('orders by last lapse descending with keyset continuation', () async {
      final repository = QuestionRepository();
      final first = await repository.listStudyWeakQuestions(
        nowUnixSeconds: 200,
        limit: 1,
      );
      expect(first.items.single.questionId, idTyped1);
      expect(first.items.single.review.lapseCount, 2);
      expect(first.hasMore, isTrue);

      final second = await repository.listStudyWeakQuestions(
        nowUnixSeconds: 200,
        limit: 1,
        afterLastLapseTime: first.items.single.review.lastLapseTime ?? 0,
        afterId: first.items.single.questionId,
      );
      expect(second.items.single.questionId, 'repo_legacy');
      expect(second.hasMore, isFalse);
    });
  });

  group('metrics seam', () {
    test('overview counts, scheduled window, and due now', () async {
      final db = await openTestDatabase();
      await insertReviewLog(db, questionId: idTyped1, reviewTime: 150);
      await insertReviewLog(db, questionId: 'repo_legacy', reviewTime: 50);

      final repository = ReviewRepository();
      final overview = await repository.getStudyOverviewCounts(
        nowUnixSeconds: 200,
        todayStartUnixSeconds: 100,
      );
      expect(overview.questionCount, 3);
      expect(overview.masteredCount, 1);
      expect(overview.dueCount, 2);
      expect(overview.todayPracticeCount, 1);
      expect(overview.wrongQuestionCount, 2);

      final math = await repository.getStudyOverviewCounts(
        bankName: bankMath,
        nowUnixSeconds: 200,
        todayStartUnixSeconds: 100,
      );
      expect(math.questionCount, 2);
      expect(math.todayPracticeCount, 1);

      final scheduled = await repository.getStudyScheduledReviewTimestamps(
        fromUnixSeconds: 0,
        toUnixSeconds: 200,
      );
      expect(scheduled, <int>[100]);
      final bankScheduledFirst =
          await repository.getStudyScheduledReviewTimestamps(
        bankName: bankMath,
        fromUnixSeconds: 0,
        toUnixSeconds: 200,
      );
      expect(bankScheduledFirst, <int>[100]);

      await db.update(
        'review_states',
        <String, Object?>{'state': 1, 'next_review_time': 150},
        where: 'question_id = ?',
        whereArgs: <Object?>['repo_other'],
      );
      final scheduledAfter = await repository.getStudyScheduledReviewTimestamps(
        fromUnixSeconds: 100,
        toUnixSeconds: 200,
      );
      expect(scheduledAfter, <int>[100, 150]);
      final bankScheduled = await repository.getStudyScheduledReviewTimestamps(
        bankName: bankMath,
        fromUnixSeconds: 100,
        toUnixSeconds: 200,
      );
      expect(bankScheduled, <int>[100]);

      expect(
        await repository.countStudyDueNow(nowUnixSeconds: 200),
        2,
      );
    });
  });

  group('boundary failure mapping', () {
    test('dropped tables map to unavailable', () async {
      final db = await openTestDatabase();
      await db.execute('DROP TABLE review_states');

      StudyQueryRepositoryException? caught;
      try {
        await ReviewRepository().getStudyOverviewCounts(
          nowUnixSeconds: 1,
          todayStartUnixSeconds: 0,
        );
      } on StudyQueryRepositoryException catch (error) {
        caught = error;
      }
      expect(caught, isNotNull);
      expect(
        caught!.failure,
        StudyQueryRepositoryFailure.unavailable,
      );
      expect(caught.toString(), isNot(contains('review_states')));
      expect(caught.toString(), isNot(contains('DROP')));
    });
  });
}
