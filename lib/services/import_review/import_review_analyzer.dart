import '../../data/models/question_draft.dart';
import '../../data/models/import_question_validation.dart';
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
        } else if (hint == 'answer_leaked_to_content') {
          issues.add(ImportReviewIssue(
            severity: ImportReviewSeverity.warning,
            code: ImportReviewIssueCode.answerLeakedToContent,
            questionIndex: i,
            message: '题干疑似混入答案或解析，请核对字段归属',
          ));
          warningCount++;
        } else if (hint == 'duplicate_q_num') {
          issues.add(ImportReviewIssue(
            severity: ImportReviewSeverity.warning,
            code: ImportReviewIssueCode.duplicateQuestionNumber,
            questionIndex: i,
            message: '视觉结果中出现重复题号，请核对是否误合并',
          ));
          warningCount++;
        } else if (hint == 'q_num_drift') {
          issues.add(ImportReviewIssue(
            severity: ImportReviewSeverity.warning,
            code: ImportReviewIssueCode.questionNumberDrift,
            questionIndex: i,
            message: '视觉结果题号顺序疑似漂移',
          ));
          warningCount++;
        } else if (hint == 'low_quality_vision_parse') {
          issues.add(ImportReviewIssue(
            severity: ImportReviewSeverity.warning,
            code: ImportReviewIssueCode.lowQualityVisionParse,
            questionIndex: i,
            message: '本批次视觉结构质量偏低，建议重点复核',
          ));
          warningCount++;
        } else if (hint == 'latex_unrenderable') {
          issues.add(ImportReviewIssue(
            severity: ImportReviewSeverity.warning,
            code: ImportReviewIssueCode.latexUnrenderable,
            questionIndex: i,
            message: '题目包含无法可靠渲染的 LaTeX，请人工核对',
          ));
          warningCount++;
        } else if (hint == 'raw_html_tag') {
          issues.add(ImportReviewIssue(
            severity: ImportReviewSeverity.warning,
            code: ImportReviewIssueCode.rawHtmlTag,
            questionIndex: i,
            message: '最终字段仍包含无法安全清理的 HTML 标签，请人工核对',
          ));
          warningCount++;
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
      final hasMeaningfulAnswer = isMeaningfulAnswer(stdAns);
      if (!hasMeaningfulAnswer) {
        final hasExplanation = expl.isNotEmpty;
        issues.add(ImportReviewIssue(
          severity: hasExplanation
              ? ImportReviewSeverity.warning
              : ImportReviewSeverity.error,
          code: ImportReviewIssueCode.missingAnswer,
          questionIndex: i,
          message: hasExplanation ? '缺少单列标准答案，已保留解析供复核' : '缺失标准答案与解析',
        ));
        if (hasExplanation) {
          warningCount++;
        } else {
          errorCount++;
        }
        missingAnswerCount++;
      }

      // Check choice options
      if (draft.type == QuestionType.singleChoice) {
        // single choice
        final opts = meaningfulOptions(draft.options);
        if (opts.length < 2) {
          issues.add(ImportReviewIssue(
            severity: ImportReviewSeverity.error,
            code: ImportReviewIssueCode.choiceWithoutOptions,
            questionIndex: i,
            message: '选择题没有提供选项',
          ));
          errorCount++;
          choiceIssueCount++;
        } else if (hasMeaningfulAnswer) {
          final parsedAnswer = parseChoiceAnswerLabels(stdAns);
          final outOfBounds = parsedAnswer.parsed &&
              parsedAnswer.labels.any(
                (label) => label.codeUnitAt(0) - 65 >= opts.length,
              );
          if (outOfBounds) {
            issues.add(ImportReviewIssue(
              severity: ImportReviewSeverity.error,
              code: ImportReviewIssueCode.choiceAnswerNotInOptions,
              questionIndex: i,
              message: '答案超出选项范围',
            ));
            errorCount++;
            choiceIssueCount++;
          } else if (!parsedAnswer.parsed) {
            issues.add(ImportReviewIssue(
              severity: ImportReviewSeverity.warning,
              code: ImportReviewIssueCode.choiceAnswerNeedsReview,
              questionIndex: i,
              message: '选择题答案无法安全解析为选项标签，请人工复核',
            ));
            warningCount++;
            choiceIssueCount++;
          }
        }
      } else if (meaningfulOptions(draft.options).isNotEmpty) {
        issues.add(ImportReviewIssue(
          severity: ImportReviewSeverity.error,
          code: ImportReviewIssueCode.typeOptionsMismatch,
          questionIndex: i,
          message: '非选择题包含选项，请核对题型',
        ));
        errorCount++;
        choiceIssueCount++;
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
