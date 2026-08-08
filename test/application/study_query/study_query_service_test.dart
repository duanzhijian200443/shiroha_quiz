// T0 read-only study query application layer acceptance.
//
// Covers the six frozen read semantics (banks, overview, due summary,
// search, detail, weak questions), the READ_ONLY proof, and the fixed
// failure mapping. All databases are synthetic in-memory sqflite FFI
// handles; the clock and timezone resolver are injected for determinism.
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/study_query/study_query_clock.dart';
import 'package:shiroha_quiz/application/study_query/study_query_dtos.dart';
import 'package:shiroha_quiz/application/study_query/study_query_error.dart';
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/application/study_query/study_query_service.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/data/repositories/review_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';

import 'study_query_test_support.dart';

final class _FixedClock implements StudyClock {
  const _FixedClock(this.now);

  final DateTime now;

  @override
  DateTime nowUtc() => now;
}

final DateTime fixedNow = DateTime.utc(2026, 8, 8, 17);

StudyQueryService _service() {
  return StudyQueryService(
    questionQuery: QuestionRepository(),
    metricsQuery: ReviewRepository(),
    clock: _FixedClock(fixedNow),
  );
}

/// Seeds the canonical mixed typed+legacy dataset used across the
/// acceptance tests. Review instants are chosen around the 2026-08-08
/// Shanghai local-day boundary (2026-08-08T16:00:00Z).
Future<void> _seedStandardDataset() async {
  final db = await openTestDatabase();

  await db.insert('bank_folders', <String, Object?>{
    'bank_name': bankMath,
    'folder_name': 'Algebra',
  });
  await db.insert('bank_folders', <String, Object?>{
    'bank_name': bankPhysics,
    'folder_name': 'Physics',
  });

  await insertTypedQuestion(
    db,
    draft: makeDraft(
      'draft_alpha',
      stem: richContent(<ContentNode>[
        const TextNode('Solve '),
        const InlineMathNode(r'x^2=1'),
        RawFallbackNode(rawFallbackPayload('synthetic-raw')),
      ]),
      options: <QuestionOption>[optionA(), optionB()],
      answer: ChoiceAnswer(optionIds: <String>['A']),
      explanation: textContent('Synthetic explanation alpha'),
    ),
    storageId: idTyped1,
    createdAt: 100,
    bankName: bankMath,
  );
  await insertTypedQuestion(
    db,
    draft: makeDraft(
      'draft_beta',
      stem: textContent('Synthetic stem beta'),
      options: <QuestionOption>[optionA(), optionB()],
      answer: ChoiceAnswer(optionIds: <String>['A']),
      explanation: textContent('Beta explanation'),
    ),
    storageId: idTyped2,
    createdAt: 90,
    bankName: bankMath,
  );
  await insertLegacyQuestion(
    db,
    id: 'legacy_q3',
    createdAt: 80,
    bankName: bankMath,
    content: 'Synthetic legacy gamma',
    type: 3,
    options: '["A. one","B. two"]',
    answer: 'Legacy answer',
    explanation: 'Legacy explanation.',
  );
  await insertLegacyQuestion(
    db,
    id: 'legacy_q4',
    createdAt: 70,
    bankName: bankPhysics,
    content: 'Physics legacy delta',
    type: 0,
    options: '["A. alpha","B. beta"]',
    answer: 'A',
    explanation: null,
  );
  await insertTypedQuestion(
    db,
    draft: makeDraft(
      'draft_epsilon',
      stem: textContent('Synthetic stem epsilon'),
      options: <QuestionOption>[optionA(), optionB()],
      // Explicit typed empty: no answer and no explanation. The V1
      // compatibility projection is drifted later to prove no fallback.
      answer: null,
      explanation: null,
    ),
    storageId: idTyped5,
    createdAt: 60,
    bankName: bankPhysics,
  );
  await insertLegacyQuestion(
    db,
    id: 'legacy_q6',
    createdAt: 50,
    bankName: bankThird,
    content: 'Third bank zeta',
    type: 2,
    options: '[]',
    answer: 'fill answer',
    explanation: null,
  );
  await insertLegacyQuestion(
    db,
    id: 'legacy_q7',
    createdAt: 40,
    bankName: bankMath,
    content: 'Progress 100%_done now',
    type: 0,
    options: '["A. yes","B. no"]',
    answer: 'A',
    explanation: null,
  );

  await insertReviewState(
    db,
    questionId: idTyped1,
    state: 3,
    nextReviewTime: unixSeconds('2026-08-08T15:59:59Z'),
    lapses: 3,
    difficulty: 4.2,
    lastLapseTime: unixSeconds('2026-08-03T07:00:00Z'),
  );
  await insertReviewState(
    db,
    questionId: idTyped2,
    state: 2,
    nextReviewTime: unixSeconds('2026-08-08T16:00:00Z'),
  );
  await insertReviewState(
    db,
    questionId: 'legacy_q3',
    state: 1,
    nextReviewTime: unixSeconds('2026-08-09T10:00:00Z'),
    lapses: 2,
    difficulty: 6.5,
    lastLapseTime: unixSeconds('2026-08-01T08:00:00Z'),
  );
  await insertReviewState(
    db,
    questionId: 'legacy_q4',
    state: 1,
    nextReviewTime: unixSeconds('2026-08-07T23:59:59Z'),
    lapses: 1,
    lastLapseTime: unixSeconds('2026-08-02T09:00:00Z'),
  );
  await insertReviewState(
    db,
    questionId: idTyped5,
    state: 3,
    nextReviewTime: unixSeconds('2026-08-10T00:00:00Z'),
  );
  await insertReviewState(
    db,
    questionId: 'legacy_q6',
    state: 0,
    nextReviewTime: unixSeconds('2026-08-08T00:00:00Z'),
  );
  await insertReviewState(
    db,
    questionId: 'legacy_q7',
    state: 0,
    nextReviewTime: unixSeconds('2026-08-06T00:00:00Z'),
  );

  await insertReviewLog(
    db,
    questionId: idTyped1,
    reviewTime: unixSeconds('2026-08-08T16:30:00Z'),
  );
  await insertReviewLog(
    db,
    questionId: idTyped2,
    reviewTime: unixSeconds('2026-08-08T15:00:00Z'),
  );
  await insertReviewLog(
    db,
    questionId: idTyped5,
    reviewTime: unixSeconds('2026-08-08T00:30:00Z'),
  );
}

