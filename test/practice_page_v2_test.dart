// R8A PracticePage V2-first acceptance. All evidence is synthetic/offline:
// sqflite FFI databases, no real OCR, Provider, Replay, network, or private
// documents.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/review_engine_service.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/review_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/services/study_plan/study_plan_practice_session_launcher.dart';
import 'package:shiroha_quiz/ui/models/practice_question_view.dart';
import 'package:shiroha_quiz/ui/pages/practice_page.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _mapper = QuestionV2PersistenceMapper();
const _bankName = 'synthetic_practice_bank';
const _globalWrongBookBankName = '🔥 全局错题本';
const _typedStorageIdA = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a01';
const _typedStorageIdB = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a02';
const _typedStorageIdC = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a03';

RichContent _text(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

Map<String, Object?> _newReviewState(
  String questionId, {
  int state = 0,
  int nextReviewTime = 0,
  int lapses = 0,
}) {
  return <String, Object?>{
    'question_id': questionId,
    'state': state,
    'difficulty': 5.0,
    'stability': 0.0,
    'last_review_time': 0,
    'next_review_time': nextReviewTime,
    'reps': 0,
    'lapses': lapses,
    'last_lapse_time': 0,
  };
}

Future<Database> _db() => DatabaseHelper.instance.database;

QuestionDraftV2 _choiceDraft({
  String stem = 'Typed stem marker.',
  QuestionKind kind = QuestionKind.singleChoice,
  List<QuestionOption>? options,
  QuestionAnswer? answer,
  RichContent? explanation,
}) {
  return QuestionDraftV2(
    questionId: 'draft_q_${DateTime.now().microsecondsSinceEpoch}',
    kind: kind,
    stem: _text(stem),
    options: options ??
        <QuestionOption>[
          QuestionOption(
            optionId: 'opt_a',
            label: 'A',
            content: _text('first'),
          ),
          QuestionOption(
            optionId: 'opt_b',
            label: 'B',
            content: _text('second'),
          ),
        ],
    answer: answer ?? ChoiceAnswer(optionIds: <String>['opt_a']),
    explanation: explanation,
  );
}

Future<void> _insertTyped(
  Database db,
  QuestionDraftV2 draft, {
  required String storageId,
  String bank = _bankName,
  int createdAt = 1,
}) async {
  final frozen = _mapper.freezeForWrite(
    storageId: storageId,
    bankName: bank,
    createdAt: createdAt,
    draft: draft,
  );
  await db.insert('questions', frozen.questionRow);
  await db.insert('question_v2_payloads', frozen.payloadRow);
}

Future<void> _insertLegacy(
  Database db, {
  required String id,
  String bank = _bankName,
  int type = 0,
  String content = 'Legacy stem.',
  String options = '["A. first", "B. second"]',
  String answer = 'A',
  String? explanation,
  String? rawExplanation,
  int createdAt = 1,
}) async {
  await db.insert('questions', <String, Object?>{
    'id': id,
    'type': type,
    'content': content,
    'options': options,
    'standard_answer': '$answer|||${explanation ?? ''}',
    'created_at': createdAt,
    'bank_name': bank,
    'explanation': explanation,
    'raw_explanation': rawExplanation,
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.deleteDatabaseFile();
    await DatabaseHelper.instance.database;
  });

  group('Practice session read (union)', () {
    test('returns typed and legacy rows through the union', () async {
      final db = await _db();
      await _insertTyped(db, _choiceDraft(), storageId: _typedStorageIdA);
      await _insertLegacy(db, id: 'legacy_1');
      await db.insert('review_states', _newReviewState(_typedStorageIdA));
      await db.insert('review_states', _newReviewState('legacy_1'));

      final rows = await ReviewRepository.instance
          .getPersistedStudySessionQuestions(_bankName, 9999999999);

      expect(rows, hasLength(2));
      final typed = rows.whereType<TypedPersistedQuestion>().single;
      expect(
        (typed.draft.stem.nodes.single as TextNode).text,
        'Typed stem marker.',
      );
      expect(typed.draft.answer, isA<ChoiceAnswer>());
      final legacy = rows.whereType<LegacyPersistedQuestion>().single;
      expect(legacy.question.content, 'Legacy stem.');
      expect(rows.map((row) => row.reviewMetrics), everyElement(isNull));
    });

    test('type filter 0 keeps legacy types 0 and 1 and drops others', () async {
      final db = await _db();
      await _insertLegacy(db, id: 'l0', type: 0);
      await _insertLegacy(db, id: 'l1', type: 1);
      await _insertLegacy(db, id: 'l2', type: 2);
      for (final id in <String>['l0', 'l1', 'l2']) {
        await db.insert('review_states', _newReviewState(id));
      }

      final rows = await ReviewRepository.instance
          .getPersistedStudySessionQuestions(_bankName, 9999999999, type: 0);

      expect(
        rows.map((row) => row.storageId).toSet(),
        <String>{'l0', 'l1'},
      );
    });

    test('exact type filter and limit stay in SQL', () async {
      final db = await _db();
      for (final id in <String>['s1', 's2', 's3']) {
        await _insertLegacy(db, id: id, type: 3);
        await db.insert(
          'review_states',
          _newReviewState(id, nextReviewTime: id == 's3' ? 999999999 : 0),
        );
      }

      final rows = await ReviewRepository.instance
          .getPersistedStudySessionQuestions(_bankName, 9999999999,
              type: 3, limit: 2);

      expect(rows, hasLength(2));
      expect(rows.map((row) => row.storageId), everyElement(isNot('s3')));
    });

    test('keeps state DESC then next_review_time ASC ordering', () async {
      final db = await _db();
      await _insertLegacy(db, id: 'l_new');
      await _insertLegacy(db, id: 'l_soon');
      await _insertLegacy(db, id: 'l_due');
      await db.insert('review_states', _newReviewState('l_new', state: 0));
      await db.insert('review_states',
          _newReviewState('l_soon', state: 2, nextReviewTime: 50));
      await db.insert('review_states',
          _newReviewState('l_due', state: 2, nextReviewTime: 100));

      final rows = await ReviewRepository.instance
          .getPersistedStudySessionQuestions(_bankName, 200);

      expect(
        rows.map((row) => row.storageId).toList(),
        <String>['l_soon', 'l_due', 'l_new'],
      );
    });

    test('wrong-book branch keeps lapses > 0 due semantics', () async {
      final db = await _db();
      await _insertLegacy(db,
          id: 'wb_a', bank: _globalWrongBookBankName, answer: 'A');
      await _insertLegacy(db,
          id: 'wb_b', bank: _globalWrongBookBankName, answer: 'B');
      await _insertLegacy(db,
          id: 'wb_later', bank: _globalWrongBookBankName, answer: 'C');
      await _insertLegacy(db,
          id: 'wb_no_lapse', bank: _globalWrongBookBankName, answer: 'D');
      await db.insert('review_states',
          _newReviewState('wb_a', state: 2, nextReviewTime: 100, lapses: 2));
      await db.insert('review_states',
          _newReviewState('wb_b', state: 2, nextReviewTime: 50, lapses: 1));
      await db.insert(
          'review_states',
          _newReviewState('wb_later',
              state: 2, nextReviewTime: 500, lapses: 1));
      await db.insert(
          'review_states',
          _newReviewState('wb_no_lapse',
              state: 2, nextReviewTime: 50, lapses: 0));

      final rows = await ReviewRepository.instance
          .getPersistedStudySessionQuestions(_globalWrongBookBankName, 200);

      expect(
        rows.map((row) => row.storageId).toList(),
        <String>['wb_b', 'wb_a'],
      );
    });

    test('corrupt sidecar fails the whole session read without fallback',
        () async {
      final db = await _db();
      await _insertTyped(db, _choiceDraft(), storageId: _typedStorageIdC);
      await _insertLegacy(db, id: 'legacy_ok');
      await db.insert('review_states', _newReviewState(_typedStorageIdC));
      await db.insert('review_states', _newReviewState('legacy_ok'));
      await db.update(
        'question_v2_payloads',
        <String, Object?>{'payload_json': '{not json'},
        where: 'question_id = ?',
        whereArgs: <Object?>[_typedStorageIdC],
      );

      expect(
        ReviewRepository.instance
            .getPersistedStudySessionQuestions(_bankName, 9999999999),
        throwsA(isA<QuestionV2PayloadException>()),
      );
    });
  });

  group('ReviewEngineService prepared session seam', () {
    LegacyPersistedQuestion legacyQuestion(String id, String content) {
      return LegacyPersistedQuestion(
        question: Question(
          id: id,
          type: 0,
          content: content,
          options: '["A. first", "B. second"]',
          answer: 'A',
          createdAt: 1,
          bankName: _bankName,
          explanation: '',
          rawExplanation: null,
        ),
      );
    }

    test('initPreparedStudySession replaces the queue in exact order', () {
      final engine = ReviewEngineService();
      final q1 = legacyQuestion('q1', 'one');
      final q2 = legacyQuestion('q2', 'two');
      final q3 = legacyQuestion('q3', 'three');

      engine.initPreparedStudySession(<PersistedQuestion>[q1, q2, q3]);
      expect(engine.popNextQuestion(), same(q1));
      expect(engine.popNextQuestion(), same(q2));
      expect(engine.popNextQuestion(), same(q3));
      expect(engine.popNextQuestion(), isNull);
    });

    test(
        'requeueQuestion keeps existing queue semantics after a prepared '
        'session', () {
      final engine = ReviewEngineService();
      final q1 = legacyQuestion('q1', 'one');
      final q2 = legacyQuestion('q2', 'two');

      engine.initPreparedStudySession(<PersistedQuestion>[q1, q2]);
      final first = engine.popNextQuestion();
      engine.requeueQuestion(first!);
      // O(1) 错题回炉: requeued question lands at the tail.
      expect(engine.popNextQuestion(), same(q2));
      expect(engine.popNextQuestion(), same(q1));
      expect(engine.popNextQuestion(), isNull);
    });
  });

  group('StudyPlan selected-ID materialization (union)', () {
    test('exact selected order preserved across mixed typed + legacy',
        () async {
      final db = await _db();
      await _insertLegacy(db, id: 'legacy_1', content: 'Legacy first.');
      await _insertTyped(db, _choiceDraft(stem: 'Typed second.'),
          storageId: _typedStorageIdA);
      await _insertLegacy(db, id: 'legacy_3', content: 'Legacy third.');

      final result =
          await ReviewRepository.instance.materializeStudyPlanSession(<String>[
        _typedStorageIdA,
        'legacy_3',
        'legacy_1',
      ]);

      expect(result, isA<StudyPlanSessionMaterializationSuccess>());
      final questions =
          (result as StudyPlanSessionMaterializationSuccess).questions;
      expect(questions.map((q) => q.storageId).toList(),
          <String>[_typedStorageIdA, 'legacy_3', 'legacy_1']);
      expect(questions[0], isA<TypedPersistedQuestion>());
      expect(
        ((questions[0] as TypedPersistedQuestion).draft.stem.nodes.single
                as TextNode)
            .text,
        'Typed second.',
      );
      expect(questions[1], isA<LegacyPersistedQuestion>());
      expect((questions[1] as LegacyPersistedQuestion).question.content,
          'Legacy third.');
      expect(questions[2], isA<LegacyPersistedQuestion>());
    });

    test('typed V2 question materializes through the typed authority',
        () async {
      final db = await _db();
      await _insertTyped(
        db,
        _choiceDraft(
          stem: 'Typed materialization marker.',
          answer: ChoiceAnswer(optionIds: <String>['opt_b']),
        ),
        storageId: _typedStorageIdB,
      );

      final result = await ReviewRepository.instance
          .materializeStudyPlanSession(<String>[_typedStorageIdB]);

      final questions =
          (result as StudyPlanSessionMaterializationSuccess).questions;
      final typed = questions.single as TypedPersistedQuestion;
      expect(typed.storageId, _typedStorageIdB);
      expect(
        (typed.draft.stem.nodes.single as TextNode).text,
        'Typed materialization marker.',
      );
      expect(typed.draft.answer, isA<ChoiceAnswer>());
    });

    test('missing selected ID fails boundedly with zero partial result',
        () async {
      final db = await _db();
      await _insertLegacy(db, id: 'present');

      final result = await ReviewRepository.instance
          .materializeStudyPlanSession(<String>['present', 'missing_id']);

      expect(result, isA<StudyPlanSessionMaterializationUnavailable>());
    });

    test('corrupt V2 sidecar fails boundedly without V1 fallback', () async {
      final db = await _db();
      await _insertTyped(db, _choiceDraft(), storageId: _typedStorageIdC);
      await db.update(
        'question_v2_payloads',
        <String, Object?>{'payload_json': '{not json'},
        where: 'question_id = ?',
        whereArgs: <Object?>[_typedStorageIdC],
      );

      final result = await ReviewRepository.instance
          .materializeStudyPlanSession(<String>[_typedStorageIdC]);

      expect(result, isA<StudyPlanSessionMaterializationUnavailable>());
    });

    test('empty / oversized / duplicate inputs fail boundedly', () async {
      final db = await _db();
      await _insertLegacy(db, id: 'present');

      expect(
        await ReviewRepository.instance.materializeStudyPlanSession(
          const <String>[],
        ),
        isA<StudyPlanSessionMaterializationUnavailable>(),
      );
      expect(
        await ReviewRepository.instance.materializeStudyPlanSession(
          <String>['present', 'present'],
        ),
        isA<StudyPlanSessionMaterializationUnavailable>(),
      );
      expect(
        await ReviewRepository.instance.materializeStudyPlanSession(
          List<String>.filled(201, 'present'),
        ),
        isA<StudyPlanSessionMaterializationUnavailable>(),
      );
    });
  });

  group('StudyPlan practice session launcher', () {
    test('launch materializes exact order and injects the engine queue',
        () async {
      final db = await _db();
      await _insertLegacy(db, id: 'l_a', content: 'A stem.');
      await _insertLegacy(db, id: 'l_b', content: 'B stem.');
      await _insertLegacy(db, id: 'l_c', content: 'C stem.');

      final launcher = StudyPlanPracticeSessionLauncher();
      final result = await launcher.launch(<String>['l_c', 'l_a', 'l_b']);

      expect(result, isA<StudyPlanPracticeLaunchSuccess>());
      expect((result as StudyPlanPracticeLaunchSuccess).questionCount, 3);

      final engine = ReviewEngineService();
      expect(engine.popNextQuestion()!.storageId, 'l_c');
      expect(engine.popNextQuestion()!.storageId, 'l_a');
      expect(engine.popNextQuestion()!.storageId, 'l_b');
      expect(engine.popNextQuestion(), isNull);
    });

    test('bounded failure leaves the current engine queue untouched', () async {
      final db = await _db();
      await _insertLegacy(db, id: 'l_a', content: 'A stem.');
      await _insertLegacy(db, id: 'l_b', content: 'B stem.');

      final launcher = StudyPlanPracticeSessionLauncher();
      await launcher.launch(<String>['l_a', 'l_b']);
      final engine = ReviewEngineService();
      expect(engine.popNextQuestion()!.storageId, 'l_a');

      final failed = await launcher.launch(<String>['l_a', 'missing']);
      expect(failed, isA<StudyPlanPracticeLaunchFailed>());

      // Zero partial prepared queue: the queue still holds exactly the
      // remaining question from the previous session ('l_b').
      expect(engine.popNextQuestion()!.storageId, 'l_b');
      expect(engine.popNextQuestion(), isNull);
    });
  });

  group('PracticeQuestionView projection', () {
    test('typed options and answers map structurally', () {
      final view = PracticeQuestionViewAdapter.fromPersisted(
        TypedPersistedQuestion(
          storageId: _typedStorageIdA,
          bankName: _bankName,
          createdAt: 1,
          draft: _choiceDraft(
            answer: ChoiceAnswer(optionIds: <String>['opt_b']),
            explanation: _text('Typed explanation marker.'),
          ),
        ),
      );

      expect(view.isTyped, isTrue);
      expect(
        view.displayOptions.map((option) => option.optionId).toList(),
        <String>['opt_a', 'opt_b'],
      );
      expect(view.answerOptionIds, <String>['opt_b']);
      expect(view.typedAnswer, isNotNull);
      expect(view.legacyQuestion, isNull);
      expect(view.stemText, 'Typed stem marker.');
      expect(view.answerText, 'B');
      expect(view.isPreview, isFalse);
    });

    test('typed explicit empty answer and explanation stay empty', () {
      final view = PracticeQuestionViewAdapter.fromPersisted(
        TypedPersistedQuestion(
          storageId: _typedStorageIdB,
          bankName: _bankName,
          createdAt: 1,
          draft: QuestionDraftV2(
            questionId: 'q_empty',
            kind: QuestionKind.shortAnswer,
            stem: RichContent(nodes: const <ContentNode>[]),
          ),
        ),
      );

      expect(view.typedStem!.nodes, isEmpty);
      expect(view.typedAnswer, isNull);
      expect(view.contentAnswer, isNull);
      expect(view.answerText, '');
      expect(view.typedExplanation, isNull);
      expect(view.displayOptions, isEmpty);
    });

    test('legacy rows keep legacy fields and parsing semantics', () {
      final legacy = LegacyPersistedQuestion(
        question: Question(
          id: 'legacy_1',
          type: 3,
          content: 'Legacy stem.',
          options: '["A. first", "B. second"]',
          answer: 'A',
          createdAt: 1,
          bankName: _bankName,
          explanation: 'Legacy explanation.',
          rawExplanation: 'Raw legacy explanation.',
        ),
      );
      final view = PracticeQuestionViewAdapter.fromPersisted(legacy);

      expect(view.isTyped, isFalse);
      expect(view.legacyStem, 'Legacy stem.');
      expect(view.legacyAnswer, 'A');
      expect(view.legacyRawExplanation, 'Raw legacy explanation.');
      expect(view.legacyExplanation, 'Legacy explanation.');
      expect(view.answerOptionIds, isEmpty);
      expect(
        view.displayOptions.map((option) => option.legacyRaw).toList(),
        <String>['A. first', 'B. second'],
      );
      expect(view.interactionQuestion, same(legacy.question));
      expect(view.isPreview, isFalse);
    });
  });

  group('PracticePage widget', () {
    Future<void> pumpUntilLoaded(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(home: PracticePage(bankName: _bankName)),
      );
      for (var frame = 0; frame < 60; frame++) {
        await tester.pump();
        if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump();
          return;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
      }
      fail('PracticePage did not finish loading.');
    }

    Future<void> settle(WidgetTester tester) async {
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
    }

    testWidgets('typed row renders sidecar content; V1 decoy never renders',
        (tester) async {
      await tester.runAsync(() async {
        final db = await _db();
        await _insertTyped(db, _choiceDraft(), storageId: _typedStorageIdA);
        await db.insert('review_states', _newReviewState(_typedStorageIdA));
        // Simulate a manually corrupted compatibility row (decoy).
        await db.update(
          'questions',
          <String, Object?>{
            'content': 'V1_DECOY_STEM',
            'options': '["V1_DECOY_OPTION"]',
            'standard_answer': 'Z|||V1_DECOY_ANSWER',
          },
          where: 'id = ?',
          whereArgs: <Object?>[_typedStorageIdA],
        );
      });

      await pumpUntilLoaded(tester);

      expect(find.text('Typed stem marker.'), findsOneWidget);
      expect(find.text('first'), findsOneWidget);
      expect(find.textContaining('V1_DECOY'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'Question delete confirmation preserves history and source file',
        (tester) async {
      await tester.runAsync(() async {
        final db = await _db();
        await _insertLegacy(db, id: 'practice_delete_question');
        await db.insert(
          'review_states',
          _newReviewState('practice_delete_question'),
        );
      });

      await pumpUntilLoaded(tester);
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('历史作答记录会保留'),
        findsOneWidget,
      );
      expect(find.textContaining('来源文件不会被删除'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      final questions = await tester.runAsync(
        () => _db().then(
          (db) => db.query(
            'questions',
            where: 'id = ?',
            whereArgs: <Object?>['practice_delete_question'],
          ),
        ),
      );
      expect(questions, hasLength(1));
      expect(find.text('确认删除'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'typed explicit empty stem/answer/explanation never falls back to '
        'V1 placeholders', (tester) async {
      await tester.runAsync(() async {
        final db = await _db();
        await _insertTyped(
          db,
          QuestionDraftV2(
            questionId: 'q_empty',
            kind: QuestionKind.shortAnswer,
            stem: RichContent(nodes: const <ContentNode>[]),
          ),
          storageId: _typedStorageIdB,
        );
        await db.insert('review_states', _newReviewState(_typedStorageIdB));
        await db.update(
          'questions',
          <String, Object?>{
            'content': '无题干',
            'standard_answer': 'Z|||V1 decoy answer',
          },
          where: 'id = ?',
          whereArgs: <Object?>[_typedStorageIdB],
        );
      });

      await pumpUntilLoaded(tester);
      expect(find.text('无题干'), findsNothing);
      expect(find.textContaining('V1 decoy answer'), findsNothing);

      await tester.tap(find.text('跳过 AI，直接看答案自评'));
      await settle(tester);

      expect(find.text('无'), findsOneWidget);
      expect(find.text('无解析'), findsOneWidget);
      expect(find.textContaining('V1 decoy'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'mixed bank: typed renders through RichContent, legacy through the '
        'legacy renderer', (tester) async {
      await tester.runAsync(() async {
        final db = await _db();
        await _insertTyped(db, _choiceDraft(), storageId: _typedStorageIdA);
        await _insertLegacy(db, id: 'legacy_1');
        await db.insert(
          'review_states',
          _newReviewState(_typedStorageIdA, state: 2, nextReviewTime: 50),
        );
        await db.insert(
          'review_states',
          _newReviewState('legacy_1', state: 2, nextReviewTime: 100),
        );
      });

      await pumpUntilLoaded(tester);

      // First question is the typed row: the RichContent path is active and
      // the legacy renderer is not used for it.
      expect(find.byType(RichContentRenderer), findsWidgets);
      expect(find.byType(StructuredContentRenderer), findsNothing);
      expect(find.text('Typed stem marker.'), findsOneWidget);

      await tester.tap(find.text('first'));
      await tester.tap(find.text('查看答案'));
      await settle(tester);
      await tester.tap(find.text('极易'));
      await settle(tester);

      // Second question is the legacy row: the legacy render path is active.
      expect(find.byType(StructuredContentRenderer), findsWidgets);
      expect(find.byType(RichContentRenderer), findsNothing);
      expect(find.text('Legacy stem.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'legacy row: choice select, reveal and FSRS grade keep writing '
        'review state', (tester) async {
      await tester.runAsync(() async {
        final db = await _db();
        await _insertLegacy(db, id: 'legacy_1');
        await db.insert('review_states', _newReviewState('legacy_1'));
      });

      await pumpUntilLoaded(tester);
      await tester.tap(find.text('first'));
      await tester.tap(find.text('查看答案'));
      await settle(tester);
      await tester.tap(find.text('极易'));
      await settle(tester);

      expect(find.text('🎉 任务完成'), findsOneWidget);
      final logs = (await tester.runAsync(() async {
        return (await _db()).query('review_logs');
      }))!;
      expect(logs, hasLength(1));
      expect(logs.single['question_id'], 'legacy_1');
      expect(logs.single['grade'], 4);
      final states = (await tester.runAsync(() async {
        return (await _db()).query(
          'review_states',
          where: 'question_id = ?',
          whereArgs: <Object?>['legacy_1'],
        );
      }))!;
      expect(states.single['reps'], 1);
      expect(states.single['state'], 2);
    });

    testWidgets(
        'typed row: optionId selection, structural reveal, FSRS write and '
        'no preview-save surface', (tester) async {
      await tester.runAsync(() async {
        final db = await _db();
        await _insertTyped(
          db,
          _choiceDraft(
            answer: ChoiceAnswer(optionIds: <String>['opt_b']),
            explanation: _text('Typed explanation marker.'),
          ),
          storageId: _typedStorageIdA,
        );
        await db.insert('review_states', _newReviewState(_typedStorageIdA));
      });

      await pumpUntilLoaded(tester);
      expect(find.text('收入题库'), findsNothing);

      await tester.tap(find.text('second'));
      await tester.tap(find.text('查看答案'));
      await settle(tester);

      // Structural answer reveal: option labels, never a V1 letter re-parse.
      expect(find.text('B'), findsWidgets);
      expect(find.text('Typed explanation marker.'), findsOneWidget);
      expect(find.text('收入题库'), findsNothing);

      await tester.tap(find.text('极易'));
      await settle(tester);

      final logs = (await tester.runAsync(() async {
        return (await _db()).query('review_logs');
      }))!;
      expect(logs, hasLength(1));
      expect(logs.single['question_id'], _typedStorageIdA);
      expect(logs.single['grade'], 4);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'SPL-1 特训 prepared session: exact order, normal FSRS mutation and '
        'requeue — NOT preview mode', (tester) async {
      await tester.runAsync(() async {
        final db = await _db();
        await _insertLegacy(
          db,
          id: 'b_legacy',
          content: 'Legacy B stem.',
          options: '["A. b-one", "B. b-two"]',
          answer: 'A',
        );
        await _insertLegacy(
          db,
          id: 'a_legacy',
          content: 'Legacy A stem.',
          options: '["A. a-one", "B. a-two"]',
          answer: 'A',
        );
        await db.insert('review_states', _newReviewState('b_legacy'));
        await db.insert('review_states', _newReviewState('a_legacy'));
        final launcher = StudyPlanPracticeSessionLauncher();
        final launch = await launcher.launch(<String>['b_legacy', 'a_legacy']);
        expect(launch, isA<StudyPlanPracticeLaunchSuccess>());
      });

      await tester.pumpWidget(
        MaterialApp(
          home: PracticePage(
            bankName: _bankName,
            usePreparedStudySession: true,
          ),
        ),
      );
      for (var frame = 0; frame < 60; frame++) {
        await tester.pump();
        if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump();
          break;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
      }

      // Exact selected order: B first, not repository order.
      expect(find.text('Legacy B stem.'), findsOneWidget);

      // Normal non-preview grade on B: FSRS/review log mutation runs.
      await tester.tap(find.text('b-one'));
      await tester.tap(find.text('查看答案'));
      await settle(tester);
      await tester.tap(find.text('极易'));
      await settle(tester);

      expect(find.text('Legacy A stem.'), findsOneWidget);

      // grade=1 requeues A through the existing queue semantics: A must come
      // back after being answered with 重来.
      await tester.tap(find.text('a-one'));
      await tester.tap(find.text('查看答案'));
      await settle(tester);
      await tester.tap(find.text('重来'));
      await settle(tester);
      expect(find.text('Legacy A stem.'), findsOneWidget);

      await tester.tap(find.text('a-one'));
      await tester.tap(find.text('查看答案'));
      await settle(tester);
      await tester.tap(find.text('极易'));
      await settle(tester);

      expect(find.text('🎉 任务完成'), findsOneWidget);

      final logs = (await tester.runAsync(() async {
        return (await _db()).query(
          'review_logs',
          orderBy: 'review_time ASC',
        );
      }))!;
      expect(logs, hasLength(3));
      expect(logs[0]['question_id'], 'b_legacy');
      expect(logs[0]['grade'], 4);
      expect(logs[1]['question_id'], 'a_legacy');
      expect(logs[1]['grade'], 1);
      expect(logs[2]['question_id'], 'a_legacy');
      expect(logs[2]['grade'], 4);
      expect(tester.takeException(), isNull);
    });
  });
}
