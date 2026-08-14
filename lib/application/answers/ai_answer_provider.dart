import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/question/question_draft_v2.dart';

/// One safe text/math content node allowed to leave the app.
///
/// The egress content vocabulary is structurally limited to the P7 v0
/// text/math subset: there is no [RawFallbackNode], no raw JSON, no asset,
/// no source, and no path representation anywhere in the provider request.
sealed class AiAnswerSafeNode {
  const AiAnswerSafeNode();
}

final class AiAnswerSafeText extends AiAnswerSafeNode {
  const AiAnswerSafeText(this.text);

  final String text;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AiAnswerSafeText && text == other.text;

  @override
  int get hashCode => Object.hash('text', text);
}

final class AiAnswerSafeInlineMath extends AiAnswerSafeNode {
  const AiAnswerSafeInlineMath(this.latex);

  final String latex;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiAnswerSafeInlineMath && latex == other.latex;

  @override
  int get hashCode => Object.hash('inline_math', latex);
}

final class AiAnswerSafeBlockMath extends AiAnswerSafeNode {
  const AiAnswerSafeBlockMath(this.latex);

  final String latex;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiAnswerSafeBlockMath && latex == other.latex;

  @override
  int get hashCode => Object.hash('block_math', latex);
}

/// Immutable safe question content for provider egress.
///
/// Constructed only through [AiAnswerSafeContent.from], which converts the
/// sealed [ContentNode] vocabulary exhaustively and fails closed on
/// [RawFallbackNode] or any unsupported node. Nothing handed to the HTTP
/// adapter can therefore contain forbidden egress fields or unsupported
/// content nodes; no silent content dropping happens.
final class AiAnswerSafeContent {
  factory AiAnswerSafeContent.from(RichContent content) {
    final nodes = <AiAnswerSafeNode>[];
    for (final node in content.nodes) {
      nodes.add(
        switch (node) {
          TextNode(:final text) => AiAnswerSafeText(text),
          InlineMathNode(:final latex) => AiAnswerSafeInlineMath(latex),
          BlockMathNode(:final latex) => AiAnswerSafeBlockMath(latex),
          RawFallbackNode() => throw const FormatException(
              'AI provider requests cannot carry raw fallback content.',
            ),
        },
      );
    }
    return AiAnswerSafeContent._(List<AiAnswerSafeNode>.unmodifiable(nodes));
  }

  const AiAnswerSafeContent._(this.nodes);

  final List<AiAnswerSafeNode> nodes;

  /// True when the content has no visible text/math payload at all.
  bool get hasVisiblePayload {
    for (final node in nodes) {
      switch (node) {
        case AiAnswerSafeText(:final text):
          if (text.trim().isNotEmpty) return true;
        case AiAnswerSafeInlineMath(:final latex):
        case AiAnswerSafeBlockMath(:final latex):
          if (latex.trim().isNotEmpty) return true;
      }
    }
    return false;
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AiAnswerSafeContent && _nodesEqual(nodes, other.nodes);
  }

  @override
  int get hashCode => Object.hashAll(nodes);
}

bool _nodesEqual(List<AiAnswerSafeNode> left, List<AiAnswerSafeNode> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

/// One safe single-choice option for provider egress.
///
/// Carries only the option identity plus a bounded label and safe text/math
/// content. A [QuestionOption] object is never carried directly, so its
/// `sourceRef` cannot become reachable from the request.
final class AiAnswerSafeOption {
  const AiAnswerSafeOption({
    required this.optionId,
    required this.label,
    required this.content,
  });

  final String optionId;
  final String label;
  final AiAnswerSafeContent content;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AiAnswerSafeOption &&
            optionId == other.optionId &&
            label == other.label &&
            content == other.content;
  }

  @override
  int get hashCode => Object.hash(optionId, label, content);
}

