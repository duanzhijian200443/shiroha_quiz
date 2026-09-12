import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_repair_policy.dart';
import 'package:shiroha_quiz/services/import_review/import_review_issue.dart';
import 'package:shiroha_quiz/services/import_review/import_review_metadata.dart';
import 'package:shiroha_quiz/services/import_review/review_repair_edit.dart';
import 'package:shiroha_quiz/services/import_review/review_repair_policy.dart';

const ImportReviewMetadata _latexMetadata = ImportReviewMetadata(
  source: 'ocr',
  sources: <String>['ocr'],
  fragmentKinds: <String>[],
  originalIndices: <int>[0],
  riskHints: <String>['latex_unrenderable'],
  latexInvalidFields: <String>['explanation'],
);

ImportReviewMetadata _metadata({
  List<String> riskHints = const <String>[],
  List<String> repairCandidateCodes = const <String>[],
  List<String> latexInvalidFields = const <String>[],
}) {
  return ImportReviewMetadata(
    source: 'ocr',
    sources: const <String>['ocr'],
    fragmentKinds: const <String>[],
    originalIndices: const <int>[0],
    riskHints: riskHints,
    repairCandidateCodes: repairCandidateCodes,
    latexInvalidFields: latexInvalidFields,
  );
}

ImportReviewIssue _issue(ImportReviewIssueCode code) {
  return ImportReviewIssue(
    severity: ImportReviewSeverity.warning,
    code: code,
    questionIndex: 0,
    message: 'synthetic',
  );
}

