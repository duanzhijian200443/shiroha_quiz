import '../../application/content/content_asset_authority.dart';

/// Performs one bounded retry for transient managed-file deletion failures.
/// The whole lease is retried idempotently; missing identities are safe.
Future<ContentAssetRollbackResult> deleteCandidateAssetsWithRetry({
  required ContentAssetStore store,
  required ContentAssetCandidateLease lease,
}) async {
  var last = ContentAssetRollbackResult(
    failedCount: lease.localAssetIds.length,
  );
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      last = await store.deleteCandidateAssets(lease);
      if (last.failedCount == 0) return last;
    } catch (_) {
      last = ContentAssetRollbackResult(
        failedCount: lease.localAssetIds.length,
      );
    }
  }
  return last;
}
