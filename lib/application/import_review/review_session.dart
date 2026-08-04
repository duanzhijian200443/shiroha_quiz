import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/question/question_draft_v2.dart';

final _opaqueIdentifierPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
final _policyBlockerCodePattern = RegExp(r'^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$');

enum ReviewStatus { open, inProgress, completed, abandoned }

enum ReviewDecision { unreviewed, accepted, rejected, deferred }

enum ReviewFieldEditKind { unchanged, replace, clear }

final class ReviewFieldEdit<T> {
  const ReviewFieldEdit.unchanged()
      : kind = ReviewFieldEditKind.unchanged,
        _replacement = null;

  factory ReviewFieldEdit.replace(T replacement) {
    if (replacement == null) {
      throw const FormatException(
        'Replacement edits require a non-null replacement value.',
      );
    }
    return ReviewFieldEdit<T>._(
      kind: ReviewFieldEditKind.replace,
      replacement: replacement,
    );
  }

  const ReviewFieldEdit.clear()
      : kind = ReviewFieldEditKind.clear,
        _replacement = null;

  const ReviewFieldEdit._({
    required this.kind,
    required T? replacement,
  }) : _replacement = replacement;

  final ReviewFieldEditKind kind;
  final T? _replacement;

  bool get isUnchanged => kind == ReviewFieldEditKind.unchanged;
  bool get isReplace => kind == ReviewFieldEditKind.replace;
  bool get isClear => kind == ReviewFieldEditKind.clear;

  T get replacement {
    if (!isReplace) {
      throw StateError('Only replacement edits carry a replacement value.');
    }
    return _replacement as T;
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ReviewFieldEdit<T> &&
            kind == other.kind &&
            _structuralValueEquals(_replacement, other._replacement);
  }

  @override
  int get hashCode => Object.hash(kind, _structuralValueHash(_replacement));
}

final class ReviewEdit {
  factory ReviewEdit({
    ReviewFieldEdit<QuestionKind>? kind,
    ReviewFieldEdit<int?>? questionNumber,
    ReviewFieldEdit<RichContent>? stem,
    ReviewFieldEdit<List<QuestionOption>>? options,
    ReviewFieldEdit<QuestionAnswer?>? answer,
    ReviewFieldEdit<RichContent?>? explanation,
  }) {
    final normalizedKind =
        kind ?? const ReviewFieldEdit<QuestionKind>.unchanged();
    final normalizedQuestionNumber =
        questionNumber ?? const ReviewFieldEdit<int?>.unchanged();
    final normalizedStem =
        stem ?? const ReviewFieldEdit<RichContent>.unchanged();
    final normalizedOptions = _freezeOptionsEdit(
      options ?? const ReviewFieldEdit<List<QuestionOption>>.unchanged(),
    );
    final normalizedAnswer =
        answer ?? const ReviewFieldEdit<QuestionAnswer?>.unchanged();
    final normalizedExplanation =
        explanation ?? const ReviewFieldEdit<RichContent?>.unchanged();

    if (normalizedKind.isClear ||
        normalizedStem.isClear ||
        normalizedOptions.isClear) {
      throw const FormatException(
        'Only question number, answer, and explanation may be cleared.',
      );
    }

    return ReviewEdit._(
      kind: normalizedKind,
      questionNumber: normalizedQuestionNumber,
      stem: normalizedStem,
      options: normalizedOptions,
      answer: normalizedAnswer,
      explanation: normalizedExplanation,
    );
  }

  factory ReviewEdit.unchanged() => ReviewEdit();

  const ReviewEdit._({
    required this.kind,
    required this.questionNumber,
    required this.stem,
    required this.options,
    required this.answer,
    required this.explanation,
  });

  final ReviewFieldEdit<QuestionKind> kind;
  final ReviewFieldEdit<int?> questionNumber;
  final ReviewFieldEdit<RichContent> stem;
  final ReviewFieldEdit<List<QuestionOption>> options;
  final ReviewFieldEdit<QuestionAnswer?> answer;
  final ReviewFieldEdit<RichContent?> explanation;

  bool get isUnchanged =>
      kind.isUnchanged &&
      questionNumber.isUnchanged &&
      stem.isUnchanged &&
      options.isUnchanged &&
      answer.isUnchanged &&
      explanation.isUnchanged;

