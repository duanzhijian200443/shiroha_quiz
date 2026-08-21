import '../assets/sourced_asset_ref.dart';
import '../content/content_node.dart';
import '../content/rich_content.dart';
import '../import/import_issue.dart';
import '../source/source_ref.dart';

final _opaqueIdentifierPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
final _labelControlPattern = RegExp(r'[\u0000-\u001f\u007f-\u009f]');

enum QuestionKind { singleChoice, fillBlank, shortAnswer }

final class QuestionOption {
  factory QuestionOption({
    required String optionId,
    required String label,
    required RichContent content,
    SourceRef? sourceRef,
  }) {
    return QuestionOption._(
      optionId: _validateOpaqueIdentifier(optionId),
      label: _validateOptionLabel(label),
      content: content,
      sourceRef: sourceRef,
    );
  }

  const QuestionOption._({
    required this.optionId,
    required this.label,
    required this.content,
    required this.sourceRef,
  });

  final String optionId;
  final String label;
  final RichContent content;
  final SourceRef? sourceRef;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is QuestionOption &&
            optionId == other.optionId &&
            label == other.label &&
            _richContentEquals(content, other.content) &&
            sourceRef == other.sourceRef;
  }

  @override
  int get hashCode => Object.hash(
        optionId,
        label,
        _richContentHash(content),
        sourceRef,
      );
}

sealed class QuestionAnswer {
  const QuestionAnswer();
}

final class ChoiceAnswer extends QuestionAnswer {
  factory ChoiceAnswer({required Iterable<String> optionIds}) {
    final copiedIds = List<String>.unmodifiable(
      optionIds.map(_validateOpaqueIdentifier),
    );
    if (copiedIds.isEmpty) {
      throw const FormatException(
        'Choice answers require at least one option identity.',
      );
    }
    return ChoiceAnswer._(copiedIds);
  }

  const ChoiceAnswer._(this.optionIds);

  final List<String> optionIds;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ChoiceAnswer && _orderedEquals(optionIds, other.optionIds);
  }

  @override
  int get hashCode => Object.hashAll(optionIds);
}

final class ContentAnswer extends QuestionAnswer {
  const ContentAnswer({required this.content});

  final RichContent content;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ContentAnswer && _richContentEquals(content, other.content);
  }

  @override
  int get hashCode => _richContentHash(content);
}

final class QuestionDraftV2 {
  factory QuestionDraftV2({
    required String questionId,
    required QuestionKind kind,
    int? questionNumber,
    required RichContent stem,
    Iterable<QuestionOption> options = const <QuestionOption>[],
    QuestionAnswer? answer,
    RichContent? explanation,
    Iterable<SourceRef> sourceRefs = const <SourceRef>[],
    Iterable<SourcedAssetRef> assetRefs = const <SourcedAssetRef>[],
    Iterable<ImportIssue> issues = const <ImportIssue>[],
  }) {
    final validatedQuestionId = _validateOpaqueIdentifier(questionId);
    if (questionNumber != null && questionNumber <= 0) {
      throw const FormatException(
        'Question numbers must be positive integers when present.',
      );
    }

    final copiedOptions = List<QuestionOption>.unmodifiable(options);
    final optionIds = <String>{};
    for (final option in copiedOptions) {
      if (!optionIds.add(option.optionId)) {
        throw const FormatException(
          'Question option identities must be unique within a draft.',
        );
      }
    }

    final copiedSourceRefs = List<SourceRef>.unmodifiable(sourceRefs);
    final sourceIds =
        copiedSourceRefs.map((sourceRef) => sourceRef.sourceId).toSet();
    final assetsByIdentity = <(String, String), SourcedAssetRef>{};
    for (final assetRef in assetRefs) {
      if (!sourceIds.contains(assetRef.sourceId)) {
        throw const FormatException(
          'Question assets must belong to a declared draft source.',
        );
      }
      final identity = (assetRef.sourceId, assetRef.localAssetId);
      final existing = assetsByIdentity[identity];
      if (existing == null) {
        assetsByIdentity[identity] = assetRef;
      } else if (existing != assetRef) {
        throw const FormatException(
          'Question asset identities must not carry conflicting metadata.',
        );
      }
    }

    void validateContentAssets(RichContent content) {
      for (final image in reachableImageNodes(content)) {
        if (!assetsByIdentity
            .containsKey((image.sourceId, image.localAssetId))) {
          throw const FormatException(
            'Question image identities must belong to the draft asset inventory.',
          );
        }
      }
    }

    validateContentAssets(stem);
    for (final option in copiedOptions) {
      validateContentAssets(option.content);
    }
    if (answer case ContentAnswer(:final content)) {
      validateContentAssets(content);
    }
    if (explanation != null) {
      validateContentAssets(explanation);
    }

    return QuestionDraftV2._(
      questionId: validatedQuestionId,
      kind: kind,
      questionNumber: questionNumber,
      stem: stem,
      options: copiedOptions,
      answer: answer,
      explanation: explanation,
      sourceRefs: copiedSourceRefs,
      assetRefs: List<SourcedAssetRef>.unmodifiable(assetsByIdentity.values),
      issues: List<ImportIssue>.unmodifiable(issues),
    );
  }

