import 'import_review_report.dart';
import 'import_review_issue.dart';

class ImportReviewReportFormatter {
  static String formatDialogSummary(ImportReviewReport report) {
    final buffer = StringBuffer();
    buffer.writeln('本次准备入库共 ${report.totalCount} 道题目。');
    buffer.writeln('最终质量评分：${report.qualityScore} 分');
    if (report.errorCount > 0 ||
        report.warningCount > 0 ||
        report.infoCount > 0 ||
        report.missingAnswerCount > 0 ||
        report.choiceIssueCount > 0) {
      buffer.writeln('发现以下问题：');
      if (report.errorCount > 0) {
        buffer.writeln('  • 严重错误：${report.errorCount} 处');
      }
      if (report.warningCount > 0) {
        buffer.writeln('  • 警告提示：${report.warningCount} 处');
      }
      if (report.infoCount > 0) {
        buffer.writeln('  • 提示信息：${report.infoCount} 处');
      }
      if (report.missingAnswerCount > 0) {
        buffer.writeln('  • 缺失答案与解析：${report.missingAnswerCount} 题');
      }
      if (report.choiceIssueCount > 0) {
        buffer.writeln('  • 选择题选项异常：${report.choiceIssueCount} 题');
      }
    } else {
      buffer.writeln('完美！未发现任何质量问题。');
    }
    return buffer.toString();
  }

  static String formatSuccessReport(
    ImportReviewReport report,
    String bankName,
    String folderName,
  ) {
    final buffer = StringBuffer();
    buffer.writeln('🎉 题目导入成功！');
    buffer.writeln('----------------------------------------');
    buffer.writeln('导入位置：$bankName / $folderName');
    buffer.writeln('成功入库：${report.totalCount} 题');
    buffer.writeln('质量评分：${report.qualityScore} 分');
    buffer.writeln('其中包含：');
    buffer.writeln('  - 严重错误：${report.errorCount} 个');
    buffer.writeln('  - 警告提示：${report.warningCount} 个');
    buffer.writeln('  - 提示信息：${report.infoCount} 个');
    buffer.writeln('----------------------------------------');

    if (report.highRiskItems.isNotEmpty) {
      buffer.writeln('⚠️ 高风险题目清单（前 5 条）：');
      final itemsToShow = report.highRiskItems.take(5).toList();
      for (final item in itemsToShow) {
        final severityStr = _getSeverityChinese(item.maxSeverity);
        buffer.writeln(
            '  第 ${item.displayIndex} 题 (原第 ${item.originalIndex + 1} 题) - [$severityStr]');
        buffer.writeln('    内容预览：${item.contentPreview}');
        if (item.issueCodes.isNotEmpty) {
          final issuesStr =
              item.issueCodes.map((c) => formatIssueCodeLabel(c)).join('、');
          buffer.writeln('    问题类型：$issuesStr');
        }
        if (item.riskHints.isNotEmpty) {
          final hintsStr =
              item.riskHints.map((h) => formatRiskHintLabel(h)).join('、');
          buffer.writeln('    风险特征：$hintsStr');
        }
      }
      if (report.highRiskItems.length > 5) {
        buffer.writeln('  ... 还有其他 ${report.highRiskItems.length - 5} 道高风险题目');
      }
    } else {
      buffer.writeln('✨ 所有题目均无明显质量缺陷。');
    }
    return buffer.toString();
  }

  static String formatIssueCodeLabel(ImportReviewIssueCode code) {
    switch (code) {
      case ImportReviewIssueCode.missingStem:
        return '题干缺失';
      case ImportReviewIssueCode.placeholderStem:
        return '包含 AI 占位符/假设';
      case ImportReviewIssueCode.missingAnswer:
        return '缺少标准答案';
      case ImportReviewIssueCode.choiceWithoutOptions:
        return '选择题无选项';
      case ImportReviewIssueCode.choiceAnswerNotInOptions:
        return '选项不包含标准答案';
      case ImportReviewIssueCode.choiceAnswerNeedsReview:
        return '选择题答案格式需复核';
      case ImportReviewIssueCode.answerConflict:
        return '图文答案冲突';
      case ImportReviewIssueCode.orphanFragment:
        return '孤立题目片段';
      case ImportReviewIssueCode.answerOnlyFragment:
        return '仅包含答案片段';
      case ImportReviewIssueCode.partialQuestion:
        return '题目可能被截断';
      case ImportReviewIssueCode.visionOnly:
        return '仅视觉提取';
      case ImportReviewIssueCode.fusedFromTextVision:
        return '图文融合题目';
      case ImportReviewIssueCode.unsupportedTypeFallback:
        return '不支持的题型回退';
      case ImportReviewIssueCode.answerLeakedToContent:
        return '答案疑似进入题干';
      case ImportReviewIssueCode.missingAnswerOrExplanation:
        return '视觉审计缺答案/解析';
      case ImportReviewIssueCode.typeOptionsMismatch:
        return '题型与选项不一致';
      case ImportReviewIssueCode.duplicateQuestionNumber:
        return '重复题号';
      case ImportReviewIssueCode.questionNumberDrift:
        return '题号顺序漂移';
      case ImportReviewIssueCode.lowQualityVisionParse:
        return '视觉结构质量偏低';
      case ImportReviewIssueCode.latexUnrenderable:
        return 'LaTeX 无法可靠渲染';
      case ImportReviewIssueCode.rawHtmlTag:
        return '最终字段存在 HTML 残留';
    }
  }

  static String formatRiskHintLabel(String hint) {
    switch (hint) {
      case 'answer_conflict':
        return '图文答案冲突';
      case 'orphan_fragment':
        return '孤立题目片段';
      case 'answer_only_fragment':
        return '仅包含答案片段';
      case 'partial_question':
        return '题目可能被截断';
      case 'vision_only':
        return '仅视觉来源';
      case 'fused_from_text_vision':
        return '图文融合来源';
      case 'answer_leaked_to_content':
        return '答案疑似进入题干';
      case 'missing_answer_or_explanation':
        return '缺失答案或解析';
      case 'type_options_mismatch':
        return '题型与选项不一致';
      case 'duplicate_q_num':
        return '重复题号';
      case 'q_num_drift':
        return '题号顺序漂移';
      case 'low_quality_vision_parse':
        return '视觉结构质量偏低';
      case 'latex_unrenderable':
        return 'LaTeX 无法可靠渲染';
      case 'raw_html_tag':
        return '最终字段存在 HTML 残留';
      default:
        return hint;
    }
  }

  static String _getSeverityChinese(ImportReviewSeverity severity) {
    switch (severity) {
      case ImportReviewSeverity.error:
        return '严重';
      case ImportReviewSeverity.warning:
        return '警告';
      case ImportReviewSeverity.info:
        return '提示';
    }
  }
}