void main() {
  setUpAll(initTestDatabaseFactory);

  setUp(() async {
    await resetTestDatabase();
    await _seedStandardDataset();
  });

  tearDown(resetTestDatabase);

  group('A list question banks', () {
    test('mixed typed+legacy banks with counts and folders', () async {
      final page = await _service().listQuestionBanks();

      expect(page.items.map((item) => item.bankName).toList(),
          <String>[bankMath, bankPhysics, bankThird]);
      final math = page.items[0];
      expect(math.folderName, 'Algebra');
      expect(math.questionCount, 4);
      expect(math.dueCount, 3);
      expect(math.masteredCount, 1);
      final physics = page.items[1];
      expect(physics.folderName, 'Physics');
      expect(physics.questionCount, 2);
      expect(physics.dueCount, 1);
      expect(physics.masteredCount, 1);
      final third = page.items[2];
      expect(third.folderName, uncategorizedFolder);
      expect(third.questionCount, 1);
      expect(third.dueCount, 1);
      expect(third.masteredCount, 0);
      expect(page.nextCursor, isNull);
    });

    test('bounded keyset pagination with an opaque cursor', () async {
      final service = _service();
      final first = await service.listQuestionBanks(limit: 2);
      expect(first.items.map((item) => item.bankName).toList(),
          <String>[bankMath, bankPhysics]);
      expect(first.nextCursor, isNotNull);
      expect(first.nextCursor!.value, isNot(contains(bankPhysics)));

      final second = await service.listQuestionBanks(
        cursor: first.nextCursor,
        limit: 2,
      );
      expect(second.items.map((item) => item.bankName).toList(),
          <String>[bankThird]);
      expect(second.nextCursor, isNull);
    });

    test('invalid limit and forged cursors are invalid requests', () async {
      final service = _service();
      await expectLater(
        service.listQuestionBanks(limit: 0),
        throwsA(
          isA<StudyQueryException>().having(
            (error) => error.failure,
            'failure',
            StudyQueryFailure.invalidRequest,
          ),
        ),
      );
      await expectLater(
        service.listQuestionBanks(limit: 101),
        throwsA(
          isA<StudyQueryException>().having(
            (error) => error.failure,
            'failure',
            StudyQueryFailure.invalidRequest,
          ),
        ),
      );
      await expectLater(
        service.listQuestionBanks(
            cursor: OpaqueCursor.fromEncoded('not-a-cursor')),
        throwsA(
          isA<StudyQueryException>().having(
            (error) => error.failure,
            'failure',
            StudyQueryFailure.invalidRequest,
          ),
        ),
      );
    });

    test('long bank names map cursor overflow to internalError', () async {
      final db = await openTestDatabase();
      final longMath = 'X' * 300;
      final longPhysics = 'Y' * 300;
      await insertLegacyQuestion(
        db,
        id: 'long_bank_q1',
        createdAt: 30,
        bankName: longMath,
        content: 'Long bank question one',
      );
      await insertLegacyQuestion(
        db,
        id: 'long_bank_q2',
        createdAt: 20,
        bankName: longPhysics,
        content: 'Long bank question two',
      );

      final service = _service();
      StudyQueryException? caught;
      try {
        await service.listQuestionBanks(limit: 4);
      } on StudyQueryException catch (error) {
        caught = error;
      }
      expect(caught, isNotNull);
      expect(caught!.failure, StudyQueryFailure.internalError);
      expect(caught.toString(), isNot(contains(longMath)));
      expect(caught.toString(), isNot(contains(longPhysics)));
    });
  });

  group('B study overview', () {
    test('global and bank scoped counts with timezone day boundary', () async {
      final service = _service();

      // Shanghai local date is 2026-08-09; today starts 2026-08-08T16:00Z.
      final shanghai =
          await service.getStudyOverview(timezone: 'Asia/Shanghai');
      expect(shanghai.questionCount, 7);
      expect(shanghai.masteredCount, 2);
      expect(shanghai.dueCount, 5);
      expect(shanghai.wrongQuestionCount, 3);
      expect(shanghai.todayPracticeCount, 1);

      final math = await service.getStudyOverview(
        bankName: '  $bankMath  ',
        timezone: 'Asia/Shanghai',
      );
      expect(math.questionCount, 4);
      expect(math.masteredCount, 1);
      expect(math.dueCount, 3);
      expect(math.wrongQuestionCount, 2);
      expect(math.todayPracticeCount, 1);

      final physics = await service.getStudyOverview(
        bankName: bankPhysics,
        timezone: 'Asia/Shanghai',
      );
      expect(physics.questionCount, 2);
      expect(physics.dueCount, 1);
      expect(physics.wrongQuestionCount, 1);
      expect(physics.todayPracticeCount, 0);

      // UTC local day is 2026-08-08; today starts 2026-08-08T00:00Z.
      final utc = await service.getStudyOverview(timezone: 'UTC');
      expect(utc.todayPracticeCount, 3);
    });

    test('invalid bank and timezone arguments are invalid requests', () async {
      final service = _service();
      await expectLater(
        service.getStudyOverview(bankName: '   ', timezone: 'UTC'),
        throwsA(
          isA<StudyQueryException>().having(
            (error) => error.failure,
            'failure',
            StudyQueryFailure.invalidRequest,
          ),
        ),
      );
      await expectLater(
        service.getStudyOverview(timezone: 'Mars/Olympus_Mons'),
        throwsA(
          isA<StudyQueryException>().having(
            (error) => error.failure,
            'failure',
            StudyQueryFailure.invalidRequest,
          ),
        ),
      );
    });
  });

  group('C due review summary', () {
    test('half-open window, 90 day cap, local-date buckets, due now', () async {
      final service = _service();
      final summary = await service.getDueReviewSummary(
        timezone: 'Asia/Shanghai',
        from: DateTime.utc(2026, 8, 8),
        to: DateTime.utc(2026, 8, 10),
      );

      expect(summary.dueNow, 5);
      expect(summary.scheduledCount, 3);
      expect(
        summary.buckets
            .map((bucket) => '${bucket.date}:${bucket.count}')
            .toList(),
        <String>['2026-08-08:1', '2026-08-09:2'],
      );

      final utc = await service.getDueReviewSummary(
        timezone: 'UTC',
        from: DateTime.utc(2026, 8, 8),
        to: DateTime.utc(2026, 8, 10),
      );
      expect(utc.scheduledCount, 3);
      expect(
        utc.buckets.map((bucket) => '${bucket.date}:${bucket.count}').toList(),
        <String>['2026-08-08:2', '2026-08-09:1'],
      );

      final math = await service.getDueReviewSummary(
        bankName: bankMath,
        timezone: 'Asia/Shanghai',
        from: DateTime.utc(2026, 8, 8),
        to: DateTime.utc(2026, 8, 10),
      );
      expect(math.dueNow, 3);
      expect(math.scheduledCount, 3);
      expect(
        math.buckets.map((bucket) => '${bucket.date}:${bucket.count}').toList(),
        <String>['2026-08-08:1', '2026-08-09:2'],
      );

      final physics = await service.getDueReviewSummary(
        bankName: bankPhysics,
        timezone: 'Asia/Shanghai',
        from: DateTime.utc(2026, 8, 8),
        to: DateTime.utc(2026, 8, 10),
      );
      expect(physics.dueNow, 1);
      expect(physics.scheduledCount, 0);
      expect(physics.buckets, isEmpty);
    });

    test('exactly 90 days is allowed and longer windows are rejected',
        () async {
      final service = _service();
      final summary = await service.getDueReviewSummary(
        timezone: 'UTC',
        from: DateTime.utc(2026, 8, 8),
        to: DateTime.utc(2026, 8, 8).add(const Duration(days: 90)),
      );
      // q5 (2026-08-10T00:00Z) falls inside the wider 90-day window.
      expect(summary.scheduledCount, 4);

      await expectLater(
        service.getDueReviewSummary(
          timezone: 'UTC',
          from: DateTime.utc(2026, 8, 8),
          to: DateTime.utc(2026, 8, 8).add(const Duration(days: 91)),
        ),
        throwsA(
          isA<StudyQueryException>().having(
            (error) => error.failure,
            'failure',
            StudyQueryFailure.invalidRequest,
          ),
        ),
      );
      await expectLater(
        service.getDueReviewSummary(
          timezone: 'UTC',
          from: DateTime.utc(2026, 8, 9),
          to: DateTime.utc(2026, 8, 8),
        ),
        throwsA(
          isA<StudyQueryException>().having(
            (error) => error.failure,
            'failure',
            StudyQueryFailure.invalidRequest,
          ),
        ),
      );
    });
  });

  group('D search questions', () {
    test('ordering, keyset cursor, preview, flags, and source kind', () async {
      final service = _service();
      final page = await service.searchQuestions(
        bankName: bankMath,
        query: 'Synthetic',
        limit: 2,
      );

      expect(page.items.map((item) => item.questionId).toList(),
          <String>[idTyped1, idTyped2]);
      expect(page.nextCursor, isNotNull);

      final first = page.items[0];
      expect(first.bankName, bankMath);
      expect(first.kind, StudyQuestionKind.singleChoice);
      expect(first.stemPreview, r'Solve x^2=1');
      expect(first.stemPreview, isNot(contains('synthetic-raw')));
      expect(first.stemPreview, isNot(contains('raw_fallback')));
      expect(first.hasAnswer, isTrue);
      expect(first.hasExplanation, isTrue);
      expect(first.due, isTrue);
      expect(first.sourceKind, StudySourceKind.typed);

      final second = page.items[1];
      expect(second.stemPreview, 'Synthetic stem beta');
      expect(second.sourceKind, StudySourceKind.typed);

      final next = await service.searchQuestions(
        bankName: bankMath,
        query: 'Synthetic',
        cursor: page.nextCursor,
        limit: 2,
      );
      expect(next.items.map((item) => item.questionId).toList(),
          <String>['legacy_q3']);
      expect(next.items.single.sourceKind, StudySourceKind.legacy);
      expect(next.items.single.kind, StudyQuestionKind.shortAnswer);
      expect(next.items.single.stemPreview, 'Synthetic legacy gamma');
      expect(next.items.single.hasExplanation, isTrue);
      expect(next.items.single.due, isFalse);
      expect(next.nextCursor, isNull);
    });

    test('LIKE wildcards in the query match literally', () async {
      final service = _service();
      final exact = await service.searchQuestions(
        bankName: bankMath,
        query: '100%_done',
      );
      expect(exact.items.map((item) => item.questionId).toList(),
          <String>['legacy_q7']);

      final wildcard = await service.searchQuestions(
        bankName: bankMath,
        query: '%',
      );
      expect(wildcard.items.map((item) => item.questionId).toList(),
          <String>['legacy_q7']);

      final none = await service.searchQuestions(
        bankName: bankMath,
        query: '100X_done',
      );
      expect(none.items, isEmpty);
      expect(none.nextCursor, isNull);
    });

    test('unknown bank returns an empty page', () async {
      final page = await _service().searchQuestions(
        bankName: 'NoSuchBank',
        query: 'Synthetic',
      );
      expect(page.items, isEmpty);
      expect(page.nextCursor, isNull);
    });

    test('argument validation', () async {
      final service = _service();
      Future<void> expectInvalid(Future<Object?> Function() action) async {
        await expectLater(
          action(),
          throwsA(
            isA<StudyQueryException>().having(
              (error) => error.failure,
              'failure',
              StudyQueryFailure.invalidRequest,
            ),
          ),
        );
      }

      await expectInvalid(
          () => service.searchQuestions(bankName: '  ', query: 'x'));
      await expectInvalid(
          () => service.searchQuestions(bankName: bankMath, query: ''));
      await expectInvalid(
          () => service.searchQuestions(bankName: bankMath, query: '  '));
      await expectInvalid(
          () => service.searchQuestions(bankName: bankMath, query: 'x' * 201));
      await expectInvalid(() =>
          service.searchQuestions(bankName: bankMath, query: 'x', limit: 0));
      await expectInvalid(() =>
          service.searchQuestions(bankName: bankMath, query: 'x', limit: 51));
    });
  });

  group('E/F question detail', () {
    test('typed detail projects safe nodes and raw fallback to unsupported',
        () async {
      final detail = await _service().getQuestionDetail(idTyped1);

      expect(detail.questionId, idTyped1);
      expect(detail.bankName, bankMath);
      expect(detail.kind, StudyQuestionKind.singleChoice);
      expect(detail.sourceKind, StudySourceKind.typed);
      expect(detail.due, isTrue);
      expect(
        detail.stem.map((node) => node.runtimeType).toList(),
        <Type>[
          StudyTextNode,
          StudyInlineMathNode,
          StudyUnsupportedNode,
        ],
      );
      expect((detail.stem[0] as StudyTextNode).text, 'Solve ');
      expect((detail.stem[1] as StudyInlineMathNode).latex, r'x^2=1');

      expect(detail.options, hasLength(2));
      expect(detail.options[0].label, 'A');
      expect((detail.options[0].content.single as StudyTextNode).text, 'one');
      expect(detail.options[1].label, 'B');

      expect(detail.answer, hasLength(1));
      expect((detail.answer!.single as StudyTextNode).text, 'A');
      expect(detail.explanation, hasLength(1));
      expect(
        (detail.explanation!.single as StudyTextNode).text,
        'Synthetic explanation alpha',
      );

      final leaked = <String>[
        ...detail.stem.whereType<StudyTextNode>().map((node) => node.text),
        ...detail.stem
            .whereType<StudyInlineMathNode>()
            .map((node) => node.latex),
        for (final option in detail.options)
          ...option.content.whereType<StudyTextNode>().map((node) => node.text),
      ].join('|');
      expect(leaked, isNot(contains('synthetic-raw')));
    });

    test('legacy detail is a safe text DTO', () async {
      final detail = await _service().getQuestionDetail('legacy_q3');

      expect(detail.questionId, 'legacy_q3');
      expect(detail.bankName, bankMath);
      expect(detail.kind, StudyQuestionKind.shortAnswer);
      expect(detail.sourceKind, StudySourceKind.legacy);
      expect(detail.due, isFalse);
      expect(detail.stem.single, isA<StudyTextNode>());
      expect(
          (detail.stem.single as StudyTextNode).text, 'Synthetic legacy gamma');
      expect(detail.options[0].label, 'A');
      expect((detail.options[0].content.single as StudyTextNode).text, 'one');
      expect((detail.answer!.single as StudyTextNode).text, 'Legacy answer');
      expect((detail.explanation!.single as StudyTextNode).text,
          'Legacy explanation.');
    });

    test('explicit typed empty never falls back to the V1 projection',
        () async {
      final db = await openTestDatabase();
      // Drift the V1 compatibility projection so it disagrees with the V2
      // sidecar authority.
      await db.update(
        'questions',
        <String, Object?>{'standard_answer': 'A|||V1 compat explanation'},
        where: 'id = ?',
        whereArgs: <Object?>[idTyped5],
      );

      final detail = await _service().getQuestionDetail(idTyped5);
      expect(detail.sourceKind, StudySourceKind.typed);
      expect(detail.answer, isNull);
      expect(detail.explanation, isNull);
      expect(
          (detail.stem.single as StudyTextNode).text, 'Synthetic stem epsilon');
    });

    test('corrupt sidecar maps to dataCorrupt with no V1 fallback', () async {
      final db = await openTestDatabase();
      await insertTypedQuestion(
        db,
        draft: makeDraft(
          'draft_corrupt',
          stem: textContent('Corrupt bank stem'),
          options: <QuestionOption>[optionA()],
          answer: ChoiceAnswer(optionIds: <String>['A']),
        ),
        storageId: idCorrupt,
        createdAt: 10,
        bankName: bankCorrupt,
      );
      await corruptSidecar(db, storageId: idCorrupt);

      StudyQueryException? caught;
      try {
        await _service().getQuestionDetail(idCorrupt);
      } on StudyQueryException catch (error) {
        caught = error;
      }
      expect(caught, isNotNull);
      expect(caught!.failure, StudyQueryFailure.dataCorrupt);
      expect(caught.retryable, isFalse);
      expect(caught.toString(), isNot(contains('oops')));
      expect(caught.toString(), isNot(contains('V1')));
    });

    test('missing question is notFound and empty id is invalidRequest',
        () async {
      final service = _service();
      await expectLater(
        service.getQuestionDetail('missing-question'),
        throwsA(
          isA<StudyQueryException>().having(
            (error) => error.failure,
            'failure',
            StudyQueryFailure.notFound,
          ),
        ),
      );
      await expectLater(
        service.getQuestionDetail('   '),
        throwsA(
          isA<StudyQueryException>().having(
            (error) => error.failure,
            'failure',
            StudyQueryFailure.invalidRequest,
          ),
        ),
      );
    });
  });

  group('G weak questions', () {
    test('metrics, ordering, bank scope, and keyset pagination', () async {
      final service = _service();
      final first = await service.getWeakQuestions(limit: 2);

      expect(first.items.map((item) => item.questionId).toList(),
          <String>[idTyped1, 'legacy_q4']);
      expect(first.nextCursor, isNotNull);

      final typed = first.items[0];
      expect(typed.bankName, bankMath);
      expect(typed.stemPreview, r'Solve x^2=1');
      expect(typed.stemPreview, isNot(contains('synthetic-raw')));
      expect(typed.lapseCount, 3);
      expect(typed.difficulty, 4.2);
      expect(typed.lastLapseAt, DateTime.utc(2026, 8, 3, 7));

      final legacy = first.items[1];
      expect(legacy.bankName, bankPhysics);
      expect(legacy.stemPreview, 'Physics legacy delta');
      expect(legacy.lapseCount, 1);
      expect(legacy.difficulty, 5.0);
      expect(legacy.lastLapseAt, DateTime.utc(2026, 8, 2, 9));

      final second = await service.getWeakQuestions(
        cursor: first.nextCursor,
        limit: 2,
      );
      expect(second.items.map((item) => item.questionId).toList(),
          <String>['legacy_q3']);
      expect(second.items.single.lapseCount, 2);
      expect(second.items.single.difficulty, 6.5);
      expect(second.nextCursor, isNull);

      final math = await service.getWeakQuestions(bankName: bankMath);
      expect(math.items.map((item) => item.questionId).toList(),
          <String>[idTyped1, 'legacy_q3']);
    });
  });

  group('I READ_ONLY proof', () {
    test('six queries leave the core tables byte-identical', () async {
      final db = await openTestDatabase();
      final before = await snapshotCoreTables(db);
      final service = _service();

      await service.listQuestionBanks();
      await service.getStudyOverview(timezone: 'Asia/Shanghai');
      await service.getDueReviewSummary(
        timezone: 'Asia/Shanghai',
        from: DateTime.utc(2026, 8, 8),
        to: DateTime.utc(2026, 8, 10),
      );
      await service.searchQuestions(bankName: bankMath, query: 'Synthetic');
      await service.getQuestionDetail(idTyped1);
      await service.getWeakQuestions();

      final after = await snapshotCoreTables(db);
      expect(after, before);
    });
  });

  group('J safe internal error mapping', () {
    test('temporary database failures map to temporarilyUnavailable', () async {
      final db = await openTestDatabase();
      await db.execute('DROP TABLE review_states');
      final service = _service();

      StudyQueryException? caught;
      try {
        await service.getStudyOverview(timezone: 'UTC');
      } on StudyQueryException catch (error) {
        caught = error;
      }
      expect(caught, isNotNull);
      expect(caught!.failure, StudyQueryFailure.temporarilyUnavailable);
      expect(caught.retryable, isTrue);
      expect(caught.toString(), isNot(contains('review_states')));
      expect(caught.toString(), isNot(contains('DROP')));
    });

    test('unclassified failures map to internalError without leaks', () async {
      final service = StudyQueryService(
        questionQuery: _BoomQuestionPort(),
        metricsQuery: _BoomMetricsPort(),
        clock: _FixedClock(fixedNow),
      );

      StudyQueryException? caught;
      try {
        await service.getQuestionDetail('anything');
      } on StudyQueryException catch (error) {
        caught = error;
      }
      expect(caught, isNotNull);
      expect(caught!.failure, StudyQueryFailure.internalError);
      expect(caught.toString(), isNot(contains('boom')));
    });
  });
}

