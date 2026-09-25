import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/data/models/review_draft_cas.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/task_manager.dart';

const _uuidA = '0d8b7a3e-7f1c-4b2a-9d3e-5a6b7c8d9e0f';
const _uuidB = '1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d';

Map<String, Object?> _envelope() {
  const codec = TypedReviewSnapshotCodec();
  return codec.encode(
    TypedReviewSnapshot(
      reviewItemId: _uuidA,
      questionId: _uuidB,
      draft: QuestionDraftV2(
        questionId: _uuidB,
        kind: QuestionKind.singleChoice,
        questionNumber: 1,
        stem: RichContent(nodes: const <ContentNode>[
          TextNode('Synthetic typed stem'),
        ]),
        options: <QuestionOption>[
          QuestionOption(
            optionId: 'option_a',
            label: 'A',
            content: RichContent(nodes: const <ContentNode>[
              TextNode('Synthetic option A'),
            ]),
          ),
        ],
        answer: ChoiceAnswer(optionIds: <String>['option_a']),
      ),
      baselineLegacy: LegacyReviewBaseline(
        type: 0,
        questionNumber: 1,
        content: 'Synthetic baseline',
        options: <String>['A'],
        standardAnswer: 'A',
        explanation: 'Synthetic explanation',
      ),
    ),
  );
}

Map<String, dynamic> _questionWithEnvelope({
  int number = 1,
  Map<String, Object?>? envelope,
  bool includeReviewItemId = true,
}) {
  return <String, dynamic>{
    'q_num': number,
    'question_number': number,
    'source_page_indices': <int>[number - 1],
    'source_block_ids': <String>['synthetic-block-$number'],
    'type': 0,
    'content': 'Synthetic question $number',
    'options': <String>['A'],
    'standard_answer': 'A',
    'explanation': 'Synthetic explanation $number',
    if (includeReviewItemId) TaskManager.keyReviewItemId: 'review-item-$number',
    TypedReviewSnapshotCodec.mapKey: envelope ?? _envelope(),
  };
}

Map<String, dynamic> _routeDiagnostics({
  String route = 'typedV2',
  String? reason = 'typed_candidate_ready',
}) {
  return <String, dynamic>{
    TaskManager.keyImportStorageRoute: route,
    if (reason != null) TaskManager.keyImportStorageReason: reason,
  };
}

String _json(Object? value) => jsonEncode(value);

const _rd0Attempt = ImportAttemptRef(
  taskId: 'rd0-task',
  attemptNumber: 1,
  attemptToken: 'rd0-attempt-1',
  traceId: 'rd0-trace-1',
);

ImportTask _rd0Task({
  bool document = true,
  String route = 'typedV2',
  Object? revision = 0,
  TaskStatus status = TaskStatus.pendingReview,
  String attemptState = 'readyForReview',
}) =>
    ImportTask(
      id: _rd0Attempt.taskId,
      title: 'Synthetic document task',
      status: status,
      bankName: 'Synthetic bank',
      folderName: 'Synthetic folder',
      parsedData: <Map<String, dynamic>>[_questionWithEnvelope()],
      diagnostics: <String, dynamic>{
        TaskManager.keyTraceId: _rd0Attempt.traceId,
        TaskManager.keyAttemptNumber: _rd0Attempt.attemptNumber,
        TaskManager.keyAttemptToken: _rd0Attempt.attemptToken,
        TaskManager.keyAttemptState: attemptState,
        if (document)
          documentImportEntryMarkerKey: documentImportEntryMarkerValue,
        TaskManager.keyImportStorageRoute: route,
        TaskManager.keyImportStorageReason: 'typed_candidate_ready',
        TaskManager.keyParseExplanationRetentionMode: 'allQuestionTypes',
        TaskManager.keyReviewExplanationRetentionMode: 'subjectiveOnly',
        if (revision != null) TaskManager.keyReviewDraftRevision: revision,
      },
    );

