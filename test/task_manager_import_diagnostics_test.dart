import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/task_manager.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('ImportTask Diagnostics Serialization & TaskManager Tests', () {
    test('toMap and fromMap preserves warnings and diagnostics', () {
      final task = ImportTask(
        id: 'test_task_1',
        title: 'Test Document',
        warnings: ['Warning 1', 'Warning 2'],
        diagnostics: {
          'pdf_render': {'status': 'crash', 'error': 'Failed'},
          'vision_batch': {'failedBatchCount': 1},
        },
      );

      final map = task.toMap();
      expect(map['warnings'], isNotNull);
      expect(map['diagnostics'], isNotNull);

      final decodedTask = ImportTask.fromMap(map);
      expect(decodedTask.id, 'test_task_1');
      expect(decodedTask.title, 'Test Document');
      expect(decodedTask.warnings, containsAll(['Warning 1', 'Warning 2']));
      expect(decodedTask.diagnostics, isNotNull);
      expect(decodedTask.diagnostics!['pdf_render']['status'], 'crash');
      expect(decodedTask.diagnostics!['vision_batch']['failedBatchCount'], 1);
    });

    test('fromMap handles null warnings and diagnostics gracefully', () {
      final task = ImportTask(
        id: 'test_task_2',
        title: 'Test Document 2',
      );

      final map = task.toMap();
      expect(map['warnings'], isNull);
      expect(map['diagnostics'], isNull);

      final decodedTask = ImportTask.fromMap(map);
      expect(decodedTask.warnings, isNull);
      expect(decodedTask.diagnostics, isNull);
    });

    test('fromMap handles malformed warnings and diagnostics without crashing',
        () {
      final malformedMap = {
        'id': 'test_task_3',
        'title': 'Test Document 3',
        'status': 0,
        'progress_text': 'running',
        'percent': 0.5,
        'created_at': 12345678,
        'warnings': '{invalid_json}',
        'diagnostics': '[1, 2, 3]', // Expected Map, got List
      };

      final decodedTask = ImportTask.fromMap(malformedMap);
      expect(decodedTask.id, 'test_task_3');
      expect(decodedTask.warnings, isNull);
      expect(decodedTask.diagnostics, isNull);
    });

    test('batch insertion keeps selection order ahead of existing tasks', () {
      final taskManager = TaskManager.forTesting();
      taskManager.addTask(
        ImportTask(id: 'existing', title: 'Existing task'),
      );

      taskManager.addTasksInOrder(<ImportTask>[
        ImportTask(id: 'batch-0', title: 'First selected task'),
        ImportTask(id: 'batch-1', title: 'Second selected task'),
        ImportTask(id: 'batch-2', title: 'Third selected task'),
      ]);

      expect(
        taskManager.tasks.map((task) => task.id),
        <String>['batch-0', 'batch-1', 'batch-2', 'existing'],
      );
    });

    test('batch identity survives review failure and serialization', () {
      final taskManager = TaskManager.forTesting();
      taskManager.addTask(
        ImportTask(
          id: 'batch-metadata',
          title: 'Synthetic batch task',
          diagnostics: const <String, dynamic>{
            TaskManager.keyTraceId: 'trace-batch',
            TaskManager.keyParseMode: 'ocr',
            TaskManager.keyExplanationRetentionMode: 'subjectiveOnly',
            TaskManager.keyBatchId: 'batch-fixture',
            TaskManager.keySelectionIndex: 2,
          },
        ),
      );

      taskManager.requireReview(
        'batch-metadata',
        'Ready',
        const <Map<String, dynamic>>[
          <String, dynamic>{
            'q_num': '1',
            'content': 'Synthetic question',
            'standard_answer': 'A',
          },
        ],
        '',
        '',
        diagnostics: const <String, dynamic>{'safeCount': 1},
      );
      taskManager.failTask(
        'batch-metadata',
        'Synthetic failure',
        diagnostics: const <String, dynamic>{
          'failedStage': 'import_parse',
          'errorType': 'SyntheticFailure',
        },
      );

      final task = taskManager.tasks.single;
      final restored = ImportTask.fromMap(task.toMap());
      expect(task.batchId, 'batch-fixture');
      expect(task.selectionIndex, 2);
      expect(task.traceId, 'trace-batch');
      expect(task.parseMode, 'ocr');
      expect(restored.batchId, 'batch-fixture');
      expect(restored.selectionIndex, 2);
      expect(restored.diagnostics?['failedStage'], 'import_parse');
    });

    test('TaskManager attachDiagnostics updates task successfully', () {
      final taskManager = TaskManager.instance;
      final task = ImportTask(
        id: 'test_task_4',
        title: 'Test Document 4',
      );
      taskManager.addTask(task);

      taskManager.attachDiagnostics(
        'test_task_4',
        warnings: ['Attached Warning'],
        diagnostics: {'some': 'diagnostic'},
      );

      final updated =
          taskManager.tasks.firstWhere((t) => t.id == 'test_task_4');
      expect(updated.warnings, contains('Attached Warning'));
      expect(updated.diagnostics, isNotNull);
      expect(updated.diagnostics!['some'], 'diagnostic');

      // Clean up task so it doesn't pollute database
      taskManager.deleteTask('test_task_4');
    });

    test('review draft replaces parsed data and preserves retention metadata',
        () async {
      final taskManager = TaskManager.forTesting();
      taskManager.addTask(
        ImportTask(
          id: 'review-draft',
          title: 'Synthetic review',
          status: TaskStatus.pendingReview,
          parsedData: [
            {'type': 3, 'content': 'Original', 'standard_answer': ''},
          ],
        ),
      );

      await taskManager.saveReviewDraft(
        'review-draft',
        questions: [
          {
            'type': 3,
            'content': 'Edited',
            'standard_answer': '42',
            '_explanation_override': 'keep',
            '_answer_distillation_status': 'local_extracted',
          },
        ],
        explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
      );

      final task = taskManager.tasks.single;
      expect(task.parsedData, hasLength(1));
      expect(task.parsedData!.single['content'], 'Edited');
      expect(task.parsedData!.single['standard_answer'], '42');
      expect(task.parsedData!.single['_explanation_override'], 'keep');
      expect(
        task.diagnostics![TaskManager.keyExplanationRetentionMode],
        ExplanationRetentionMode.allQuestionTypes.name,
      );

      final restored = ImportTask.fromMap(task.toMap());
      expect(restored.parsedData!.single['standard_answer'], '42');
      expect(
        restored.parsedData!.single['_answer_distillation_status'],
        'local_extracted',
      );
    });

    test('review draft persistence failure keeps the previous snapshot',
        () async {
      final taskManager = TaskManager.forTesting(
        saveTask: (_) async => throw StateError('synthetic persistence error'),
      );
      taskManager.addTask(
        ImportTask(
          id: 'failed-review-draft',
          title: 'Synthetic failed draft',
          status: TaskStatus.pendingReview,
          parsedData: [
            {'content': 'Original', 'standard_answer': ''},
          ],
        ),
      );

      final result = await taskManager.saveReviewDraft(
        'failed-review-draft',
        questions: [
          {'content': 'Changed', 'standard_answer': '42'},
        ],
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result.status, ReviewDraftSaveStatus.failed);
      expect(
        taskManager.tasks.single.parsedData!.single['content'],
        'Original',
      );
    });

    test('stale answer merge cannot revive a deleted review item', () async {
      final taskManager = TaskManager.forTesting();
      taskManager.addTask(
        ImportTask(
          id: 'deleted-review-item',
          title: 'Synthetic deleted item',
          status: TaskStatus.pendingReview,
          parsedData: [
            {
              TaskManager.keyReviewItemId: 'q17',
              'content': 'Question',
              'standard_answer': '',
            },
          ],
        ),
      );
      final base = await taskManager.saveReviewDraft(
        'deleted-review-item',
        questions: taskManager.tasks.single.parsedData!,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );
      await taskManager.saveReviewDraft(
        'deleted-review-item',
        questions: const [],
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      final stale = await taskManager.mergeReviewDraftAnswer(
        'deleted-review-item',
        reviewItemId: 'q17',
        expectedRevision: base.revision,
        standardAnswer: 'Stale answer',
        status: 'ai_applied',
      );

      expect(stale.status, ReviewDraftSaveStatus.stale);
      expect(taskManager.tasks.single.parsedData, isEmpty);
    });

    test('stale answer merge cannot overwrite a newer manual answer', () async {
      final taskManager = TaskManager.forTesting();
      taskManager.addTask(
        ImportTask(
          id: 'updated-review-item',
          title: 'Synthetic updated item',
          status: TaskStatus.pendingReview,
          parsedData: [
            {
              TaskManager.keyReviewItemId: 'q17',
              'content': 'Question',
              'standard_answer': '',
            },
          ],
        ),
      );
      final base = await taskManager.saveReviewDraft(
        'updated-review-item',
        questions: taskManager.tasks.single.parsedData!,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );
      await taskManager.saveReviewDraft(
        'updated-review-item',
        questions: [
          {
            TaskManager.keyReviewItemId: 'q17',
            'content': 'Question',
            'standard_answer': 'Manual answer',
          },
        ],
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      final stale = await taskManager.mergeReviewDraftAnswer(
        'updated-review-item',
        reviewItemId: 'q17',
        expectedRevision: base.revision,
        standardAnswer: 'Stale answer',
        status: 'ai_applied',
      );

      expect(stale.status, ReviewDraftSaveStatus.stale);
      expect(
        taskManager.tasks.single.parsedData!.single['standard_answer'],
        'Manual answer',
      );
    });

    test('failed distillation persists safe status without changing the answer',
        () async {
      final taskManager = TaskManager.forTesting();
      taskManager.addTask(
        ImportTask(
          id: 'failed-distillation',
          title: 'Synthetic failed distillation',
          status: TaskStatus.pendingReview,
          parsedData: [
            {
              TaskManager.keyReviewItemId: 'q17',
              'content': 'Question',
              'standard_answer': '',
            },
          ],
        ),
      );
      final base = await taskManager.saveReviewDraft(
        'failed-distillation',
        questions: taskManager.tasks.single.parsedData!,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      final result = await taskManager.mergeReviewDraftAnswerDistillation(
        'failed-distillation',
        reviewItemId: 'q17',
        expectedRevision: base.revision,
        status: 'ai_failed',
        reasonCode: 'answer_distillation_failed',
      );

      expect(result.status, ReviewDraftSaveStatus.saved);
      final question = taskManager.tasks.single.parsedData!.single;
      expect(question['standard_answer'], isEmpty);
      expect(
        question[TaskManager.keyAnswerDistillationStatus],
        'ai_failed',
      );
      expect(
        question[TaskManager.keyAnswerDistillationReason],
        'answer_distillation_failed',
      );

      final restored = ImportTask.fromMap(taskManager.tasks.single.toMap());
      expect(
        restored.parsedData!.single[TaskManager.keyAnswerDistillationStatus],
        'ai_failed',
      );
    });

    test('full snapshot save removes unknown distillation metadata', () async {
      final taskManager = TaskManager.forTesting();
      taskManager.addTask(
        ImportTask(
          id: 'unsafe-distillation-snapshot',
          title: 'Synthetic unsafe distillation snapshot',
          status: TaskStatus.pendingReview,
          parsedData: [
            {
              TaskManager.keyReviewItemId: 'q17',
              'content': 'Question',
              'standard_answer': '',
            },
          ],
        ),
      );

      final result = await taskManager.saveReviewDraft(
        'unsafe-distillation-snapshot',
        questions: [
          {
            TaskManager.keyReviewItemId: 'q17',
            'content': 'Question',
            'standard_answer': '',
            TaskManager.keyAnswerDistillationStatus: 'ai_rejected',
            TaskManager.keyAnswerDistillationReason:
                'answer_distillation_rejected_sensitive_provider_body',
          },
        ],
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result.status, ReviewDraftSaveStatus.saved);
      final question = taskManager.tasks.single.parsedData!.single;
      expect(
        question[TaskManager.keyAnswerDistillationStatus],
        'ai_rejected',
      );
      expect(
        question.containsKey(TaskManager.keyAnswerDistillationReason),
        isFalse,
      );
      expect(question.toString(), isNot(contains('sensitive_provider_body')));
    });

    test('distillation merge rejects reason from a different outcome',
        () async {
      final taskManager = TaskManager.forTesting();
      taskManager.addTask(
        ImportTask(
          id: 'mismatched-distillation-reason',
          title: 'Synthetic mismatched distillation reason',
          status: TaskStatus.pendingReview,
          parsedData: [
            {
              TaskManager.keyReviewItemId: 'q17',
              'content': 'Question',
              'standard_answer': '',
            },
          ],
        ),
      );
      final base = await taskManager.saveReviewDraft(
        'mismatched-distillation-reason',
        questions: taskManager.tasks.single.parsedData!,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      final result = await taskManager.mergeReviewDraftAnswerDistillation(
        'mismatched-distillation-reason',
        reviewItemId: 'q17',
        expectedRevision: base.revision,
        status: 'ai_failed',
        reasonCode: 'answer_distillation_rejected_basis',
      );

      expect(result.status, ReviewDraftSaveStatus.saved);
      final question = taskManager.tasks.single.parsedData!.single;
      expect(
        question[TaskManager.keyAnswerDistillationStatus],
        'ai_failed',
      );
      expect(
        question.containsKey(TaskManager.keyAnswerDistillationReason),
        isFalse,
      );
    });

    test('full snapshot save removes caller-provided failure type payload',
        () async {
      final taskManager = TaskManager.forTesting();
      taskManager.addTask(
        ImportTask(
          id: 'unsafe-failure-type-snapshot',
          title: 'Synthetic unsafe failure type snapshot',
          status: TaskStatus.pendingReview,
          parsedData: [
            {
              TaskManager.keyReviewItemId: 'q17',
              'content': 'Question',
              'standard_answer': '',
            },
          ],
        ),
      );

      final result = await taskManager.saveReviewDraft(
        'unsafe-failure-type-snapshot',
        questions: [
          {
            TaskManager.keyReviewItemId: 'q17',
            'content': 'Question',
            'standard_answer': '',
            TaskManager.keyAnswerDistillationStatus: 'ai_failed',
            TaskManager.keyAnswerDistillationReason:
                'answer_distillation_failure_type:SENSITIVEPROVIDERBODY123',
          },
        ],
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result.status, ReviewDraftSaveStatus.saved);
      final question = taskManager.tasks.single.parsedData!.single;
      expect(
        question[TaskManager.keyAnswerDistillationStatus],
        'ai_failed',
      );
      expect(
        question.containsKey(TaskManager.keyAnswerDistillationReason),
        isFalse,
      );
      expect(
        question.toString(),
        isNot(contains('SENSITIVEPROVIDERBODY123')),
      );
    });
  });
}
