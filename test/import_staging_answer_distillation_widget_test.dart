import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/data/models/review_draft_cas.dart';
import 'package:shiroha_quiz/application/questions/folder_query_port.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/subjective_answer_distillation_service.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';

class _QuestionRepository extends Fake implements FolderQueryPort {
  @override
  Future<List<String>> listAvailableFolders() async => const [];
}

class _FakeDistiller implements SubjectiveAnswerDistiller {
  _FakeDistiller({
    this.failure = false,
    this.pending,
    this.result,
  });

  final bool failure;
  final Completer<SubjectiveAnswerDistillationResult>? pending;
  final SubjectiveAnswerDistillationResult? result;
  int callCount = 0;

  @override
  Future<SubjectiveAnswerDistillationResult> distill({
    required int questionNumber,
    required QuestionDraft question,
    required bool isStemOnly,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    callCount++;
    if (pending != null) return pending!.future;
    if (result != null) return result!;
    if (failure) {
      return const SubjectiveAnswerDistillationResult.failed(
        diagnostics: ['answer_distillation_failed'],
      );
    }
    return const SubjectiveAnswerDistillationResult.applied(
      'Generated concise answer',
    );
  }
}

Map<String, dynamic> _subjectiveQuestion(int number) => <String, dynamic>{
      'q_num': number,
      'question_number': number,
      'source_page_indices': [number - 1],
      'source_block_ids': ['synthetic-block-$number'],
      'type': 3,
      'content': 'Synthetic subjective question $number',
      'options': const <String>[],
      'standard_answer': '',
      'explanation': 'Synthetic explanation $number',
      'raw_explanation': 'Synthetic raw explanation $number',
    };

Widget _widget(
  SubjectiveAnswerDistiller distiller, {
  List<Map<String, dynamic>>? questions,
  TaskManager? taskManager,
  String? taskId,
  Map<String, dynamic>? diagnostics,
}) {
  return MaterialApp(
    home: ImportStagingScreen(
      parsedQuestions: questions ?? [_subjectiveQuestion(1)],
      taskId: taskId,
      diagnostics: diagnostics,
      folderQuery: _QuestionRepository(),
      answerDistiller: distiller,
      taskManager: taskManager,
    ),
  );
}

/// Diagnostics of a photo-capture task: it records retention but carries no
/// document-import marker, so Review keeps the retention controls.
Map<String, dynamic> _photoCaptureDiagnostics() => <String, dynamic>{
      TaskManager.keyParseExplanationRetentionMode: 'subjectiveOnly',
      TaskManager.keyReviewExplanationRetentionMode: 'subjectiveOnly',
      TaskManager.keyExplanationRetentionMode: 'subjectiveOnly',
    };

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
      'provider is called only after explicit action and refreshes stats',
      (tester) async {
    final distiller = _FakeDistiller();
    await tester.pumpWidget(_widget(distiller));
    await tester.pumpAndSettle();

    expect(distiller.callCount, 0);
    expect(find.byKey(const ValueKey('answer-distillation-batch')), findsOne);
    expect(find.textContaining('缺答案: 1'), findsOne);

    expect(
      find.byKey(const ValueKey('answer-distillation-single-0')),
      findsOne,
    );
    await tester.tap(find.byKey(const ValueKey('answer-distillation-batch')));
    await tester.pumpAndSettle();

    expect(distiller.callCount, 1);
    expect(find.text('Generated concise answer'), findsOne);
    expect(find.textContaining('缺答案: 0'), findsOne);
    expect(find.textContaining('警告: 0'), findsOne);
  });

  testWidgets('local answer extraction updates stats without provider call',
      (tester) async {
    final distiller = _FakeDistiller();
    final taskManager = TaskManager.forTesting();
    final source = [
      {
        ..._subjectiveQuestion(1),
        'explanation': r'Calculation steps. 答案为：\(x=2\)',
      },
    ];
    taskManager.addTask(
      ImportTask(
        id: 'local-extraction-task',
        title: 'Synthetic local extraction',
        status: TaskStatus.pendingReview,
        parsedData: source,
      ),
    );
    await tester.pumpWidget(
      _widget(
        distiller,
        questions: source,
        taskManager: taskManager,
        taskId: 'local-extraction-task',
      ),
    );
    await tester.pumpAndSettle();

    expect(distiller.callCount, 0);
    expect(
      taskManager.tasks.single.parsedData!.single['standard_answer'],
      r'\(x=2\)',
    );
    expect(taskManager.tasks.single.parsedData!.single['question_number'], 1);
    expect(
      taskManager.tasks.single.parsedData!.single['source_page_indices'],
      [0],
    );
    expect(find.textContaining('缺答案: 0'), findsOne);
    expect(
        find.byKey(const ValueKey('answer-distillation-batch')), findsNothing);
  });

  testWidgets('proof explanation is not missing and never becomes candidate',
      (tester) async {
    final distiller = _FakeDistiller();
    await tester.pumpWidget(
      _widget(
        distiller,
        questions: [
          {
            ..._subjectiveQuestion(1),
            'content': '证明该命题成立',
            'explanation': 'Synthetic complete proof process.',
          },
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(distiller.callCount, 0);
    expect(find.text('证明过程已识别'), findsOne);
    expect(find.textContaining('缺答案: 0'), findsOne);
    expect(
        find.byKey(const ValueKey('answer-distillation-batch')), findsNothing);
  });

  testWidgets('AI answer is restored from task review draft after re-entry',
      (tester) async {
    final taskManager = TaskManager.forTesting();
    final source = [_subjectiveQuestion(1)];
    taskManager.addTask(
      ImportTask(
        id: 'review-task',
        title: 'Synthetic review',
        status: TaskStatus.pendingReview,
        parsedData: source,
      ),
    );
    final distiller = _FakeDistiller();

    await tester.pumpWidget(
      _widget(
        distiller,
        questions: source,
        taskManager: taskManager,
        taskId: 'review-task',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('answer-distillation-batch')));
    await tester.pumpAndSettle();

    expect(
      taskManager.tasks.single.parsedData!.single['standard_answer'],
      'Generated concise answer',
    );

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    await tester.pumpWidget(
      _widget(
        distiller,
        questions: taskManager.tasks.single.parsedData!,
        taskManager: taskManager,
        taskId: 'review-task',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Generated concise answer'), findsOne);
    expect(distiller.callCount, 1);
  });

  testWidgets('failed result remains reviewable', (tester) async {
    final distiller = _FakeDistiller(failure: true);
    final taskManager = TaskManager.forTesting();
    final source = [_subjectiveQuestion(1)];
    taskManager.addTask(
      ImportTask(
        id: 'failed-review-task',
        title: 'Synthetic failed review',
        status: TaskStatus.pendingReview,
        parsedData: source,
      ),
    );
    await tester.pumpWidget(
      _widget(
        distiller,
        questions: source,
        taskManager: taskManager,
        taskId: 'failed-review-task',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('answer-distillation-batch')));
    await tester.pumpAndSettle();

    expect(distiller.callCount, 1);
    expect(find.textContaining('缺答案: 1'), findsOne);
    expect(
      taskManager.tasks.single.parsedData!.single['standard_answer'],
      isEmpty,
    );
    expect(
      taskManager.tasks.single.parsedData!
          .single[TaskManager.keyAnswerDistillationStatus],
      'ai_failed',
    );
    expect(
      taskManager.tasks.single.parsedData!
          .single[TaskManager.keyAnswerDistillationReason],
      'answer_distillation_failed',
    );
    expect(find.text('生成失败，可重试'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('answer-distillation-single-0')),
      findsOne,
    );

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    await tester.pumpWidget(
      _widget(
        distiller,
        questions: taskManager.tasks.single.parsedData!,
        taskManager: taskManager,
        taskId: 'failed-review-task',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('生成失败，可重试'), findsOneWidget);
    expect(distiller.callCount, 1);
  });

  testWidgets('rejected result remains retryable and restores its safe status',
      (tester) async {
    final distiller = _FakeDistiller(
      result: const SubjectiveAnswerDistillationResult.rejected(
        diagnostics: ['answer_distillation_rejected_basis'],
      ),
    );
    final taskManager = TaskManager.forTesting();
    final source = [_subjectiveQuestion(1)];
    taskManager.addTask(
      ImportTask(
        id: 'rejected-review-task',
        title: 'Synthetic rejected review',
        status: TaskStatus.pendingReview,
        parsedData: source,
      ),
    );
    await tester.pumpWidget(
      _widget(
        distiller,
        questions: source,
        taskManager: taskManager,
        taskId: 'rejected-review-task',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('answer-distillation-batch')));
    await tester.pumpAndSettle();

    expect(find.text('未找到可安全提炼的答案'), findsOneWidget);
    expect(
      taskManager.tasks.single.parsedData!
          .single[TaskManager.keyAnswerDistillationStatus],
      'ai_rejected',
    );
    expect(
      taskManager.tasks.single.parsedData!
          .single[TaskManager.keyAnswerDistillationReason],
      'answer_distillation_rejected_basis',
    );
    expect(
      find.byKey(const ValueKey('answer-distillation-single-0')),
      findsOneWidget,
    );
  });

  testWidgets('prefixed diagnostic payload is never persisted', (tester) async {
    final distiller = _FakeDistiller(
      result: const SubjectiveAnswerDistillationResult.rejected(
        diagnostics: [
          'answer_distillation_rejected_sensitive_provider_body',
        ],
      ),
    );
    final taskManager = TaskManager.forTesting();
    final source = [_subjectiveQuestion(1)];
    taskManager.addTask(
      ImportTask(
        id: 'unsafe-reason-review-task',
        title: 'Synthetic unsafe reason review',
        status: TaskStatus.pendingReview,
        parsedData: source,
      ),
    );
    await tester.pumpWidget(
      _widget(
        distiller,
        questions: source,
        taskManager: taskManager,
        taskId: 'unsafe-reason-review-task',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('answer-distillation-batch')));
    await tester.pumpAndSettle();

    final question = taskManager.tasks.single.parsedData!.single;
    expect(
      question[TaskManager.keyAnswerDistillationStatus],
      'ai_rejected',
    );
    expect(
      question[TaskManager.keyAnswerDistillationReason],
      'answer_distillation_rejected',
    );
    expect(question.toString(), isNot(contains('sensitive_provider_body')));
  });

  testWidgets('failed diagnostic payload is never persisted', (tester) async {
    final distiller = _FakeDistiller(
      result: const SubjectiveAnswerDistillationResult.failed(
        diagnostics: [
          'answer_distillation_failure_type:SENSITIVEPROVIDERBODY123',
        ],
      ),
    );
    final taskManager = TaskManager.forTesting();
    final source = [_subjectiveQuestion(1)];
    taskManager.addTask(
      ImportTask(
        id: 'unsafe-failure-reason-review-task',
        title: 'Synthetic unsafe failure reason review',
        status: TaskStatus.pendingReview,
        parsedData: source,
      ),
    );
    await tester.pumpWidget(
      _widget(
        distiller,
        questions: source,
        taskManager: taskManager,
        taskId: 'unsafe-failure-reason-review-task',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('answer-distillation-batch')));
    await tester.pumpAndSettle();

    final question = taskManager.tasks.single.parsedData!.single;
    expect(
      question[TaskManager.keyAnswerDistillationStatus],
      'ai_failed',
    );
    expect(
      question[TaskManager.keyAnswerDistillationReason],
      'answer_distillation_failed',
    );
    expect(
      question.toString(),
      isNot(contains('SENSITIVEPROVIDERBODY123')),
    );
  });

  // The user path this covers is real for every compatibility task: photo
  // capture and tasks persisted by older builds record their own retention
  // policy and still expose the document switch, so a retention toggle can
  // still land while an AI answer merge is in flight.
  testWidgets(
      'compatibility task: retention toggle during an AI merge preserves both latest states',
      (tester) async {
    final pending = Completer<SubjectiveAnswerDistillationResult>();
    final mergeWriteStarted = Completer<void>();
    final releaseMergeWrite = Completer<void>();
    final taskManager = TaskManager.forTesting(
      saveReviewDraftCas: ({
        required String taskId,
        required ReviewDraftAttemptIdentity expectedAttempt,
        required int expectedRevision,
        required List<Map<String, dynamic>> questions,
        required String explanationRetentionMode,
      }) async {
        final question = questions.single;
        if (question['standard_answer'] == 'Concurrent generated answer' &&
            !mergeWriteStarted.isCompleted) {
          mergeWriteStarted.complete();
          await releaseMergeWrite.future;
        }
        return ReviewDraftCasResult(
          ReviewDraftCasStatus.saved,
          durableRevision: expectedRevision + 1,
        );
      },
    );
    final source = [_subjectiveQuestion(1)];
    taskManager.addTask(
      ImportTask(
        id: 'concurrent-retention-review-task',
        title: 'Synthetic concurrent retention review',
        status: TaskStatus.pendingReview,
        parsedData: source,
        diagnostics: _photoCaptureDiagnostics(),
      ),
    );
    final distiller = _FakeDistiller(pending: pending);
    await tester.pumpWidget(
      _widget(
        distiller,
        questions: source,
        diagnostics: _photoCaptureDiagnostics(),
        taskManager: taskManager,
        taskId: 'concurrent-retention-review-task',
      ),
    );
    await tester.pumpAndSettle();

    // The compatibility task exposes the retention controls.
    final switchFinder =
        find.byKey(const ValueKey('objective-explanation-document-switch'));
    expect(switchFinder, findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('answer-distillation-batch')));
    await tester.pump();
    pending.complete(
      const SubjectiveAnswerDistillationResult.applied(
        'Concurrent generated answer',
      ),
    );
    await tester.pump();

    // Wait on real persistence progress rather than on frames: the merge's
    // write must have reached the harness before the retention toggle lands.
    for (var i = 0; i < 100 && !mergeWriteStarted.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(mergeWriteStarted.isCompleted, isTrue);

    await tester.tap(switchFinder);
    await tester.pump();
    releaseMergeWrite.complete();
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    final task = taskManager.tasks.single;
    final question = task.parsedData!.single;
    // The merge must not have reverted the retention decision...
    expect(
      task.reviewExplanationRetentionMode,
      ExplanationRetentionMode.allQuestionTypes,
    );
    expect(
      task.diagnostics?[TaskManager.keyReviewExplanationRetentionMode],
      'allQuestionTypes',
    );
    // ...and the retention save must not have reverted the merged answer.
    expect(question['standard_answer'], 'Concurrent generated answer');
    expect(
      question[TaskManager.keyAnswerDistillationStatus],
      'ai_applied',
    );
    expect(
      taskManager.reviewDraftRevision('concurrent-retention-review-task'),
      greaterThanOrEqualTo(2),
      reason: 'both writes must have advanced the revision',
    );

    // Re-entry still shows both latest states.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    await tester.pumpWidget(
      _widget(
        distiller,
        questions: task.parsedData!,
        diagnostics: task.diagnostics,
        taskManager: taskManager,
        taskId: 'concurrent-retention-review-task',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Concurrent generated answer'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(
              const ValueKey('objective-explanation-document-switch'),
            ),
          )
          .value,
      isTrue,
      reason: 'the retained policy must survive re-entry',
    );
  });

  testWidgets('batch can cancel before starting another question',
      (tester) async {
    final pending = Completer<SubjectiveAnswerDistillationResult>();
    final distiller = _FakeDistiller(pending: pending);
    await tester.pumpWidget(
      _widget(
        distiller,
        questions: [_subjectiveQuestion(1), _subjectiveQuestion(2)],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('answer-distillation-batch')));
    await tester.pump();
    expect(distiller.callCount, 1);

    await tester.tap(find.byKey(const ValueKey('answer-distillation-cancel')));
    pending.complete(
      const SubjectiveAnswerDistillationResult.applied('First answer'),
    );
    await tester.pumpAndSettle();

    expect(distiller.callCount, 1);
    expect(find.textContaining('缺答案: 1'), findsOne);
  });

  testWidgets('disposing the page ignores a late provider result',
      (tester) async {
    final pending = Completer<SubjectiveAnswerDistillationResult>();
    final distiller = _FakeDistiller(pending: pending);
    final taskManager = TaskManager.forTesting();
    final source = [_subjectiveQuestion(1)];
    taskManager.addTask(
      ImportTask(
        id: 'late-review-task',
        title: 'Synthetic late review',
        status: TaskStatus.pendingReview,
        parsedData: source,
      ),
    );
    await tester.pumpWidget(
      _widget(
        distiller,
        questions: source,
        taskManager: taskManager,
        taskId: 'late-review-task',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('answer-distillation-batch')));
    await tester.pump();
    expect(distiller.callCount, 1);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));

    pending.complete(
      const SubjectiveAnswerDistillationResult.applied('Late answer'),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      taskManager.tasks.single.parsedData!.single['standard_answer'],
      'Late answer',
    );
  });

  testWidgets('late result cannot revive a question deleted after navigation',
      (tester) async {
    final pending = Completer<SubjectiveAnswerDistillationResult>();
    final distiller = _FakeDistiller(pending: pending);
    final taskManager = TaskManager.forTesting();
    final source = [_subjectiveQuestion(1)];
    taskManager.addTask(
      ImportTask(
        id: 'deleted-during-request',
        title: 'Synthetic deleted request',
        status: TaskStatus.pendingReview,
        parsedData: source,
      ),
    );
    await tester.pumpWidget(
      _widget(
        distiller,
        questions: source,
        taskManager: taskManager,
        taskId: 'deleted-during-request',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('answer-distillation-batch')));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await taskManager.saveReviewDraft(
      'deleted-during-request',
      questions: const [],
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );

    pending.complete(
      const SubjectiveAnswerDistillationResult.applied('Stale answer'),
    );
    await tester.pump();

    expect(taskManager.tasks.single.parsedData, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
