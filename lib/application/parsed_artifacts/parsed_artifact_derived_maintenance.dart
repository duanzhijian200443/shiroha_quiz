final class CurrentArtifactStorageRow {
  const CurrentArtifactStorageRow({
    required this.fileId,
    required this.storageKey,
  });

  final String fileId;
  final String storageKey;
}

/// Paged metadata and bounded derived-index cleanup for startup reconciliation.
abstract interface class ParsedArtifactDerivedMaintenancePort {
  Future<List<CurrentArtifactStorageRow>> currentPage({
    required int offset,
    required int limit,
  });

  Future<int> deleteStaleRetrievalBuilds({required int maxRows});
}
