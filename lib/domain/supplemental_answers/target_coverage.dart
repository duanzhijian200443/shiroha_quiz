/// Coverage of one formal typed target by the supplemental document.
///
/// This is deliberately distinct from a source fragment's `unmatched`
/// disposition: `uncovered` is about the target side (no supplemental
/// answer), while `unmatched` is about the source side (a fragment with no
/// target).
enum TargetCoverageStatus {
  covered,
  uncovered,
  ineligible,
}

/// One typed target's coverage result.
final class TargetCoverage {
  const TargetCoverage({
    required this.storageId,
    required this.bankName,
    required this.status,
  });

  final String storageId;
  final String bankName;
  final TargetCoverageStatus status;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is TargetCoverage &&
            storageId == other.storageId &&
            bankName == other.bankName &&
            status == other.status;
  }

  @override
  int get hashCode => Object.hash(storageId, bankName, status);
}
