import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/question/question_draft_v2.dart';
import 'ocr_safe_html_cleanup.dart';

QuestionDraftV2 cleanupOcrTypedDraft(QuestionDraftV2 draft) {
  final explanation = draft.explanation;
  if (explanation == null) return draft;
  final cleaned = cleanupOcrTypedHtml(explanation);
  if (identical(cleaned, explanation)) return draft;
  return QuestionDraftV2(
    questionId: draft.questionId,
    kind: draft.kind,
    questionNumber: draft.questionNumber,
    stem: draft.stem,
    options: draft.options,
    answer: draft.answer,
    explanation: cleaned,
    sourceRefs: draft.sourceRefs,
    assetRefs: draft.assetRefs,
    issues: draft.issues,
  );
}

/// Finalizes OCR layout markup after ownership slices have been materialized.
/// Non-text nodes are opaque: math, images and tables retain their identity.
RichContent cleanupOcrTypedHtml(RichContent content) {
  final text = content.nodes.whereType<TextNode>().map((n) => n.text).join();
  if (!containsRawHtmlTag(text)) return content;
  var prefix = '\uE000';
  while (text.contains(prefix)) {
    prefix += '\uE000';
  }
  final opaque = <String, ContentNode>{};
  final input = StringBuffer();
  for (final node in content.nodes) {
    if (node is TextNode) {
      input.write(node.text);
    } else {
      final key = '$prefix${opaque.length}\uE002';
      opaque[key] = node;
      input.write(key);
    }
  }
  final cleaned = stripSafeHtmlWrappers(input.toString());
  // This seam only removes known layout wrappers, never unsafe/unknown HTML
  // or structural content inside it. Existing admission remains authoritative.
  if (cleaned.diagnostics.isNotEmpty) return content;
  if (opaque.isEmpty) {
    return RichContent(
        nodes: [if (cleaned.text.isNotEmpty) TextNode(cleaned.text)]);
  }
  final pattern = RegExp(opaque.keys.map(RegExp.escape).join('|'));
  final matches = pattern.allMatches(cleaned.text).toList(growable: false);
  final keys = opaque.keys.toList(growable: false);
  if (matches.length != keys.length) return content;
  for (var i = 0; i < keys.length; i++) {
    if (matches[i].group(0) != keys[i]) return content;
  }
  final nodes = <ContentNode>[];
  var cursor = 0;
  for (final match in matches) {
    if (cursor < match.start) {
      nodes.add(TextNode(cleaned.text.substring(cursor, match.start)));
    }
    nodes.add(opaque[match.group(0)]!);
    cursor = match.end;
  }
  if (cursor < cleaned.text.length) {
    nodes.add(TextNode(cleaned.text.substring(cursor)));
  }
  return RichContent(nodes: nodes);
}