  const QuestionDraftV2._({
    required this.questionId,
    required this.kind,
    required this.questionNumber,
    required this.stem,
    required this.options,
    required this.answer,
    required this.explanation,
    required this.sourceRefs,
    required this.assetRefs,
    required this.issues,
  });

  final String questionId;
  final QuestionKind kind;
  final int? questionNumber;
  final RichContent stem;
  final List<QuestionOption> options;
  final QuestionAnswer? answer;
  final RichContent? explanation;
  final List<SourceRef> sourceRefs;
  final List<SourcedAssetRef> assetRefs;
  final List<ImportIssue> issues;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is QuestionDraftV2 &&
            questionId == other.questionId &&
            kind == other.kind &&
            questionNumber == other.questionNumber &&
            _richContentEquals(stem, other.stem) &&
            _orderedEquals(options, other.options) &&
            answer == other.answer &&
            _nullableRichContentEquals(explanation, other.explanation) &&
            _orderedEquals(sourceRefs, other.sourceRefs) &&
            _orderedEquals(assetRefs, other.assetRefs) &&
            _orderedEquals(issues, other.issues);
  }

  @override
  int get hashCode => Object.hash(
        questionId,
        kind,
        questionNumber,
        _richContentHash(stem),
        Object.hashAll(options),
        answer,
        explanation == null ? null : _richContentHash(explanation!),
        Object.hashAll(sourceRefs),
        Object.hashAll(assetRefs),
        Object.hashAll(issues),
      );
}

String _validateOpaqueIdentifier(String value) {
  if (!_opaqueIdentifierPattern.hasMatch(value)) {
    throw const FormatException(
      'Question identities must use the bounded opaque token format.',
    );
  }
  return value;
}

String _validateOptionLabel(String value) {
  if (value.runes.length > 32 ||
      value != value.trim() ||
      _labelControlPattern.hasMatch(value)) {
    throw const FormatException(
      'Question option labels must use the safe bounded display format.',
    );
  }
  return value;
}

bool _nullableRichContentEquals(RichContent? left, RichContent? right) {
  if (left == null || right == null) return left == right;
  return _richContentEquals(left, right);
}

bool _richContentEquals(RichContent left, RichContent right) {
  if (identical(left, right)) return true;
  if (left.nodes.length != right.nodes.length) return false;
  for (var index = 0; index < left.nodes.length; index++) {
    if (!_contentNodeEquals(left.nodes[index], right.nodes[index])) {
      return false;
    }
  }
  return true;
}

int _richContentHash(RichContent content) {
  return Object.hashAll(content.nodes.map(_contentNodeHash));
}

bool _contentNodeEquals(ContentNode left, ContentNode right) {
  if (identical(left, right)) return true;
  if (left.runtimeType != right.runtimeType) return false;
  return switch (left) {
    TextNode(:final text) => text == (right as TextNode).text,
    InlineMathNode(:final latex) => latex == (right as InlineMathNode).latex,
    BlockMathNode(:final latex) => latex == (right as BlockMathNode).latex,
    ImageNode() => left == right,
    TableNode() => left == right,
    RawFallbackNode(:final rawJson) =>
      _jsonValueEquals(rawJson, (right as RawFallbackNode).rawJson),
  };
}

int _contentNodeHash(ContentNode node) {
  return switch (node) {
    TextNode(:final text) => Object.hash('text', text),
    InlineMathNode(:final latex) => Object.hash('inline_math', latex),
    BlockMathNode(:final latex) => Object.hash('block_math', latex),
    ImageNode() => node.hashCode,
    TableNode() => node.hashCode,
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

bool _orderedEquals<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