/// Immutable egress-safe AI answer request.
///
/// The request contains only what the model needs: the [QuestionKind], a
/// safe text/math stem, and (for `singleChoice` only) safe options with
/// their option identities. It structurally cannot carry storageId, bankName,
/// questionId, source identity, artifact identity, asset references,
/// diagnostics, filesystem paths, Base64, the current formal answer,
/// explanation, or any raw JSON fallback data.
final class AiAnswerProviderRequest {
  factory AiAnswerProviderRequest({
    required QuestionKind kind,
    required AiAnswerSafeContent stem,
    List<AiAnswerSafeOption> options = const <AiAnswerSafeOption>[],
  }) {
    if (kind == QuestionKind.singleChoice) {
      if (options.isEmpty) {
        throw const FormatException(
          'Single-choice AI requests require at least one option.',
        );
      }
    } else if (options.isNotEmpty) {
      throw const FormatException(
        'Content AI requests cannot carry choice options.',
      );
    }
    return AiAnswerProviderRequest._(
      kind: kind,
      stem: stem,
      options: List<AiAnswerSafeOption>.unmodifiable(options),
    );
  }

  const AiAnswerProviderRequest._({
    required this.kind,
    required this.stem,
    required this.options,
  });

  final QuestionKind kind;
  final AiAnswerSafeContent stem;
  final List<AiAnswerSafeOption> options;
}

/// Safe typed result of one bounded AI answer provider call.
///
/// Only the typed answer (plus the safe bounded engine identity needed for
/// later `AiAnswerOrigin` provenance) survives the adapter; the raw provider
/// response, credentials, headers, base URL, reasoning, and request
/// serialization never appear here.
final class AiAnswerProviderResult {
  const AiAnswerProviderResult({
    required this.answer,
    required this.providerProfileId,
  });

  final QuestionAnswer answer;

  /// Bounded opaque identity of the engine profile that produced the answer.
  final String providerProfileId;
}

/// Safe typed failures of the P7 AI answer provider boundary.
///
/// Semantics are frozen by the P7 contract; the provider/output subset that
/// D1 owns is listed here. Target/content and lifecycle categories belong to
/// later stages. `replace`/`noOp` are never provider failures.
enum AiAnswerProviderFailure {
  providerUnconfigured,
  providerAuthenticationFailed,
  providerRateLimited,
  providerTimeout,
  providerUnavailable,
  providerRejected,
  malformedProviderOutput,
  validationFailed,
  internalError,
}

final class AiAnswerProviderException implements Exception {
  const AiAnswerProviderException(this.failure);

  final AiAnswerProviderFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      AiAnswerProviderFailure.providerUnconfigured =>
        'No usable text engine is configured.',
      AiAnswerProviderFailure.providerAuthenticationFailed =>
        'The provider rejected the credential.',
      AiAnswerProviderFailure.providerRateLimited =>
        'The provider is rate limiting requests.',
      AiAnswerProviderFailure.providerTimeout =>
        'The provider request timed out.',
      AiAnswerProviderFailure.providerUnavailable =>
        'The provider is temporarily unavailable.',
      AiAnswerProviderFailure.providerRejected =>
        'The provider rejected the request.',
      AiAnswerProviderFailure.malformedProviderOutput =>
        'The provider output did not match the bounded envelope contract.',
      AiAnswerProviderFailure.validationFailed =>
        'The provider answer failed strict typed validation.',
      AiAnswerProviderFailure.internalError =>
        'The answer provider encountered an internal error.',
    };
    return 'AiAnswerProviderException(${failure.name}): $detail';
  }
}

/// Producer-independent AI answer provider port.
///
/// Presentation and later Application orchestration never talk to a provider
/// SDK directly; they call this port with an already-admitted safe request
/// and receive a typed result or a safe typed failure.
abstract interface class AiAnswerProviderPort {
  Future<AiAnswerProviderResult> generateAnswer(
    AiAnswerProviderRequest request,
  );
}