void main() {
  group('TaskManager typed review snapshot persistence', () {
    test('RD0 writes revision 1 once through existing CAS and keeps retention',
        () async {
      var writes = 0;
      final manager = TaskManager.forTesting(
        saveReviewDraftCas: ({
          required taskId,
          required expectedAttempt,
          required expectedRevision,
          required questions,
          required explanationRetentionMode,
        }) async {
          writes++;
          expect(taskId, _rd0Attempt.taskId);
          expect(expectedAttempt.attemptToken, _rd0Attempt.attemptToken);
          expect(expectedAttempt.traceId, _rd0Attempt.traceId);
          expect(expectedRevision, writes - 1);
          expect(questions, hasLength(1));
          expect(
            _json(questions.single[TypedReviewSnapshotCodec.mapKey]),
            _json(_envelope()),
          );
          expect(explanationRetentionMode, 'subjectiveOnly');
          return ReviewDraftCasResult(
            ReviewDraftCasStatus.saved,
            durableRevision: expectedRevision + 1,
          );
        },
      );
      manager.tasks.add(_rd0Task());

      expect(
        await manager.materializeInitialTypedDocumentReviewDraft(_rd0Attempt),
        InitialTypedDocumentReviewDraftStatus.materialized,
      );
      expect(manager.reviewDraftRevision(_rd0Attempt.taskId), 1);
      expect(
        await manager.materializeInitialTypedDocumentReviewDraft(_rd0Attempt),
        InitialTypedDocumentReviewDraftStatus.alreadyMaterialized,
      );
      expect(writes, 1);
      expect(
        (await manager.saveReviewDraft(
          _rd0Attempt.taskId,
          questions: manager.tasks.single.parsedData!,
          explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
        ))
            .revision,
        2,
      );
    });

    test('RD0 rejects stale, legacy and malformed state without writing',
        () async {
      final manager = TaskManager.forTesting();
      manager.tasks.add(_rd0Task());
      const stale = ImportAttemptRef(
        taskId: 'rd0-task',
        attemptNumber: 1,
        attemptToken: 'old-token',
        traceId: 'rd0-trace-1',
      );
      expect(
        await manager.materializeInitialTypedDocumentReviewDraft(stale),
        InitialTypedDocumentReviewDraftStatus.staleAttempt,
      );
      for (final task in <ImportTask>[
        _rd0Task(document: false),
        _rd0Task(route: 'legacyV1'),
        _rd0Task(revision: 'invalid'),
        _rd0Task(status: TaskStatus.processing),
      ]) {
        manager.tasks[0] = task;
        expect(
          await manager.materializeInitialTypedDocumentReviewDraft(_rd0Attempt),
          InitialTypedDocumentReviewDraftStatus.ineligible,
        );
      }
      expect(manager.reviewDraftRevision(_rd0Attempt.taskId), 0);
    });

    test('manual Review save winning revision 1 makes RD0 a no-op', () async {
      var writes = 0;
      final manager = TaskManager.forTesting(
        saveReviewDraftCas: ({
          required taskId,
          required expectedAttempt,
          required expectedRevision,
          required questions,
          required explanationRetentionMode,
        }) async {
          writes++;
          return ReviewDraftCasResult(
            ReviewDraftCasStatus.saved,
            durableRevision: expectedRevision + 1,
          );
        },
      );
      manager.tasks.add(_rd0Task());
      final manualQuestions = <Map<String, dynamic>>[
        <String, dynamic>{..._questionWithEnvelope(), 'content': 'Manual edit'},
      ];

      final manual = manager.saveReviewDraft(
        _rd0Attempt.taskId,
        questions: manualQuestions,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );
      final rd0 =
          manager.materializeInitialTypedDocumentReviewDraft(_rd0Attempt);
      expect((await manual).revision, 1);
      expect(
        await rd0,
        InitialTypedDocumentReviewDraftStatus.alreadyMaterialized,
      );
      expect(writes, 1);
      expect(manager.tasks.single.parsedData!.single['content'], 'Manual edit');
    });

    test('failed RD0 keeps parsed review available for first manual save',
        () async {
      var writes = 0;
      final manager = TaskManager.forTesting(
        saveReviewDraftCas: ({
          required taskId,
          required expectedAttempt,
          required expectedRevision,
          required questions,
          required explanationRetentionMode,
        }) async {
          writes++;
          if (writes == 1) throw StateError('synthetic persistence failure');
          return ReviewDraftCasResult(
            ReviewDraftCasStatus.saved,
            durableRevision: expectedRevision + 1,
          );
        },
      );
      manager.tasks.add(_rd0Task());

      expect(
        await manager.materializeInitialTypedDocumentReviewDraft(_rd0Attempt),
        InitialTypedDocumentReviewDraftStatus.failed,
      );
      expect(manager.tasks.single.status, TaskStatus.pendingReview);
      expect(manager.tasks.single.parsedData, hasLength(1));
      expect(manager.reviewDraftRevision(_rd0Attempt.taskId), 0);
      final manual = await manager.saveReviewDraft(
        _rd0Attempt.taskId,
        questions: manager.tasks.single.parsedData!,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );
      expect(manual.status, ReviewDraftSaveStatus.saved);
      expect(manual.revision, 1);
    });

    test('CAS rejection is ineligible and preserves the manual Review payload',
        () async {
      final manager = TaskManager.forTesting(
        saveReviewDraftCas: ({
          required taskId,
          required expectedAttempt,
          required expectedRevision,
          required questions,
          required explanationRetentionMode,
        }) async =>
            const ReviewDraftCasResult(
          ReviewDraftCasStatus.invalidMetadata,
          durableRevision: null,
        ),
      );
      manager.tasks.add(_rd0Task());

      expect(
        await manager.materializeInitialTypedDocumentReviewDraft(_rd0Attempt),
        InitialTypedDocumentReviewDraftStatus.ineligible,
      );
      expect(manager.tasks.single.status, TaskStatus.pendingReview);
      expect(manager.tasks.single.parsedData, hasLength(1));
      expect(manager.reviewDraftRevision(_rd0Attempt.taskId), 0);
    });

    test('frozen document target survives review transition and retry',
        () async {
      final manager = TaskManager.forTesting();
      final task = _rd0Task(
        status: TaskStatus.processing,
        attemptState: 'queued',
      );
      manager.tasks.add(task);
      expect(
        await manager.requireAttemptReview(
          _rd0Attempt,
          'Ready',
          <Map<String, dynamic>>[_questionWithEnvelope()],
          '',
          '',
        ),
        ImportAttemptWriteStatus.applied,
      );
      expect(manager.tasks.single.bankName, 'Synthetic bank');
      expect(manager.tasks.single.folderName, 'Synthetic folder');

      final conflicting = _rd0Task(
        status: TaskStatus.processing,
        attemptState: 'queued',
      );
      manager.tasks[0] = conflicting;
      expect(
        await manager.requireAttemptReview(
          _rd0Attempt,
          'Ready',
          <Map<String, dynamic>>[_questionWithEnvelope()],
          'Other bank',
          'Synthetic folder',
        ),
        ImportAttemptWriteStatus.invalidState,
      );
      expect(manager.tasks.single.status, TaskStatus.processing);
      expect(manager.tasks.single.bankName, 'Synthetic bank');
      expect(
        await manager.requireAttemptReview(
          _rd0Attempt,
          'Ready',
          <Map<String, dynamic>>[_questionWithEnvelope()],
          'Synthetic bank',
          'Other folder',
        ),
        ImportAttemptWriteStatus.invalidState,
      );

      manager.tasks[0] = _rd0Task(
        status: TaskStatus.error,
        attemptState: 'failed',
      );
      const retry = ImportAttemptRef(
        taskId: 'rd0-task',
        attemptNumber: 2,
        attemptToken: 'rd0-attempt-2',
        traceId: 'rd0-trace-2',
      );
      expect(
        await manager.restartAttempt(
          retry,
          parseMode: 'ocr',
          explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
        ),
        ImportAttemptWriteStatus.applied,
      );
      expect(manager.tasks.single.bankName, 'Synthetic bank');
      expect(manager.tasks.single.folderName, 'Synthetic folder');

      manager.tasks[0] = _rd0Task(
        document: false,
        status: TaskStatus.processing,
        attemptState: 'queued',
      );
      expect(
        await manager.requireAttemptReview(
          _rd0Attempt,
          'Ready',
          <Map<String, dynamic>>[_questionWithEnvelope()],
          '',
          '',
        ),
        ImportAttemptWriteStatus.applied,
      );
      expect(manager.tasks.single.bankName, '');
      expect(manager.tasks.single.folderName, '');
    });
    test('ImportTask.toMap/fromMap preserves the per-question envelope', () {
      final task = ImportTask(
        id: 'round-trip-task',
        title: 'Synthetic typed task',
        status: TaskStatus.pendingReview,
        parsedData: <Map<String, dynamic>>[
          _questionWithEnvelope(),
        ],
      );

      final restored = ImportTask.fromMap(task.toMap());
      final question = restored.parsedData!.single;

      expect(
          question, containsPair(TypedReviewSnapshotCodec.mapKey, isA<Map>()));
      expect(
        _json(question[TypedReviewSnapshotCodec.mapKey]),
        _json(_envelope()),
      );
    });

    test('ImportTask.toMap/fromMap preserves route and reason scalars', () {
      final task = ImportTask(
        id: 'route-round-trip-task',
        title: 'Synthetic typed task',
        status: TaskStatus.pendingReview,
        diagnostics: _routeDiagnostics(),
      );

      final restored = ImportTask.fromMap(task.toMap());
      expect(
        restored.diagnostics?[TaskManager.keyImportStorageRoute],
        'typedV2',
      );
      expect(
        restored.diagnostics?[TaskManager.keyImportStorageReason],
        'typed_candidate_ready',
      );
    });

    test('requireAttemptReview and deduplication preserve the envelope',
        () async {
      final saved = <Map<String, dynamic>>[];
      final taskManager = TaskManager.forTesting(
        saveTask: (taskMap) async {
          saved.add(Map<String, dynamic>.from(taskMap));
        },
      );
      const attempt = ImportAttemptRef(
        taskId: 'attempt-task',
        attemptNumber: 1,
        attemptToken: 'attempt-1',
        traceId: 'trace-1',
      );
      await taskManager.addAttemptTask(
        ImportTask(
          id: attempt.taskId,
          title: 'Synthetic attempt task',
          diagnostics: <String, dynamic>{
            TaskManager.keyTraceId: 'trace-1',
            TaskManager.keyParseMode: 'ocr',
            TaskManager.keyAttemptNumber: 1,
            TaskManager.keyAttemptToken: 'attempt-1',
            TaskManager.keyAttemptState: 'queued',
            ..._routeDiagnostics(),
          },
        ),
      );

      final duplicate = _questionWithEnvelope();
      final status = await taskManager.requireAttemptReview(
        attempt,
        'Ready for review',
        <Map<String, dynamic>>[duplicate, _questionWithEnvelope()],
        'Synthetic bank',
        'Synthetic folder',
      );
      expect(status, ImportAttemptWriteStatus.applied);

      final last = ImportTask.fromMap(saved.last);
      expect(last.parsedData, hasLength(1));
      expect(
        _json(last.parsedData!.single[TypedReviewSnapshotCodec.mapKey]),
        _json(_envelope()),
      );
      expect(
        last.diagnostics?[TaskManager.keyImportStorageRoute],
        'typedV2',
      );
    });

    test('save then reload preserves envelope, route and reason', () async {
      final saved = <Map<String, dynamic>>[];
      final writer = TaskManager.forTesting(
        saveTask: (taskMap) async {
          saved.add(Map<String, dynamic>.from(taskMap));
        },
      );
      writer.addTask(
        ImportTask(
          id: 'reload-task',
          title: 'Synthetic typed task',
          status: TaskStatus.pendingReview,
          parsedData: <Map<String, dynamic>>[
            _questionWithEnvelope(),
          ],
          diagnostics: _routeDiagnostics(),
        ),
      );
      await writer.ready;

      final reader = TaskManager.forTesting(
        loadTasks: () async => List<Map<String, dynamic>>.from(saved),
      );
      await reader.ready;

      final restored = reader.tasks.single;
      expect(
        _json(
          restored.parsedData!.single[TypedReviewSnapshotCodec.mapKey],
        ),
        _json(_envelope()),
      );
      expect(
        restored.diagnostics?[TaskManager.keyImportStorageRoute],
        'typedV2',
      );
      expect(
        restored.diagnostics?[TaskManager.keyImportStorageReason],
        'typed_candidate_ready',
      );
    });

    test('saveReviewDraft preserves the envelope', () async {
      final saved = <Map<String, dynamic>>[];
      final taskManager = TaskManager.forTesting(
        saveTask: (taskMap) async {
          saved.add(Map<String, dynamic>.from(taskMap));
        },
      );
      taskManager.addTask(
        ImportTask(
          id: 'draft-task',
          title: 'Synthetic typed task',
          status: TaskStatus.pendingReview,
          parsedData: <Map<String, dynamic>>[
            _questionWithEnvelope(),
          ],
        ),
      );

      final result = await taskManager.saveReviewDraft(
        'draft-task',
        questions: <Map<String, dynamic>>[
          _questionWithEnvelope(envelope: _envelope()),
        ],
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );
      expect(result.saved, isTrue);

      final last = ImportTask.fromMap(saved.last);
      expect(
        _json(last.parsedData!.single[TypedReviewSnapshotCodec.mapKey]),
        _json(_envelope()),
      );
    });

    test('review retention updates its own key without overwriting parse mode',
        () async {
      for (final values in <({
        ExplanationRetentionMode parse,
        ExplanationRetentionMode review,
      })>[
        (
          parse: ExplanationRetentionMode.allQuestionTypes,
          review: ExplanationRetentionMode.subjectiveOnly,
        ),
        (
          parse: ExplanationRetentionMode.subjectiveOnly,
          review: ExplanationRetentionMode.allQuestionTypes,
        ),
      ]) {
        final saved = <Map<String, dynamic>>[];
        final taskManager = TaskManager.forTesting(
          saveTask: (taskMap) async {
            saved.add(Map<String, dynamic>.from(taskMap));
          },
        );
        taskManager.addTask(
          ImportTask(
            id: 'retention-authority-${values.parse.name}',
            title: 'Synthetic retention authority task',
            status: TaskStatus.pendingReview,
            parsedData: <Map<String, dynamic>>[
              _questionWithEnvelope(),
            ],
            diagnostics: <String, dynamic>{
              TaskManager.keyParseExplanationRetentionMode: values.parse.name,
              TaskManager.keyReviewExplanationRetentionMode: values.parse.name,
              TaskManager.keyExplanationRetentionMode: values.parse.name,
            },
          ),
        );

        final result = await taskManager.saveReviewDraft(
          'retention-authority-${values.parse.name}',
          questions: <Map<String, dynamic>>[
            _questionWithEnvelope(),
          ],
          explanationRetentionMode: values.review,
        );

        expect(result.saved, isTrue);
        final restored = ImportTask.fromMap(saved.last);
        expect(restored.parseExplanationRetentionMode, values.parse);
        expect(restored.explanationRetentionMode, values.parse);
        expect(restored.reviewExplanationRetentionMode, values.review);
        expect(
          restored.diagnostics?[TaskManager.keyParseExplanationRetentionMode],
          values.parse.name,
        );
        expect(
          restored.diagnostics?[TaskManager.keyReviewExplanationRetentionMode],
          values.review.name,
        );
        expect(
          restored.diagnostics?[TaskManager.keyExplanationRetentionMode],
          values.review.name,
        );
      }
    });

    test('legacy compatibility retention is frozen before review overwrite',
        () async {
      final saved = <Map<String, dynamic>>[];
      final taskManager = TaskManager.forTesting(
        saveTask: (taskMap) async {
          saved.add(Map<String, dynamic>.from(taskMap));
        },
      );
      taskManager.addTask(
        ImportTask(
          id: 'legacy-retention-authority',
          title: 'Synthetic legacy retention authority task',
          status: TaskStatus.pendingReview,
          parsedData: <Map<String, dynamic>>[
            _questionWithEnvelope(),
          ],
          diagnostics: <String, dynamic>{
            TaskManager.keyExplanationRetentionMode:
                ExplanationRetentionMode.allQuestionTypes.name,
          },
        ),
      );

      final result = await taskManager.saveReviewDraft(
        'legacy-retention-authority',
        questions: <Map<String, dynamic>>[
          _questionWithEnvelope(),
        ],
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result.saved, isTrue);
      final current = taskManager.tasks.single;
      final restored = ImportTask.fromMap(saved.last);
      for (final task in <ImportTask>[current, restored]) {
        expect(
          task.parseExplanationRetentionMode,
          ExplanationRetentionMode.allQuestionTypes,
        );
        expect(
          task.reviewExplanationRetentionMode,
          ExplanationRetentionMode.subjectiveOnly,
        );
        expect(
          task.diagnostics?[TaskManager.keyParseExplanationRetentionMode],
          ExplanationRetentionMode.allQuestionTypes.name,
        );
        expect(
          task.diagnostics?[TaskManager.keyReviewExplanationRetentionMode],
          ExplanationRetentionMode.subjectiveOnly.name,
        );
        expect(
          task.diagnostics?[TaskManager.keyExplanationRetentionMode],
          ExplanationRetentionMode.subjectiveOnly.name,
        );
      }
    });

    test('answer distillation state update preserves the envelope', () async {
      final saved = <Map<String, dynamic>>[];
      final taskManager = TaskManager.forTesting(
        saveTask: (taskMap) async {
          saved.add(Map<String, dynamic>.from(taskMap));
        },
      );
      taskManager.addTask(
        ImportTask(
          id: 'distill-task',
          title: 'Synthetic typed task',
          status: TaskStatus.pendingReview,
          parsedData: <Map<String, dynamic>>[
            _questionWithEnvelope(),
          ],
        ),
      );

      final result = await taskManager.mergeReviewDraftAnswerDistillation(
        'distill-task',
        reviewItemId: 'review-item-1',
        expectedRevision: 0,
        status: 'ai_applied',
        standardAnswer: 'A',
      );
      expect(result.saved, isTrue);

      final last = ImportTask.fromMap(saved.last);
      final question = last.parsedData!.single;
      expect(
        _json(question[TypedReviewSnapshotCodec.mapKey]),
        _json(_envelope()),
      );
      expect(question[TaskManager.keyAnswerDistillationStatus], 'ai_applied');
      expect(question['standard_answer'], 'A');
    });

    test('stale review draft writes never replace a newer envelope', () async {
      final saved = <Map<String, dynamic>>[];
      final taskManager = TaskManager.forTesting(
        saveTask: (taskMap) async {
          saved.add(Map<String, dynamic>.from(taskMap));
        },
      );
      taskManager.addTask(
        ImportTask(
          id: 'stale-task',
          title: 'Synthetic typed task',
          status: TaskStatus.pendingReview,
          parsedData: <Map<String, dynamic>>[
            _questionWithEnvelope(),
          ],
        ),
      );

      final newer = await taskManager.saveReviewDraft(
        'stale-task',
        questions: <Map<String, dynamic>>[
          _questionWithEnvelope(
            number: 1,
            envelope: _envelope(),
            includeReviewItemId: true,
          ),
        ],
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );
      expect(newer.saved, isTrue);
      expect(newer.revision, 1);

      final stale = await taskManager.mergeReviewDraftAnswerDistillation(
        'stale-task',
        reviewItemId: 'review-item-1',
        expectedRevision: 0,
        status: 'ai_applied',
        standardAnswer: 'stale answer',
      );
      expect(stale.saved, isFalse);
      expect(stale.status, ReviewDraftSaveStatus.stale);

      final last = ImportTask.fromMap(saved.last);
      expect(
        _json(last.parsedData!.single[TypedReviewSnapshotCodec.mapKey]),
        _json(_envelope()),
      );
      expect(
        last.parsedData!.single['standard_answer'],
        isNot('stale answer'),
      );
    });

    test('historical legacy tasks without route or envelope still load',
        () async {
      final persisted = ImportTask(
        id: 'legacy-task',
        title: 'Historical legacy task',
        status: TaskStatus.pendingReview,
        parsedData: <Map<String, dynamic>>[
          <String, dynamic>{
            'q_num': 1,
            'type': 0,
            'content': 'Synthetic legacy question',
            'options': <String>['A', 'B'],
            'standard_answer': 'A',
          },
        ],
      ).toMap();

      final reader = TaskManager.forTesting(
        loadTasks: () async => <Map<String, dynamic>>[persisted],
      );
      await reader.ready;

      final restored = reader.tasks.single;
      expect(restored.parsedData, hasLength(1));
      expect(
        restored.parsedData!.single,
        isNot(contains(TypedReviewSnapshotCodec.mapKey)),
      );
      expect(
        decodeImportStorageRoute(
          restored.diagnostics?[TaskManager.keyImportStorageRoute],
        ),
        ImportStorageRoute.legacyV1,
      );
    });

    test('attachDiagnostics preserves route and reason metadata', () {
      final taskManager = TaskManager.forTesting();
      taskManager.addTask(
        ImportTask(
          id: 'attach-task',
          title: 'Synthetic typed task',
          status: TaskStatus.pendingReview,
          diagnostics: _routeDiagnostics(),
        ),
      );

      taskManager.attachDiagnostics(
        'attach-task',
        diagnostics: const <String, dynamic>{'safeCount': 1},
      );

      final task = taskManager.tasks.single;
      expect(task.diagnostics?['safeCount'], 1);
      expect(
        task.diagnostics?[TaskManager.keyImportStorageRoute],
        'typedV2',
      );
      expect(
        task.diagnostics?[TaskManager.keyImportStorageReason],
        'typed_candidate_ready',
      );
    });

    test('restartAttempt preserves route and reason metadata', () async {
      final saved = <Map<String, dynamic>>[];
      final taskManager = TaskManager.forTesting(
        saveTask: (taskMap) async {
          saved.add(Map<String, dynamic>.from(taskMap));
        },
      );
      const firstAttempt = ImportAttemptRef(
        taskId: 'restart-task',
        attemptNumber: 1,
        attemptToken: 'attempt-1',
        traceId: 'trace-1',
      );
      await taskManager.addAttemptTask(
        ImportTask(
          id: firstAttempt.taskId,
          title: 'Synthetic typed task',
          diagnostics: <String, dynamic>{
            TaskManager.keyTraceId: 'trace-1',
            TaskManager.keyParseMode: 'ocr',
            TaskManager.keyAttemptNumber: 1,
            TaskManager.keyAttemptToken: 'attempt-1',
            TaskManager.keyAttemptState: 'failed',
            ..._routeDiagnostics(),
          },
        ),
      );

      const secondAttempt = ImportAttemptRef(
        taskId: 'restart-task',
        attemptNumber: 2,
        attemptToken: 'attempt-2',
        traceId: 'trace-2',
      );
      final status = await taskManager.restartAttempt(
        secondAttempt,
        parseMode: 'ocr',
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );
      expect(status, ImportAttemptWriteStatus.applied);

      final current = taskManager.tasks.single;
      expect(
        current.diagnostics?[TaskManager.keyImportStorageRoute],
        'typedV2',
      );
      expect(
        current.diagnostics?[TaskManager.keyImportStorageReason],
        'typed_candidate_ready',
      );
      final last = ImportTask.fromMap(saved.last);
      expect(
        last.diagnostics?[TaskManager.keyImportStorageRoute],
        'typedV2',
      );
      expect(
        last.diagnostics?[TaskManager.keyImportStorageReason],
        'typed_candidate_ready',
      );
    });
  });
}
