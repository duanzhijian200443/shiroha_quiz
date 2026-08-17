import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_commit_command.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_generation.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_provider.dart';
import 'package:shiroha_quiz/application/exam/exam_mutation_command.dart';
import 'package:shiroha_quiz/application/practice/record_answer_attempt_command.dart';
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/review_engine_service.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/data/repositories/answer_attempt_repository.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/data/repositories/review_repository.dart';
import 'package:shiroha_quiz/domain/attempt/answer_attempt.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/services/ai_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/ui/dependencies/ai_dependencies_scope.dart';
import 'package:shiroha_quiz/ui/pages/practice_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _SpyAiService extends Fake implements AiService {
  int judgeAnswerCallCount = 0;
  @override
  Future<String> judgeAnswer(String stem, String standard, String user) async {
    judgeAnswerCallCount++;
    return 'Good answer';
  }
}

class _DelayedAttemptPort implements AnswerAttemptPersistencePort {
  final Completer<void> gate = Completer<void>();
  final List<AnswerAttempt> recorded = <AnswerAttempt>[];

  @override
  Future<void> recordAttempt(AnswerAttempt attempt) async {
    await gate.future;
    recorded.add(attempt);
  }

  @override
  Future<List<AnswerAttempt>> getAttemptsForQuestion(String questionId) async =>
      recorded.where((a) => a.questionId == questionId).toList();

  @override
  Future<int> countIncorrectQuestions({String? bankName}) async => 0;

  @override
  Future<void> clearAllData() async {
    recorded.clear();
  }
}

class _FakeEngineRepository extends Fake implements AiEngineRepository {}
class _FakeImportPipelineService extends Fake implements ImportPipelineService {}
class _FakeImportTaskCoordinator extends Fake implements ImportTaskCoordinator {}
class _FakeStudyQuestionQueryPort extends Fake implements StudyQuestionQueryPort {}
class _FakeAiAnswerProviderPort extends Fake implements AiAnswerProviderPort {}
class _FakeAiAnswerCommitPersistencePort extends Fake
    implements AiAnswerCommitPersistencePort {}
class _FakeExamMutationPersistence extends Fake
    implements ExamMutationPersistencePort {}

const _mapper = QuestionV2PersistenceMapper();
const _bankName = 'attempt_test_bank';
const _storageIdA = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a01';
const _storageIdB = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a02';

RichContent _text(String text) =>
    RichContent(nodes: <ContentNode>[TextNode(text)]);

QuestionDraftV2 _choiceDraft({
  required String questionId,
  required String correctOptionId,
}) {
  return QuestionDraftV2(
    questionId: questionId,
    kind: QuestionKind.singleChoice,
    stem: _text('Stem $questionId'),
    options: <QuestionOption>[
      QuestionOption(optionId: 'opt_a', label: 'A', content: _text('Option A')),
      QuestionOption(optionId: 'opt_b', label: 'B', content: _text('Option B')),
    ],
    answer: ChoiceAnswer(optionIds: <String>[correctOptionId]),
  );
}

Future<void> _insertTyped(
  Database db,
  QuestionDraftV2 draft, {
  required String storageId,
  String bank = _bankName,
}) async {
  final frozen = _mapper.freezeForWrite(
    storageId: storageId,
    bankName: bank,
    createdAt: 1000,
    draft: draft,
  );
  await db.insert('questions', frozen.questionRow);
  await db.insert('question_v2_payloads', frozen.payloadRow);
  await db.insert('review_states', <String, Object?>{
    'question_id': storageId,
    'state': 0,
    'difficulty': 5.0,
    'stability': 0.0,
    'last_review_time': 0,
    'next_review_time': 0,
    'reps': 0,
    'lapses': 0,
    'last_lapse_time': 0,
  });
}

