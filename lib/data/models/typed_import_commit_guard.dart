/// Frozen shared persistence contract for the attempt-aware typed import
/// commit.
///
/// The data layer must never import `services/task_manager.dart` or any UI
/// file. [TypedImportCommitGuard] and the fixed constants below are the
/// single source of truth shared by `TaskManager` (in-memory gate), the
/// repository (persisted gate) and `ImportCommitService` (guard assembly).
final class TypedImportCommitGuard {
  const TypedImportCommitGuard({
    required this.taskId,
    required this.attemptToken,
    required this.attemptNumber,
    required this.reviewDraftRevision,
    required this.storageRoute,
    required this.storageReason,
  });

  final String taskId;
  final String attemptToken;
  final int attemptNumber;
  final int reviewDraftRevision;
  final String storageRoute;
  final String storageReason;
}

/// Immutable result of one atomic typed import commit transaction.
final class TypedImportCommitPersistenceResult {
  const TypedImportCommitPersistenceResult({
    required this.questionCount,
    required this.completedAt,
  });

  final int questionCount;
  final int completedAt;
}

/// Fixed failure classification of the repository-level atomic typed import
/// commit. Exceptions carry only the enum; no cause, SQL, diagnostics JSON,
/// question content, path, token, task id, source id or database message.
enum TypedImportCommitPersistenceFailure {
  taskMissing,
  taskNotPendingReview,
  staleAttempt,
  invalidTaskMetadata,
  staleReviewDraft,
  alreadyCompleted,
  transactionFailed,
}

final class TypedImportCommitPersistenceException implements Exception {
  const TypedImportCommitPersistenceException(this.failure);

  final TypedImportCommitPersistenceFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      TypedImportCommitPersistenceFailure.taskMissing =>
        'The import task does not exist.',
      TypedImportCommitPersistenceFailure.taskNotPendingReview =>
        'The import task is not pending review.',
      TypedImportCommitPersistenceFailure.staleAttempt =>
        'The import task attempt does not match.',
      TypedImportCommitPersistenceFailure.invalidTaskMetadata =>
        'The import task metadata is invalid.',
      TypedImportCommitPersistenceFailure.staleReviewDraft =>
        'The import task review draft is stale.',
      TypedImportCommitPersistenceFailure.alreadyCompleted =>
        'The import task is already completed.',
      TypedImportCommitPersistenceFailure.transactionFailed =>
        'The typed import commit transaction failed.',
    };
    return 'TypedImportCommitPersistenceException(${failure.name}): $detail';
  }
}

/// Fixed persistence constants shared by the in-memory task gate, the
/// persisted `import_tasks` gate and the commit guard.
///
/// `TaskManager` aliases its public diagnostic keys to these constants so no
/// second string set can drift. The persisted status codes are frozen:
/// `TaskStatus.pendingReview.index == [pendingReviewStatusCode]` and
/// `TaskStatus.completed.index == [completedStatusCode]` are enforced by
/// test.
abstract final class TypedImportCommitPersistence {
  static const String keyImportStorageRoute = '_importStorageRoute';
  static const String keyImportStorageReason = '_importStorageReason';
  static const String keyAttemptNumber = '_attemptNumber';
  static const String keyAttemptToken = '_attemptToken';
  static const String keyAttemptState = '_attemptState';
  static const String keyReviewDraftRevision = '_reviewDraftRevision';

  static const String typedV2RouteValue = 'typedV2';
  static const String typedCandidateReadyReasonValue = 'typed_candidate_ready';
  static const String readyForReviewAttemptStateValue = 'readyForReview';

  static const int pendingReviewStatusCode = 1;
  static const int completedStatusCode = 2;
}
