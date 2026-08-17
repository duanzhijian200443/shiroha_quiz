import '../content/content_node.dart';
import '../content/rich_content.dart';

/// Structural equality helper for [RichContent] values inside the
/// supplemental-answer domain.
///
/// Mirrors the canonical structural semantics used by the typed core: a
/// persisted `TextNode` is never reparsed, and math/raw-fallback nodes
/// compare by their typed payload, not by rendered text.
bool richContentEquals(RichContent left, RichContent right) {
  if (identical(left, right)) return true;
  if (left.nodes.length != right.nodes.length) return false;
  for (var index = 0; index < left.nodes.length; index++) {
    if (!_contentNodeEquals(left.nodes[index], right.nodes[index])) {
      return false;
    }
  }
  return true;
}

/// Stable structural hash compatible with [richContentEquals].
int richContentHash(RichContent content) {
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
