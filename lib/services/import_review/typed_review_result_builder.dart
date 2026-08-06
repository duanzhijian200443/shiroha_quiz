import 'package:shiroha_quiz/application/import_review/question_draft_v2_review_session_adapter.dart';
import 'package:shiroha_quiz/application/import_review/review_session.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/data/models/import_question_validation.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:uuid/uuid.dart';

/// One typed commit input: the R7A persisted review marker identity, the
/// `_typed_review_v1` envelope, and the commit-time finalized legacy draft.
///
/// Collections are defensively copied. No arbitrary provenance map,
/// diagnostics, file path or Provider content is ever carried here.
final class TypedReviewCommitInput {
  TypedReviewCommitInput({
    required this.reviewItemId,
    required this.envelope,
    required QuestionDraft currentDraft,
  }) : currentDraft = QuestionDraft(
          type: currentDraft.type,
          content: currentDraft.content,
          options: List<String>.unmodifiable(currentDraft.options),
          standardAnswer: currentDraft.standardAnswer,
          explanation: currentDraft.explanation,
          rawExplanation: currentDraft.rawExplanation,
        );

  final String reviewItemId;
  final Object? envelope;
  final QuestionDraft currentDraft;
}

/// Pure outcome of a typed review build: the completed [ReviewResult] and
/// the accepted final drafts extracted from that result.
final class TypedReviewBuildResult {
  TypedReviewBuildResult({
    required this.reviewResult,
    required List<QuestionDraftV2> acceptedDrafts,
  }) : acceptedDrafts = List<QuestionDraftV2>.unmodifiable(acceptedDrafts);

  final ReviewResult reviewResult;
  final List<QuestionDraftV2> acceptedDrafts;
}

/// Fixed classification of typed commit failures.
enum TypedReviewCommitFailure {
  invalidRoute,
  invalidOrigin,
  missingSnapshot,
  corruptSnapshot,
  identityMismatch,
  baselineMismatch,
  unsupportedOptionEdit,
  qualityBlocked,
  emptyCommit,
  reviewCompletionFailed,
  unsafePayload,
  persistenceFailed,
}

/// Safe fixed typed commit exception.
///
/// Carries only the failure classification. [toString] returns fixed text
/// and never includes question content, envelopes, paths, source IDs,
/// database errors, stack traces or Provider content.
final class TypedReviewCommitException implements Exception {
  const TypedReviewCommitException(this.failure);

  final TypedReviewCommitFailure failure;

  @override
  String toString() {
    return switch (failure) {
      TypedReviewCommitFailure.invalidRoute =>
        'Typed commit requires the typedV2 route and ready reason.',
      TypedReviewCommitFailure.invalidOrigin =>
        'Typed commit requires a valid task origin.',
      TypedReviewCommitFailure.missingSnapshot =>
        'Typed commit requires a review snapshot envelope.',
      TypedReviewCommitFailure.corruptSnapshot =>
        'Typed commit review snapshot envelope is invalid.',
      TypedReviewCommitFailure.identityMismatch =>
        'Typed commit review snapshot identity does not match.',
      TypedReviewCommitFailure.baselineMismatch =>
        'Typed commit review baseline does not match the snapshot.',
      TypedReviewCommitFailure.unsupportedOptionEdit =>
        'Typed commit does not support structural option edits.',
      TypedReviewCommitFailure.qualityBlocked =>
        'Typed commit is blocked by the quality gate.',
      TypedReviewCommitFailure.emptyCommit =>
        'Typed commit requires at least one accepted question.',
      TypedReviewCommitFailure.reviewCompletionFailed =>
        'Typed review session could not be completed.',
      TypedReviewCommitFailure.unsafePayload =>
        'Typed commit payload is unsafe.',
      TypedReviewCommitFailure.persistenceFailed =>
        'Typed commit persistence failed.',
    };
  }
}

/// Pure business logic bridge from current staging edits to a completed
/// [ReviewSession] [ReviewResult].
///
/// This component never accesses SQLite, repositories, task managers, UI,
/// Provider, filesystem or network. Every input envelope is strictly
/// restored and cross-checked against the marker identity and the committed
/// legacy draft; any failure blocks the whole commit with a fixed
/// [TypedReviewCommitException].
final class TypedReviewResultBuilder {
  TypedReviewResultBuilder({
    QuestionDraftV2ReviewSessionAdapter? adapter,
    String Function()? sessionIdFactory,
  })  : _adapter = adapter ?? const QuestionDraftV2ReviewSessionAdapter(),
        _sessionIdFactory = sessionIdFactory ?? _defaultSessionIdFactory;

