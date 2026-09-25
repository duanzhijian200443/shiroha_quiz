import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import/import_advanced_preferences.dart';
import 'package:shiroha_quiz/application/import/import_target_catalog_service.dart';
import 'package:shiroha_quiz/application/import/import_target_selection.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/data/models/typed_import_commit_guard.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_review/import_commit_service.dart';
import 'package:shiroha_quiz/services/import_review/import_perfect_auto_commit_service.dart';
import 'package:shiroha_quiz/services/task_manager.dart';

const _taskId = 'perfect-task';
const _token = 'perfect-attempt';
const _trace = 'perfect-trace';
const _questionId = '66666666-6666-4666-8666-666666666666';
const _itemId = '77777777-7777-4777-8777-777777777777';
const _sourceId = '88888888-8888-4888-8888-888888888888';

final class _Repository extends Fake implements QuestionRepository {
  int typedWrites = 0;
  int legacyWrites = 0;
  TypedImportCommitGuard? guard;
  Completer<void>? pause;
  Completer<void>? entered;
  Object? failure;

  @override
  Future<TypedImportCommitPersistenceResult> commitQuestionDraftsV2ForImport({
    required String bankName,
    String? folderName,
    required List<QuestionDraftV2> questions,
    required TypedImportCommitGuard guard,
    required String completionText,
  }) async {
    typedWrites++;
    entered?.complete();
    this.guard = guard;
    if (pause case final gate?) await gate.future;
    if (failure case final error?) throw error;
    return TypedImportCommitPersistenceResult(
      questionCount: questions.length,
      completedAt: 1700000000,
    );
  }

  @override
  Future<LegacyImportCommitPersistenceResult>
      commitQuestionDraftsLegacyForImport({
    required String bankName,
    String? folderName,
    required List<QuestionDraft> questions,
    required LegacyImportCommitGuard guard,
    required String completionText,
  }) async {
    legacyWrites++;
    return LegacyImportCommitPersistenceResult(
      questionCount: questions.length,
      completedAt: 1700000000,
    );
  }
}

final class _EmptyCatalog implements ImportTargetCatalogPort {
  @override
  Future<List<ImportTargetSummary>> listImportTargets() async => const [];

  @override
  Future<List<String>> listAvailableFolders() async => const [];
}

final class _NoopSelectionStore implements ImportTargetSelectionStore {
  @override
  Future<ImportTargetSelection?> getLastImportTarget() async => null;

  @override
  Future<void> setLastImportTarget(ImportTargetSelection? selection) async {}
}

Map<String, dynamic> _question({bool informationalOnly = false}) {
  final draft = QuestionDraftV2(
    questionId: _questionId,
    kind: QuestionKind.shortAnswer,
    questionNumber: 1,
    stem: RichContent(nodes: [TextNode('Synthetic stem')]),
    answer: ContentAnswer(
      content: RichContent(nodes: [TextNode('Conclusion')]),
    ),
    explanation: RichContent(nodes: [TextNode('Explanation')]),
    sourceRefs: [SourceRef.document(sourceId: _sourceId, displayLabel: null)],
  );
  return <String, dynamic>{
    'q_num': 1,
    'type': 3,
    'content': 'Synthetic stem',
    'options': <String>[],
    'standard_answer': 'Conclusion',
    'explanation': 'Explanation',
    '_explanation_edit_provenance': 'untouched',
    if (informationalOnly)
      '_import_review': <String, dynamic>{
        'source': 'vision',
        'sources': <String>['vision'],
        'fragmentKinds': <String>['fullQuestion'],
        'originalIndices': <int>[0],
        'riskHints': <String>['vision_only'],
      },
    TypedReviewSnapshotCodec.mapKey: const TypedReviewSnapshotCodec().encode(
      TypedReviewSnapshot(
        reviewItemId: _itemId,
        questionId: _questionId,
        draft: draft,
        baselineLegacy: LegacyReviewBaseline(
          type: 3,
          questionNumber: 1,
          content: 'Synthetic stem',
          options: <String>[],
          standardAnswer: 'Conclusion',
          explanation: 'Explanation',
        ),
      ),
    ),
  };
}

ImportTask _task(
        {int revision = 1,
        bool typed = true,
        bool informationalOnly = false,
        ImportTargetKind kind = ImportTargetKind.proposedNew}) =>
    ImportTask(
      id: _taskId,
      title: 'Synthetic import',
      status: TaskStatus.pendingReview,
      bankName: '考研数学一',
      folderName: '数学',
      parsedData: [_question(informationalOnly: informationalOnly)],
      diagnostics: <String, dynamic>{
        TaskManager.keyTraceId: _trace,
        TaskManager.keyAttemptToken: _token,
        TaskManager.keyAttemptNumber: 1,
        TaskManager.keyAttemptState: ImportAttemptState.readyForReview.name,
        TaskManager.keyReviewDraftRevision: revision,
        TaskManager.keyImportStorageRoute: typed ? 'typedV2' : 'legacyV1',
        TaskManager.keyImportStorageReason:
            typed ? 'typed_candidate_ready' : 'legacy_fallback',
        documentImportEntryMarkerKey: documentImportEntryMarkerValue,
        importTargetKindMarkerKey: kind.name,
        TaskManager.keyReviewExplanationRetentionMode:
            ExplanationRetentionMode.allQuestionTypes.name,
      },
    );

