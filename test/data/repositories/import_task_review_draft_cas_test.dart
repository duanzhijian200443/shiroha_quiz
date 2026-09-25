import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/import_task_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _rd0Attempt = ImportAttemptRef(
  taskId: 'durable-rd0-task',
  attemptNumber: 1,
  attemptToken: 'durable-rd0-attempt',
  traceId: 'durable-rd0-trace',
);

Map<String, dynamic> _typedQuestion() {
  const questionId = '1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d';
  const reviewItemId = '0d8b7a3e-7f1c-4b2a-9d3e-5a6b7c8d9e0f';
  const codec = TypedReviewSnapshotCodec();
  return <String, dynamic>{
    'q_num': 1,
    'type': 0,
    'content': 'Synthetic stem',
    'options': <String>['A'],
    'standard_answer': 'A',
    'explanation': 'Synthetic explanation',
    TaskManager.keyReviewItemId: reviewItemId,
    TypedReviewSnapshotCodec.mapKey: codec.encode(
      TypedReviewSnapshot(
        reviewItemId: reviewItemId,
        questionId: questionId,
        draft: QuestionDraftV2(
          questionId: questionId,
          kind: QuestionKind.singleChoice,
          questionNumber: 1,
          stem: RichContent(nodes: const <ContentNode>[
            TextNode('Synthetic stem'),
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
          content: 'Synthetic stem',
          options: <String>['A'],
          standardAnswer: 'A',
          explanation: 'Synthetic explanation',
        ),
      ),
    ),
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(DatabaseHelper.resetRuntimeProfileForTesting);
  tearDown(DatabaseHelper.resetRuntimeProfileForTesting);

  test(
    'two managers CAS revision N exactly once and loser sees durable N+1',
    () async {
      const taskId = 'review-draft-cas-task';
      const initialRevision = 4;
      const diagnostics = <String, Object?>{
        TaskManager.keyTraceId: 'trace-cas-1',
        TaskManager.keyAttemptToken: 'attempt-cas-1',
        TaskManager.keyAttemptNumber: 1,
        TaskManager.keyAttemptState: 'readyForReview',
        TaskManager.keyReviewDraftRevision: initialRevision,
        'sentinel': 'durable-metadata-must-survive',
      };
      final repository = ImportTaskRepository();
      await repository.saveImportTask(
        ImportTask(
          id: taskId,
          title: 'durable-title-must-survive',
          status: TaskStatus.pendingReview,
          progressText: 'durable-progress-must-survive',
          parsedData: const <Map<String, dynamic>>[
            <String, dynamic>{'content': 'revision-N'},
          ],
          diagnostics: diagnostics,
        ).toMap(),
      );

      TaskManager manager() => TaskManager.forTesting(
            loadTasks: repository.getAllImportTasks,
            saveReviewDraftCas: repository.saveReviewDraftCas,
          );

      final first = manager();
      final second = manager();
      await Future.wait(<Future<void>>[first.ready, second.ready]);

      final results = await Future.wait(<Future<ReviewDraftSaveResult>>[
        first.saveReviewDraft(
          taskId,
          questions: const <Map<String, dynamic>>[
            <String, dynamic>{'content': 'winner-A'},
          ],
          explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
        ),
        second.saveReviewDraft(
          taskId,
          questions: const <Map<String, dynamic>>[
            <String, dynamic>{'content': 'winner-B'},
          ],
          explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
        ),
      ]);

      expect(
        results.where((result) => result.status == ReviewDraftSaveStatus.saved),
        hasLength(1),
      );
      final loser = results.singleWhere(
        (result) => result.status == ReviewDraftSaveStatus.stale,
      );
      expect(loser.durableRevision, initialRevision + 1);

      final durableRows = await repository.getAllImportTasks();
      expect(durableRows, hasLength(1));
      final durable = durableRows.single;
      expect(durable['title'], 'durable-title-must-survive');
      expect(durable['progress_text'], 'durable-progress-must-survive');
      expect(durable['status'], TaskStatus.pendingReview.index);
      final durableDiagnostics =
          jsonDecode(durable['diagnostics']! as String) as Map<String, dynamic>;
      expect(
        durableDiagnostics[TaskManager.keyReviewDraftRevision],
        initialRevision + 1,
      );
      expect(durableDiagnostics['sentinel'], 'durable-metadata-must-survive');
      final durableQuestions =
          jsonDecode(durable['parsed_data']! as String) as List<dynamic>;
      expect(durableQuestions, hasLength(1));
      expect(
        <String>{'winner-A', 'winner-B'},
        contains((durableQuestions.single as Map<String, dynamic>)['content']),
      );

      // Replaying the stale manager can neither overwrite the winner nor
      // resurrect an older projection.
      final replay =
          await (identical(results[0], loser) ? first : second).saveReviewDraft(
        taskId,
        questions: const <Map<String, dynamic>>[
          <String, dynamic>{'content': 'stale-resurrection'},
        ],
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );
      expect(replay.status, ReviewDraftSaveStatus.stale);
      expect(replay.durableRevision, initialRevision + 1);
      final afterReplay = (await repository.getAllImportTasks()).single;
      expect(afterReplay['parsed_data'], durable['parsed_data']);
    },
  );

  test(
    'durable CAS freezes legacy parse retention before review overwrite',
    () async {
      const taskId = 'legacy-retention-review-draft-cas-task';
      final repository = ImportTaskRepository();
      await repository.saveImportTask(
        ImportTask(
          id: taskId,
          title: 'Synthetic legacy retention task',
          status: TaskStatus.pendingReview,
          parsedData: const <Map<String, dynamic>>[
            <String, dynamic>{'content': 'before-review'},
          ],
          diagnostics: const <String, Object?>{
            TaskManager.keyExplanationRetentionMode: 'allQuestionTypes',
            TaskManager.keyReviewDraftRevision: 0,
          },
        ).toMap(),
      );

      final manager = TaskManager.forTesting(
        loadTasks: repository.getAllImportTasks,
        saveReviewDraftCas: repository.saveReviewDraftCas,
      );
      await manager.ready;

      final before = manager.tasks.singleWhere((task) => task.id == taskId);
      expect(
        before.diagnostics,
        isNot(contains(TaskManager.keyParseExplanationRetentionMode)),
      );
      expect(
        before.parseExplanationRetentionMode,
        ExplanationRetentionMode.allQuestionTypes,
      );

      final result = await manager.saveReviewDraft(
        taskId,
        questions: const <Map<String, dynamic>>[
          <String, dynamic>{'content': 'after-review'},
        ],
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );
      expect(result.status, ReviewDraftSaveStatus.saved);

      final durable = ImportTask.fromMap(
        (await repository.getAllImportTasks())
            .singleWhere((row) => row['id'] == taskId),
      );
      expect(
        durable.parseExplanationRetentionMode,
        ExplanationRetentionMode.allQuestionTypes,
      );
      expect(
        durable.reviewExplanationRetentionMode,
        ExplanationRetentionMode.subjectiveOnly,
      );
      expect(
        durable.diagnostics?[TaskManager.keyParseExplanationRetentionMode],
        ExplanationRetentionMode.allQuestionTypes.name,
      );
      expect(
        durable.diagnostics?[TaskManager.keyReviewExplanationRetentionMode],
        ExplanationRetentionMode.subjectiveOnly.name,
      );
      expect(
        durable.diagnostics?[TaskManager.keyExplanationRetentionMode],
        ExplanationRetentionMode.subjectiveOnly.name,
      );
    },
  );

  test('RD0 revision 1 survives restart with typed envelope and frozen target',
      () async {
    final repository = ImportTaskRepository();
    await repository.saveImportTask(
      ImportTask(
        id: _rd0Attempt.taskId,
        title: 'Synthetic typed document',
        status: TaskStatus.pendingReview,
        bankName: 'Synthetic bank',
        folderName: 'Synthetic folder',
        parsedData: <Map<String, dynamic>>[_typedQuestion()],
        diagnostics: <String, dynamic>{
          TaskManager.keyTraceId: _rd0Attempt.traceId,
          TaskManager.keyAttemptToken: _rd0Attempt.attemptToken,
          TaskManager.keyAttemptNumber: _rd0Attempt.attemptNumber,
          TaskManager.keyAttemptState: 'readyForReview',
          documentImportEntryMarkerKey: documentImportEntryMarkerValue,
          TaskManager.keyImportStorageRoute: 'typedV2',
          TaskManager.keyImportStorageReason: 'typed_candidate_ready',
          TaskManager.keyParseExplanationRetentionMode: 'allQuestionTypes',
          TaskManager.keyReviewExplanationRetentionMode: 'subjectiveOnly',
        },
      ).toMap(),
    );
    TaskManager manager() => TaskManager.forTesting(
          loadTasks: repository.getAllImportTasks,
          saveReviewDraftCas: repository.saveReviewDraftCas,
        );
    final first = manager();
    await first.ready;

    expect(
      await first.materializeInitialTypedDocumentReviewDraft(_rd0Attempt),
      InitialTypedDocumentReviewDraftStatus.materialized,
    );
    final restarted = manager();
    await restarted.ready;
    final loaded = restarted.tasks.single;
    expect(loaded.status, TaskStatus.pendingReview);
    expect(loaded.bankName, 'Synthetic bank');
    expect(loaded.folderName, 'Synthetic folder');
    expect(restarted.reviewDraftRevision(_rd0Attempt.taskId), 1);
    expect(
      loaded.parsedData!.single[TypedReviewSnapshotCodec.mapKey],
      _typedQuestion()[TypedReviewSnapshotCodec.mapKey],
    );
    expect(
      await restarted.materializeInitialTypedDocumentReviewDraft(_rd0Attempt),
      InitialTypedDocumentReviewDraftStatus.alreadyMaterialized,
    );
    expect(
      (await restarted.saveReviewDraft(
        _rd0Attempt.taskId,
        questions: loaded.parsedData!,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      ))
          .revision,
      2,
    );
  });
}
