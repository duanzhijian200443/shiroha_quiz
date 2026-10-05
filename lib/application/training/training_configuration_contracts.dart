import '../../domain/training/category_key.dart';
import '../home_training_result.dart';
import 'training_contracts.dart';

/// One read transaction, including configurations whose banks no longer exist.
final class TrainingConfigurationSnapshot {
  TrainingConfigurationSnapshot({
    required this.catalog,
    required Iterable<TrainingCategorySnapshot> categories,
  }) : categories = List.unmodifiable(categories);

  final TrainingCatalogSnapshot catalog;
  final List<TrainingCategorySnapshot> categories;
}

abstract interface class TrainingConfigurationQuery {
  Future<HomeTrainingResult<TrainingConfigurationSnapshot>> readConfiguration();
}

enum TrainingContentMove { up, down }

/// Captures the complete ordered Category, including revisions. A concurrent
/// insertion, deletion, edit or reorder rejects the entire move without writes.
final class MoveTrainingContentRequest {
  MoveTrainingContentRequest({
    required this.categoryKey,
    required Iterable<TrainingContentTarget> orderedTargets,
    required this.contentId,
    required this.direction,
  }) : orderedTargets = List.unmodifiable(orderedTargets) {
    requireHomeTrainingInput(this.orderedTargets.isNotEmpty &&
        this.orderedTargets.map((t) => t.contentId).toSet().length ==
            this.orderedTargets.length &&
        this.orderedTargets.any((t) => t.contentId == contentId));
  }

  final CategoryKey categoryKey;
  final List<TrainingContentTarget> orderedTargets;
  final String contentId;
  final TrainingContentMove direction;
}

abstract interface class TrainingContentOrderCommand {
  Future<HomeTrainingResult<HomeTrainingUnit>> moveContent(
      MoveTrainingContentRequest request);
}