void main() {
  const policy = ReviewRepairPolicy();

  ReviewRepairTarget? targetFor({
    String content = 'Stem',
    List<String> options = const <String>[],
    String standardAnswer = 'A',
    String explanation = 'Explanation',
    ImportReviewMetadata? metadata,
    ImportReviewMetadataProjectionState state =
        ImportReviewMetadataProjectionState.available,
    List<ImportReviewIssue> issues = const <ImportReviewIssue>[],
    int originalIndex = 20,
    bool hasTypedSnapshot = true,
  }) {
    return policy.targetFor(
      originalIndex: originalIndex,
      questionNumber: originalIndex + 1,
      draft: QuestionDraft(
        type: options.isEmpty
            ? QuestionType.shortAnswer
            : QuestionType.singleChoice,
        content: content,
        options: options,
        standardAnswer: standardAnswer,
        explanation: explanation,
      ),
      metadata: metadata ?? _latexMetadata,
      metadataProjectionState: state,
      issues: issues,
      hasTypedSnapshot: hasTypedSnapshot,
    );
  }

  group('ReviewRepairPolicy eligibility', () {
    test('an unrenderable LaTeX field is repairable', () {
      final target = targetFor(issues: <ImportReviewIssue>[
        _issue(ImportReviewIssueCode.latexUnrenderable),
      ]);

      expect(target, isNotNull);
      expect(target!.fields, <ReviewRepairField>[
        ReviewRepairField.explanation,
      ]);
      expect(target.triggerCodes, <String>['latex_unrenderable']);
      expect(target.strategy, ReviewRepairStrategy.latexFragment);
      expect(target.questionNumber, 21);
    });

    test('pure LaTeX repair requires a typed snapshot', () {
      expect(
        targetFor(
          hasTypedSnapshot: false,
          issues: <ImportReviewIssue>[
            _issue(ImportReviewIssueCode.latexUnrenderable),
          ],
        ),
        isNull,
      );
    });

    test('mixed issues route only the structural repair first', () {
      final target = targetFor(
        explanation: r'Broken \(x',
        metadata: _metadata(
          riskHints: const <String>['latex_unrenderable'],
          repairCandidateCodes: const <String>['dangling_latex'],
          latexInvalidFields: const <String>['explanation'],
        ),
        issues: <ImportReviewIssue>[
          _issue(ImportReviewIssueCode.latexUnrenderable),
        ],
      );

      expect(target, isNotNull);
      expect(target!.strategy, ReviewRepairStrategy.structuralQuestion);
      expect(target.triggerCodes, <String>['dangling_latex']);
      expect(
        target.fields,
        <ReviewRepairField>[ReviewRepairField.explanation],
      );
    });

    test('allows every safe invalid field name the audit records', () {
      final target = targetFor(
        content: r'Bad \(x',
        options: <String>['A. bad \\(y', 'B. ok'],
        metadata: _metadata(
          riskHints: const <String>['latex_unrenderable'],
          latexInvalidFields: const <String>[
            'content',
            'options',
            'standard_answer',
          ],
        ),
        issues: <ImportReviewIssue>[
          _issue(ImportReviewIssueCode.latexUnrenderable),
        ],
      );

      expect(target, isNotNull);
      expect(target!.fields, <ReviewRepairField>[
        ReviewRepairField.content,
        ReviewRepairField.options,
        ReviewRepairField.standardAnswer,
      ]);
    });

    test('requires a flagged invalid field', () {
      final target = targetFor(
        metadata: _metadata(riskHints: const <String>['latex_unrenderable']),
        issues: <ImportReviewIssue>[
          _issue(ImportReviewIssueCode.latexUnrenderable),
        ],
      );

      expect(target, isNull);
    });

    test('keeps non-repairable risks review-only', () {
      for (final code in <ImportReviewIssueCode>[
        ImportReviewIssueCode.rawHtmlTag,
        ImportReviewIssueCode.answerConflict,
        ImportReviewIssueCode.orphanFragment,
        ImportReviewIssueCode.answerOnlyFragment,
        ImportReviewIssueCode.partialQuestion,
        ImportReviewIssueCode.visionOnly,
        ImportReviewIssueCode.fusedFromTextVision,
        ImportReviewIssueCode.answerLeakedToContent,
        ImportReviewIssueCode.duplicateQuestionNumber,
        ImportReviewIssueCode.questionNumberDrift,
        ImportReviewIssueCode.lowQualityVisionParse,
        ImportReviewIssueCode.missingStem,
        ImportReviewIssueCode.placeholderStem,
        ImportReviewIssueCode.missingAnswer,
        ImportReviewIssueCode.choiceWithoutOptions,
        ImportReviewIssueCode.choiceAnswerNotInOptions,
        ImportReviewIssueCode.choiceAnswerNeedsReview,
        ImportReviewIssueCode.typeOptionsMismatch,
        ImportReviewIssueCode.missingAnswerOrExplanation,
        ImportReviewIssueCode.unsupportedTypeFallback,
      ]) {
        expect(targetFor(issues: <ImportReviewIssue>[_issue(code)]), isNull,
            reason: code.name);
      }
    });

    test('requires available review metadata', () {
      expect(
        targetFor(
          state: ImportReviewMetadataProjectionState.unavailable,
          issues: <ImportReviewIssue>[
            _issue(ImportReviewIssueCode.latexUnrenderable),
          ],
        ),
        isNull,
      );
      expect(
        targetFor(
          state: ImportReviewMetadataProjectionState.notProvided,
          issues: <ImportReviewIssue>[
            _issue(ImportReviewIssueCode.latexUnrenderable),
          ],
        ),
        isNull,
      );
    });

    test('maps the repairable candidate codes to their fields', () {
      final dangling = targetFor(
        explanation: r'Broken \(x',
        hasTypedSnapshot: false,
        metadata: _metadata(
          repairCandidateCodes: const <String>['dangling_latex'],
        ),
      );
      expect(dangling!.fields, <ReviewRepairField>[
        ReviewRepairField.explanation,
      ]);
      expect(dangling.triggerCodes, <String>['dangling_latex']);

      final emptyContent = targetFor(
        content: '',
        metadata:
            _metadata(repairCandidateCodes: const <String>['empty_content']),
      );
      expect(emptyContent!.fields, <ReviewRepairField>[
        ReviewRepairField.content,
      ]);

      final choiceOptions = targetFor(
        options: const <String>['A. one'],
        metadata: _metadata(
          repairCandidateCodes: const <String>['choice_options_less_than_2'],
        ),
      );
      expect(choiceOptions!.fields, <ReviewRepairField>[
        ReviewRepairField.options,
      ]);

      final choiceAnswer = targetFor(
        options: const <String>['A. one', 'B. two'],
        standardAnswer: '',
        metadata: _metadata(
          repairCandidateCodes: const <String>['choice_missing_answer'],
        ),
      );
      expect(choiceAnswer!.fields, <ReviewRepairField>[
        ReviewRepairField.standardAnswer,
      ]);
    });

    test('ignores unknown candidate codes and non-applicable ones', () {
      expect(
        targetFor(
          metadata:
              _metadata(repairCandidateCodes: const <String>['cross_page']),
        ),
        isNull,
      );
      expect(
        targetFor(
          content: 'Healthy',
          metadata:
              _metadata(repairCandidateCodes: const <String>['empty_content']),
        ),
        isNull,
      );
      // A subjective question never maps choice-only codes onto its own fields.
      expect(
        targetFor(
          metadata: _metadata(
            repairCandidateCodes: const <String>['choice_missing_answer'],
          ),
        ),
        isNull,
      );
    });
  });

  group('import-time repair isolation', () {
    test('review eligibility never adds an import-time trigger', () {
      const importPolicy = ImportQuestionRepairPolicy();
      final question = <String, dynamic>{
        'question_number': 21,
        'type': 3,
        'content': r'Synthetic \begin{array}{l} broken stem',
        'options': <String>[],
        'standard_answer': 'answer',
        'explanation': r'Broken \(\begin{matrix}1',
        'diagnostics': <String>['latex_unrenderable'],
      };

      expect(importPolicy.candidateCodes(question), isEmpty);
      expect(
        importPolicy.candidateCodes(question, diagnostics: const <String>[]),
        isEmpty,
      );
      // The import-time trigger set is unchanged.
      expect(
        importPolicy.candidateCodes(
          question,
          diagnostics: const <String>['dangling_latex'],
        ),
        <String>['dangling_latex'],
      );
    });
  });
}
