import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/question/question_draft_v2.dart';

/// Application-owned W0 proposed-answer policy.
///
/// Staging admission and the dedicated commit defense-in-depth share this
/// single policy so the two gates can never diverge:
///
/// - `QuestionKind.singleChoice` accepts only a `ChoiceAnswer` whose option
///   identities are unique and exist in the admitted/current options;
/// - `QuestionKind.fillBlank` / `QuestionKind.shortAnswer` accept only a
///   `ContentAnswer` that is structurally non-empty: whitespace-only text or
///   math does not count as visible, and raw fallback payloads are refused.
final class AgentWriteProposedAnswerPolicy {
  const AgentWriteProposedAnswerPolicy();

  /// Kind-independent structural gate. Used before staging admission so a
  /// clearly invalid payload is refused without touching the target; it is a
  /// necessary condition of [isValidForDraft].
  bool isStructurallyValidPayload(QuestionAnswer proposed) {
    switch (proposed) {
      case ChoiceAnswer(:final optionIds):
        return optionIds.isNotEmpty &&
            optionIds.toSet().length == optionIds.length;
      case ContentAnswer(:final content):
        return _isStructurallyNonEmptyContent(content);
    }
  }

  /// Full kind-compatibility gate: the answer type must match the question
  /// kind and be valid against the current options / structural rules.
  bool isValidForDraft(QuestionAnswer proposed, QuestionDraftV2 draft) {
    return switch ((draft.kind, proposed)) {
      (QuestionKind.singleChoice, ChoiceAnswer(:final optionIds)) =>
        _isValidChoiceIdentities(optionIds, draft.options),
      (
        QuestionKind.fillBlank || QuestionKind.shortAnswer,
        ContentAnswer(:final content),
      ) =>
        _isStructurallyNonEmptyContent(content),
      _ => false,
    };
  }

  bool _isValidChoiceIdentities(
    List<String> optionIds,
    List<QuestionOption> options,
  ) {
    final optionIdsInDraft = <String>{
      for (final option in options) option.optionId,
    };
    return optionIds.toSet().length == optionIds.length &&
        optionIds.every(optionIdsInDraft.contains);
  }

  bool _isStructurallyNonEmptyContent(RichContent content) {
    if (content.nodes.isEmpty) return false;
    var hasVisibleNode = false;
    for (final node in content.nodes) {
      switch (node) {
        case TextNode(:final text):
          if (text.trim().isNotEmpty) hasVisibleNode = true;
        case InlineMathNode(:final latex):
          if (latex.trim().isNotEmpty) hasVisibleNode = true;
        case BlockMathNode(:final latex):
          if (latex.trim().isNotEmpty) hasVisibleNode = true;
        case ImageNode():
          hasVisibleNode = true;
        case RawFallbackNode():
          return false;
      }
    }
    return hasVisibleNode;
  }
}