  QuestionDraftV2 deriveWorkingDraft(QuestionDraftV2 original) {
    final workingOptions = options.isReplace
        ? _validateOptionReplacement(original, options.replacement)
        : original.options;

    return QuestionDraftV2(
      questionId: original.questionId,
      kind: _requiredValue(kind, original.kind),
      questionNumber: _nullableValue(questionNumber, original.questionNumber),
      stem: _requiredValue(stem, original.stem),
      options: workingOptions,
      answer: _nullableValue(answer, original.answer),
      explanation: _nullableValue(explanation, original.explanation),
      sourceRefs: original.sourceRefs,
      assetRefs: original.assetRefs,
      issues: original.issues,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ReviewEdit &&
            kind == other.kind &&
            questionNumber == other.questionNumber &&
            stem == other.stem &&
            options == other.options &&
            answer == other.answer &&
            explanation == other.explanation;
  }

  @override
  int get hashCode => Object.hash(
        kind,
        questionNumber,
        stem,
        options,
        answer,
        explanation,
      );
}

final class ReviewSessionOrigin {
  factory ReviewSessionOrigin({
    required String taskId,
    required String attemptToken,
    required int attemptNumber,
  }) {
    if (attemptNumber <= 0) {
      throw const FormatException('Attempt numbers must be positive.');
    }
    return ReviewSessionOrigin._(
      taskId: _validateOpaqueIdentifier(taskId, 'taskId'),
      attemptToken: _validateOpaqueIdentifier(attemptToken, 'attemptToken'),
      attemptNumber: attemptNumber,
    );
  }

  const ReviewSessionOrigin._({
    required this.taskId,
    required this.attemptToken,
    required this.attemptNumber,
  });

  final String taskId;
  final String attemptToken;
  final int attemptNumber;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ReviewSessionOrigin &&
            taskId == other.taskId &&
            attemptToken == other.attemptToken &&
            attemptNumber == other.attemptNumber;
  }

  @override
  int get hashCode => Object.hash(taskId, attemptToken, attemptNumber);
}

final class ReviewItem {
  factory ReviewItem.initial({
    required String itemId,
    required QuestionDraftV2 original,
  }) {
    final initialEdit = ReviewEdit.unchanged();
    return ReviewItem._(
      itemId: _validateOpaqueIdentifier(itemId, 'itemId'),
      original: original,
      working: initialEdit.deriveWorkingDraft(original),
      edit: initialEdit,
      decision: ReviewDecision.unreviewed,
      answerAssist: null,
    );
  }

  const ReviewItem._({
    required this.itemId,
    required this.original,
    required this.working,
    required this.edit,
    required this.decision,
    required this.answerAssist,
  });

  final String itemId;
  final QuestionDraftV2 original;
  final QuestionDraftV2 working;
  final ReviewEdit edit;
  final ReviewDecision decision;
  final AnswerAssist? answerAssist;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ReviewItem &&
            itemId == other.itemId &&
            original == other.original &&
            working == other.working &&
            edit == other.edit &&
            decision == other.decision &&
            answerAssist == other.answerAssist;
  }

  @override
  int get hashCode => Object.hash(
        itemId,
        original,
        working,
        edit,
        decision,
        answerAssist,
      );
}

final class ReviewSession {
  factory ReviewSession.open({
    required String sessionId,
    required String taskId,
    required String attemptToken,
    required int attemptNumber,
    required Iterable<ReviewItem> items,
  }) {
    final copiedItems = List<ReviewItem>.unmodifiable(items);
    if (copiedItems.isEmpty) {
      throw const FormatException('Review sessions require at least one item.');
    }

    final itemIds = <String>{};
    final questionIds = <String>{};
    for (final item in copiedItems) {
      if (!itemIds.add(item.itemId)) {
        throw const FormatException(
          'Review item identities must be unique within a session.',
        );
      }
      if (!questionIds.add(item.original.questionId)) {
        throw const FormatException(
          'Question identities must be unique within a review session.',
        );
      }
    }

    return ReviewSession._(
      sessionId: _validateOpaqueIdentifier(sessionId, 'sessionId'),
      origin: ReviewSessionOrigin(
        taskId: taskId,
        attemptToken: attemptToken,
        attemptNumber: attemptNumber,
      ),
      status: ReviewStatus.open,
      revision: 0,
      items: copiedItems,
    );
  }