  final QuestionDraftV2ReviewSessionAdapter _adapter;
  final String Function() _sessionIdFactory;

  static String _defaultSessionIdFactory() => 'review_${const Uuid().v4()}';

  /// Builds the completed [ReviewResult] for the current commit set.
  ///
  /// [inputs] must be the current staging items in stable order; deleted
  /// questions never enter the session. The returned accepted drafts are
  /// extracted from [TypedReviewBuildResult.reviewResult] only.
  TypedReviewBuildResult build({
    required List<TypedReviewCommitInput> inputs,
    required String taskId,
    required String attemptToken,
    required int attemptNumber,
  }) {
    if (inputs.isEmpty) {
      throw const TypedReviewCommitException(
        TypedReviewCommitFailure.emptyCommit,
      );
    }
    _requireValidOrigin(taskId, attemptToken, attemptNumber);

    const codec = TypedReviewSnapshotCodec();
    final snapshots = <TypedReviewSnapshot>[];
    final reviewItemIds = <String>{};
    final questionIds = <String>{};
    for (final input in inputs) {
      final snapshot = _decodeSnapshot(codec, input);
      if (input.reviewItemId != snapshot.reviewItemId ||
          snapshot.questionId != snapshot.draft.questionId) {
        throw const TypedReviewCommitException(
          TypedReviewCommitFailure.identityMismatch,
        );
      }
      if (!reviewItemIds.add(snapshot.reviewItemId) ||
          !questionIds.add(snapshot.questionId)) {
        throw const TypedReviewCommitException(
          TypedReviewCommitFailure.identityMismatch,
        );
      }
      _requireCanonicalSourceIds(snapshot.draft);
      _requireBaselineConsistency(snapshot);
      snapshots.add(snapshot);
    }

    final ReviewSession session;
    try {
      session = _adapter.openSession(
        sessionId: _sessionIdFactory(),
        taskId: taskId,
        attemptToken: attemptToken,
        attemptNumber: attemptNumber,
        items: <QuestionDraftV2ReviewItemInput>[
          for (var index = 0; index < inputs.length; index++)
            (
              itemId: inputs[index].reviewItemId,
              draft: snapshots[index].draft,
            ),
        ],
      );
    } on FormatException {
      throw const TypedReviewCommitException(
        TypedReviewCommitFailure.invalidOrigin,
      );
    }

    try {
      var working = session;
      for (var index = 0; index < inputs.length; index++) {
        final edit = _buildEdit(snapshots[index], inputs[index].currentDraft);
        if (edit.isUnchanged) continue;
        working = working.edit(
          itemId: inputs[index].reviewItemId,
          edit: edit,
          expectedRevision: working.revision,
        );
      }
      for (var index = 0; index < inputs.length; index++) {
        working = working.decide(
          itemId: inputs[index].reviewItemId,
          decision: ReviewDecision.accepted,
          expectedRevision: working.revision,
        );
      }

      final assessment = ReviewCompletionAssessment(
        sessionId: working.sessionId,
        assessedRevision: working.revision,
        items: <ReviewItemCompletionAssessment>[
          for (final item in working.items)
            ReviewItemCompletionAssessment(
              itemId: item.itemId,
              decision: item.decision,
              issueCount: item.original.issues.length,
              issueAcknowledgements: item.issueAcknowledgements,
            ),
        ],
      );
      final completed = working.complete(
        expectedRevision: working.revision,
        assessment: assessment,
      );
      if (completed.session.status != ReviewStatus.completed ||
          completed.result.completedRevision != completed.session.revision) {
        throw const TypedReviewCommitException(
          TypedReviewCommitFailure.reviewCompletionFailed,
        );
      }

      final acceptedDrafts = <QuestionDraftV2>[
        for (final item in completed.result.items)
          if (item.decision == ReviewDecision.accepted) item.finalDraft!,
      ];
      if (acceptedDrafts.isEmpty) {
        throw const TypedReviewCommitException(
          TypedReviewCommitFailure.emptyCommit,
        );
      }
      return TypedReviewBuildResult(
        reviewResult: completed.result,
        acceptedDrafts: acceptedDrafts,
      );
    } on TypedReviewCommitException {
      rethrow;
    } on FormatException {
      throw const TypedReviewCommitException(
        TypedReviewCommitFailure.reviewCompletionFailed,
      );
    } on ReviewSessionStaleRevisionError {
      throw const TypedReviewCommitException(
        TypedReviewCommitFailure.reviewCompletionFailed,
      );
    }
  }

