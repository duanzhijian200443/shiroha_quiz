import '../assets/asset_ref.dart';
import '../content/content_node.dart';
import '../content/rich_content.dart';
import '../content/rich_content_privacy_admission.dart';
import 'source_ref.dart';

final _fallbackKindCodePattern = RegExp(r'^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$');

enum SourceContentRole { unknown, paragraph, heading, formula, answerLike }

sealed class SourcePart {
  const SourcePart({required this.sourceRef});

  final SourceRef sourceRef;
}

final class SourceContentPart extends SourcePart {
  factory SourceContentPart({
    required SourceRef sourceRef,
    required RichContent content,
    SourceContentRole role = SourceContentRole.unknown,
  }) {
    _validateSourceContent(content);
    return SourceContentPart._(
      sourceRef: sourceRef,
      content: content,
      role: role,
    );
  }

  const SourceContentPart._({
    required super.sourceRef,
    required this.content,
    required this.role,
  });

  final RichContent content;
  final SourceContentRole role;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SourceContentPart &&
            sourceRef == other.sourceRef &&
            role == other.role &&
            _richContentEquals(content, other.content);
  }

  @override
  int get hashCode => Object.hash(
        SourceContentPart,
        sourceRef,
        role,
        _richContentHash(content),
      );
}

final class SourceTablePart extends SourcePart {
  factory SourceTablePart({
    required SourceRef sourceRef,
    required Iterable<Iterable<RichContent>> rows,
  }) {
    final copiedRows = List<List<RichContent>>.unmodifiable(
      rows.map((row) => List<RichContent>.unmodifiable(row)),
    );
    for (final row in copiedRows) {
      for (final cell in row) {
        _validateSourceContent(cell);
      }
    }
    return SourceTablePart._(
      sourceRef: sourceRef,
      rows: copiedRows,
    );
  }

  const SourceTablePart._({
    required super.sourceRef,
    required this.rows,
  });

  final List<List<RichContent>> rows;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SourceTablePart &&
            sourceRef == other.sourceRef &&
            _tableRowsEqual(rows, other.rows);
  }

  @override
  int get hashCode => Object.hash(
        SourceTablePart,
        sourceRef,
        Object.hashAll(
          rows.map(
            (row) => Object.hashAll(row.map(_richContentHash)),
          ),
        ),
      );
}

final class SourceAssetPart extends SourcePart {
  factory SourceAssetPart({
    required SourceRef sourceRef,
    required AssetRef asset,
    RichContent? alternativeText,
  }) {
    if (alternativeText != null) {
      _validateSourceContent(alternativeText);
    }
    return SourceAssetPart._(
      sourceRef: sourceRef,
      asset: asset,
      alternativeText: alternativeText,
    );
  }

  const SourceAssetPart._({
    required super.sourceRef,
    required this.asset,
    required this.alternativeText,
  });

  final AssetRef asset;
  final RichContent? alternativeText;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SourceAssetPart &&
            sourceRef == other.sourceRef &&
            asset == other.asset &&
            _nullableRichContentEquals(
              alternativeText,
              other.alternativeText,
            );
  }

  @override
  int get hashCode => Object.hash(
        SourceAssetPart,
        sourceRef,
        asset,
        alternativeText == null ? null : _richContentHash(alternativeText!),
      );
}

final class UnsupportedSourcePart extends SourcePart {
  factory UnsupportedSourcePart({
    required SourceRef sourceRef,
    required String kindCode,
    required RichContent fallbackContent,
  }) {
    if (kindCode.length > 64 || !_fallbackKindCodePattern.hasMatch(kindCode)) {
      throw const FormatException(
        'Fallback kind codes must use bounded lower snake case.',
      );
    }
    if (fallbackContent.nodes.isEmpty) {
      throw const FormatException(
        'Unsupported source parts require formal fallback content.',
      );
    }
    _validateSourceContent(fallbackContent);
    return UnsupportedSourcePart._(
      sourceRef: sourceRef,
      kindCode: kindCode,
      fallbackContent: fallbackContent,
    );
  }

