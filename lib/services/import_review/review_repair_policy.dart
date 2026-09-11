import '../../data/models/question_draft.dart';
import '../import_pipeline/latex_sanity_checker.dart';
import 'import_review_issue.dart';
import 'import_review_metadata.dart';
import 'review_repair_edit.dart';

enum ReviewRepairStrategy { structuralQuestion, latexFragment }

/// One eligible review question together with the fields an AI repair may
/// rewrite.
///
/// [fields] is the complete allow-list for the proposal: a repair that changes
/// any other field is rejected, so a review repair can never silently rewrite
/// content the review already accepted.
final class ReviewRepairTarget {
  factory ReviewRepairTarget({
    required int originalIndex,
    required int questionNumber,
    required List<String> triggerCodes,
    required List<ReviewRepairField> fields,
    ReviewRepairStrategy strategy = ReviewRepairStrategy.structuralQuestion,
  }) {
    if (fields.isEmpty) {
      throw const FormatException('review repair target requires a field');
    }
    return ReviewRepairTarget._(
      originalIndex: originalIndex,
      questionNumber: questionNumber,
      triggerCodes: List<String>.unmodifiable(triggerCodes),
      fields: List<ReviewRepairField>.unmodifiable(fields),
      strategy: strategy,
    );
  }

  const ReviewRepairTarget._({
    required this.originalIndex,
    required this.questionNumber,
    required this.triggerCodes,
    required this.fields,
    required this.strategy,
  });

  final int originalIndex;
  final int questionNumber;
  final List<String> triggerCodes;
  final List<ReviewRepairField> fields;
  final ReviewRepairStrategy strategy;

  bool allows(ReviewRepairField field) => fields.contains(field);
}

/// Review-layer AI repair eligibility.
///
/// This policy is deliberately *not* the import-time automatic repair policy.
/// Import-time repair keeps its own trigger set
/// (`ImportQuestionRepairPolicy.candidateCodes`) and never consults this class,
/// so adding a review repair entry point cannot add an automatic OCR import
/// provider call.
///
/// Eligibility is allow-listed. Everything that cannot be repaired from the
/// current question text alone stays review-only, including source ownership
/// problems, asset identity, unsafe or corrupt metadata and unsupported typed
/// structure.
final class ReviewRepairPolicy {
  const ReviewRepairPolicy();

  /// Safe trigger code for an unrenderable final LaTeX field.
  static const String latexUnrenderableCode = 'latex_unrenderable';

  /// Import-time candidate codes that may also be repaired on demand.
  static const Set<String> _repairableCandidateCodes = <String>{
    'dangling_latex',
    'empty_content',
    'choice_options_less_than_2',
    'choice_missing_answer',
  };

  /// Returns the repair target for one review item, or `null` when AI repair is
  /// not allowed for it.
  ReviewRepairTarget? targetFor({
    required int originalIndex,
    required int questionNumber,
    required QuestionDraft draft,
    required ImportReviewMetadata metadata,
    required ImportReviewMetadataProjectionState metadataProjectionState,
    required List<ImportReviewIssue> issues,
    bool hasTypedSnapshot = true,
  }) {
    if (metadataProjectionState !=
        ImportReviewMetadataProjectionState.available) {
      return null;
    }

    final structuralTriggers = <String>[];
    final structuralFields = <ReviewRepairField>{};

    for (final code in metadata.repairCandidateCodes) {
      if (!_repairableCandidateCodes.contains(code)) continue;
      final mapped = _fieldsForCandidateCode(code, draft);
      if (mapped.isEmpty) continue;
      structuralTriggers.add(code);
      structuralFields.addAll(mapped);
    }

    // Structural issues always run first. A mixed item is re-audited after the
    // structural proposal is applied before a later fragment attempt.
    if (structuralFields.isNotEmpty) {
      return ReviewRepairTarget(
        originalIndex: originalIndex,
        questionNumber: questionNumber,
        triggerCodes: structuralTriggers.toSet().toList()..sort(),
        fields: ReviewRepairField.values
            .where(structuralFields.contains)
            .toList(growable: false),
      );
    }

    if (!hasTypedSnapshot ||
        !issues.any(
          (issue) => issue.code == ImportReviewIssueCode.latexUnrenderable,
        )) {
      return null;
    }
    final latexFields = _latexFields(metadata);
    if (latexFields.isEmpty) return null;

    return ReviewRepairTarget(
      originalIndex: originalIndex,
      questionNumber: questionNumber,
      triggerCodes: const <String>[latexUnrenderableCode],
      fields: ReviewRepairField.values
          .where(latexFields.contains)
          .toList(growable: false),
      strategy: ReviewRepairStrategy.latexFragment,
    );
  }

  List<ReviewRepairField> _latexFields(ImportReviewMetadata metadata) {
    return <ReviewRepairField>[
      for (final name in metadata.latexInvalidFields)
        if (ReviewRepairField.fromWireKey(name) case final field?) field,
    ];
  }

  List<ReviewRepairField> _fieldsForCandidateCode(
    String code,
    QuestionDraft draft,
  ) {
    switch (code) {
      case 'dangling_latex':
        const checker = LatexSanityChecker();
        return <ReviewRepairField>[
          if (checker.hasDanglingDelimiters(draft.content))
            ReviewRepairField.content,
          if (draft.options.any(checker.hasDanglingDelimiters))
            ReviewRepairField.options,
          if (checker.hasDanglingDelimiters(draft.standardAnswer))
            ReviewRepairField.standardAnswer,
          if (checker.hasDanglingDelimiters(draft.explanation))
            ReviewRepairField.explanation,
        ];
      case 'empty_content':
        return draft.content.trim().isEmpty
            ? const <ReviewRepairField>[ReviewRepairField.content]
            : const <ReviewRepairField>[];
      case 'choice_options_less_than_2':
        return draft.type == QuestionType.singleChoice
            ? const <ReviewRepairField>[ReviewRepairField.options]
            : const <ReviewRepairField>[];
      case 'choice_missing_answer':
        return draft.type == QuestionType.singleChoice
            ? const <ReviewRepairField>[ReviewRepairField.standardAnswer]
            : const <ReviewRepairField>[];
      default:
        return const <ReviewRepairField>[];
    }
  }
}
