import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_review/import_review_issue.dart';
import 'package:shiroha_quiz/services/import_review/import_review_report.dart';
import 'package:shiroha_quiz/services/import_review/import_review_report_formatter.dart';

void main() {
  group('ImportReviewReportFormatter Tests', () {
    test('Formats dialog summary correctly', () {
      final report = ImportReviewReport(
        totalCount: 10,
        qualityScore: 75,
        errorCount: 2,
        warningCount: 3,
        infoCount: 1,
        missingAnswerCount: 1,
        choiceIssueCount: 1,
        issueCodeCounts: const {},
        riskHintCounts: const {},
        sourceCounts: const {},
        highRiskItems: const [],
      );

      final summaryStr =
          ImportReviewReportFormatter.formatDialogSummary(report);
      expect(summaryStr, contains('本次准备入库共 10 道题目。'));
      expect(summaryStr, contains('最终质量评分：75 分'));
      expect(summaryStr, contains('严重错误：2 处'));
      expect(summaryStr, contains('警告提示：3 处'));
      expect(summaryStr, contains('缺失答案与解析：1 题'));
      expect(summaryStr, contains('选择题选项异常：1 题'));
    });

    test('Formats perfect dialog summary correctly', () {
      final report = ImportReviewReport(
        totalCount: 5,
        qualityScore: 100,
        errorCount: 0,
        warningCount: 0,
        infoCount: 0,
        missingAnswerCount: 0,
        choiceIssueCount: 0,
        issueCodeCounts: const {},
        riskHintCounts: const {},
        sourceCounts: const {},
        highRiskItems: const [],
      );

      final summaryStr =
          ImportReviewReportFormatter.formatDialogSummary(report);
      expect(summaryStr, contains('本次准备入库共 5 道题目。'));
      expect(summaryStr, contains('最终质量评分：100 分'));
      expect(summaryStr, contains('完美！未发现任何质量问题。'));
    });

    test('Formats dialog summary with only info issues correctly', () {
      final report = ImportReviewReport(
        totalCount: 3,
        qualityScore: 90,
        errorCount: 0,
        warningCount: 0,
        infoCount: 2,
        missingAnswerCount: 0,
        choiceIssueCount: 0,
        issueCodeCounts: const {},
        riskHintCounts: const {},
        sourceCounts: const {},
        highRiskItems: const [],
      );

      final summaryStr =
          ImportReviewReportFormatter.formatDialogSummary(report);
      expect(summaryStr, contains('本次准备入库共 3 道题目。'));
      expect(summaryStr, contains('最终质量评分：90 分'));
      expect(summaryStr, contains('发现以下问题：'));
      expect(summaryStr, contains('提示信息：2 处'));
      expect(summaryStr, isNot(contains('完美！')));
    });

    test('Formats success report with high risk items correctly', () {
      final report = ImportReviewReport(
        totalCount: 5,
        qualityScore: 80,
        errorCount: 1,
        warningCount: 1,
        infoCount: 1,
        missingAnswerCount: 0,
        choiceIssueCount: 0,
        issueCodeCounts: const {},
        riskHintCounts: const {},
        sourceCounts: const {},
        highRiskItems: [
          ImportReviewReportItem(
            originalIndex: 2,
            displayIndex: 1,
            contentPreview: 'This is question content',
            issueCodes: const [ImportReviewIssueCode.missingStem],
            riskHints: const ['answer_conflict'],
            maxSeverity: ImportReviewSeverity.error,
          ),
        ],
      );

      final successStr = ImportReviewReportFormatter.formatSuccessReport(
        report,
        'My Question Bank',
        'Chapter 1',
      );

      expect(successStr, contains('🎉 题目导入成功！'));
      expect(successStr, contains('导入位置：My Question Bank / Chapter 1'));
      expect(successStr, contains('成功入库：5 题'));
      expect(successStr, contains('质量评分：80 分'));
      expect(successStr, contains('第 1 题 (原第 3 题) - [严重]'));
      expect(successStr, contains('内容预览：This is question content'));
      expect(successStr, contains('问题类型：题干缺失'));
      expect(successStr, contains('风险特征：图文答案冲突'));
    });

    test('Formats issue codes and risk hints labels', () {
      expect(
        ImportReviewReportFormatter.formatIssueCodeLabel(
            ImportReviewIssueCode.missingStem),
        '题干缺失',
      );
      expect(
        ImportReviewReportFormatter.formatRiskHintLabel('answer_conflict'),
        '图文答案冲突',
      );
      expect(
        ImportReviewReportFormatter.formatRiskHintLabel('random_hint_name'),
        'random_hint_name',
      );
    });
  });
}