  const UnsupportedSourcePart._({
    required super.sourceRef,
    required this.kindCode,
    required this.fallbackContent,
  });

  final String kindCode;
  final RichContent fallbackContent;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is UnsupportedSourcePart &&
            sourceRef == other.sourceRef &&
            kindCode == other.kindCode &&
            _richContentEquals(fallbackContent, other.fallbackContent);
  }

  @override
  int get hashCode => Object.hash(
        UnsupportedSourcePart,
        sourceRef,
        kindCode,
        _richContentHash(fallbackContent),
      );
}

void _validateSourceContent(RichContent content) {
  const RichContentPrivacyAdmission().validate(content);
}

bool _tableRowsEqual(
  List<List<RichContent>> left,
  List<List<RichContent>> right,
) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var rowIndex = 0; rowIndex < left.length; rowIndex++) {
    final leftRow = left[rowIndex];
    final rightRow = right[rowIndex];
    if (leftRow.length != rightRow.length) return false;
    for (var cellIndex = 0; cellIndex < leftRow.length; cellIndex++) {
      if (!_richContentEquals(leftRow[cellIndex], rightRow[cellIndex])) {
        return false;
      }
    }
  }
  return true;
}

bool _nullableRichContentEquals(RichContent? left, RichContent? right) {
  if (left == null || right == null) return left == right;
  return _richContentEquals(left, right);
}

bool _richContentEquals(RichContent left, RichContent right) {
  if (identical(left, right)) return true;
  if (left.nodes.length != right.nodes.length) return false;
  for (var index = 0; index < left.nodes.length; index++) {
    if (!_contentNodeEquals(left.nodes[index], right.nodes[index])) {
      return false;
    }
  }
  return true;
}

int _richContentHash(RichContent content) {
  return Object.hashAll(content.nodes.map(_contentNodeHash));
}

bool _contentNodeEquals(ContentNode left, ContentNode right) {
  if (identical(left, right)) return true;
  if (left.runtimeType != right.runtimeType) return false;
  return switch (left) {
    TextNode(:final text) => text == (right as TextNode).text,
    InlineMathNode(:final latex) => latex == (right as InlineMathNode).latex,
    BlockMathNode(:final latex) => latex == (right as BlockMathNode).latex,
    ImageNode(:final assetRef, :final altText) =>
      assetRef == (right as ImageNode).assetRef && altText == right.altText,
    RawFallbackNode(:final rawJson) =>
      _jsonValueEquals(rawJson, (right as RawFallbackNode).rawJson),
  };
}

int _contentNodeHash(ContentNode node) {
  return switch (node) {
    TextNode(:final text) => Object.hash('text', text),
    InlineMathNode(:final latex) => Object.hash('inline_math', latex),
    BlockMathNode(:final latex) => Object.hash('block_math', latex),
    ImageNode(:final assetRef, :final altText) =>
      Object.hash('image', assetRef, altText),
    RawFallbackNode(:final rawJson) =>
      Object.hash('raw_fallback', _jsonValueHash(rawJson)),
  };
}

bool _jsonValueEquals(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_jsonValueEquals(left[index], right[index])) return false;
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_jsonValueEquals(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List || right is List || left is Map || right is Map) {
    return false;
  }
  return left.runtimeType == right.runtimeType && left == right;
}

int _jsonValueHash(Object? value) {
  if (value is List) {
    return Object.hash(
      'json_list',
      Object.hashAll(value.map(_jsonValueHash)),
    );
  }
  if (value is Map) {
    return Object.hash(
      'json_map',
      Object.hashAllUnordered(
        value.entries.map(
          (entry) => Object.hash(entry.key, _jsonValueHash(entry.value)),
        ),
      ),
    );
  }
  return Object.hash(value.runtimeType, value);
}
