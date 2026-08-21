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

/// Typed optimistic-concurrency (CAS) failure for review session
/// transitions: the caller-supplied [expectedRevision] does not match the
/// session's current [actualRevision], so the transition was rejected with
/// zero partial updates.
final class ReviewSessionStaleRevisionError implements Exception {
  const ReviewSessionStaleRevisionError({
    required this.sessionId,
    required this.expectedRevision,
    required this.actualRevision,
  });

  final String sessionId;
  final int expectedRevision;
  final int actualRevision;

  @override
  String toString() => 'ReviewSessionStaleRevisionError(sessionId: $sessionId, '
      'expectedRevision: $expectedRevision, actualRevision: $actualRevision)';
}

/// Selects the single typed field restored by [ReviewSession.restore].
enum ReviewRestoreField {
  kind,
  questionNumber,
  stem,
  options,
  answer,
  explanation,
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
      revision: 0,
      issueAcknowledgements: const <ReviewIssueAcknowledgement>[],
    );
  }

  const ReviewItem._({
    required this.itemId,
    required this.original,
    required this.working,
    required this.edit,
    required this.decision,
    required this.answerAssist,
    required this.revision,
    required this.issueAcknowledgements,
  });

  final String itemId;
  final QuestionDraftV2 original;
  final QuestionDraftV2 working;
  final ReviewEdit edit;
  final ReviewDecision decision;
  final AnswerAssist? answerAssist;
  final int revision;
  final List<ReviewIssueAcknowledgement> issueAcknowledgements;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ReviewItem &&
            itemId == other.itemId &&
            original == other.original &&
            working == other.working &&
            edit == other.edit &&
            decision == other.decision &&
            answerAssist == other.answerAssist &&
            revision == other.revision &&
            _orderedEquals(
              issueAcknowledgements,
              other.issueAcknowledgements,
            );
  }

  @override
  int get hashCode => Object.hash(
        itemId,
        original,
        working,
        edit,
        decision,
        answerAssist,
        revision,
        Object.hashAll(issueAcknowledgements),
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

  /// Applies a typed field [edit] to [itemId]'s working draft. Field edits
  /// compose with the item's accumulated edit (later non-unchanged fields
  /// win), and any existing review decision is cleared back to unreviewed.
  ReviewSession edit({
    required String itemId,
    required ReviewEdit edit,
    required int expectedRevision,
  }) {
    _requireMutable();
    _requireRevision(expectedRevision);
    final itemIndex = _requireItemIndex(itemId);
    final item = items[itemIndex];
    final composedEdit = _composeEdits(item.edit, edit);
    if (composedEdit == item.edit) return this;
    final working = composedEdit.deriveWorkingDraft(item.original);
    return _withItem(
      itemIndex,
      ReviewItem._(
        itemId: item.itemId,
        original: item.original,
        working: working,
        edit: composedEdit,
        decision: ReviewDecision.unreviewed,
        answerAssist: _assistForWorkingExplanation(
          item.answerAssist,
          working.explanation,
        ),
        revision: item.revision + 1,
        issueAcknowledgements: item.issueAcknowledgements,
      ),
    );
  }

  /// Restores a single typed [field] of [itemId] to its original value,
  /// removing that field from the accumulated edit, and clears any review
  /// decision back to unreviewed.
  ReviewSession restore({
    required String itemId,
    required ReviewRestoreField field,
    required int expectedRevision,
  }) {
    _requireMutable();
    _requireRevision(expectedRevision);
    final itemIndex = _requireItemIndex(itemId);
    final item = items[itemIndex];
    if (_editFieldIsUnchanged(item.edit, field)) {
      throw const FormatException(
        'Restoring an already-unchanged review field is not allowed.',
      );
    }
    final restoredEdit = _editWithoutField(item.edit, field);
    final working = restoredEdit.deriveWorkingDraft(item.original);
    return _withItem(
      itemIndex,
      ReviewItem._(
        itemId: item.itemId,
        original: item.original,
        working: working,
        edit: restoredEdit,
        decision: ReviewDecision.unreviewed,
        answerAssist: _assistForWorkingExplanation(
          item.answerAssist,
          working.explanation,
        ),
        revision: item.revision + 1,
        issueAcknowledgements: item.issueAcknowledgements,
      ),
    );
  }

  /// Resets [itemId] to its original draft: all edits, the review decision,
  /// and all issue acknowledgements are cleared, and answer-assist state
  /// inconsistent with the reset working content is removed.
  ReviewSession reset({
    required String itemId,
    required int expectedRevision,
  }) {
    _requireMutable();
    _requireRevision(expectedRevision);
    final itemIndex = _requireItemIndex(itemId);
    final item = items[itemIndex];
    final initialEdit = ReviewEdit.unchanged();
    final working = initialEdit.deriveWorkingDraft(item.original);
    return _withItem(
      itemIndex,
      ReviewItem._(
        itemId: item.itemId,
        original: item.original,
        working: working,
        edit: initialEdit,
        decision: ReviewDecision.unreviewed,
        answerAssist: _assistForWorkingExplanation(
          item.answerAssist,
          working.explanation,
        ),
        revision: item.revision + 1,
        issueAcknowledgements: const <ReviewIssueAcknowledgement>[],
      ),
    );
  }

  /// Records a review [decision] for [itemId] without touching content.
  ReviewSession decide({
    required String itemId,
    required ReviewDecision decision,
    required int expectedRevision,
  }) {
    _requireMutable();
    _requireRevision(expectedRevision);
    if (decision == ReviewDecision.unreviewed) {
      throw const FormatException(
        'Review decisions must be accepted, rejected, or deferred.',
      );
    }
    final itemIndex = _requireItemIndex(itemId);
    final item = items[itemIndex];
    return _withItem(
      itemIndex,
      ReviewItem._(
        itemId: item.itemId,
        original: item.original,
        working: item.working,
        edit: item.edit,
        decision: decision,
        answerAssist: item.answerAssist,
        revision: item.revision + 1,
        issueAcknowledgements: item.issueAcknowledgements,
      ),
    );
  }

  /// Acknowledges one frozen stable issue identity of [itemId]. The issue is
  /// referenced by its index in the item's immutable original issue list;
  /// original [ImportIssue]s are never deleted, modified, or recomputed.
  ReviewSession acknowledge({
    required String itemId,
    required ReviewIssueAcknowledgement acknowledgement,
    required int expectedRevision,
  }) {
    _requireMutable();
    _requireRevision(expectedRevision);
    final itemIndex = _requireItemIndex(itemId);
    final item = items[itemIndex];
    if (acknowledgement.issueIndex >= item.original.issues.length) {
      throw const FormatException(
        'Issue acknowledgements must reference an issue of the reviewed item.',
      );
    }
    final acknowledgements = item.issueAcknowledgements;
    final updatedAcknowledgements = acknowledgements.contains(acknowledgement)
        ? acknowledgements
        : List<ReviewIssueAcknowledgement>.unmodifiable(
            <ReviewIssueAcknowledgement>[
              ...acknowledgements,
              acknowledgement,
            ]..sort(
                (left, right) => left.issueIndex.compareTo(right.issueIndex),
              ),
          );
    return _withItem(
      itemIndex,
      ReviewItem._(
        itemId: item.itemId,
        original: item.original,
        working: item.working,
        edit: item.edit,
        decision: item.decision,
        answerAssist: item.answerAssist,
        revision: item.revision + 1,
        issueAcknowledgements: updatedAcknowledgements,
      ),
    );
  }

  /// Records [assist] answer-assist state for [itemId] after validating it
  /// against the item's current working content.
  ReviewSession applyAnswerAssist({
    required String itemId,
    required AnswerAssist assist,
    required int expectedRevision,
  }) {
    _requireMutable();
    _requireRevision(expectedRevision);
    final itemIndex = _requireItemIndex(itemId);
    final item = items[itemIndex];
    if (assist.status == AnswerAssistStatus.proofExplanationRecognized &&
        !_hasStructuralExplanation(item.working.explanation)) {
      throw const FormatException(
        'Proof recognition requires a structurally non-empty working '
        'explanation.',
      );
    }
    return _withItem(
      itemIndex,
      ReviewItem._(
        itemId: item.itemId,
        original: item.original,
        working: item.working,
        edit: item.edit,
        decision: item.decision,
        answerAssist: assist,
        revision: item.revision + 1,
        issueAcknowledgements: item.issueAcknowledgements,
      ),
    );
  }

  /// Completes the session when [assessment] judges every item as ready. The
  /// assessment must target this session and assess the exact pre-transition
  /// revision; it only judges and never modifies session state. Returns the
  /// completed session together with its [ReviewResult].
  ({ReviewSession session, ReviewResult result}) complete({
    required int expectedRevision,
    required ReviewCompletionAssessment assessment,
  }) {
    _requireMutable();
    _requireRevision(expectedRevision);
    if (assessment.sessionId != sessionId) {
      throw const FormatException(
        'Completion assessments must target this review session.',
      );
    }
    if (assessment.assessedRevision != revision) {
      throw const FormatException(
        'Completion assessments must assess the current pre-transition '
        'revision.',
      );
    }
    if (assessment.items.length != items.length) {
      throw const FormatException(
        'Completion assessments must cover every session item exactly.',
      );
    }
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      final assessed = assessment.items[index];
      if (assessed.itemId != item.itemId) {
        throw const FormatException(
          'Completion assessments must mirror session items in order.',
        );
      }
      if (assessed.decision != item.decision) {
        throw const FormatException(
          'Completion assessments must match the reviewed decisions.',
        );
      }
      if (assessed.issueCount != item.original.issues.length) {
        throw const FormatException(
          "Completion assessments must assess the item's actual issue count.",
        );
      }
      if (!_orderedEquals(
        assessed.issueAcknowledgements,
        item.issueAcknowledgements,
      )) {
        throw const FormatException(
          'Completion assessments must mirror the acknowledged issues.',
        );
      }
      final hasEligibleDecision =
          assessed.decision == ReviewDecision.accepted ||
              assessed.decision == ReviewDecision.rejected;
      final hasAllRequiredAcknowledgements =
          assessed.requiredIssueAcknowledgements.every(
        assessed.issueAcknowledgements.contains,
      );
      if (!hasEligibleDecision ||
          assessed.policyBlockers.isNotEmpty ||
          !hasAllRequiredAcknowledgements) {
        throw const FormatException(
          'Blocking issues or unmet issue acknowledgements prevent '
          'completion.',
        );
      }
    }

    final completedRevision = assessment.assessedRevision + 1;
    final result = ReviewResult(
      sessionId: sessionId,
      completedRevision: completedRevision,
      items: [
        for (final item in items)
          ReviewItemResult(
            itemId: item.itemId,
            decision: item.decision,
            finalDraft:
                item.decision == ReviewDecision.accepted ? item.working : null,
          ),
      ],
    );
    final completedSession = ReviewSession._(
      sessionId: sessionId,
      origin: origin,
      status: ReviewStatus.completed,
      revision: completedRevision,
      items: items,
    );
    return (session: completedSession, result: result);
  }

  /// Terminates the session as abandoned through a CAS transition.
  ReviewSession abandon({required int expectedRevision}) {
    _requireMutable();
    _requireRevision(expectedRevision);
    return ReviewSession._(
      sessionId: sessionId,
      origin: origin,
      status: ReviewStatus.abandoned,
      revision: revision + 1,
      items: items,
    );
  }

  void _requireMutable() {
    if (status == ReviewStatus.completed || status == ReviewStatus.abandoned) {
      throw const FormatException(
        'Review sessions in a terminal state cannot be modified.',
      );
    }
  }

  void _requireRevision(int expectedRevision) {
    if (expectedRevision != revision) {
      throw ReviewSessionStaleRevisionError(
        sessionId: sessionId,
        expectedRevision: expectedRevision,
        actualRevision: revision,
      );
    }
  }

  int _requireItemIndex(String itemId) {
    for (var index = 0; index < items.length; index++) {
      if (items[index].itemId == itemId) return index;
    }
    throw FormatException('Unknown review item identity: $itemId');
  }

  ReviewSession _withItem(int itemIndex, ReviewItem updatedItem) {
    return ReviewSession._(
      sessionId: sessionId,
      origin: origin,
      status: status == ReviewStatus.open ? ReviewStatus.inProgress : status,
      revision: revision + 1,
      items: List<ReviewItem>.unmodifiable([
        for (var index = 0; index < items.length; index++)
          if (index == itemIndex) updatedItem else items[index],
      ]),
    );
  }

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
    Iterable<ReviewIssueAcknowledgement> requiredIssueAcknowledgements =
        const <ReviewIssueAcknowledgement>[],
    Iterable<ReviewPolicyBlocker> policyBlockers =
        const <ReviewPolicyBlocker>[],
  }) {
    if (issueCount < 0) {
      throw const FormatException('Issue counts must be non-negative.');
    }
    final copiedAcknowledgements =
        List<ReviewIssueAcknowledgement>.unmodifiable(
      List<ReviewIssueAcknowledgement>.of(issueAcknowledgements)
        ..sort((left, right) => left.issueIndex.compareTo(right.issueIndex)),
    );
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
    final copiedRequiredAcknowledgements =
        List<ReviewIssueAcknowledgement>.unmodifiable(
      List<ReviewIssueAcknowledgement>.of(requiredIssueAcknowledgements)
        ..sort((left, right) => left.issueIndex.compareTo(right.issueIndex)),
    );
    final requiredIndexes = <int>{};
    for (final acknowledgement in copiedRequiredAcknowledgements) {
      if (acknowledgement.issueIndex >= issueCount) {
        throw const FormatException(
          'Required issue acknowledgements must reference an assessed issue.',
        );
      }
      if (!requiredIndexes.add(acknowledgement.issueIndex)) {
        throw const FormatException(
          'Required issue acknowledgements must be unique within an '
          'assessment.',
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
      requiredIssueAcknowledgements: copiedRequiredAcknowledgements,
      policyBlockers: copiedBlockers,
    );
  }

  const ReviewItemCompletionAssessment._({
    required this.itemId,
    required this.decision,
    required this.issueCount,
    required this.issueAcknowledgements,
    required this.requiredIssueAcknowledgements,
    required this.policyBlockers,
  });

  final String itemId;
  final ReviewDecision decision;
  final int issueCount;
  final List<ReviewIssueAcknowledgement> issueAcknowledgements;
  final List<ReviewIssueAcknowledgement> requiredIssueAcknowledgements;
  final List<ReviewPolicyBlocker> policyBlockers;

  bool get canComplete =>
      (decision == ReviewDecision.accepted ||
          decision == ReviewDecision.rejected) &&
      policyBlockers.isEmpty &&
      requiredIssueAcknowledgements.every(issueAcknowledgements.contains);

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
            _orderedEquals(
              requiredIssueAcknowledgements,
              other.requiredIssueAcknowledgements,
            ) &&
            _orderedEquals(policyBlockers, other.policyBlockers);
  }

  @override
  int get hashCode => Object.hash(
        itemId,
        decision,
        issueCount,
        Object.hashAll(issueAcknowledgements),
        Object.hashAll(requiredIssueAcknowledgements),
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

/// One completed item result: an accepted item carries its final working
/// draft, a rejected item carries none. The original draft never changes.
final class ReviewItemResult {
  factory ReviewItemResult({
    required String itemId,
    required ReviewDecision decision,
    QuestionDraftV2? finalDraft,
  }) {
    if (decision != ReviewDecision.accepted &&
        decision != ReviewDecision.rejected) {
      throw const FormatException(
        'Completed item results only carry accepted or rejected decisions.',
      );
    }
    if (decision == ReviewDecision.accepted && finalDraft == null) {
      throw const FormatException(
        'Accepted item results require the final working draft.',
      );
    }
    if (decision == ReviewDecision.rejected && finalDraft != null) {
      throw const FormatException(
        'Rejected item results do not carry a final draft.',
      );
    }
    return ReviewItemResult._(
      itemId: _validateOpaqueIdentifier(itemId, 'itemId'),
      decision: decision,
      finalDraft: finalDraft,
    );
  }

  const ReviewItemResult._({
    required this.itemId,
    required this.decision,
    required this.finalDraft,
  });

  final String itemId;
  final ReviewDecision decision;
  final QuestionDraftV2? finalDraft;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ReviewItemResult &&
            itemId == other.itemId &&
            decision == other.decision &&
            finalDraft == other.finalDraft;
  }

  @override
  int get hashCode => Object.hash(itemId, decision, finalDraft);
}

/// Pure completion result of a review session. [completedRevision] equals the
/// session revision after the completion transition; there is no separate
/// source revision in this result.
final class ReviewResult {
  factory ReviewResult({
    required String sessionId,
    required int completedRevision,
    required Iterable<ReviewItemResult> items,
  }) {
    if (completedRevision < 0) {
      throw const FormatException(
        'Completed review revisions must be non-negative.',
      );
    }
    final copiedItems = List<ReviewItemResult>.unmodifiable(items);
    if (copiedItems.isEmpty) {
      throw const FormatException(
        'Completed review results require at least one item.',
      );
    }
    final itemIds = <String>{};
    for (final item in copiedItems) {
      if (!itemIds.add(item.itemId)) {
        throw const FormatException(
          'Completed review item identities must be unique.',
        );
      }
    }
    return ReviewResult._(
      sessionId: _validateOpaqueIdentifier(sessionId, 'sessionId'),
      completedRevision: completedRevision,
      items: copiedItems,
    );
  }

  const ReviewResult._({
    required this.sessionId,
    required this.completedRevision,
    required this.items,
  });

  final String sessionId;
  final int completedRevision;
  final List<ReviewItemResult> items;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ReviewResult &&
            sessionId == other.sessionId &&
            completedRevision == other.completedRevision &&
            _orderedEquals(items, other.items);
  }

  @override
  int get hashCode =>
      Object.hash(sessionId, completedRevision, Object.hashAll(items));
}

