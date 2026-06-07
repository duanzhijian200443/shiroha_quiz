import '../../data/models/question_draft.dart';
import 'import_review_issue.dart';
import 'import_review_summary.dart';
import 'import_review_item.dart';
import 'import_review_metadata.dart';
import '../import_pipeline/question_fragment.dart';

class ImportReviewAnalyzerResult {
  final ImportReviewSummary summary;
  final List<ImportReviewIssue> issues;

  const ImportReviewAnalyzerResult(this.summary, this.issues);
}

class ImportReviewAnalyzer {
  static ImportReviewAnalyzerResult analyze(List<QuestionDraft> drafts) {
    final items = drafts
        .asMap()
        .entries
        .map((e) => ImportReviewItem(
              draft: e.value,
              metadata: ImportReviewMetadata.empty(),
              originalIndex: e.key,
            ))
        .toList();
    return analyzeItems(items);
  }

  static ImportReviewAnalyzerResult analyzeItems(List<ImportReviewItem> items) {
    int errorCount = 0;
    int warningCount = 0;
    int missingAnswerCount = 0;
    int choiceIssueCount = 0;
    final List<ImportReviewIssue> issues = [];

    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      final draft = item.draft;
      final content = draft.content.trim();

      // Analyze metadata risk hints
      for (final hint in item.metadata.riskHints) {
        if (hint == 'answer_conflict') {
          issues.add(ImportReviewIssue(
            severity: ImportReviewSeverity.warning,
            code: ImportReviewIssueCode.answerConflict,
            questionIndex: i,
            message: '图文独立解析时答案存在冲突，已保留双方结果，需人工确认',
          ));
          warningCount++;
        } else if (hint == 'orphan_fragment') {
          issues.add(ImportReviewIssue(
            severity: ImportReviewSeverity.warning,
            code: ImportReviewIssueCode.orphanFragment,
            questionIndex: i,
            message: '融合阶段出现孤立片段，请检查原文档题号或结构',
          ));
          warningCount++;
        } else if (hint == 'answer_only_fragment') {
          issues.add(ImportReviewIssue(
            severity: ImportReviewSeverity.warning,
            code: ImportReviewIssueCode.answerOnlyFragment,
            questionIndex: i,
            message: '发现仅有答案的片段被保留',
          ));
          warningCount++;
        } else if (hint == 'partial_question') {
          issues.add(ImportReviewIssue(
            severity: ImportReviewSeverity.warning,
            code: ImportReviewIssueCode.partialQuestion,
            questionIndex: i,
            message: '题目似乎被截断，请检查原图或文本',
          ));
          warningCount++;
        } else if (hint == 'vision_only') {
          issues.add(ImportReviewIssue(
            severity: ImportReviewSeverity.info,
            code: ImportReviewIssueCode.visionOnly,
            questionIndex: i,
            message: '本题仅由视觉模型提取',
          ));
        } else if (hint == 'fused_from_text_vision') {
          issues.add(ImportReviewIssue(
            severity: ImportReviewSeverity.info,
            code: ImportReviewIssueCode.fusedFromTextVision,
            questionIndex: i,
            message: '本题由文本与视觉模型结果融合而成',
          ));
        }
      }

      // Check missing stem
      if (content.isEmpty) {
        issues.add(ImportReviewIssue(
          severity: ImportReviewSeverity.error,
          code: ImportReviewIssueCode.missingStem,
          questionIndex: i,
          message: '题干为空',
        ));
        errorCount++;
      } else if (QuestionFragment.isPlaceholderStem(content)) {
        issues.add(ImportReviewIssue(
          severity: ImportReviewSeverity.error,
          code: ImportReviewIssueCode.missingStem,
          questionIndex: i,
          message: '题干为保留占位符',
        ));
        errorCount++;
      } else if (content.contains('假设') || content.contains('原题干')) {
        issues.add(ImportReviewIssue(
          severity: ImportReviewSeverity.warning,
          code: ImportReviewIssueCode.placeholderStem,
          questionIndex: i,
          message: '题干可能包含 AI 占位符假设',
        ));
        warningCount++;
      }

      // Check missing answer
      final stdAns = draft.standardAnswer.trim();
      final expl = draft.explanation.trim();
      if (stdAns.isEmpty && expl.isEmpty) {
        issues.add(ImportReviewIssue(
          severity: ImportReviewSeverity.error,
          code: ImportReviewIssueCode.missingAnswer,
          questionIndex: i,
          message: '缺失标准答案与解析',
        ));
        errorCount++;
        missingAnswerCount++;
      }

      // Check choice options
      if (draft.type == QuestionType.singleChoice) {
        // single choice
        final opts = draft.options;
        if (opts.isEmpty) {
          issues.add(ImportReviewIssue(
            severity: ImportReviewSeverity.error,
            code: ImportReviewIssueCode.choiceWithoutOptions,
            questionIndex: i,
            message: '选择题没有提供选项',
          ));
          errorCount++;
          choiceIssueCount++;
        } else if (stdAns.isNotEmpty) {
          // simple check: if answer letters (A,B,C,D) are not matching options count or content
          // In standard format, stdAns might be "A" or "A,B".
          // Just do a basic check for out-of-bounds letters if stdAns is purely alphabetic.
          final cleanAns =
              stdAns.replaceAll(',', '').replaceAll(' ', '').toUpperCase();
          bool outOfBounds = false;
          for (int j = 0; j < cleanAns.length; j++) {
            final char = cleanAns[j];
            if (char.codeUnitAt(0) >= 65 && char.codeUnitAt(0) <= 90) {
              // A-Z
              final idx = char.codeUnitAt(0) - 65;
              if (idx >= opts.length) {
                outOfBounds = true;
                break;
              }
            }
          }
          if (outOfBounds) {
            issues.add(ImportReviewIssue(
              severity: ImportReviewSeverity.error,
              code: ImportReviewIssueCode.choiceAnswerNotInOptions,
              questionIndex: i,
              message: '答案超出选项范围',
            ));
            errorCount++;
            choiceIssueCount++;
          }
        }
      }
    }

    // calculate quality score
    int qualityScore = 100;
    qualityScore -= (errorCount * 15);
    qualityScore -= (warningCount * 5);

    if (items.isNotEmpty) {
      double missingRatio = missingAnswerCount / items.length;
      if (missingRatio > 0.4) {
        qualityScore -= 20;
      }
    }

    if (qualityScore < 0) {
      qualityScore = 0;
    }

    return ImportReviewAnalyzerResult(
      ImportReviewSummary(
        totalCount: items.length,
        errorCount: errorCount,
        warningCount: warningCount,
        missingAnswerCount: missingAnswerCount,
        choiceIssueCount: choiceIssueCount,
        qualityScore: qualityScore,
      ),
      issues,
    );
  }
}
