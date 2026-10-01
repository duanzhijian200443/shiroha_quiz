/// Read-only ordinary Today snapshot. Counts retain the existing ordinary
/// training semantics; this is not a StudyPlan or a new statistics contract.
final class TodayContextSnapshot {
  const TodayContextSnapshot({
    this.bankName,
    this.newCount = 0,
    this.reviewCount = 0,
    this.totalCount = 0,
    this.masteredCount = 0,
  });

  final String? bankName;
  final int newCount;
  final int reviewCount;
  final int totalCount;
  final int masteredCount;
}

/// A safe read failure, never containing storage errors or private payloads.
final class TodayContextUnavailable implements Exception {
  const TodayContextUnavailable();
}

abstract interface class TodayContextQuery {
  Future<TodayContextSnapshot> loadContext();
}
