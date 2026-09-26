/// Final, typed-only eligibility. The score is supplied by the existing
/// ImportReviewAnalyzer; this policy does not calculate a second score.
final class ImportPerfectAutoCommitFacts {
  const ImportPerfectAutoCommitFacts({
    required this.enabled,
    required this.documentImportEntry,
    required this.hasFrozenTarget,
    required this.pendingReview,
    required this.readyForReview,
    required this.typedCandidateReady,
    required this.itemCount,
    required this.qualityScore,
    required this.errorCount,
    required this.warningCount,
    required this.qualityGateBlocked,
    required this.reviewDraftRevision,
    required this.commitInProgress,
    required this.typedSnapshotValid,
  });

  final bool enabled;
  final bool documentImportEntry;
  final bool hasFrozenTarget;
  final bool pendingReview;
  final bool readyForReview;
  final bool typedCandidateReady;
  final int itemCount;
  final int qualityScore;
  final int errorCount;
  final int warningCount;
  final bool qualityGateBlocked;
  final int reviewDraftRevision;
  final bool commitInProgress;
  final bool typedSnapshotValid;
}

final class ImportPerfectAutoCommitPolicy {
  const ImportPerfectAutoCommitPolicy();

  /// Auto commit is only the RD0 snapshot's commit path, so eligibility
  /// requires exactly that materialized revision. Any later positive revision
  /// means Review has started editing and keeps authority.
  bool isEligible(ImportPerfectAutoCommitFacts facts) =>
      facts.enabled &&
      facts.documentImportEntry &&
      facts.hasFrozenTarget &&
      facts.pendingReview &&
      facts.readyForReview &&
      facts.typedCandidateReady &&
      facts.itemCount > 0 &&
      facts.qualityScore == 100 &&
      facts.errorCount == 0 &&
      facts.warningCount == 0 &&
      !facts.qualityGateBlocked &&
      facts.reviewDraftRevision == 1 &&
      !facts.commitInProgress &&
      facts.typedSnapshotValid;
}