  TypedReviewSnapshot _decodeSnapshot(
    TypedReviewSnapshotCodec codec,
    TypedReviewCommitInput input,
  ) {
    try {
      return codec.decodeRequired(input.envelope);
    } on TypedReviewSnapshotException catch (error) {
      throw TypedReviewCommitException(
        switch (error.failure) {
          TypedReviewSnapshotFailure.missingPayload =>
            TypedReviewCommitFailure.missingSnapshot,
          TypedReviewSnapshotFailure.unsafePayload =>
            TypedReviewCommitFailure.unsafePayload,
          _ => TypedReviewCommitFailure.corruptSnapshot,
        },
      );
    }
  }

  void _requireValidOrigin(
    String taskId,
    String attemptToken,
    int attemptNumber,
  ) {
    final originValid = taskId.trim().isNotEmpty &&
        attemptToken.trim().isNotEmpty &&
        attemptNumber > 0;
    if (!originValid) {
      throw const TypedReviewCommitException(
        TypedReviewCommitFailure.invalidOrigin,
      );
    }
  }

  void _requireCanonicalSourceIds(QuestionDraftV2 draft) {
    for (final sourceRef in draft.sourceRefs) {
      if (!isCanonicalUuidV4(sourceRef.sourceId)) {
        throw const TypedReviewCommitException(
          TypedReviewCommitFailure.identityMismatch,
        );
      }
    }
  }

  void _requireBaselineConsistency(TypedReviewSnapshot snapshot) {
    final baseline = snapshot.baselineLegacy;
    if (baseline.questionNumber != snapshot.draft.questionNumber) {
      throw const TypedReviewCommitException(
        TypedReviewCommitFailure.baselineMismatch,
      );
    }
    if (_kindForLegacyType(baseline.type) != snapshot.draft.kind) {
      throw const TypedReviewCommitException(
        TypedReviewCommitFailure.baselineMismatch,
      );
    }
  }

  ReviewEdit _buildEdit(
    TypedReviewSnapshot snapshot,
    QuestionDraft current,
  ) {
    final baseline = snapshot.baselineLegacy;
    final kindEdit =
        _kindForLegacyType(baseline.type) == _kindForQuestionType(current.type)
            ? const ReviewFieldEdit<QuestionKind>.unchanged()
            : ReviewFieldEdit<QuestionKind>.replace(
                _kindForQuestionType(current.type),
              );

    final stemEdit = current.content == baseline.content
        ? const ReviewFieldEdit<RichContent>.unchanged()
        : ReviewFieldEdit<RichContent>.replace(
            RichContent(nodes: <ContentNode>[TextNode(current.content)]),
          );

    final explanationEdit = _explanationEdit(
      current.explanation,
      baseline.explanation,
    );
    final optionsEdit = _optionsEdit(snapshot, current);
    final answerEdit = _answerEdit(snapshot, current);

    return ReviewEdit(
      kind: kindEdit,
      stem: stemEdit,
      options: optionsEdit,
      answer: answerEdit,
      explanation: explanationEdit,
    );
  }

  ReviewFieldEdit<RichContent?> _explanationEdit(
    String current,
    String baseline,
  ) {
    if (current == baseline) {
      return const ReviewFieldEdit<RichContent?>.unchanged();
    }
    if (current.isEmpty) {
      return const ReviewFieldEdit<RichContent?>.clear();
    }
    return ReviewFieldEdit<RichContent?>.replace(
      RichContent(nodes: <ContentNode>[TextNode(current)]),
    );
  }

