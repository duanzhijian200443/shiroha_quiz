// R7C.1 shared persistence contract: the immutable commit guard, the atomic
// persistence result, the fixed repository failure taxonomy and the frozen
// persistence constants shared by TaskManager, the repository and the commit
// service. The frozen status codes are asserted against TaskStatus indices so
// an enum reorder can never silently change persisted behavior.
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/typed_import_commit_guard.dart';
import 'package:shiroha_quiz/services/task_manager.dart';

void main() {
  test('guard exposes the frozen attempt ownership fields', () {
    const guard = TypedImportCommitGuard(
      taskId: 'synthetic-task',
      attemptToken: 'synthetic-attempt',
      attemptNumber: 7,
      reviewDraftRevision: 3,
      storageRoute: TypedImportCommitPersistence.typedV2RouteValue,
      storageReason:
          TypedImportCommitPersistence.typedCandidateReadyReasonValue,
    );

    expect(guard.taskId, 'synthetic-task');
    expect(guard.attemptToken, 'synthetic-attempt');
    expect(guard.attemptNumber, 7);
    expect(guard.reviewDraftRevision, 3);
    expect(guard.storageRoute, 'typedV2');
    expect(guard.storageReason, 'typed_candidate_ready');
  });

  test('persistence result carries question count and completed timestamp', () {
    const result = TypedImportCommitPersistenceResult(
      questionCount: 12,
      completedAt: 1700000000,
    );

    expect(result.questionCount, 12);
    expect(result.completedAt, 1700000000);
  });

  test('fixed persistence failure taxonomy has all frozen values', () {
    expect(
      TypedImportCommitPersistenceFailure.values,
      <TypedImportCommitPersistenceFailure>[
        TypedImportCommitPersistenceFailure.taskMissing,
        TypedImportCommitPersistenceFailure.taskNotPendingReview,
        TypedImportCommitPersistenceFailure.staleAttempt,
        TypedImportCommitPersistenceFailure.invalidTaskMetadata,
        TypedImportCommitPersistenceFailure.staleReviewDraft,
        TypedImportCommitPersistenceFailure.alreadyCompleted,
        TypedImportCommitPersistenceFailure.transactionFailed,
      ],
    );
  });

  test('persistence exceptions carry only the enum and fixed text', () {
    for (final failure in TypedImportCommitPersistenceFailure.values) {
      const exception = TypedImportCommitPersistenceException(
        TypedImportCommitPersistenceFailure.taskMissing,
      );
      expect(exception.failure, isA<TypedImportCommitPersistenceFailure>());
      expect(exception.toString(), isNot(contains('SQL')));
      expect(exception.toString(), isNot(contains('synthetic-task')));
      expect(exception.toString(), isNot(contains('synthetic-attempt')));
      expect(exception.toString(), isNot(contains('diagnostics')));
      expect(failure, isNotNull);
    }
  });

  test('frozen keys match the TaskManager public aliases', () {
    expect(
      TaskManager.keyImportStorageRoute,
      TypedImportCommitPersistence.keyImportStorageRoute,
    );
    expect(
      TaskManager.keyImportStorageReason,
      TypedImportCommitPersistence.keyImportStorageReason,
    );
    expect(
      TaskManager.keyAttemptNumber,
      TypedImportCommitPersistence.keyAttemptNumber,
    );
    expect(
      TaskManager.keyAttemptToken,
      TypedImportCommitPersistence.keyAttemptToken,
    );
    expect(
      TaskManager.keyAttemptState,
      TypedImportCommitPersistence.keyAttemptState,
    );
    expect(
      TaskManager.keyReviewDraftRevision,
      TypedImportCommitPersistence.keyReviewDraftRevision,
    );
  });

  test('frozen persisted status codes equal the TaskStatus indices', () {
    expect(
      TaskStatus.pendingReview.index,
      TypedImportCommitPersistence.pendingReviewStatusCode,
      reason: 'persisted pendingReview code must stay frozen at 1',
    );
    expect(
      TaskStatus.completed.index,
      TypedImportCommitPersistence.completedStatusCode,
      reason: 'persisted completed code must stay frozen at 2',
    );
  });

  test('frozen route/reason/attempt-state values are exact', () {
    expect(TypedImportCommitPersistence.typedV2RouteValue, 'typedV2');
    expect(
      TypedImportCommitPersistence.typedCandidateReadyReasonValue,
      'typed_candidate_ready',
    );
    expect(
      TypedImportCommitPersistence.readyForReviewAttemptStateValue,
      'readyForReview',
    );
  });
}
