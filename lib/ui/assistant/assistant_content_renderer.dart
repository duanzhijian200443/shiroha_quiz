import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../widgets/structured_content_renderer.dart';

/// Shared renderer for persisted and streaming Assistant output.
///
/// Markdown block structure is handled by the existing GPT renderer while
/// every math fragment is delegated to the app's established structured
/// LaTeX renderer.
class AssistantContentRenderer extends StatelessWidget {
  const AssistantContentRenderer({
    super.key,
    required this.text,
  });

  final String text;

  @override
  Widget build(BuildContext context) {
    final style =
        Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5) ??
            const TextStyle(fontSize: 14, height: 1.5);
    return GptMarkdown(
      text,
      style: style,
      useDollarSignsForLatex: true,
      latexBuilder: (context, tex, textStyle, inline) =>
          StructuredContentRenderer(
        text: inline ? '\\($tex\\)' : '\\[$tex\\]',
        textColor: textStyle.color,
        fontSize: textStyle.fontSize ?? 14,
        fontWeight: textStyle.fontWeight ?? FontWeight.normal,
      ),
      imageBuilder: (_, __, ___, ____) => const Text('[Image]'),
    );
  }
}
