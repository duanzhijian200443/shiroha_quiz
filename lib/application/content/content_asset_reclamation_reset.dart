/// Reset derived grace evidence before an identity enters a writer or durable
/// owner. Failure must prevent the ownership transition and byte visibility.
abstract interface class ContentAssetReclamationResetPort {
  Future<void> resetBeforeOwnership({
    required String sourceId,
    required Iterable<String> localAssetIds,
  });
}