void main() {
  final attempt = ImportAttemptRef(
    taskId: _taskId,
    attemptNumber: 1,
    attemptToken: _token,
    traceId: _trace,
  );
  late TaskManager manager;
  late _Repository repository;
  late ImportPerfectAutoCommitService service;

  setUp(() async {
    manager = TaskManager.forTesting();
    await manager.ready;
    repository = _Repository();
    service = ImportPerfectAutoCommitService(
      taskManager: manager,
      commitService: ImportCommitService(
        taskManager: manager,
        questionRepository: repository,
      ),
      preferencesLoader: () async =>
          const ImportAdvancedPreferences(autoCommitPerfectImports: true),
    );
  });

  test('clean durable typed draft commits through the existing CAS writer',
      () async {
    manager.addTask(_task());
    final outcome = await service.tryCommit(attempt);
    expect(outcome.status, ImportPerfectAutoCommitStatus.committed);
    expect(outcome.questionCount, 1);
    expect(repository.typedWrites, 1);
    expect(repository.legacyWrites, 0);
    expect(repository.guard?.reviewDraftRevision, 1);
    expect(manager.tasks.single.status, TaskStatus.completed);
  });

  test('writer failure preserves Review and parsed payload', () async {
    repository.failure = StateError('synthetic persistence failure');
    manager.addTask(_task());
    final outcome = await service.tryCommit(attempt);
    expect(outcome.status, ImportPerfectAutoCommitStatus.reviewFallback);
    expect(manager.tasks.single.status, TaskStatus.pendingReview);
    expect(manager.tasks.single.parsedData, isNotEmpty);
    expect(manager.reviewDraftRevision(_taskId), 1);
    expect(repository.legacyWrites, 0);
  });

  test('second concurrent attempt cannot acquire the same commit lease',
      () async {
    final pause = Completer<void>();
    final entered = Completer<void>();
    repository.pause = pause;
    repository.entered = entered;
    manager.addTask(_task());
    final first = service.tryCommit(attempt);
    await entered.future;
    final second = await service.tryCommit(attempt);
    expect(second.status, isNot(ImportPerfectAutoCommitStatus.committed));
    pause.complete();
    expect((await first).status, ImportPerfectAutoCommitStatus.committed);
    expect(repository.typedWrites, 1);
  });

  test('legacy route never auto commits', () async {
    manager.addTask(_task(typed: false));
    expect((await service.tryCommit(attempt)).status,
        ImportPerfectAutoCommitStatus.notEligible);
    expect(repository.typedWrites, 0);
  });

  test('informational metadata alone does not block a score of 100', () async {
    manager.addTask(_task(informationalOnly: true));
    expect((await service.tryCommit(attempt)).status,
        ImportPerfectAutoCommitStatus.committed);
    expect(repository.typedWrites, 1);
  });

  test('deleted existing target falls back to manual Review', () async {
    manager.addTask(_task(kind: ImportTargetKind.existing));
    final guarded = ImportPerfectAutoCommitService(
      taskManager: manager,
      commitService: ImportCommitService(
          taskManager: manager, questionRepository: repository),
      preferencesLoader: () async =>
          const ImportAdvancedPreferences(autoCommitPerfectImports: true),
      targetCatalog: ImportTargetCatalogService(
        catalog: _EmptyCatalog(),
        selectionStore: _NoopSelectionStore(),
      ),
    );
    expect((await guarded.tryCommit(attempt)).status,
        ImportPerfectAutoCommitStatus.reviewFallback);
    expect(manager.tasks.single.status, TaskStatus.pendingReview);
    expect(repository.typedWrites, 0);
  });

  test('RD0 regression is surfaced without creating revision one', () async {
    manager.addTask(_task(revision: 0));
    expect((await service.tryCommit(attempt)).status,
        ImportPerfectAutoCommitStatus.lifecycleRegression);
    expect(manager.reviewDraftRevision(_taskId), 0);
    expect(repository.typedWrites, 0);
  });

  test('manual Review revision beyond RD0 is never auto committed', () async {
    manager.addTask(_task(revision: 2));
    expect((await service.tryCommit(attempt)).status,
        ImportPerfectAutoCommitStatus.notEligible);
    expect(repository.typedWrites, 0);
    expect(manager.tasks.single.status, TaskStatus.pendingReview);
  });
}