final class _BoomQuestionPort implements StudyQuestionQueryPort {
  Never _boom() => throw StateError('boom');

  @override
  Future<StudyPage<QuestionBankSummary>> listStudyQuestionBanks({
    required int nowUnixSeconds,
    required int limit,
    String? afterBankName,
  }) async =>
      _boom();

  @override
  Future<StudyPage<StudyQuestionRead>> searchStudyQuestions({
    required String bankName,
    required String query,
    required int nowUnixSeconds,
    required int limit,
    int? afterCreatedAt,
    String? afterId,
  }) async =>
      _boom();

  @override
  Future<StudyQuestionRead?> getStudyQuestionDetail(
    String questionId, {
    required int nowUnixSeconds,
  }) async =>
      _boom();

  @override
  Future<StudyPage<StudyQuestionRead>> listStudyWeakQuestions({
    required int nowUnixSeconds,
    required int limit,
    String? bankName,
    int? afterLastLapseTime,
    String? afterId,
  }) async =>
      _boom();
}

final class _BoomMetricsPort implements StudyMetricsQueryPort {
  Never _boom() => throw StateError('boom');

  @override
  Future<StudyOverviewCounts> getStudyOverviewCounts({
    String? bankName,
    required int nowUnixSeconds,
    required int todayStartUnixSeconds,
  }) async =>
      _boom();

  @override
  Future<List<int>> getStudyScheduledReviewTimestamps({
    String? bankName,
    required int fromUnixSeconds,
    required int toUnixSeconds,
  }) async =>
      _boom();

  @override
  Future<int> countStudyDueNow({
    String? bankName,
    required int nowUnixSeconds,
  }) async =>
      _boom();
}
