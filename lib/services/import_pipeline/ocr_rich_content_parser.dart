import 'dart:collection';

import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/question/question_region.dart';
import '../../utils/content_tokenizer.dart';
import 'latex_renderability_checker.dart';

/// Call-local source spans. This object is never serialized or logged.
final class OcrMathSourceMap {
  final Map<RichContent, OcrParsedContent> _contents = HashMap.identity();
  final Map<ContentNode, String> _rawMath = HashMap.identity();

  OcrParsedContent? parsed(RichContent content) => _contents[content];
  String? rawMath(ContentNode node) => _rawMath[node];

  /// Creates an inline math node for a bare (undelimited) expression that the
  /// structural table-cell segmenter admitted.
  ///
  /// The raw span is registered exactly like delimited OCR math, so text
  /// projections and extraction views keep their node-identity semantics and
  /// never re-parse a flattened payload into math.
  InlineMathNode bareInlineMath(String raw) {
    final node = InlineMathNode(raw);
    _rawMath[node] = raw;
    return node;
  }

  RichContent parse(String text, {bool formula = false}) {
    final spans = ContentTokenizer.tokenizeMathSpans(text);
    final nodes = <ContentNode>[];
    final ranges = <({int start, int end})>[];
    final bareFormula = formula &&
        text.trim().isNotEmpty &&
        spans.every((span) => span.token is TextToken) &&
        !text.contains(r'$') &&
        !text.contains(r'\(') &&
        !text.contains(r'\)') &&
        !text.contains(r'\[') &&
        !text.contains(r'\]') &&
        const LatexRenderabilityChecker()
            .check(text, assumeMathContext: true)
            .isRenderable;
    if (bareFormula) {
      final node = BlockMathNode(text);
      nodes.add(node);
      ranges.add((start: 0, end: text.length));
      _rawMath[node] = text;
    } else {
      for (final span in spans) {
        final node = switch (span.token) {
          InlineMathToken(:final tex) => InlineMathNode(tex),
          BlockMathToken(:final tex) => BlockMathNode(tex),
          TextToken(:final text) => TextNode(text),
          _ => throw StateError('Unexpected OCR math token.'),
        };
        nodes.add(node);
        ranges.add((start: span.start, end: span.end));
        if (node is! TextNode) {
          _rawMath[node] = text.substring(span.start, span.end);
        }
      }
    }
    final content = RichContent(nodes: nodes);
    _contents[content] = OcrParsedContent._(text, content, ranges);
    return content;
  }
}

final class OcrParsedContent {
  OcrParsedContent._(
      this.original, this.content, List<({int start, int end})> ranges)
      : ranges = List.unmodifiable(ranges);

  final String original;
  final RichContent content;
  final List<({int start, int end})> ranges;

  /// Translate only exact boundaries; never widen a partial math interval.
  SourceSlice slice(int start, int end) {
    if (start < 0 || end > original.length || start >= end) {
      throw const FormatException('Invalid OCR content interval.');
    }
    ({int node, int offset}) position(int offset) {
      if (offset == original.length) return (node: ranges.length, offset: 0);
      for (var i = 0; i < ranges.length; i++) {
        final range = ranges[i];
        if (offset == range.start) return (node: i, offset: 0);
        if (offset > range.start &&
            offset < range.end &&
            content.nodes[i] is TextNode) {
          return (node: i, offset: offset - range.start);
        }
      }
      throw const FormatException('OCR boundary splits a math node.');
    }

    final first = position(start);
    final last = position(end);
    return SourceSlice(
        startNodeIndex: first.node,
        startCodeUnitOffset: first.offset,
        endNodeIndex: last.node,
        endCodeUnitOffset: last.offset);
  }
}

/// An extraction view with atomic, collision-free placeholders. Existing text
/// policies may slice this view; restoration returns the original math objects,
/// never parses their payload or reconstructs math from flattened strings.
final class OcrMathExtractionView {
  OcrMathExtractionView(Iterable<ContentNode> nodes, this.sourceMap) {
    final text = nodes.whereType<TextNode>().map((node) => node.text).join();
    var prefix = '\uE000';
    while (text.contains(prefix)) {
      prefix += '\uE000';
    }
    for (final node in nodes) {
      if (sourceMap.rawMath(node) != null && !_keys.containsKey(node)) {
        final key = '$prefix${_keys.length}\uE002';
        _keys[node] = key;
        _nodes[key] = node;
      }
    }
  }

  final OcrMathSourceMap sourceMap;
  final Map<ContentNode, String> _keys = HashMap.identity();
  final Map<String, ContentNode> _nodes = {};

  String? text(List<ContentNode> nodes) {
    final buffer = StringBuffer();
    for (final node in nodes) {
      if (node is TextNode) {
        buffer.write(node.text);
      } else if (_keys.containsKey(node)) {
        buffer.write(_keys[node]);
      } else {
        return null;
      }
    }
    return buffer.toString();
  }

  List<ContentNode> restore(String text) {
    if (_nodes.isEmpty) return [TextNode(text)];
    final pattern = RegExp(_nodes.keys.map(RegExp.escape).join('|'));
    final result = <ContentNode>[];
    var cursor = 0;
    for (final match in pattern.allMatches(text)) {
      if (cursor < match.start) {
        result.add(TextNode(text.substring(cursor, match.start)));
      }
      result.add(_nodes[match.group(0)]!);
      cursor = match.end;
    }
    if (cursor < text.length) result.add(TextNode(text.substring(cursor)));
    return result;
  }
}
