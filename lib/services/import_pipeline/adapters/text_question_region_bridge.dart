import '../../../domain/content/content_node.dart';
import '../../../domain/content/rich_content.dart';
import '../../../domain/import/import_issue.dart';
import '../../../domain/question/question_region.dart';
import '../../../domain/source/source_part.dart';
import '../../../domain/source/source_ref.dart';
import '../text_question_region.dart';

final class TextQuestionRegionBridge {
  const TextQuestionRegionBridge();

  QuestionRegion convert(
    TextQuestionRegion region, {
    required SourceRef sourceRef,
  }) {
    final coarseRef = SourceRef.document(
      sourceId: sourceRef.sourceId,
      displayLabel: sourceRef.displayLabel,
    );
    final stemText = region.rawText;

    final fragments = <QuestionRegionFragment>[
      QuestionRegionFragment(
        field: QuestionRegionField.stem,
        part: SourceContentPart(
          sourceRef: coarseRef,
          content: _textContent(stemText),
        ),
      ),
    ];
    final issues = <ImportIssue>{
      ImportIssue(
        code: 'legacy_provenance_coarse',
        severity: ImportIssueSeverity.warning,
        field: ImportIssueField.source,
        sourceRef: coarseRef,
      ),
    };

    final answerText = region.answerText?.trim();
    if (answerText != null && answerText.isNotEmpty) {
      fragments.add(
        QuestionRegionFragment(
          field: QuestionRegionField.answer,
          part: SourceContentPart(
            sourceRef: coarseRef,
            content: _textContent(answerText),
          ),
        ),
      );
    }

    for (final diagnostic in region.diagnostics) {
      issues.add(_mapTextDiagnostic(diagnostic, coarseRef));
    }

    final healthIssue = switch (region.health) {
      RegionHealth.repairable => ImportIssue(
          code: 'legacy_region_repairable',
          severity: ImportIssueSeverity.warning,
          sourceRef: coarseRef,
        ),
      RegionHealth.rejected => ImportIssue(
          code: 'legacy_region_rejected',
          severity: ImportIssueSeverity.error,
          sourceRef: coarseRef,
        ),
      RegionHealth.clean => null,
    };
    if (healthIssue != null) {
      issues.add(healthIssue);
    }

    if (stemText.trim().isEmpty) {
      issues.add(
        ImportIssue(
          code: 'missing_stem',
          severity: ImportIssueSeverity.warning,
          field: ImportIssueField.stem,
          sourceRef: coarseRef,
        ),
      );
    }

    return QuestionRegion(
      questionNumber: region.number,
      fragments: fragments,
      kindHint: _mapKind(region.kind),
      issues: issues,
    );
  }
}

ImportIssue _mapTextDiagnostic(String diagnostic, SourceRef stemRef) {
  final code = switch (diagnostic) {
    '缺少 A 选项' || 'missing_option_a' => 'missing_option_a',
    '缺少 B 选项' || 'missing_option_b' => 'missing_option_b',
    '疑似未闭合行内公式 \\(' || 'unclosed_inline_math' => 'unclosed_inline_math',
    '疑似未闭合块级公式 \\[' || 'unclosed_block_math' => 'unclosed_block_math',
    _ when diagnostic.startsWith('题号存在跳跃:') => 'question_number_gap',
    'question_number_gap' => 'question_number_gap',
    _ => 'legacy_region_diagnostic',
  };
  final field = switch (code) {
    'missing_option_a' || 'missing_option_b' => ImportIssueField.options,
    'unclosed_inline_math' || 'unclosed_block_math' => ImportIssueField.stem,
    'question_number_gap' => ImportIssueField.question,
    _ => null,
  };
  return ImportIssue(
    code: code,
    severity: ImportIssueSeverity.warning,
    field: field,
    sourceRef: stemRef,
  );
}

QuestionRegionKindHint _mapKind(TextQuestionKind kind) {
  return switch (kind) {
    TextQuestionKind.choice => QuestionRegionKindHint.singleChoice,
    TextQuestionKind.multiChoice => QuestionRegionKindHint.multipleChoice,
    TextQuestionKind.trueFalse => QuestionRegionKindHint.trueFalse,
    TextQuestionKind.fillBlank => QuestionRegionKindHint.fillBlank,
    TextQuestionKind.subjective => QuestionRegionKindHint.shortAnswer,
    TextQuestionKind.unknown => QuestionRegionKindHint.unknown,
  };
}

RichContent _textContent(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}
