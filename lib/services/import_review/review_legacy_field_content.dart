import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/content/rich_content_text_projection.dart';
import '../../utils/content_normalizer.dart';
import '../../utils/content_tokenizer.dart';
import '../import_pipeline/latex_block_environment_normalizer.dart';
import 'explanation_edit_provenance.dart';

/// Structural representation of an AI-repaired review field.
///
/// Legacy review fields are plain strings. When an accepted AI repair changed
/// such a field, the typed commit must keep the repaired math as math instead
/// of degrading the whole field to one literal text node.
///
/// The rebuild uses the exact pipeline the legacy renderer already uses
/// (`LatexBlockEnvironmentNormalizer` -> `ContentNormalizer.normalizeForRender`
/// -> `ContentTokenizer`), so the committed typed content renders like the
/// staging preview did.
///
/// Returns `null` when the text must stay literal:
/// * the text is empty;
/// * it contains an image reference, whose asset identity cannot be
///   reconstructed from text and must never be invented;
/// * it contains an unclosed math delimiter (`ParseErrorToken`).
///
/// The caller keeps the frozen literal-text behavior in every `null` case.
RichContent? reviewFieldContentFromLegacyText(String legacyText) {
  if (legacyText.trim().isEmpty) return null;

  final blockNormalized =
      const LatexBlockEnvironmentNormalizer().normalize(legacyText);
  final normalized = ContentNormalizer.normalizeForRender(blockNormalized.text);
  final tokens = ContentTokenizer.tokenize(normalized);
  if (tokens.isEmpty) return null;

  final nodes = <ContentNode>[];
  for (final token in tokens) {
    switch (token) {
      case TextToken(:final text):
        if (text.isNotEmpty) nodes.add(TextNode(text));
      case InlineMathToken(:final tex):
        if (tex.trim().isEmpty) return null;
        nodes.add(InlineMathNode(tex));
      case BlockMathToken(:final tex):
        if (tex.trim().isEmpty) return null;
        nodes.add(BlockMathNode(tex));
      case BlankToken(:final length):
        nodes.add(TextNode('_' * length));
      case ImageToken():
      case ParseErrorToken():
        return null;
    }
  }
  if (nodes.isEmpty) return null;
  return RichContent(nodes: nodes);
}

/// Whether [content] can be represented structurally without dropping content
/// that a text rebuild cannot reconstruct.
///
/// Image, table and raw-fallback nodes carry identity that legacy text does not
/// contain, so a field holding them is never rebuilt from text.
bool reviewFieldSupportsStructuralEdit(RichContent content) {
  for (final node in content.nodes) {
    switch (node) {
      case TextNode():
      case InlineMathNode():
      case BlockMathNode():
        continue;
      case ImageNode():
      case TableNode():
      case RawFallbackNode():
        return false;
    }
  }
  return true;
}

/// Returns the original typed content only when the current legacy text is an
/// exact projection of it.
///
/// This is the legacy compatibility fallback for review drafts whose edit
/// provenance is unknown. It never normalizes: only an exact match against the
/// frozen baseline or against the exact text projection is accepted, because a
/// typed explanation and its legacy text rendering are intentionally different
/// representations and no string rule can tell them apart from a real edit.
///
/// New typed review items do not use this path; they carry
/// [ExplanationEditProvenance.untouched] and resolve their structure directly.
RichContent? originalReviewContentForCurrentLegacyText({
  required RichContent? originalContent,
  required String baselineText,
  required String currentText,
}) {
  if (originalContent == null || currentText.isEmpty) return null;
  if (baselineText.isNotEmpty && currentText == baselineText) {
    return originalContent;
  }
  try {
    return const RichContentTextProjection().project(originalContent) ==
            currentText
        ? originalContent
        : null;
  } on FormatException {
    return null;
  }
}

/// Resolves the explanation content one review item must render or commit.
///
/// This is the single authority shared by the Review preview and the typed
/// commit, so a table or image can never be shown in Review and then flattened
/// at commit time. The decision is driven by the retention decision plus the
/// explicit [ExplanationEditProvenance]; it never compares the legacy text with
/// the typed projection to guess whether an edit happened.
///
/// Returns the typed [RichContent] to use, or `null` when the caller must fall
/// back to the literal legacy/manual rendering path.
RichContent? resolveExplanationReviewContent({
  required RichContent? originalContent,
  required String baselineText,
  required String currentText,
  required bool retained,
  required ExplanationEditProvenance provenance,
}) {
  // Not retained: the policy answer wins over any provenance state.
  if (!retained) return null;
  if (provenance == ExplanationEditProvenance.manualEdited) {
    // A user edit is terminal: the original structure is never re-inherited,
    // even when the edited text happens to match the baseline or projection.
    return null;
  }
  if (provenance == ExplanationEditProvenance.untouched) {
    // Confirmed untouched review content keeps its original structural
    // authority; its legacy text rendering is not compared at all.
    return originalContent;
  }
  return originalReviewContentForCurrentLegacyText(
    originalContent: originalContent,
    baselineText: baselineText,
    currentText: currentText,
  );
}
