import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/subjective_answer_distillation_service.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';

class _QuestionRepository extends Fake implements QuestionRepository {
  @override
  Future<List<String>> getAvailableFolders() async => const [];
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
}) {
  return MaterialApp(
    home: ImportStagingScreen(
      parsedQuestions: questions ?? [_subjectiveQuestion(1)],
      taskId: taskId,
      questionRepository: _QuestionRepository(),
      answerDistiller: distiller,
      taskManager: taskManager,
    ),
  );
}

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

  testWidgets(
      'retention save queued during AI merge preserves both latest states',
      (tester) async {
    final pending = Completer<SubjectiveAnswerDistillationResult>();
    final mergeWriteStarted = Completer<void>();
    final releaseMergeWrite = Completer<void>();
    final taskManager = TaskManager.forTesting(
      saveTask: (taskMap) async {
        final rawParsedData = taskMap['parsed_data'];
        if (rawParsedData is! String) return;
        final decoded = jsonDecode(rawParsedData);
        if (decoded is! List || decoded.isEmpty || decoded.first is! Map) {
          return;
        }
        final question = Map<String, dynamic>.from(decoded.first as Map);
        if (question['standard_answer'] == 'Concurrent generated answer' &&
            !mergeWriteStarted.isCompleted) {
          mergeWriteStarted.complete();
          await releaseMergeWrite.future;
        }
      },
    );
    final source = [_subjectiveQuestion(1)];
    taskManager.addTask(
      ImportTask(
        id: 'concurrent-retention-review-task',
        title: 'Synthetic concurrent retention review',
        status: TaskStatus.pendingReview,
        parsedData: source,
      ),
    );
    final distiller = _FakeDistiller(pending: pending);
    await tester.pumpWidget(
      _widget(
        distiller,
        questions: source,
        taskManager: taskManager,
        taskId: 'concurrent-retention-review-task',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('answer-distillation-batch')));
    await tester.pump();
    pending.complete(
      const SubjectiveAnswerDistillationResult.applied(
        'Concurrent generated answer',
      ),
    );
    await tester.pump();
    await mergeWriteStarted.future;

    await tester.tap(
      find.byKey(const ValueKey('objective-explanation-document-switch')),
    );
    await tester.pump();
    releaseMergeWrite.complete();
    await tester.pumpAndSettle();

    final task = taskManager.tasks.single;
    final question = task.parsedData!.single;
    expect(question['standard_answer'], 'Concurrent generated answer');
    expect(
      question[TaskManager.keyAnswerDistillationStatus],
      'ai_applied',
    );
    expect(
      task.explanationRetentionMode,
      ExplanationRetentionMode.allQuestionTypes,
    );

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    await tester.pumpWidget(
      _widget(
        distiller,
        questions: task.parsedData!,
        taskManager: taskManager,
        taskId: 'concurrent-retention-review-task',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Concurrent generated answer'), findsOneWidget);
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
