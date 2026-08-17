import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/question/question_draft_v2.dart';
import '../../domain/question/question_region.dart';
import '../../domain/source/source_part.dart';
import '../../domain/source/source_ref.dart';
import 'import_question_field_policy.dart';
import 'latex_sanity_checker.dart';
import 'local_question_assembler.dart';

/// Explicit, stable projection profile selecting the legacy map shape,
/// provenance fields, and source tag of one authoritative legacy assembler.
sealed class LegacyProjectionProfile {
  const LegacyProjectionProfile();

  String get sourceTag;
}

/// Projects onto the `LocalQuestionAssembler` (text) map contract.
final class TextLegacyProjectionProfile extends LegacyProjectionProfile {
  const TextLegacyProjectionProfile();

  static const String sourceTagValue = 'docx_text_deterministic';

  @override
  String get sourceTag => sourceTagValue;
}

/// Projects onto the `OcrQuestionAssembler` (OCR) map contract, including
/// `q_num`, `source_page_indices`, and `source_block_ids`.
final class OcrLegacyProjectionProfile extends LegacyProjectionProfile {
  const OcrLegacyProjectionProfile();

  static const String sourceTagValue = 'glm_ocr_intermediate';

  @override
  String get sourceTag => sourceTagValue;
}

/// Raised when a [QuestionRegion] or its assembled [QuestionDraftV2] cannot be
/// projected losslessly: raw fallback content, unsupported source parts,
/// source-qualified asset identity, or a draft/region identity mismatch.
final class LegacyProjectionUnsupportedException implements Exception {
  const LegacyProjectionUnsupportedException({
    required this.kindCode,
    required this.message,
  });

  final String kindCode;
  final String message;

  @override
  String toString() =>
      'LegacyProjectionUnsupportedException($kindCode): $message';
}

/// Rebuilds the legacy [LocalAssemblyResult] shape from a typed draft without
/// delegating to the legacy assemblers. The projection keeps map fields,
/// source tag, provenance, diagnostics, and repair/rejected parity with the
/// authoritative legacy implementation; reusable pure policies are shared
/// through [ImportQuestionFieldPolicy] and [LatexSanityChecker].
final class QuestionDraftV2LegacyProjector {
  const QuestionDraftV2LegacyProjector();

