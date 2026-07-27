import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/services/import_review/import_review_analyzer.dart';
import 'package:shiroha_quiz/services/import_review/import_review_blocking_policy.dart';
import 'package:shiroha_quiz/services/import_review/import_review_issue.dart';
import 'package:shiroha_quiz/services/import_review/import_review_item.dart';
import 'package:shiroha_quiz/services/import_review/import_review_metadata.dart';

void main() {
  group('ImportReviewAnalyzer Tests', () {
    test('Empty list returns perfect score with zero counts', () {
      final res = ImportReviewAnalyzer.analyze([]);
      expect(res.summary.totalCount, 0);
      expect(res.summary.qualityScore, 100);
      expect(res.issues.length, 0);
    });

    test('Valid questions return perfect score', () {
      final drafts = [
        QuestionDraft(
          content: 'Normal question',
          type: QuestionType.shortAnswer,
          options: const [],
          explanation: '',
          standardAnswer: 'Yes',
        ),
      ];
      final res = ImportReviewAnalyzer.analyze(drafts);
      expect(res.summary.qualityScore, 100);
      expect(res.issues.isEmpty, true);
    });

    test('Detects missing stem', () {
      final drafts = [
        QuestionDraft(
          content: '   ',
          type: QuestionType.shortAnswer,
          options: const [],
          explanation: '',
          standardAnswer: 'Yes',
        ),
        QuestionDraft(
          content: '无题干',
          type: QuestionType.shortAnswer,
          options: const [],
          explanation: '',
          standardAnswer: 'Yes',
        ),
      ];
      final res = ImportReviewAnalyzer.analyze(drafts);
      expect(res.summary.errorCount, 2);
      expect(
          res.issues
              .where((i) => i.code == ImportReviewIssueCode.missingStem)
              .length,
          2);
      expect(res.summary.qualityScore, 70); // 100 - 15*2
    });

    test('Detects placeholder stem', () {
      final drafts = [
        QuestionDraft(
          content: '假设XXX',
          type: QuestionType.shortAnswer,
          options: const [],
          explanation: '',
          standardAnswer: 'Yes',
        ),
      ];
      final res = ImportReviewAnalyzer.analyze(drafts);
      expect(res.summary.warningCount, 1);
      expect(res.issues[0].code, ImportReviewIssueCode.placeholderStem);
      expect(res.summary.qualityScore, 95); // 100 - 5
    });

    test('Detects template placeholder stem as missing stem', () {
      final drafts = [
        QuestionDraft(
          content: '题干内容',
          type: QuestionType.shortAnswer,
          options: const [],
          explanation: '',
          standardAnswer: 'A',
        ),
      ];

      final res = ImportReviewAnalyzer.analyze(drafts);
      expect(res.summary.errorCount, 1);
      expect(res.issues.single.code, ImportReviewIssueCode.missingStem);
    });

    test('Detects missing answer', () {
      final drafts = [
        QuestionDraft(
          content: 'Good question',
          type: QuestionType.shortAnswer,
          options: const [],
          explanation: '',
          standardAnswer: '',
        ),
      ];
      final res = ImportReviewAnalyzer.analyze(drafts);
      expect(res.summary.missingAnswerCount, 1);
      expect(res.summary.errorCount, 1);
      expect(res.issues[0].code, ImportReviewIssueCode.missingAnswer);

      // 100 - 15 (error) - 20 (ratio > 40%)
      expect(res.summary.qualityScore, 65);
    });

    test('Detects choice without options', () {
      final drafts = [
        QuestionDraft(
          content: 'Choice q',
          type: QuestionType.singleChoice,
          options: const [],
          explanation: '',
          standardAnswer: 'A',
        ),
      ];
      final res = ImportReviewAnalyzer.analyze(drafts);
      expect(res.summary.choiceIssueCount, 1);
      expect(res.issues[0].code, ImportReviewIssueCode.choiceWithoutOptions);
    });

    test('Detects choice answer out of bounds', () {
      final drafts = [
        QuestionDraft(
          content: 'Choice q',
          type: QuestionType.singleChoice,
          options: const ['Option A', 'Option B'],
          explanation: '',
          standardAnswer: 'C',
        ),
      ];
      final res = ImportReviewAnalyzer.analyze(drafts);
      expect(res.summary.choiceIssueCount, 1);
      expect(
          res.issues[0].code, ImportReviewIssueCode.choiceAnswerNotInOptions);
    });

    test('parses supported choice answer wrappers without scanning prefixes',
        () {
      for (final answer in const ['Option A', 'Answer: B']) {
        final result = ImportReviewAnalyzer.analyze([
          QuestionDraft(
            content: 'Choice question',
            type: QuestionType.singleChoice,
            options: const ['A', 'B'],
            explanation: '',
            standardAnswer: answer,
          ),
        ]);

        expect(
          result.issues,
          isNot(contains(predicate<ImportReviewIssue>(
            (issue) =>
                issue.code == ImportReviewIssueCode.choiceAnswerNotInOptions,
          ))),
          reason: answer,
        );
        expect(ImportReviewBlockingPolicy.isBlocked(result), isFalse);
      }
    });

    test('E is a hard out-of-range answer for four options', () {
      final result = ImportReviewAnalyzer.analyze([
        const QuestionDraft(
          content: 'Choice question',
          type: QuestionType.singleChoice,
          options: ['A', 'B', 'C', 'D'],
          explanation: '',
          standardAnswer: 'E',
        ),
      ]);

      expect(
        result.issues.map((issue) => issue.code),
        contains(ImportReviewIssueCode.choiceAnswerNotInOptions),
      );
      expect(ImportReviewBlockingPolicy.isBlocked(result), isTrue);
    });

    test('unparseable meaningful choice answer is review only', () {
      final result = ImportReviewAnalyzer.analyze([
        const QuestionDraft(
          content: 'Choice question',
          type: QuestionType.singleChoice,
          options: ['A', 'B', 'C', 'D'],
          explanation: '',
          standardAnswer: 'The correct option is described in the source',
        ),
      ]);

      expect(result.summary.warningCount, 1);
      expect(result.summary.errorCount, 0);
      expect(ImportReviewBlockingPolicy.isBlocked(result), isFalse);
    });

    test('single-word text choice answer is review only', () {
      final result = ImportReviewAnalyzer.analyze([
        const QuestionDraft(
          content: 'Choice question',
          type: QuestionType.singleChoice,
          options: ['A', 'B', 'C', 'D'],
          standardAnswer: 'CORRECT',
          explanation: '',
        ),
      ]);

      expect(result.summary.errorCount, 0);
      expect(result.summary.warningCount, 1);
      expect(
        result.issues.single.code,
        ImportReviewIssueCode.choiceAnswerNeedsReview,
      );
      expect(ImportReviewBlockingPolicy.isBlocked(result), isFalse);
    });

    test('blank choice options are structurally missing', () {
      final result = ImportReviewAnalyzer.analyze([
        const QuestionDraft(
          content: 'Choice question',
          type: QuestionType.singleChoice,
          options: ['', '   '],
          explanation: '',
          standardAnswer: 'A',
        ),
      ]);

      expect(
        result.issues.map((issue) => issue.code),
        contains(ImportReviewIssueCode.choiceWithoutOptions),
      );
      expect(ImportReviewBlockingPolicy.isBlocked(result), isTrue);
    });

    test('answer placeholders count as missing without duplicate scoring', () {
      for (final placeholder in const ['无', '暂无', '未知', '未提供', '未给出']) {
        final item = ImportReviewItem(
          draft: QuestionDraft(
            content: 'Short answer question',
            type: QuestionType.shortAnswer,
            options: const [],
            explanation: '',
            standardAnswer: placeholder,
          ),
          metadata: const ImportReviewMetadata(
            source: 'vision',
            sources: ['vision'],
            fragmentKinds: [],
            originalIndices: [0],
            riskHints: ['missing_answer_or_explanation'],
          ),
          originalIndex: 0,
        );

        final result = ImportReviewAnalyzer.analyzeItems([item]);

        expect(result.summary.missingAnswerCount, 1, reason: placeholder);
        expect(result.summary.errorCount, 1, reason: placeholder);
        expect(result.summary.warningCount, 0, reason: placeholder);
        expect(
          result.issues
              .where(
                  (issue) => issue.code == ImportReviewIssueCode.missingAnswer)
              .length,
          1,
          reason: placeholder,
        );
        expect(result.summary.qualityScore, lessThan(100));
      }
    });

    test('missing standalone answer with explanation is review only', () {
      final result = ImportReviewAnalyzer.analyze([
        const QuestionDraft(
          content: 'Short answer question',
          type: QuestionType.shortAnswer,
          options: [],
          explanation: 'A retained explanation',
          standardAnswer: '',
        ),
      ]);

      expect(result.summary.missingAnswerCount, 1);
      expect(result.summary.warningCount, 1);
      expect(result.summary.errorCount, 0);
      expect(result.issues.single.code, ImportReviewIssueCode.missingAnswer);
      expect(ImportReviewBlockingPolicy.isBlocked(result), isFalse);
    });

    test('analyzeItems correctly handles risk hints from metadata', () {
      final items = [
        ImportReviewItem(
          draft: QuestionDraft(
            content: 'Conflict question',
            type: QuestionType.shortAnswer,
            options: const [],
            explanation: '',
            standardAnswer: 'Yes',
          ),
          metadata: const ImportReviewMetadata(
            source: 'fused',
            sources: ['text', 'vision'],
            fragmentKinds: [],
            originalIndices: [],
            riskHints: ['answer_conflict', 'fused_from_text_vision'],
          ),
          originalIndex: 0,
        ),
        ImportReviewItem(
          draft: QuestionDraft(
            content: 'Vision question',
            type: QuestionType.shortAnswer,
            options: const [],
            explanation: '',
            standardAnswer: 'Yes',
          ),
          metadata: const ImportReviewMetadata(
            source: 'vision',
            sources: ['vision'],
            fragmentKinds: [],
            originalIndices: [],
            riskHints: ['vision_only'],
          ),
          originalIndex: 1,
        ),
      ];

      final res = ImportReviewAnalyzer.analyzeItems(items);
      expect(res.summary.warningCount,
          1); // answer_conflict is warning, others are info
      expect(
          res.issues.any((i) => i.code == ImportReviewIssueCode.answerConflict),
          true);
      expect(
          res.issues
              .any((i) => i.code == ImportReviewIssueCode.fusedFromTextVision),
          true);
      expect(res.issues.any((i) => i.code == ImportReviewIssueCode.visionOnly),
          true);

      final conflictIssue = res.issues
          .firstWhere((i) => i.code == ImportReviewIssueCode.answerConflict);
      expect(conflictIssue.severity, ImportReviewSeverity.warning);

      final visionIssue = res.issues
          .firstWhere((i) => i.code == ImportReviewIssueCode.visionOnly);
      expect(visionIssue.severity, ImportReviewSeverity.info);
    });

    test('analyzeItems converts vision quality gate hints into warnings', () {
      final items = [
        ImportReviewItem(
          draft: QuestionDraft(
            content: '解：可得答案。',
            type: QuestionType.shortAnswer,
            options: const [],
            explanation: '',
            standardAnswer: 'A',
          ),
          metadata: const ImportReviewMetadata(
            source: 'vision',
            sources: ['vision'],
            fragmentKinds: [],
            originalIndices: [],
            riskHints: [
              'answer_leaked_to_content',
              'q_num_drift',
              'duplicate_q_num',
              'low_quality_vision_parse',
            ],
          ),
          originalIndex: 0,
        ),
      ];

      final res = ImportReviewAnalyzer.analyzeItems(items);

      expect(res.summary.warningCount, 4);
      expect(
        res.issues.map((issue) => issue.code),
        containsAll([
          ImportReviewIssueCode.answerLeakedToContent,
          ImportReviewIssueCode.questionNumberDrift,
          ImportReviewIssueCode.duplicateQuestionNumber,
          ImportReviewIssueCode.lowQualityVisionParse,
        ]),
      );
    });

    test('does not double count metadata hints for canonical field defects',
        () {
      final items = [
        ImportReviewItem(
          draft: const QuestionDraft(
            content: 'Synthetic question',
            type: QuestionType.singleChoice,
            options: [],
            explanation: '',
            standardAnswer: '',
          ),
          metadata: const ImportReviewMetadata(
            source: 'vision',
            sources: ['vision'],
            fragmentKinds: [],
            originalIndices: [0],
            riskHints: [
              'missing_answer_or_explanation',
              'type_options_mismatch',
            ],
          ),
          originalIndex: 0,
        ),
      ];

      final result = ImportReviewAnalyzer.analyzeItems(items);

      expect(result.summary.errorCount, 2);
      expect(result.summary.warningCount, 0);
      expect(
        result.issues.map((issue) => issue.code),
        containsAll([
          ImportReviewIssueCode.missingAnswer,
          ImportReviewIssueCode.choiceWithoutOptions,
        ]),
      );
    });
  });
}
