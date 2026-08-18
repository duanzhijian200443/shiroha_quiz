import '../../data/models/question_draft.dart';
import 'import_review_metadata.dart';

class ImportReviewItem {
  final QuestionDraft draft;
  final ImportReviewMetadata metadata;
  final ImportReviewMetadataProjectionState metadataProjectionState;
  final int originalIndex;

  const ImportReviewItem({
    required this.draft,
    required this.metadata,
    this.metadataProjectionState =
        ImportReviewMetadataProjectionState.available,
    required this.originalIndex,
  });

  ImportReviewItem copyWith({
    QuestionDraft? draft,
    ImportReviewMetadata? metadata,
    ImportReviewMetadataProjectionState? metadataProjectionState,
    int? originalIndex,
  }) {
    return ImportReviewItem(
      draft: draft ?? this.draft,
      metadata: metadata ?? this.metadata,
      metadataProjectionState:
          metadataProjectionState ?? this.metadataProjectionState,
      originalIndex: originalIndex ?? this.originalIndex,
    );
  }

  Map<String, dynamic>? toPersistedMetadata() {
    switch (metadataProjectionState) {
      case ImportReviewMetadataProjectionState.notProvided:
        return null;
      case ImportReviewMetadataProjectionState.available:
        return metadata.toMap();
      case ImportReviewMetadataProjectionState.unavailable:
        return {
          ...metadata.toMap(),
          ImportReviewMetadata.projectionStateKey:
              ImportReviewMetadataProjectionState.unavailable.name,
        };
    }
  }

  factory ImportReviewItem.fromMap(Map<String, dynamic> map, int index) {
    final draft = QuestionDraft.fromMap(map);
    final rawMeta = map[ImportReviewMetadata.key];
    Map<String, dynamic>? metadataMap;
    var metadataProjectionState =
        ImportReviewMetadataProjectionState.notProvided;
    if (map.containsKey(ImportReviewMetadata.key)) {
      metadataProjectionState = ImportReviewMetadataProjectionState.unavailable;
    }
    if (rawMeta is Map) {
      try {
        metadataMap = <String, dynamic>{};
        rawMeta.forEach((k, v) {
          metadataMap![k.toString()] = v;
        });
        final hasProjectionStateMarker =
            rawMeta.containsKey(ImportReviewMetadata.projectionStateKey);
        if (!hasProjectionStateMarker && !_hasInvalidListContainer(rawMeta)) {
          metadataProjectionState =
              ImportReviewMetadataProjectionState.available;
        }
      } catch (_) {
        metadataMap = null;
      }
    }
    final metadata = ImportReviewMetadata.fromMap(metadataMap);

    return ImportReviewItem(
      draft: draft,
      metadata: metadata,
      metadataProjectionState: metadataProjectionState,
      originalIndex: index,
    );
  }

  static bool _hasInvalidListContainer(Map<dynamic, dynamic> rawMeta) {
    const listKeys = {
      'sources',
      'fragmentKinds',
      'originalIndices',
      'riskHints',
      'repairCandidateCodes',
      'latexInvalidFields',
    };
    for (final key in listKeys) {
      if (rawMeta.containsKey(key) && rawMeta[key] is! List) return true;
    }
    return false;
  }
}
