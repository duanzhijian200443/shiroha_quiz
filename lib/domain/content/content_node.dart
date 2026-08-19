import 'dart:collection';

sealed class ContentNode {
  const ContentNode();
}

final class TextNode extends ContentNode {
  const TextNode(this.text);

  final String text;
}

final class InlineMathNode extends ContentNode {
  const InlineMathNode(this.latex);

  final String latex;
}

final class BlockMathNode extends ContentNode {
  const BlockMathNode(this.latex);

  final String latex;
}

final class ImageNode extends ContentNode {
  const ImageNode({
    required this.assetRef,
    this.altText,
  });

  final String assetRef;
  final String? altText;
}

final class RawFallbackNode extends ContentNode {
  RawFallbackNode(Map<Object?, Object?> rawJson)
      : rawJson = _freezeRawJson(rawJson);

  final Map<String, Object?> rawJson;
}

Map<String, Object?> _freezeRawJson(Map<Object?, Object?> rawJson) {
  final frozen = _freezeJsonValue(
    rawJson,
    HashSet<Object>.identity(),
  ) as Map<String, Object?>;
  final type = frozen['type'];
  if (type is! String || type.trim().isEmpty) {
    throw const FormatException(
      'Raw fallback nodes require a non-empty string type.',
    );
  }
  _validateFallbackShape(frozen, type);
  return frozen;
}

void _validateFallbackShape(
  Map<String, Object?> rawJson,
  String type,
) {
  switch (type) {
    case 'text':
      _requireExtendedKnownFallback(rawJson, 'text');
    case 'inline_math':
    case 'block_math':
      _requireExtendedKnownFallback(rawJson, 'latex');
    case 'image':
      _requireExtendedKnownFallback(rawJson, 'assetRef');
    case 'raw_fallback':
      if (!rawJson.containsKey('payload')) {
        throw const FormatException(
          'Raw fallback nodes require a payload field.',
        );
      }
  }
}

void _requireExtendedKnownFallback(
  Map<String, Object?> rawJson,
  String contentKey,
) {
  if (rawJson[contentKey] is! String) {
    throw const FormatException(
      'Known fallback nodes require their canonical string field.',
    );
  }
  if (rawJson.length == 2) {
    throw const FormatException(
      'Canonical known nodes cannot be represented as raw fallback nodes.',
    );
  }
}

Object? _freezeJsonValue(
  Object? value,
  Set<Object> ancestors,
) {
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double) {
    if (!value.isFinite) {
      throw const FormatException(
        'Raw fallback nodes contain a non-JSON number.',
      );
    }
    return value;
  }
  if (value is List) {
    if (!ancestors.add(value)) {
      throw const FormatException(
        'Raw fallback nodes contain a cyclic collection.',
      );
    }
    try {
      return List<Object?>.unmodifiable(
        value.map((item) => _freezeJsonValue(item, ancestors)),
      );
    } finally {
      ancestors.remove(value);
    }
  }
  if (value is Map) {
    if (!ancestors.add(value)) {
      throw const FormatException(
        'Raw fallback nodes contain a cyclic collection.',
      );
    }
    try {
      final copy = <String, Object?>{};
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String) {
          throw const FormatException(
            'Raw fallback node object keys must be strings.',
          );
        }
        copy[key] = _freezeJsonValue(entry.value, ancestors);
      }
      return Map<String, Object?>.unmodifiable(copy);
    } finally {
      ancestors.remove(value);
    }
  }

  throw const FormatException(
    'Raw fallback nodes contain a non-JSON value.',
  );
}
