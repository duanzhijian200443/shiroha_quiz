/// Application query capability for import-review folder selection.
///
/// This seam intentionally exposes no question-list query or mutation
/// capability.
abstract interface class FolderQueryPort {
  Future<List<String>> listAvailableFolders();
}
