import 'import_advanced_preferences.dart';

/// Auto navigation is permitted only for one user-started task after review
/// admission. Batches keep the existing notification path.
final class ImportCompletionNavigationPolicy {
  const ImportCompletionNavigationPolicy();

  bool shouldOpenReview({
    required ImportCompletionBehavior behavior,
    required bool singleUserTask,
    required bool pendingReview,
    required bool foreground,
    required bool navigationFree,
  }) =>
      behavior == ImportCompletionBehavior.openReview &&
      singleUserTask &&
      pendingReview &&
      foreground &&
      navigationFree;
}