  LocalAssemblyResult project({
    required QuestionDraftV2 draft,
    required QuestionRegion region,
    required LegacyProjectionProfile profile,
  }) {
    _guardProjectionBoundary(draft, region);
    final isOcr = profile is OcrLegacyProjectionProfile;
    final draftStem = _contentText(draft.stem).trim();
    // The OCR profile mirrors the authoritative OCR assembler: options are
    // split only for the complete ordered A-D sequence, and the full region
    // stem (including dropped option text) is kept for non-choice kinds.
    final ocrStem = isOcr ? _ocrRegionStem(region) : '';
    final ocrRawExtract = isOcr
        ? _ocrExtractOptions(ocrStem)
        : const _OcrOptionExtract(stem: '', options: <String>[]);
    final keepOcrOptions = isOcr &&
        _ocrShouldKeepOptions(region.kindHint, ocrRawExtract.options.length);
    final ocrExtract = keepOcrOptions
        ? ocrRawExtract
        : _OcrOptionExtract(stem: ocrStem.trim(), options: const <String>[]);
    final ocrContent =
        ocrExtract.stem.trim().isEmpty ? ocrStem : ocrExtract.stem.trim();

    final type = isOcr
        ? _ocrClassifyType(
            content: ocrContent,
            options: ocrExtract.options,
            kindHint: region.kindHint,
          )
        : _legacyTypeCode(draft.kind);
    final rawContent = isOcr ? ocrContent : draftStem;
    final content = rawContent.trim().isEmpty && isOcr
        ? _composeRawText(region)
        : rawContent.trim();
    final options = isOcr
        ? ocrExtract.options
        : <String>[
            for (final option in draft.options)
              '${option.label}. ${_contentText(option.content)}',
          ];
    final typedAnswer = _answerText(draft.answer);
    // The text legacy assembler uppercases every answer, while the OCR legacy
    // assembler preserves non-choice answer case. Keep the typed draft
    // lossless and apply the profile-specific compatibility rule here.
    final answer = isOcr ? typedAnswer : typedAnswer.toUpperCase();
    final rawExplanation =
        draft.explanation == null ? '' : _contentText(draft.explanation!);

    final diagnostics = <String>[
      for (final issue in region.issues)
        if (_isLegacyDiagnosticToken(issue.code)) issue.code,
    ];
    if (rawContent.trim().isEmpty) diagnostics.add('empty_content');
    if (answer.trim().isEmpty) diagnostics.add('missing_answer');
    if (!isOcr && rawExplanation.isEmpty) {
      diagnostics.add('info_missing_explanation');
    }
    if (type != 3 && rawExplanation.isNotEmpty) {
      diagnostics.add('dropped_non_subjective_explanation');
    }
    if (isOcr && region.kindHint != QuestionRegionKindHint.unknown) {
      diagnostics.add(
        'type_constrained_by_region:${_legacyKindName(region.kindHint)}',
      );
    }
    if (isOcr &&
        region.kindHint != QuestionRegionKindHint.singleChoice &&
        ocrRawExtract.options.isNotEmpty &&
        ocrExtract.options.isEmpty) {
      diagnostics.add('ignored_options_due_to_region_type');
    }
    if (type == 0 && options.length < 2) {
      diagnostics.add('choice_options_less_than_2');
    }

    var question =
        const ImportQuestionFieldPolicy().applyToMap(<String, dynamic>{
      'question_number': region.questionNumber,
      'type': type,
      'content': content,
      'options': options,
      'standard_answer': answer,
      'explanation': rawExplanation,
      'raw_explanation': rawExplanation.isEmpty ? null : rawExplanation,
      'source': profile.sourceTag,
      'diagnostics': diagnostics,
      if (isOcr) ...<String, dynamic>{
        'q_num': region.questionNumber.toString(),
        'source_page_indices': _pageNumbers(region),
        'source_block_ids': _blockIds(region),
      },
    });
    if (_hasDanglingLatexInFinalFields(question)) {
      diagnostics.add('dangling_latex');
    }

    final repairRecommended = isOcr
        ? _ocrRepairRecommended(
            region: region,
            type: type,
            content: rawContent,
            options: options,
            answer: answer,
            diagnostics: diagnostics,
          )
        : _textRepairRecommended(
            type: type,
            content: rawContent,
            options: options,
            diagnostics: diagnostics,
            rawTextLength:
                _untrimmedTextLength(region, QuestionRegionField.stem),
          );
    final rejected =
        rawContent.trim().isEmpty && _rawTextLength(region, isOcr: isOcr) < 8;
    final finalDiagnostics = <String>[...diagnostics.toSet()];
    question = <String, dynamic>{...question, 'diagnostics': finalDiagnostics};

    return LocalAssemblyResult(
      question: question,
      diagnostics: finalDiagnostics,
      repairRecommended: repairRecommended,
      rejected: rejected,
    );
  }
}

int _legacyTypeCode(QuestionKind kind) {
  return switch (kind) {
    QuestionKind.singleChoice => 0,
    QuestionKind.fillBlank => 2,
    QuestionKind.shortAnswer => 3,
  };
}

String _legacyKindName(QuestionRegionKindHint hint) {
  return switch (hint) {
    QuestionRegionKindHint.singleChoice => 'choice',
    QuestionRegionKindHint.multipleChoice => 'multiChoice',
    QuestionRegionKindHint.trueFalse => 'trueFalse',
    QuestionRegionKindHint.fillBlank => 'fillBlank',
    QuestionRegionKindHint.shortAnswer => 'subjective',
    QuestionRegionKindHint.unknown => 'unknown',
  };
}

String _answerText(QuestionAnswer? answer) {
  return switch (answer) {
    null => '',
    ChoiceAnswer(:final optionIds) => optionIds.join(),
    ContentAnswer(:final content) => _contentText(content),
  };
}

bool _textRepairRecommended({
  required int type,
  required String content,
  required List<String> options,
  required List<String> diagnostics,
  required int rawTextLength,
}) {
  if (content.trim().length < 6 && rawTextLength > 20) return true;
  if (diagnostics.contains('dangling_latex')) return true;
  if (type == 0 && options.length < 2) return true;
  if (type == 3 && !diagnostics.contains('dangling_latex')) return false;
  return false;
}