  const ReviewSession._({
    required this.sessionId,
    required this.origin,
    required this.status,
    required this.revision,
    required this.items,
  });

  final String sessionId;
  final ReviewSessionOrigin origin;
  final ReviewStatus status;
  final int revision;
  final List<ReviewItem> items;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ReviewSession &&
            sessionId == other.sessionId &&
            origin == other.origin &&
            status == other.status &&
            revision == other.revision &&
            _orderedEquals(items, other.items);
  }

  @override
  int get hashCode => Object.hash(
        sessionId,
        origin,
        status,
        revision,
        Object.hashAll(items),
      );
}

enum AnswerAssistStatus {
  localExtracted,
  proofExplanationRecognized,
  aiApplied,
  aiRejected,
  aiFailed,
}

enum AnswerAssistReason {
  rejected('answer_distillation_rejected'),
  rejectedNotCandidate('answer_distillation_rejected_not_candidate'),
  rejectedQuestionNumberChanged(
    'answer_distillation_rejected_question_number_changed',
  ),
  rejectedBasis('answer_distillation_rejected_basis'),
  rejectedEmpty('answer_distillation_rejected_empty'),
  rejectedPlaceholder('answer_distillation_rejected_placeholder'),
  rejectedTooVerbose('answer_distillation_rejected_too_verbose'),
  failed('answer_distillation_failed');

  const AnswerAssistReason(this.code);

  final String code;
}

final class AnswerAssist {
  factory AnswerAssist({
    required AnswerAssistStatus status,
    AnswerAssistReason? reason,
    QuestionDraftV2? currentWorkingDraft,
  }) {
    switch (status) {
      case AnswerAssistStatus.localExtracted:
      case AnswerAssistStatus.aiApplied:
        if (reason != null || currentWorkingDraft != null) {
          throw const FormatException(
            'Successful answer-assist states do not carry a reason or draft.',
          );
        }
      case AnswerAssistStatus.proofExplanationRecognized:
        if (reason != null ||
            currentWorkingDraft == null ||
            !_hasStructuralExplanation(currentWorkingDraft.explanation)) {
          throw const FormatException(
            'Proof recognition requires a structurally non-empty current '
            'working explanation and no reason.',
          );
        }
      case AnswerAssistStatus.aiRejected:
        if (reason == null ||
            reason == AnswerAssistReason.failed ||
            currentWorkingDraft != null) {
          throw const FormatException(
            'AI rejection requires a rejection reason and no draft.',
          );
        }
      case AnswerAssistStatus.aiFailed:
        if (reason != AnswerAssistReason.failed ||
            currentWorkingDraft != null) {
          throw const FormatException(
            'AI failure requires the failed reason and no draft.',
          );
        }
    }
    return AnswerAssist._(status: status, reason: reason);
  }

  const AnswerAssist._({required this.status, required this.reason});

  final AnswerAssistStatus status;
  final AnswerAssistReason? reason;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AnswerAssist &&
            status == other.status &&
            reason == other.reason;
  }

  @override
  int get hashCode => Object.hash(status, reason);
}

final class ReviewIssueAcknowledgement {
  factory ReviewIssueAcknowledgement({required int issueIndex}) {
    if (issueIndex < 0) {
      throw const FormatException('Issue indexes must be non-negative.');
    }
    return ReviewIssueAcknowledgement._(issueIndex);
  }

  const ReviewIssueAcknowledgement._(this.issueIndex);

  final int issueIndex;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ReviewIssueAcknowledgement && issueIndex == other.issueIndex;
  }

  @override
  int get hashCode => issueIndex.hashCode;
}

final class ReviewPolicyBlocker {
  factory ReviewPolicyBlocker({required String code}) {
    if (code.length > 64 || !_policyBlockerCodePattern.hasMatch(code)) {
      throw const FormatException(
        'Policy blocker codes must use bounded lower snake case.',
      );
    }
    return ReviewPolicyBlocker._(code);
  }

