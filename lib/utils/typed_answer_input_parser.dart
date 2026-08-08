import '../domain/content/rich_content.dart';
import '../domain/content/typed_answer_editor_codec.dart';

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
/// Manual user input is deliberately separated from provider/AI output
/// normalization: this parser never strips `<think>...</think>` blocks,
/// never truncates unclosed `<think>` text, and never drops user content.
/// It delegates the lossless text/structural conversion to the typed editor
/// boundary ([TypedAnswerEditorCodec]): text, inline math, and block math
/// become structural nodes; image, blank, and parse error input is a safe
/// validation failure; raw fallback nodes are never produced. Structural
/// nodes are consumed directly by the renderer and text nodes are not
/// re-parsed into math.
final class TypedAnswerInputParser {
  const TypedAnswerInputParser._();

  static TypedAnswerInputParseResult parse(String input) {
    if (input.trim().isEmpty) return const TypedAnswerInputEmpty();

    switch (TypedAnswerEditorCodec.decode(input)) {
      case TypedAnswerEditorContent(:final content):
        return TypedAnswerInputParsed(content);
      case TypedAnswerEditorText():
        // decode never produces an editor text form.
        return const TypedAnswerInputUnsupported();
      case TypedAnswerEditorUnsupported():
        return const TypedAnswerInputUnsupported();
    }
  }
}