bool _ocrRepairRecommended({
  required QuestionRegion region,
  required int type,
  required String content,
  required List<String> options,
  required String answer,
  required List<String> diagnostics,
}) {
  return _pageNumbers(region).length > 1 ||
      content.trim().isEmpty ||
      (type == 0 && options.length < 2) ||
      (type == 0 && answer.trim().isEmpty) ||
      diagnostics.contains('dangling_latex');
}

bool _hasDanglingLatexInFinalFields(Map<String, dynamic> question) {
  const checker = LatexSanityChecker();
  for (final key in const ['content', 'standard_answer', 'explanation']) {
    final value = question[key];
    if (value is String && checker.hasDanglingDelimiters(value)) return true;
  }
  final options = question['options'];
  return options is List &&
      options.whereType<String>().any(checker.hasDanglingDelimiters);
}

String _contentText(RichContent content) {
  return _searchText(content.nodes);
}

String _searchText(List<ContentNode> nodes) {
  final buffer = StringBuffer();
  for (final node in nodes) {
    switch (node) {
      case TextNode(:final text):
        buffer.write(text);
      case InlineMathNode(:final latex):
        buffer.write(latex);
      case BlockMathNode(:final latex):
        buffer.write(latex);
      case ImageNode():
        // Image structure belongs to the typed draft. The legacy map predates
        // durable image content and must retain its exact text-only parity.
        break;
      case RawFallbackNode():
        break;
    }
  }
  return buffer.toString();
}

String _fragmentText(QuestionRegion region, QuestionRegionField field) {
  final parts = <String>[];
  for (final fragment in region.fragmentsFor(field)) {
    final part = fragment.part;
    if (part is SourceContentPart) {
      final text = _searchText(
        _materializeContentNodes(part.content, fragment.slice),
      ).trim();
      if (text.isNotEmpty) parts.add(text);
    }
  }
  return parts.join('\n');
}

/// Sums the untrimmed searchable text length of every [field] fragment,
/// mirroring the legacy assemblers that threshold on `region.rawText.length`.
int _untrimmedTextLength(
  QuestionRegion region,
  QuestionRegionField field,
) {
  final parts = <String>[];
  for (final fragment in region.fragmentsFor(field)) {
    final part = fragment.part;
    if (part is SourceContentPart) {
      final text = _searchText(
        _materializeContentNodes(part.content, fragment.slice),
      );
      if (text.isNotEmpty) parts.add(text);
    }
  }
  return parts.join('\n').length;
}

void _guardNoRawFallback(
  QuestionDraftV2 draft,
  QuestionRegion region,
) {
  void check(String label, List<ContentNode> nodes) {
    if (nodes.any((node) => node is RawFallbackNode)) {
      throw LegacyProjectionUnsupportedException(
        kindCode: 'raw_fallback',
        message: 'Raw fallback content cannot be projected losslessly by the '
            'legacy map ($label).',
      );
    }
  }

  check('stem', draft.stem.nodes);
  if (draft.answer case ContentAnswer(:final content)) {
    check('answer', content.nodes);
  }
  if (draft.explanation != null) {
    check('explanation', draft.explanation!.nodes);
  }
  for (final option in draft.options) {
    check('option', option.content.nodes);
  }
  for (final fragment in region.fragments) {
    switch (fragment.part) {
      case SourceContentPart(:final content):
        check(
          fragment.field.name,
          _materializeContentNodes(content, fragment.slice),
        );
      case SourceAssetPart():
        break;
      case SourceTablePart():
        throw LegacyProjectionUnsupportedException(
          kindCode: 'source_table',
          message: 'Table fragments cannot be projected losslessly by the '
              'legacy map.',
        );
      case UnsupportedSourcePart(:final kindCode):
        throw LegacyProjectionUnsupportedException(
          kindCode: kindCode,
          message: 'Unsupported source content cannot be projected losslessly '
              'by the legacy map.',
        );
    }
  }
}

void _guardProjectionBoundary(
  QuestionDraftV2 draft,
  QuestionRegion region,
) {
  _guardNoRawFallback(draft, region);
  _guardDraftRegionConsistency(draft, region);
}