  const ReviewPolicyBlocker._(this.code);

  final String code;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ReviewPolicyBlocker && code == other.code;
  }

  @override
  int get hashCode => code.hashCode;
}

final class ReviewItemCompletionAssessment {
  factory ReviewItemCompletionAssessment({
    required String itemId,
    required ReviewDecision decision,
    required int issueCount,
    Iterable<ReviewIssueAcknowledgement> issueAcknowledgements =
        const <ReviewIssueAcknowledgement>[],
    Iterable<ReviewPolicyBlocker> policyBlockers =
        const <ReviewPolicyBlocker>[],
  }) {
    if (issueCount < 0) {
      throw const FormatException('Issue counts must be non-negative.');
    }
    final copiedAcknowledgements =
        List<ReviewIssueAcknowledgement>.unmodifiable(issueAcknowledgements);
    final acknowledgedIndexes = <int>{};
    for (final acknowledgement in copiedAcknowledgements) {
      if (acknowledgement.issueIndex >= issueCount) {
        throw const FormatException(
          'Issue acknowledgements must reference an assessed issue.',
        );
      }
      if (!acknowledgedIndexes.add(acknowledgement.issueIndex)) {
        throw const FormatException(
          'Issue acknowledgements must be unique within an assessment.',
        );
      }
    }
    final copiedBlockers = List<ReviewPolicyBlocker>.unmodifiable(
      policyBlockers,
    );
    final blockerCodes = <String>{};
    for (final blocker in copiedBlockers) {
      if (!blockerCodes.add(blocker.code)) {
        throw const FormatException(
          'Policy blocker codes must be unique within an assessment.',
        );
      }
    }

    return ReviewItemCompletionAssessment._(
      itemId: _validateOpaqueIdentifier(itemId, 'itemId'),
      decision: decision,
      issueCount: issueCount,
      issueAcknowledgements: copiedAcknowledgements,
      policyBlockers: copiedBlockers,
    );
  }

  const ReviewItemCompletionAssessment._({
    required this.itemId,
    required this.decision,
    required this.issueCount,
    required this.issueAcknowledgements,
    required this.policyBlockers,
  });

  final String itemId;
  final ReviewDecision decision;
  final int issueCount;
  final List<ReviewIssueAcknowledgement> issueAcknowledgements;
  final List<ReviewPolicyBlocker> policyBlockers;

  bool get canComplete =>
      decision != ReviewDecision.unreviewed &&
      issueAcknowledgements.length == issueCount &&
      policyBlockers.isEmpty;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ReviewItemCompletionAssessment &&
            itemId == other.itemId &&
            decision == other.decision &&
            issueCount == other.issueCount &&
            _orderedEquals(
              issueAcknowledgements,
              other.issueAcknowledgements,
            ) &&
            _orderedEquals(policyBlockers, other.policyBlockers);
  }

  @override
  int get hashCode => Object.hash(
        itemId,
        decision,
        issueCount,
        Object.hashAll(issueAcknowledgements),
        Object.hashAll(policyBlockers),
      );
}

final class ReviewCompletionAssessment {
  factory ReviewCompletionAssessment({
    required String sessionId,
    required int assessedRevision,
    required Iterable<ReviewItemCompletionAssessment> items,
  }) {
    if (assessedRevision < 0) {
      throw const FormatException(
        'Assessed revisions must be non-negative.',
      );
    }
    final copiedItems = List<ReviewItemCompletionAssessment>.unmodifiable(
      items,
    );
    if (copiedItems.isEmpty) {
      throw const FormatException(
        'Completion assessments require at least one item.',
      );
    }
    final itemIds = <String>{};
    for (final item in copiedItems) {
      if (!itemIds.add(item.itemId)) {
        throw const FormatException(
          'Completion assessment item identities must be unique.',
        );
      }
    }
    return ReviewCompletionAssessment._(
      sessionId: _validateOpaqueIdentifier(sessionId, 'sessionId'),
      assessedRevision: assessedRevision,
      items: copiedItems,
    );
  }

  const ReviewCompletionAssessment._({
    required this.sessionId,
    required this.assessedRevision,
    required this.items,
  });

