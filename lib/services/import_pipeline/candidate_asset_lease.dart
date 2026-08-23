import '../../application/content/content_asset_authority.dart';

const String candidateAssetSourceIdKey = '_candidate_asset_source_id';
const String candidateAssetLocalIdsKey = '_candidate_asset_local_ids';
const String candidateAssetCleanupPendingKey =
    '_candidate_asset_cleanup_pending';
const String candidateAssetCleanupSourceIdKey =
    '_candidate_asset_cleanup_source_id';
const String candidateAssetCleanupLocalIdsKey =
    '_candidate_asset_cleanup_local_ids';

Map<String, dynamic> candidateAssetLeaseDiagnostics(
  ContentAssetCandidateLease lease,
) {
  return <String, dynamic>{
    candidateAssetSourceIdKey: lease.sourceId,
    candidateAssetLocalIdsKey: lease.localAssetIds,
  };
}

Map<String, dynamic> candidateAssetCleanupPendingDiagnostics(
  ContentAssetCandidateLease lease,
) {
  return <String, dynamic>{
    candidateAssetCleanupPendingKey: true,
    candidateAssetCleanupSourceIdKey: lease.sourceId,
    candidateAssetCleanupLocalIdsKey: lease.localAssetIds,
  };
}

ContentAssetCandidateLease? decodeCandidateAssetLeaseFromDiagnostics(
  Map<String, dynamic>? diagnostics, {
  bool cleanupPending = false,
}) {
  final sourceId = diagnostics?[cleanupPending
      ? candidateAssetCleanupSourceIdKey
      : candidateAssetSourceIdKey];
  final rawIds = diagnostics?[cleanupPending
      ? candidateAssetCleanupLocalIdsKey
      : candidateAssetLocalIdsKey];
  if (sourceId is! String || sourceId.trim().isEmpty || rawIds is! List) {
    return null;
  }
  final localIds = <String>[];
  for (final value in rawIds) {
    if (value is! String || value.trim().isEmpty) return null;
    localIds.add(value);
  }
  if (localIds.isEmpty) return null;
  return ContentAssetCandidateLease(
    sourceId: sourceId,
    localAssetIds: localIds,
  );
}
