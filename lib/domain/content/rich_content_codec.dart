import 'content_node.dart';
import 'rich_content.dart';

final class RichContentCodec {
  const RichContentCodec();

  static const int schemaVersion = 1;

  Map<String, Object?> encode(RichContent content) {
    return <String, Object?>{
      'schemaVersion': schemaVersion,
      'nodes': content.nodes.map(_encodeNode).toList(),
    };
  }

  RichContent decode(Object? json) {
    if (json is! Map) {
      throw const FormatException(
        'RichContent root must be a JSON object.',
      );
    }
    final root = _stringKeyedMap(json);
    if (!root.containsKey('schemaVersion')) {
      throw const FormatException(
        'RichContent schemaVersion is required.',
      );
    }
    if (!root.containsKey('nodes')) {
      throw const FormatException(
        'RichContent nodes are required.',
      );
    }
    if (root.length != 2) {
      throw const FormatException(
        'RichContent root contains unsupported fields.',
      );
    }

    final version = root['schemaVersion'];
    if (version is! int) {
      throw const FormatException(
        'RichContent schemaVersion must be an integer.',
      );
    }
    if (version != schemaVersion) {
      throw UnsupportedError(
        'Unsupported RichContent schemaVersion: $version.',
      );
    }

    final rawNodes = root['nodes'];
    if (rawNodes is! List) {
      throw const FormatException(
        'RichContent nodes must be a JSON array.',
      );
    }

    final nodes = <ContentNode>[];
    for (final rawNode in rawNodes) {
      nodes.add(_decodeNode(rawNode));
    }
    return RichContent(nodes: nodes);
  }

  Map<String, Object?> _encodeNode(ContentNode node) {
    return switch (node) {
      TextNode(:final text) => <String, Object?>{
          'type': 'text',
          'text': text,
        },
      InlineMathNode(:final latex) => <String, Object?>{
          'type': 'inline_math',
          'latex': latex,
        },
      BlockMathNode(:final latex) => <String, Object?>{
          'type': 'block_math',
          'latex': latex,
        },
      ImageNode(:final assetRef, :final altText) => <String, Object?>{
          'type': 'image',
          'assetRef': assetRef,
          if (altText != null) 'altText': altText,
        },
      RawFallbackNode(:final rawJson) => _copyJsonMap(rawJson),
    };
  }

  ContentNode _decodeNode(Object? rawNode) {
    if (rawNode is! Map) {
      throw const FormatException(
        'RichContent nodes must be JSON objects.',
      );
    }
    final node = _stringKeyedMap(rawNode);
    final type = node['type'];
    if (type is! String || type.trim().isEmpty) {
      throw const FormatException(
        'RichContent node type must be a non-empty string.',
      );
    }

    return switch (type) {
      'text' => _decodeTextNode(node),
      'inline_math' => _decodeInlineMathNode(node),
      'block_math' => _decodeBlockMathNode(node),
      'image' => _decodeImageNode(node),
      'raw_fallback' => _decodeRawFallbackNode(node),
      _ => RawFallbackNode(node),
    };
  }

  ContentNode _decodeImageNode(Map<String, Object?> node) {
    final assetRef = node['assetRef'];
    if (assetRef is! String || assetRef.trim().isEmpty) {
      throw const FormatException(
        'Image nodes require a non-empty string assetRef field.',
      );
    }
    final altText = node['altText'];
    if (altText != null && altText is! String) {
      throw const FormatException(
        'Image node altText must be a string when present.',
      );
    }
    final allowedKeys = altText != null
        ? const <String>{'type', 'assetRef', 'altText'}
        : const <String>{'type', 'assetRef'};
    if (!_hasExactKeys(node, allowedKeys)) {
      return RawFallbackNode(node);
    }
    return ImageNode(
      assetRef: assetRef,
      altText: altText as String?,
    );
  }

  ContentNode _decodeTextNode(Map<String, Object?> node) {
    final text = node['text'];
    if (text is! String) {
      throw const FormatException(
        'Text nodes require a string text field.',
      );
    }
    if (!_hasExactKeys(node, const <String>{'type', 'text'})) {
      return RawFallbackNode(node);
    }
    return TextNode(text);
  }

  ContentNode _decodeInlineMathNode(Map<String, Object?> node) {
    final latex = node['latex'];
    if (latex is! String) {
      throw const FormatException(
        'Inline math nodes require a string latex field.',
      );
    }
    if (!_hasExactKeys(node, const <String>{'type', 'latex'})) {
      return RawFallbackNode(node);
    }
    return InlineMathNode(latex);
  }

  ContentNode _decodeBlockMathNode(Map<String, Object?> node) {
    final latex = node['latex'];
    if (latex is! String) {
      throw const FormatException(
        'Block math nodes require a string latex field.',
      );
    }
    if (!_hasExactKeys(node, const <String>{'type', 'latex'})) {
      return RawFallbackNode(node);
    }
    return BlockMathNode(latex);
  }

  ContentNode _decodeRawFallbackNode(Map<String, Object?> node) {
    if (!node.containsKey('payload')) {
      throw const FormatException(
        'Raw fallback nodes require a payload field.',
      );
    }
    return RawFallbackNode(node);
  }
}

Map<String, Object?> _stringKeyedMap(Map<Object?, Object?> source) {
  final copy = <String, Object?>{};
  for (final entry in source.entries) {
    final key = entry.key;
    if (key is! String) {
      throw const FormatException(
        'JSON object keys must be strings.',
      );
    }
    copy[key] = entry.value;
  }
  return copy;
}

bool _hasExactKeys(
  Map<String, Object?> source,
  Set<String> expected,
) {
  if (source.length != expected.length) return false;
  return expected.every(source.containsKey);
}

Map<String, Object?> _copyJsonMap(Map<String, Object?> source) {
  return <String, Object?>{
    for (final entry in source.entries) entry.key: _copyJsonValue(entry.value),
  };
}

Object? _copyJsonValue(Object? value) {
  if (value is Map<String, Object?>) {
    return _copyJsonMap(value);
  }
  if (value is List<Object?>) {
    return value.map(_copyJsonValue).toList();
  }
  return value;
}