  ReviewFieldEdit<List<QuestionOption>> _optionsEdit(
    TypedReviewSnapshot snapshot,
    QuestionDraft current,
  ) {
    final typedOptions = snapshot.draft.options;
    final baselineOptions = snapshot.baselineLegacy.options;
    final currentOptions = current.options;
    if (baselineOptions.length != currentOptions.length ||
        baselineOptions.length != typedOptions.length) {
      throw const TypedReviewCommitException(
        TypedReviewCommitFailure.unsupportedOptionEdit,
      );
    }

    final currentLabels = <String>{};
    var changed = false;
    final replacement = <QuestionOption>[];
    for (var index = 0; index < baselineOptions.length; index++) {
      final baselineOption = _parseLegacyOption(baselineOptions[index]);
      final currentOption = _parseLegacyOption(currentOptions[index]);
      if (baselineOption.label != currentOption.label ||
          !currentLabels.add(currentOption.label)) {
        throw const TypedReviewCommitException(
          TypedReviewCommitFailure.unsupportedOptionEdit,
        );
      }
      final original = typedOptions[index];
      if (baselineOption.body == currentOption.body) {
        replacement.add(original);
      } else {
        changed = true;
        replacement.add(
          QuestionOption(
            optionId: original.optionId,
            label: original.label,
            content: RichContent(
              nodes: <ContentNode>[TextNode(currentOption.body)],
            ),
            sourceRef: original.sourceRef,
          ),
        );
      }
    }
    if (!changed) {
      return const ReviewFieldEdit<List<QuestionOption>>.unchanged();
    }
    return ReviewFieldEdit<List<QuestionOption>>.replace(
      List<QuestionOption>.unmodifiable(replacement),
    );
  }

  ReviewFieldEdit<QuestionAnswer?> _answerEdit(
    TypedReviewSnapshot snapshot,
    QuestionDraft current,
  ) {
    final baseline = snapshot.baselineLegacy.standardAnswer;
    final currentAnswer = current.standardAnswer;
    if (currentAnswer == baseline) {
      return const ReviewFieldEdit<QuestionAnswer?>.unchanged();
    }
    if (currentAnswer.isEmpty) {
      return const ReviewFieldEdit<QuestionAnswer?>.clear();
    }
    return ReviewFieldEdit<QuestionAnswer?>.replace(
      _mapAnswerText(
        currentAnswer,
        _kindForQuestionType(current.type),
        snapshot.draft,
      ),
    );
  }

  QuestionAnswer _mapAnswerText(
    String text,
    QuestionKind currentKind,
    QuestionDraftV2 typedDraft,
  ) {
    if (currentKind == QuestionKind.singleChoice) {
      final parsed = parseChoiceAnswerLabels(text);
      if (parsed.parsed && parsed.labels.isNotEmpty) {
        final optionIdByLabel = <String, String>{};
        var labelsUnique = true;
        for (final option in typedDraft.options) {
          if (optionIdByLabel.containsKey(option.label)) {
            labelsUnique = false;
            break;
          }
          optionIdByLabel[option.label] = option.optionId;
        }
        if (labelsUnique) {
          final optionIds = <String>[];
          var allFound = true;
          for (final label in parsed.labels) {
            final optionId = optionIdByLabel[label];
            if (optionId == null) {
              allFound = false;
              break;
            }
            optionIds.add(optionId);
          }
          if (allFound) {
            return ChoiceAnswer(optionIds: optionIds);
          }
        }
      }
    }
    return ContentAnswer(
      content: RichContent(nodes: <ContentNode>[TextNode(text)]),
    );
  }

  QuestionKind _kindForLegacyType(int type) {
    return switch (type) {
      0 => QuestionKind.singleChoice,
      2 => QuestionKind.fillBlank,
      3 => QuestionKind.shortAnswer,
      _ => throw const TypedReviewCommitException(
          TypedReviewCommitFailure.corruptSnapshot,
        ),
    };
  }

  QuestionKind _kindForQuestionType(QuestionType type) {
    return switch (type) {
      QuestionType.singleChoice => QuestionKind.singleChoice,
      QuestionType.fillBlank => QuestionKind.fillBlank,
      QuestionType.shortAnswer => QuestionKind.shortAnswer,
    };
  }
}

final _legacyOptionPattern = RegExp(
  r'^([A-Za-z])\s*[.．、]\s*(.*)$',
  dotAll: true,
);

({String label, String body}) _parseLegacyOption(String value) {
  final match = _legacyOptionPattern.firstMatch(value);
  if (match == null) return (label: value, body: '');
  return (label: match.group(1)!, body: match.group(2)!);
}
