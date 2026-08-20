/// Exact persisted attempt identity captured by a ReviewDraft writer.
///
/// Every nullable field is authoritative: `null` means the persisted task must
/// also omit that field. It is never a wildcard and no identity is generated
/// for historical compatibility tasks.
final class ReviewDraftAttemptIdentity {
  const ReviewDraftAttemptIdentity({
    required this.attemptToken,
    required this.attemptNumber,
    required this.traceId,
  });

  final String? attemptToken;
  final int? attemptNumber;
  final String? traceId;
}

enum ReviewDraftCasStatus {
  saved,
  staleRevision,
  staleAttempt,
  taskMissing,
  taskNotPendingReview,
  invalidMetadata,
}

/// Result of the persisted ReviewDraft compare-and-set transaction.
///
/// [durableRevision] is absent when metadata is invalid or persistence fails;
/// callers must never substitute an in-memory revision in those cases.
final class ReviewDraftCasResult {
  const ReviewDraftCasResult(this.status, {required this.durableRevision});

  final ReviewDraftCasStatus status;
  final int? durableRevision;
}

abstract final class ReviewDraftCasPersistence {
  static const String keyAttemptToken = '_attemptToken';
  static const String keyAttemptNumber = '_attemptNumber';
  static const String keyTraceId = '_traceId';
  static const String keyReviewDraftRevision = '_reviewDraftRevision';
  static const String keyExplanationRetentionMode = '_explanationRetentionMode';
  static const int pendingReviewStatusCode = 1;
}
