import '../assets/asset_ref.dart';
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

    for (final part in copiedParts) {
      _validateMemberSource(documentRef, part.sourceRef);
      if (part is SourceAssetPart) {
        final existing = assetsById[part.asset.assetId];
        if (existing != null && existing != part.asset) {
          throw const FormatException(
            'Source asset identities must not carry conflicting metadata.',
          );
        }
        assetsById[part.asset.assetId] = part.asset;
      }
    }
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
    );
  }

  const SourceDocument._({
    required this.documentRef,
    required this.parts,
    required this.issues,
  });

  final SourceRef documentRef;
  final List<SourcePart> parts;
  final List<ImportIssue> issues;

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