void _guardDraftRegionConsistency(
  QuestionDraftV2 draft,
  QuestionRegion region,
) {
  if (draft.questionNumber != region.questionNumber ||
      !_orderedEquals(draft.sourceRefs, region.sourceRefs)) {
    throw LegacyProjectionUnsupportedException(
      kindCode: 'draft_region_mismatch',
      message: 'The draft and region must agree on the question number and '
          'the ordered source references before legacy projection.',
    );
  }
}

bool _orderedEquals<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

String _ocrRegionStem(QuestionRegion region) {
  final text = _fragmentText(region, QuestionRegionField.stem);
  final withoutNumber = text.replaceFirst(
    RegExp('^\\s*(?:第\\s*)?${region.questionNumber}\\s*(?:题|[\\.、．])?\\s*'),
    '',
  );
  return _stripOcrFieldLabels(withoutNumber)
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

/// Mirrors the OCR assembler option split: only the complete ordered A-D
/// sequence with non-empty values is extracted.
_OcrOptionExtract _ocrExtractOptions(String text) {
  final markerRegex = RegExp(
    r'(?:（\s*([A-D])\s*）|(?:^|\n)[ \t]*([A-D])\s*[.．、])[ \t\r\n]*',
    multiLine: true,
  );
  final matches = markerRegex.allMatches(text).toList();
  const expectedKeys = ['A', 'B', 'C', 'D'];
  final keys = matches
      .map((match) => (match.group(1) ?? match.group(2) ?? '').toUpperCase())
      .toList();
  if (keys.length != expectedKeys.length ||
      !_hasExpectedOptionSequence(keys, expectedKeys)) {
    return _OcrOptionExtract(stem: text.trim(), options: const <String>[]);
  }

  final stem = text.substring(0, matches.first.start).trim();
  final options = <String>[];
  for (var index = 0; index < matches.length; index++) {
    final match = matches[index];
    final start = match.end;
    final end =
        index + 1 < matches.length ? matches[index + 1].start : text.length;
    final optionText = text.substring(start, end).trim();
    if (optionText.isEmpty) {
      return _OcrOptionExtract(stem: text.trim(), options: const <String>[]);
    }
    options.add('${keys[index]}. $optionText');
  }
  return _OcrOptionExtract(stem: stem, options: options);
}

bool _hasExpectedOptionSequence(List<String> actual, List<String> expected) {
  for (var index = 0; index < expected.length; index++) {
    if (actual[index] != expected[index]) return false;
  }
  return true;
}

bool _ocrShouldKeepOptions(
  QuestionRegionKindHint kindHint,
  int rawOptionCount,
) {
  return switch (kindHint) {
    QuestionRegionKindHint.singleChoice ||
    QuestionRegionKindHint.multipleChoice =>
      true,
    QuestionRegionKindHint.fillBlank ||
    QuestionRegionKindHint.shortAnswer =>
      false,
    QuestionRegionKindHint.trueFalse ||
    QuestionRegionKindHint.unknown =>
      rawOptionCount >= 2,
  };
}

int _ocrClassifyType({
  required String content,
  required List<String> options,
  required QuestionRegionKindHint kindHint,
}) {
  return switch (kindHint) {
    QuestionRegionKindHint.singleChoice ||
    QuestionRegionKindHint.multipleChoice =>
      0,
    QuestionRegionKindHint.fillBlank => 2,
    QuestionRegionKindHint.shortAnswer => 3,
    QuestionRegionKindHint.trueFalse ||
    QuestionRegionKindHint.unknown =>
      _inferOcrKind(content, options),
  };
}

int _inferOcrKind(String content, List<String> options) {
  if (options.length >= 2) return 0;
  if (_ocrHasBlankMarkers(content)) return 2;
  if (RegExp(r'填空|应填').hasMatch(content)) return 2;
  return 3;
}

bool _ocrHasBlankMarkers(String content) {
  return RegExp(r'[_＿—–－﹏]{2,}|（\s*）|\(\s*\)|____').hasMatch(content);
}

String _stripOcrFieldLabels(String text) {
  return text
      .replaceFirst(
        RegExp(r'^\s*(?:标准答案|参考答案|答案)\s*[:：]?\s*'),
        '',
      )
      .replaceFirst(
        RegExp(r'^\s*(?:答案解析|解析|分析|详解|解|证明)\s*[:：]?\s*'),
        '',
      )
      .trim();
}

/// Materializes the UTF-16 half-open node interval selected by [slice] with
/// the same semantics as [TypedQuestionAssembler]: text nodes may be trimmed
/// at the edges, math and raw fallback nodes are kept whole, and a null slice
/// selects the whole part.
List<ContentNode> _materializeContentNodes(
  RichContent content,
  SourceSlice? slice,
) {
  final nodes = content.nodes;
  if (slice == null) return nodes;
  final endExcluded = slice.endCodeUnitOffset == 0;
  final lastIncluded =
      endExcluded ? slice.endNodeIndex - 1 : slice.endNodeIndex;
  final materialized = <ContentNode>[];
  for (var index = slice.startNodeIndex; index <= lastIncluded; index++) {
    final node = nodes[index];
    final startOffset =
        index == slice.startNodeIndex ? slice.startCodeUnitOffset : 0;
    final endOffset =
        index == slice.endNodeIndex ? slice.endCodeUnitOffset : null;
    if (node is TextNode) {
      materialized.add(
        TextNode(
          endOffset == null
              ? node.text.substring(startOffset)
              : node.text.substring(startOffset, endOffset),
        ),
      );
    } else {
      materialized.add(node);
    }
  }
  return materialized;
}

final class _OcrOptionExtract {
  const _OcrOptionExtract({required this.stem, required this.options});

  final String stem;
  final List<String> options;
}

String _composeRawText(QuestionRegion region) {
  final buffer = StringBuffer();
  buffer.writeln(
    '${region.questionNumber} '
    '${_fragmentText(region, QuestionRegionField.stem).trim()}',
  );
  final answer = _fragmentText(region, QuestionRegionField.answer).trim();
  if (answer.isNotEmpty) buffer.writeln('答案: $answer');
  final explanation =
      _fragmentText(region, QuestionRegionField.explanation).trim();
  if (explanation.isNotEmpty) buffer.writeln('解析: $explanation');
  return buffer.toString().trim();
}

int _rawTextLength(QuestionRegion region, {required bool isOcr}) {
  return isOcr
      ? _composeRawText(region).length
      : _fragmentText(region, QuestionRegionField.stem).length;
}

Iterable<SourceRef> _legacySourceRefs(QuestionRegion region) sync* {
  final seen = <SourceRef>{};
  for (final fragment in region.fragments) {
    if (fragment.part is! SourceContentPart) continue;
    final ref = fragment.sourceRef;
    if (seen.add(ref)) yield ref;
  }
}

List<int> _pageNumbers(QuestionRegion region) {
  final pages = <int>[];
  for (final ref in _legacySourceRefs(region)) {
    for (final point in <SourcePoint?>[ref.start, ref.end]) {
      final page = point?.pageNumber;
      if (page != null && !pages.contains(page)) pages.add(page);
    }
  }
  pages.sort();
  return pages;
}

List<String> _blockIds(QuestionRegion region) {
  final blocks = <String>[];
  for (final ref in _legacySourceRefs(region)) {
    for (final point in <SourcePoint?>[ref.start, ref.end]) {
      final block = point?.blockId;
      if (block != null && !blocks.contains(block)) blocks.add(block);
    }
  }
  return blocks;
}

const _legacyDiagnosticTokens = <String>{
  'missing_option_a',
  'missing_option_b',
  'unclosed_inline_math',
  'unclosed_block_math',
  'question_number_gap',
  'legacy_region_diagnostic',
  'attached_numbered_field_in_current_region',
  'attached_numbered_field_candidate',
  'contains_formula_block',
  'contains_table_block',
  'cross_page_region',
  'missing_stem',
  'missing_answer',
  'reference_answer_attached',
  'reference_answer_confirmed',
  'reference_answer_conflict',
  'reference_answer_duplicate_conflict',
  'reference_answer_pattern',
  'kind_declared_from_section',
  'kind_inferred_from_question_number_range',
  'empty_content',
  'choice_options_less_than_2',
  'dangling_latex',
};

bool _isLegacyDiagnosticToken(String code) {
  return _legacyDiagnosticTokens.contains(code);
}
