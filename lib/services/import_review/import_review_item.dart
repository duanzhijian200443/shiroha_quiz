import '../../data/models/question_draft.dart';
import 'import_review_metadata.dart';

class ImportReviewItem {
  final QuestionDraft draft;
  final ImportReviewMetadata metadata;
  final int originalIndex;

  const ImportReviewItem({
    required this.draft,
    required this.metadata,
    required this.originalIndex,
  });

  ImportReviewItem copyWith({
    QuestionDraft? draft,
    ImportReviewMetadata? metadata,
    int? originalIndex,
  }) {
    return ImportReviewItem(
      draft: draft ?? this.draft,
      metadata: metadata ?? this.metadata,
      originalIndex: originalIndex ?? this.originalIndex,
    );
  }

  factory ImportReviewItem.fromMap(Map<String, dynamic> map, int index) {
    final draft = QuestionDraft.fromMap(map);
    final rawMeta = map[ImportReviewMetadata.key];
    Map<String, dynamic>? metadataMap;
    if (rawMeta is Map) {
      try {
        metadataMap = <String, dynamic>{};
        rawMeta.forEach((k, v) {
          metadataMap![k.toString()] = v;
        });
      } catch (_) {
        metadataMap = null;
      }
    }
    final metadata = ImportReviewMetadata.fromMap(metadataMap);

    return ImportReviewItem(
      draft: draft,
      metadata: metadata,
      originalIndex: index,
    );
  }
}
