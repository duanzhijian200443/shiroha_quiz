import '../domain/content/content_node.dart';
import '../domain/content/rich_content.dart';
import 'content_normalizer.dart';
import 'content_tokenizer.dart';

/// Parsed typed manual answer input. The sealed result never silently drops
/// content: unsupported input is an explicit safe failure and empty input is
/// an explicit empty result the caller maps to a null answer.
sealed class TypedAnswerInputParseResult {
  const TypedAnswerInputParseResult();
}

final class TypedAnswerInputParsed extends TypedAnswerInputParseResult {
  const TypedAnswerInputParsed(this.content);

  final RichContent content;
}

/// Explicit empty result for empty or whitespace-only input. Callers map it
/// to `answer = null` and must never store placeholder text.
final class TypedAnswerInputEmpty extends TypedAnswerInputParseResult {
  const TypedAnswerInputEmpty();
}

/// Safe validation failure for image, blank, or parse-error tokens. The text
/// is fixed and redacted; the input is never discarded silently.
final class TypedAnswerInputUnsupported extends TypedAnswerInputParseResult {
  const TypedAnswerInputUnsupported();

  static const String _message =
      'The typed answer contains unsupported content.';

  @override
  String toString() => _message;
}

/// Pure-Dart parser for typed manual answers.
///
/// Flow: [ContentNormalizer.normalizeForStorage] (existing dollar/think
/// rules, never copied) then [ContentTokenizer.tokenize]. Text, inline math,
/// and block math tokens become structural nodes; image, blank, and parse
/// error tokens are safe validation failures; raw fallback nodes are never
/// produced. Structural nodes are consumed directly by the renderer and
/// text nodes are not re-parsed into math.
final class TypedAnswerInputParser {
  const TypedAnswerInputParser._();

  static TypedAnswerInputParseResult parse(String input) {
    final normalized = ContentNormalizer.normalizeForStorage(input);
    if (normalized.trim().isEmpty) return const TypedAnswerInputEmpty();

    final nodes = <ContentNode>[];
    for (final token in ContentTokenizer.tokenize(normalized)) {
      switch (token) {
        case TextToken(:final text):
          nodes.add(TextNode(text));
        case InlineMathToken(:final tex):
          nodes.add(InlineMathNode(tex));
        case BlockMathToken(:final tex):
          nodes.add(BlockMathNode(tex));
        case ImageToken() || BlankToken() || ParseErrorToken():
          return const TypedAnswerInputUnsupported();
      }
    }
    return TypedAnswerInputParsed(RichContent(nodes: nodes));
  }
}
