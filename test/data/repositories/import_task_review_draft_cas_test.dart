import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/import_task_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
}
