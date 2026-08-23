import '../assets/asset_ref.dart';
import '../assets/sourced_asset_ref.dart';
import '../content/content_node.dart';
import '../content/rich_content.dart';
import '../import/import_issue.dart';
import 'source_part.dart';
import 'source_ref.dart';

final class SourceDocument {
  factory SourceDocument({
    required String sourceId,
    String? displayLabel,
    Iterable<SourcePart> parts = const <SourcePart>[],
    Iterable<ImportIssue> issues = const <ImportIssue>[],
  }) {
    final documentRef = SourceRef.document(
      sourceId: sourceId,
      displayLabel: displayLabel,
    );
    final copiedParts = List<SourcePart>.unmodifiable(parts);
    final copiedIssues = List<ImportIssue>.unmodifiable(issues);
    final assetsById = <String, AssetRef>{};
    final sourcedAssets = <SourcedAssetRef>[];

    for (final part in copiedParts) {
      _validateMemberSource(documentRef, part.sourceRef);
      if (part is SourceAssetPart) {
        final existing = assetsById[part.asset.assetId];
        if (existing != null && existing != part.asset) {
          throw const FormatException(
            'Source asset identities must not carry conflicting metadata.',
          );
        }
        if (existing == null) {
          assetsById[part.asset.assetId] = part.asset;
          sourcedAssets.add(
            SourcedAssetRef(
              sourceId: part.sourceRef.sourceId,
              asset: part.asset,
            ),
          );
        }
      }
    }
    _validateNestedSourceAssets(
      documentRef: documentRef,
      parts: copiedParts,
      assetsById: assetsById,
    );
    for (final issue in copiedIssues) {
      final sourceRef = issue.sourceRef;
      if (sourceRef != null) {
        _validateMemberSource(documentRef, sourceRef);
      }
    }

    return SourceDocument._(
      documentRef: documentRef,
      parts: copiedParts,
      issues: copiedIssues,
      assetRefs: List<SourcedAssetRef>.unmodifiable(sourcedAssets),
    );
  }

  const SourceDocument._({
    required this.documentRef,
    required this.parts,
    required this.issues,
    required this.assetRefs,
  });

  final SourceRef documentRef;
  final List<SourcePart> parts;
  final List<ImportIssue> issues;

  /// Source-level metadata authority used by nested ImageNode values. This is
  /// derived from existing SourceAssetPart entries, so the SourceDocument v1
  /// wire shape does not gain a second inventory field.
  final List<SourcedAssetRef> assetRefs;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SourceDocument &&
            documentRef == other.documentRef &&
            _orderedEquals(parts, other.parts) &&
            _orderedEquals(issues, other.issues);
  }

  @override
  int get hashCode => Object.hash(
        documentRef,
        Object.hashAll(parts),
        Object.hashAll(issues),
      );
}

void _validateNestedSourceAssets({
  required SourceRef documentRef,
  required List<SourcePart> parts,
  required Map<String, AssetRef> assetsById,
}) {
  for (final part in parts) {
    final contents = switch (part) {
      SourceContentPart(:final content) => <RichContent>[content],
      SourceAssetPart(:final alternativeText) => alternativeText == null
          ? const <RichContent>[]
          : <RichContent>[alternativeText],
      SourceTablePart(:final rows) => [
          for (final row in rows) ...row,
        ],
      UnsupportedSourcePart(:final fallbackContent) => <RichContent>[
          fallbackContent,
        ],
    };
    for (final content in contents) {
      for (final image in reachableImageNodes(content)) {
        if (image.sourceId != documentRef.sourceId ||
            !assetsById.containsKey(image.localAssetId)) {
          throw const FormatException(
            'Nested source images require source-level asset metadata.',
          );
        }
      }
    }
  }
}

void _validateMemberSource(SourceRef documentRef, SourceRef memberRef) {
  if (memberRef.sourceId != documentRef.sourceId) {
    throw const FormatException(
      'Source document members must share the document identity.',
    );
  }
  if (memberRef.displayLabel != null &&
      memberRef.displayLabel != documentRef.displayLabel) {
    throw const FormatException(
      'Source document members contain conflicting display labels.',
    );
  }
}

bool _orderedEquals<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
