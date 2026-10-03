import '../../domain/training/category_key.dart';
import '../../domain/training/training_content.dart';
import 'training_contracts.dart';

/// Exact identity ordering, shared by configuration and runtime selection.
int compareTrainingCategories(CategoryKey a, CategoryKey b) {
  if (a is FolderCategoryKey && b is FolderCategoryKey) {
    final byName = a.exactFolderName.compareTo(b.exactFolderName);
    if (byName != 0) return byName;
  } else if (a is FolderCategoryKey) {
    return -1;
  } else if (b is FolderCategoryKey) {
    return 1;
  }
  const codec = CategoryKeyCodec();
  return codec.encodeString(a).compareTo(codec.encodeString(b));
}

int compareTrainingContents(TrainingContent a, TrainingContent b) {
  final byOrder = a.sortOrder.compareTo(b.sortOrder);
  return byOrder != 0 ? byOrder : a.contentId.compareTo(b.contentId);
}

/// Uses one captured eligibility decision per exact bank. Never repairs binding
/// state or omits a zero-weight member from usability admission.
TrainingContentView projectTrainingContent(
    TrainingContent content, TrainingCatalogSnapshot catalog) {
  final banks = {for (final bank in catalog.banks) bank.bankName: bank};
  return TrainingContentView(
    content: content,
    usable: content.hasValidBindings &&
        content.members.every((member) {
          final bank = banks[member.bankName];
          return bank != null &&
              bank.ordinaryTrainingEligible &&
              bank.categoryKey == content.categoryKey;
        }),
  );
}

/// Runtime context resolution only. Persisted references remain visible in the
/// result even when a different Category/content is temporarily selected.
TrainingCurrentSelection resolveTrainingCurrent({
  required CategoryKey? persistedCategoryKey,
  required TrainingCatalogSnapshot catalog,
  required Iterable<TrainingCategorySnapshot> categories,
}) {
  final snapshots = {
    for (final category in categories) category.categoryKey: category
  };
  final visible = <CategoryKey>{
    for (final bank in catalog.banks)
      if (bank.ordinaryTrainingEligible) bank.categoryKey,
    for (final category in snapshots.values)
      if (category.contents.isNotEmpty) category.categoryKey,
  }.toList()
    ..sort(compareTrainingCategories);
  final key = visible.contains(persistedCategoryKey)
      ? persistedCategoryKey
      : visible.firstOrNull;
  if (key == null) {
    return TrainingCurrentSelection(
      persistedCategoryKey: persistedCategoryKey,
      categoryKey: null,
      preference: null,
      currentContent: null,
      state: TrainingCurrentContentState.unconfigured,
    );
  }
  final snapshot = snapshots[key]!;
  final usable = snapshot.contents.where((view) => view.usable).toList()
    ..sort((a, b) => compareTrainingContents(a.content, b.content));
  final current = usable
          .where((view) =>
              view.content.contentId == snapshot.preference.currentContentId)
          .firstOrNull ??
      usable.firstOrNull;
  return TrainingCurrentSelection(
    persistedCategoryKey: persistedCategoryKey,
    categoryKey: key,
    preference: snapshot.preference,
    currentContent: current,
    state: current != null
        ? TrainingCurrentContentState.usable
        : snapshot.contents.isEmpty
            ? TrainingCurrentContentState.unconfigured
            : TrainingCurrentContentState.unavailable,
  );
}
