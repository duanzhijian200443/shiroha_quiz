import '../../domain/question/question_draft_v2.dart';

enum ContentAssetMaintenanceOutcome {
  complete,
  busy,
  incompleteRoots,
  incompleteInventory,
  ledgerUnavailable,
  revalidationFailed,
  deleteFailed,
}

/// Fixed status and counts only; no identity, path, payload, or raw error.
final class ContentAssetMaintenanceReport {
  const ContentAssetMaintenanceReport({
    required this.outcome,
    this.physicalCount = 0,
    this.liveCount = 0,
    this.unobservedCount = 0,
    this.gracePendingCount = 0,
    this.graceEligibleCount = 0,
    this.deletedCount = 0,
    this.unknownCount = 0,
    this.boundHit = false,
  });

  final ContentAssetMaintenanceOutcome outcome;
  final int physicalCount;
  final int liveCount;
  final int unobservedCount;
  final int gracePendingCount;
  final int graceEligibleCount;
  final int deletedCount;
  final int unknownCount;
  final bool boundHit;
}

abstract interface class ContentAssetMaintenancePort {
  Future<ContentAssetMaintenanceReport> reportOnly();

  /// Runs the same complete-scan, grace and exact-delete authority as startup.
  Future<ContentAssetMaintenanceReport> sweepEligible();
}

final class ContentAssetTaskRootRow {
  const ContentAssetTaskRootRow({
    required this.status,
    required this.diagnostics,
    required this.parsedData,
  });

  final int status;
  final String? diagnostics;
  final String? parsedData;
}

/// Paged persistence reads for a complete lifecycle root scan.
abstract interface class ContentAssetRootPagePort {
  Future<List<QuestionDraftV2?>> questionPage({
    required int offset,
    required int limit,
  });

  Future<List<String>> currentArtifactFileIdsPage({
    required int offset,
    required int limit,
  });

  Future<List<ContentAssetTaskRootRow>> importTaskPage({
    required int offset,
    required int limit,
  });
}