  final String sessionId;
  final int assessedRevision;
  final List<ReviewItemCompletionAssessment> items;

  bool get canComplete => items.every((item) => item.canComplete);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ReviewCompletionAssessment &&
            sessionId == other.sessionId &&
            assessedRevision == other.assessedRevision &&
            _orderedEquals(items, other.items);
  }

  @override
  int get hashCode => Object.hash(
        sessionId,
        assessedRevision,
        Object.hashAll(items),
      );
}

ReviewFieldEdit<List<QuestionOption>> _freezeOptionsEdit(
  ReviewFieldEdit<List<QuestionOption>> edit,
) {
  if (!edit.isReplace) return edit;
  return ReviewFieldEdit<List<QuestionOption>>.replace(
    List<QuestionOption>.unmodifiable(edit.replacement),
  );
}

T _requiredValue<T>(ReviewFieldEdit<T> edit, T original) {
  return edit.isReplace ? edit.replacement : original;
}

T? _nullableValue<T>(ReviewFieldEdit<T?> edit, T? original) {
  if (edit.isClear) return null;
  return edit.isReplace ? edit.replacement : original;
}

List<QuestionOption> _validateOptionReplacement(
  QuestionDraftV2 original,
  List<QuestionOption> replacement,
) {
  final originalById = <String, QuestionOption>{
    for (final option in original.options) option.optionId: option,
  };
  for (final option in replacement) {
    final originalOption = originalById[option.optionId];
    if (originalOption == null) {
      if (option.sourceRef != null) {
        throw const FormatException(
          'New review options must not fabricate source provenance.',
        );
      }
      continue;
    }
    if (option.sourceRef != originalOption.sourceRef) {
      throw const FormatException(
        'Review option edits must preserve existing source provenance.',
      );
    }
  }
  return replacement;
}

String _validateOpaqueIdentifier(String value, String fieldName) {
  if (!_opaqueIdentifierPattern.hasMatch(value)) {
    throw FormatException(
      '$fieldName must use the bounded opaque token format.',
    );
  }
  return value;
}

bool _hasStructuralExplanation(RichContent? explanation) {
  if (explanation == null) return false;
  for (final node in explanation.nodes) {
    if (node is TextNode) {
      if (node.text.trim().isNotEmpty) return true;
    } else {
      return true;
    }
  }
  return false;
}

bool _structuralValueEquals(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is RichContent && right is RichContent) {
    return _orderedStructuralEquals(left.nodes, right.nodes);
  }
  if (left is ContentNode && right is ContentNode) {
    if (left.runtimeType != right.runtimeType) return false;
    return switch (left) {
      TextNode(:final text) => text == (right as TextNode).text,
      InlineMathNode(:final latex) => latex == (right as InlineMathNode).latex,
      BlockMathNode(:final latex) => latex == (right as BlockMathNode).latex,
      RawFallbackNode(:final rawJson) =>
        _structuralValueEquals(rawJson, (right as RawFallbackNode).rawJson),
    };
  }
  if (left is List && right is List) {
    return _orderedStructuralEquals(left, right);
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_structuralValueEquals(entry.value, right[entry.key])) {
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

int _structuralValueHash(Object? value) {
  if (value is RichContent) {
    return Object.hashAll(value.nodes.map(_structuralValueHash));
  }
  if (value is TextNode) return Object.hash('text', value.text);
  if (value is InlineMathNode) {
    return Object.hash('inline_math', value.latex);
  }
  if (value is BlockMathNode) {
    return Object.hash('block_math', value.latex);
  }
  if (value is RawFallbackNode) {
    return Object.hash('raw_fallback', _structuralValueHash(value.rawJson));
  }
  if (value is List) {
    return Object.hashAll(value.map(_structuralValueHash));
  }
  if (value is Map) {
    return Object.hashAllUnordered(
      value.entries.map(
        (entry) => Object.hash(
          _structuralValueHash(entry.key),
          _structuralValueHash(entry.value),
        ),
      ),
    );
  }
  return Object.hash(value.runtimeType, value);
}

bool _orderedStructuralEquals(List<Object?> left, List<Object?> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (!_structuralValueEquals(left[index], right[index])) return false;
  }
  return true;
}

bool _orderedEquals<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