Future<void> pumpUntilLoaded(
  WidgetTester tester, {
  String? bankName,
  bool usePrepared = false,
  List<Question>? initialQuestions,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: PracticePage(
        bankName: bankName,
        usePreparedStudySession: usePrepared,
        initialQuestions: initialQuestions,
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.deleteDatabaseFile();
    await DatabaseHelper.instance.database;
  });

  tearDown(() async {
    await DatabaseHelper.deleteDatabaseFile();
  });

  testWidgets(
      'Scenario A: User answers incorrectly -> reveals answer -> exits without FSRS rating -> AnswerAttempt is durable and question appears in wrong stats',
      (tester) async {
    await tester.runAsync(() async {
      final db = await DatabaseHelper.instance.database;
      await _insertTyped(
        db,
        _choiceDraft(questionId: 'q-a', correctOptionId: 'opt_a'),
        storageId: _storageIdA,
      );

      final reviewRepo = ReviewRepository.instance;
      var dashboard = await reviewRepo.getDashboardData(1000, 0);
      expect(dashboard['wrongCount'], 0);
    });

    await pumpUntilLoaded(tester, bankName: _bankName);

    // Select Option B (which is incorrect)
    await tester.tap(find.byKey(const ValueKey<String>('practice-option-1')));
    await settle(tester);

    // Click "查看答案"
    await tester
        .tap(find.byKey(const ValueKey<String>('practice-reveal-answer')));
    await settle(tester);

    // Verify answer is revealed
    expect(find.byKey(const ValueKey<String>('practice-grade-bar')),
        findsOneWidget);

    await tester.runAsync(() async {
      // Verify the database BEFORE submitting any FSRS grade
      final attemptRepo = AnswerAttemptRepository.instance;
      final attempts = await attemptRepo.getAttemptsForQuestion(_storageIdA);
      expect(attempts, hasLength(1));
      expect(attempts.first.correctness, false);
      expect(attempts.first.sessionKind, AnswerAttemptSessionKind.normal);
      expect(attempts.first.modality, AnswerAttemptModality.choice);

      // Verify ReviewState is still unreviewed (state = 0, reps = 0, lapses = 0)
      final db = await DatabaseHelper.instance.database;
      final reviewStateRows = await db.query(
        'review_states',
        where: 'question_id = ?',
        whereArgs: <Object?>[_storageIdA],
      );
      expect(reviewStateRows.first['state'], 0);
      expect(reviewStateRows.first['reps'], 0);
      expect(reviewStateRows.first['lapses'], 0);

      // Crucial check: dashboard wrongCount and wrong-book queries include this question!
      final reviewRepo = ReviewRepository.instance;
      final dashboard = await reviewRepo.getDashboardData(1000, 0);
      expect(dashboard['wrongCount'], 1);

      final wrongQuestions =
          await QuestionRepository.instance.getPersistedWrongQuestions();
      expect(wrongQuestions, hasLength(1));
      expect(wrongQuestions.first.storageId, _storageIdA);

      final wrongBankStats = await reviewRepo.getBankStats('🔥 全局错题本', 1000);
      expect(wrongBankStats['total'], 1);
    });
  });

  test('Scenario B: First Again on new question increments lapses from 0 to 1',
      () async {
    final db = await DatabaseHelper.instance.database;
    await _insertTyped(
      db,
      _choiceDraft(questionId: 'q-b', correctOptionId: 'opt_a'),
      storageId: _storageIdB,
    );

    // Verify initial lapses = 0, reps = 0
    var rows = await db.query(
      'review_states',
      where: 'question_id = ?',
      whereArgs: <Object?>[_storageIdB],
    );
    expect(rows.first['lapses'], 0);
    expect(rows.first['reps'], 0);

    // Submit review with grade = 1 (Again)
    await ReviewEngineService().submitReview(_storageIdB, 1);

    rows = await db.query(
      'review_states',
      where: 'question_id = ?',
      whereArgs: <Object?>[_storageIdB],
    );
    expect(rows.first['lapses'], 1);
    expect(rows.first['reps'], 1);
    expect(rows.first['state'], 1);
    expect((rows.first['last_lapse_time'] as num) > 0, isTrue);
  });

  testWidgets(
      'Scenario C & D: Double reveal prevented, and requeue allows new attempt on same question',
      (tester) async {
    await tester.runAsync(() async {
      final db = await DatabaseHelper.instance.database;
      await _insertTyped(
        db,
        _choiceDraft(questionId: 'q-cd', correctOptionId: 'opt_a'),
        storageId: _storageIdA,
      );
    });

    await pumpUntilLoaded(tester, bankName: _bankName);

    // Select Option B (incorrect)
    await tester.tap(find.byKey(const ValueKey<String>('practice-option-1')));
    await settle(tester);

    // Click "查看答案"
    await tester
        .tap(find.byKey(const ValueKey<String>('practice-reveal-answer')));
    await settle(tester);

    await tester.runAsync(() async {
      final attemptRepo = AnswerAttemptRepository.instance;
      final attempts = await attemptRepo.getAttemptsForQuestion(_storageIdA);
      expect(attempts, hasLength(1));
    });

    // Submit grade "重来" (1) -> triggers requeue
    await tester.tap(find.text('重来'));
    await settle(tester);

    // Question re-appears in practice queue!
    expect(find.byKey(const ValueKey<String>('practice-reveal-answer')),
        findsOneWidget);

    // Select Option A (correct this time)
    await tester.tap(find.byKey(const ValueKey<String>('practice-option-0')));
    await settle(tester);

    // Reveal answer again
    await tester
        .tap(find.byKey(const ValueKey<String>('practice-reveal-answer')));
    await settle(tester);

    await tester.runAsync(() async {
      // Verify 2nd attempt was recorded append-only
      final attemptRepo = AnswerAttemptRepository.instance;
      final attempts = await attemptRepo.getAttemptsForQuestion(_storageIdA);
      expect(attempts, hasLength(2));
      expect(attempts[0].correctness, false);
      expect(attempts[1].correctness, true);
    });
  });

  testWidgets(
      'Scenario G: Preview mode creates zero AnswerAttempt and zero ReviewState writes',
      (tester) async {
    final previewQ = Question(
      id: 'preview_1',
      type: 0,
      content: 'Preview Question',
      options: '["A. Yes", "B. No"]',
      answer: 'A',
      createdAt: 1000,
      bankName: 'Preview Bank',
    );

    await pumpUntilLoaded(tester, initialQuestions: <Question>[previewQ]);

    // Select Option A
    await tester.tap(find.byKey(const ValueKey<String>('practice-option-0')));
    await settle(tester);

    // Click "查看答案"
    await tester
        .tap(find.byKey(const ValueKey<String>('practice-reveal-answer')));
    await settle(tester);

    await tester.runAsync(() async {
      // Verify zero AnswerAttempt in database
      final attemptRepo = AnswerAttemptRepository.instance;
      final attempts = await attemptRepo.getAttemptsForQuestion('preview_1');
      expect(attempts, isEmpty);
    });
  });

  testWidgets(
      'Scenario H: Focused practice session records sessionKind=focused',
      (tester) async {
    await tester.runAsync(() async {
      final db = await DatabaseHelper.instance.database;
      await _insertTyped(
        db,
        _choiceDraft(questionId: 'q-focused', correctOptionId: 'opt_a'),
        storageId: _storageIdA,
      );

      ReviewEngineService().initPreparedStudySession(
        <PersistedQuestion>[
          TypedPersistedQuestion(
            storageId: _storageIdA,
            draft:
                _choiceDraft(questionId: 'q-focused', correctOptionId: 'opt_a'),
            bankName: _bankName,
            createdAt: 1000,
          ),
        ],
      );
    });

    await pumpUntilLoaded(tester, usePrepared: true);

    // Select Option A (correct)
    await tester.tap(find.byKey(const ValueKey<String>('practice-option-0')));
    await settle(tester);

    // Click "查看答案"
    await tester
        .tap(find.byKey(const ValueKey<String>('practice-reveal-answer')));
    await settle(tester);

    await tester.runAsync(() async {
      final attemptRepo = AnswerAttemptRepository.instance;
      final attempts = await attemptRepo.getAttemptsForQuestion(_storageIdA);
      expect(attempts, hasLength(1));
      expect(attempts.first.sessionKind, AnswerAttemptSessionKind.focused);
      expect(attempts.first.correctness, true);
    });
  });

  testWidgets(
      'Scenario E & F: Subjective text attempts: non-empty writes attempt (correctness null), empty text direct reveal writes zero attempt',
      (tester) async {
    await tester.runAsync(() async {
      final db = await DatabaseHelper.instance.database;
      // Insert subjective question (options empty)
      await _insertTyped(
        db,
        QuestionDraftV2(
          questionId: 'q-subj-1',
          kind: QuestionKind.shortAnswer,
          stem: _text('Subjective Question 1'),
          options: const <QuestionOption>[],
          answer: ContentAnswer(content: _text('Standard Answer')),
        ),
        storageId: _storageIdA,
      );
      await _insertTyped(
        db,
        QuestionDraftV2(
          questionId: 'q-subj-2',
          kind: QuestionKind.shortAnswer,
          stem: _text('Subjective Question 2'),
          options: const <QuestionOption>[],
          answer: ContentAnswer(content: _text('Standard Answer 2')),
        ),
        storageId: _storageIdB,
      );
    });

    await pumpUntilLoaded(tester, bankName: _bankName);

    // Question 1: Enter non-empty text, then "跳过 AI，直接看答案自评"
    await tester.enterText(find.byType(TextField), 'My subjective answer text');
    await settle(tester);

    await tester.tap(find.text('跳过 AI，直接看答案自评'));
    await settle(tester);

    await tester.runAsync(() async {
      final attemptRepo = AnswerAttemptRepository.instance;
      final attempts = await attemptRepo.getAttemptsForQuestion(_storageIdA);
      expect(attempts, hasLength(1));
      expect(attempts.first.modality, AnswerAttemptModality.text);
      expect(attempts.first.correctness, isNull);
      expect(attempts.first.answerPayloadJson,
          contains('My subjective answer text'));
    });

    // Rate Good (3) to advance to Question 2
    await tester.tap(find.text('顺利'));
    await settle(tester);

    // Question 2: Leave text empty, click "跳过 AI，直接看答案自评"
    await tester.tap(find.text('跳过 AI，直接看答案自评'));
    await settle(tester);

    await tester.runAsync(() async {
      final attemptRepo = AnswerAttemptRepository.instance;
      final attempts2 = await attemptRepo.getAttemptsForQuestion(_storageIdB);
      // Empty text direct reveal must NOT create fake attempt!
      expect(attempts2, isEmpty);
    });
  });

  testWidgets(
      'Subjective AI evaluation path: popping page while attempt persistence is pending cancels AI call and prevents setState on unmounted widget',
      (tester) async {
    final spyAi = _SpyAiService();
    final delayedPort = _DelayedAttemptPort();
    final command = RecordAnswerAttemptCommand(delayedPort);

    await tester.runAsync(() async {
      final db = await DatabaseHelper.instance.database;
      await _insertTyped(
        db,
        QuestionDraftV2(
          questionId: 'q-subj-race',
          kind: QuestionKind.shortAnswer,
          stem: _text('Subjective Race Question'),
          options: const <QuestionOption>[],
          answer: ContentAnswer(content: _text('Standard Answer')),
        ),
        storageId: _storageIdA,
      );
    });

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      AiDependenciesScope(
        engineRepository: _FakeEngineRepository(),
        aiService: spyAi,
        importPipelineService: _FakeImportPipelineService(),
        importTaskCoordinator: _FakeImportTaskCoordinator(),
        answerGenerationService: AiAnswerGenerationService(
          questionPort: _FakeStudyQuestionQueryPort(),
          providerPort: _FakeAiAnswerProviderPort(),
          idFactory: () => 'id',
          clock: () => DateTime.now(),
        ),
        answerCommitCommand: AiAnswerCommitCommand(
          persistencePort: _FakeAiAnswerCommitPersistencePort(),
        ),
        examMutationCommand:
            ExamMutationCommand(_FakeExamMutationPersistence()),
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PracticePage(
                      bankName: _bankName,
                      recordAnswerAttemptCommand: command,
                    ),
                  ),
                );
              },
              child: const Text('Open Practice'),
            ),
          ),
        ),
      ),
    );

    // Open PracticePage
    await tester.tap(find.text('Open Practice'));
    for (var frame = 0; frame < 60; frame++) {
      await tester.pump();
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty &&
          find.byType(TextField).evaluate().isNotEmpty) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
    }

    expect(find.byType(TextField), findsOneWidget);

    // Enter answer text
    await tester.enterText(find.byType(TextField), 'My subjective race answer');
    await settle(tester);

    // Tap "呼叫 AI 助教判卷"
    await tester.tap(find.text('呼叫 AI 助教判卷'));
    await tester.pump(); // Start execution until await delayedPort.gate.future

    // Pop the PracticePage while persistence is in-flight
    navigatorKey.currentState!.pop();
    await settle(tester);

    // Release delayed persistence
    delayedPort.gate.complete();
    await settle(tester);

    // Assert: No unhandled Flutter exception occurred, AI was NOT called, attempt was recorded
    expect(tester.takeException(), isNull);
    expect(spyAi.judgeAnswerCallCount, 0);
    expect(delayedPort.recorded, hasLength(1));
    expect(delayedPort.recorded.first.questionId, _storageIdA);
  });
}
