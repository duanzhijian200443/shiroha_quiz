import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/services/import_review/import_review_item.dart';
import 'package:shiroha_quiz/services/import_review/import_review_metadata.dart';
import 'package:shiroha_quiz/services/import_review/import_review_analyzer.dart';
import 'package:shiroha_quiz/services/import_review/import_review_issue.dart';
import 'package:shiroha_quiz/services/import_review/import_review_report_builder.dart';

void main() {
  group('ImportReviewReportBuilder Tests', () {
    test('Builds report with correct issue code counts and risk hint counts',
        () {
      final items = [
        ImportReviewItem(
          draft: QuestionDraft(
            content: 'Clean Question 1',
            type: QuestionType.singleChoice,
            options: const ['A', 'B', 'C', 'D'],
            explanation: 'Exp',
            standardAnswer: 'A',
          ),
          metadata: const ImportReviewMetadata(
            source: 'fused',
            sources: ['text', 'vision'],
            fragmentKinds: ['fullQuestion'],
            originalIndices: [0],
            riskHints: ['fused_from_text_vision'],
          ),
          originalIndex: 0,
        ),
        ImportReviewItem(
          draft: QuestionDraft(
            content: '', // missingStem -> error
            type: QuestionType.singleChoice,
            options: const ['A', 'B'],
            explanation: 'Exp',
            standardAnswer: 'A',
          ),
          metadata: const ImportReviewMetadata(
            source: 'text',
            sources: ['text'],
            fragmentKinds: ['stem'],
            originalIndices: [1],
            riskHints: [],
          ),
          originalIndex: 1,
        ),
        ImportReviewItem(
          draft: QuestionDraft(
            content: 'Question 3',
            type: QuestionType.singleChoice,
            options: const [], // choiceWithoutOptions -> error, missingAnswer -> error
            explanation: '',
            standardAnswer: '',
          ),
          metadata: const ImportReviewMetadata(
            source: 'vision',
            sources: ['vision'],
            fragmentKinds: [],
            originalIndices: [2],
            riskHints: ['vision_only', 'answer_conflict'],
          ),
          originalIndex: 2,
        ),
      ];

      final analysis = ImportReviewAnalyzer.analyzeItems(items);
      final report = ImportReviewReportBuilder.build(items, analysis);

      expect(report.totalCount, 3);
      expect(report.errorCount, analysis.summary.errorCount);
      expect(report.warningCount, analysis.summary.warningCount);

      // Verify issue code counts
      expect(report.issueCodeCounts[ImportReviewIssueCode.missingStem], 1);
      expect(report.issueCodeCounts[ImportReviewIssueCode.choiceWithoutOptions],
          1);
      expect(report.issueCodeCounts[ImportReviewIssueCode.missingAnswer], 1);

      // Verify risk hint counts
      expect(report.riskHintCounts['fused_from_text_vision'], 1);
      expect(report.riskHintCounts['vision_only'], 1);
      expect(report.riskHintCounts['answer_conflict'], 1);

      // Verify source counts
      expect(report.sourceCounts['fused'], 1);
      expect(report.sourceCounts['text'], 1);
      expect(report.sourceCounts['vision'], 1);
    });

    test('Filters deleted questions and reflects remaining questions in report',
        () {
      final allItems = [
        ImportReviewItem(
          draft: QuestionDraft(
            content: 'Question 1',
            type: QuestionType.singleChoice,
            options: const ['A', 'B'],
            explanation: 'Exp',
            standardAnswer: 'A',
          ),
          metadata: ImportReviewMetadata.empty(),
          originalIndex: 0,
        ),
        ImportReviewItem(
          draft: QuestionDraft(
            content: 'Question 2 (To be deleted)',
            type: QuestionType.singleChoice,
            options: const [], // choiceWithoutOptions -> error
            explanation: 'Exp',
            standardAnswer: 'A',
          ),
          metadata: ImportReviewMetadata.empty(),
          originalIndex: 1,
        ),
        ImportReviewItem(
          draft: QuestionDraft(
            content: 'Question 3',
            type: QuestionType.singleChoice,
            options: const ['A', 'B'],
            explanation: 'Exp',
            standardAnswer: 'A',
          ),
          metadata: ImportReviewMetadata.empty(),
          originalIndex: 2,
        ),
      ];

      // Simulate deleting item at index 1
      final remainingItems = [allItems[0], allItems[2]];
      final analysis = ImportReviewAnalyzer.analyzeItems(remainingItems);
      final report = ImportReviewReportBuilder.build(remainingItems, analysis);

      expect(report.totalCount, 2);
      expect(report.errorCount, 0); // The error item was deleted
      expect(report.highRiskItems, isEmpty);
    });

    test(
        'Sorts high risk items descending by severity (error > warning > info)',
        () {
      final items = [
        // 0. Info item (fused)
        ImportReviewItem(
          draft: QuestionDraft(
            content: 'Question Info',
            type: QuestionType.singleChoice,
            options: const ['A', 'B'],
            explanation: 'Exp',
            standardAnswer: 'A',
          ),
          metadata: const ImportReviewMetadata(
            source: 'fused',
            sources: ['text', 'vision'],
            fragmentKinds: [],
            originalIndices: [0],
            riskHints: ['fused_from_text_vision'], // Generates Info issue
          ),
          originalIndex: 0,
        ),
        // 1. Error item (missing stem)
        ImportReviewItem(
          draft: QuestionDraft(
            content: '',
            type: QuestionType.singleChoice,
            options: const ['A', 'B'],
            explanation: 'Exp',
            standardAnswer: 'A',
          ),
          metadata: ImportReviewMetadata.empty(),
          originalIndex: 1,
        ),
        // 2. Warning item (placeholder stem)
        ImportReviewItem(
          draft: QuestionDraft(
            content: '假设这道题是这样的...', // Placeholder stem -> warning
            type: QuestionType.singleChoice,
            options: const ['A', 'B'],
            explanation: 'Exp',
            standardAnswer: 'A',
          ),
          metadata: ImportReviewMetadata.empty(),
          originalIndex: 2,
        ),
      ];

      final analysis = ImportReviewAnalyzer.analyzeItems(items);
      final report = ImportReviewReportBuilder.build(items, analysis);

      expect(report.highRiskItems.length, 3);
      // Order should be Error (index 1), Warning (index 2), Info (index 0)
      expect(report.highRiskItems[0].originalIndex, 1);
      expect(report.highRiskItems[0].maxSeverity, ImportReviewSeverity.error);

      expect(report.highRiskItems[1].originalIndex, 2);
      expect(report.highRiskItems[1].maxSeverity, ImportReviewSeverity.warning);

      expect(report.highRiskItems[2].originalIndex, 0);
      expect(report.highRiskItems[2].maxSeverity, ImportReviewSeverity.info);
    });

    test('Content preview fallback works for empty content', () {
      final items = [
        ImportReviewItem(
          draft: QuestionDraft(
            content: '',
            type: QuestionType.singleChoice,
            options: const ['A', 'B'],
            explanation: 'Exp',
            standardAnswer: 'A',
          ),
          metadata: ImportReviewMetadata.empty(),
          originalIndex: 0,
        ),
      ];

      final analysis = ImportReviewAnalyzer.analyzeItems(items);
      final report = ImportReviewReportBuilder.build(items, analysis);

      expect(report.highRiskItems.first.contentPreview, '无题干描述');
    });
  });
}