ReviewFieldEdit<List<QuestionOption>> _freezeOptionsEdit(
  ReviewFieldEdit<List<QuestionOption>> edit,
) {
  if (!edit.isReplace) return edit;
  return ReviewFieldEdit<List<QuestionOption>>.replace(
    List<QuestionOption>.unmodifiable(edit.replacement),
  );
}

ReviewEdit _composeEdits(ReviewEdit current, ReviewEdit delta) {
  return ReviewEdit._(
    kind: delta.kind.isUnchanged ? current.kind : delta.kind,
    questionNumber: delta.questionNumber.isUnchanged
        ? current.questionNumber
        : delta.questionNumber,
    stem: delta.stem.isUnchanged ? current.stem : delta.stem,
    options: delta.options.isUnchanged ? current.options : delta.options,
    answer: delta.answer.isUnchanged ? current.answer : delta.answer,
    explanation:
        delta.explanation.isUnchanged ? current.explanation : delta.explanation,
  );
}

ReviewEdit _editWithoutField(ReviewEdit edit, ReviewRestoreField field) {
  return switch (field) {
    ReviewRestoreField.kind => ReviewEdit._(
        kind: const ReviewFieldEdit<QuestionKind>.unchanged(),
        questionNumber: edit.questionNumber,
        stem: edit.stem,
        options: edit.options,
        answer: edit.answer,
        explanation: edit.explanation,
      ),
    ReviewRestoreField.questionNumber => ReviewEdit._(
        kind: edit.kind,
        questionNumber: const ReviewFieldEdit<int?>.unchanged(),
        stem: edit.stem,
        options: edit.options,
        answer: edit.answer,
        explanation: edit.explanation,
      ),
    ReviewRestoreField.stem => ReviewEdit._(
        kind: edit.kind,
        questionNumber: edit.questionNumber,
        stem: const ReviewFieldEdit<RichContent>.unchanged(),
        options: edit.options,
        answer: edit.answer,
        explanation: edit.explanation,
      ),
    ReviewRestoreField.options => ReviewEdit._(
        kind: edit.kind,
        questionNumber: edit.questionNumber,
        stem: edit.stem,
        options: const ReviewFieldEdit<List<QuestionOption>>.unchanged(),
        answer: edit.answer,
        explanation: edit.explanation,
      ),
    ReviewRestoreField.answer => ReviewEdit._(
        kind: edit.kind,
        questionNumber: edit.questionNumber,
        stem: edit.stem,
        options: edit.options,
        answer: const ReviewFieldEdit<QuestionAnswer?>.unchanged(),
        explanation: edit.explanation,
      ),
    ReviewRestoreField.explanation => ReviewEdit._(
        kind: edit.kind,
        questionNumber: edit.questionNumber,
        stem: edit.stem,
        options: edit.options,
        answer: edit.answer,
        explanation: const ReviewFieldEdit<RichContent?>.unchanged(),
      ),
  };
}

bool _editFieldIsUnchanged(ReviewEdit edit, ReviewRestoreField field) {
  return switch (field) {
    ReviewRestoreField.kind => edit.kind.isUnchanged,
    ReviewRestoreField.questionNumber => edit.questionNumber.isUnchanged,
    ReviewRestoreField.stem => edit.stem.isUnchanged,
    ReviewRestoreField.options => edit.options.isUnchanged,
    ReviewRestoreField.answer => edit.answer.isUnchanged,
    ReviewRestoreField.explanation => edit.explanation.isUnchanged,
  };
}

AnswerAssist? _assistForWorkingExplanation(
  AnswerAssist? assist,
  RichContent? explanation,
) {
  if (assist == null) return null;
  if (assist.status == AnswerAssistStatus.proofExplanationRecognized &&
      !_hasStructuralExplanation(explanation)) {
    return null;
  }
  return assist;
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
      ImageNode() || TableNode() => left == right,
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
  if (value is ImageNode || value is TableNode) return value.hashCode;
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
