import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/import/import_issue.dart';
import '../../domain/question/question_draft_v2.dart';
import '../../domain/question/question_region.dart';
import '../../domain/source/source_part.dart';
import 'latex_sanity_checker.dart';

/// Raised when a [QuestionRegion] fragment cannot be expressed losslessly by
/// [QuestionDraftV2] without changing the frozen domain models or inventing an
/// unfrozen persistence payload.
final class QuestionRegionUnsupportedException implements Exception {
  const QuestionRegionUnsupportedException({
    required this.kindCode,
    required this.field,
    required this.message,
  });

  final String kindCode;
  final QuestionRegionField field;
  final String message;

  @override
  String toString() =>
      'QuestionRegionUnsupportedException($kindCode, ${field.name}): $message';
}

/// Assembles a typed [QuestionDraftV2] directly from [QuestionRegion] field
/// fragments.
///
/// The stem/answer/explanation fragments are composed into [RichContent]
/// without any legacy question-map round trip. Option text embedded in the
/// stem (the frozen region contract has no options field) is extracted with a
/// deterministic policy that mirrors the authoritative legacy assemblers:
/// inline answer/explanation labels are removed, `A`-`D` options are split
/// off, and the leading question number is stripped. When the stem contains
/// non-text nodes (math or raw fallback), extraction is skipped entirely so
/// the content is preserved verbatim.
final class TypedQuestionAssembler {
  const TypedQuestionAssembler();

  QuestionDraftV2 assemble(
    QuestionRegion region, {
    required String questionId,
  }) {
    final nodesByField = <QuestionRegionField, List<ContentNode>>{};
    for (final fragment in region.fragments) {
      switch (fragment.part) {
        case SourceContentPart(:final content):
          final nodes = _materializeContentNodes(content, fragment.slice);
          if (_isStructurallyEmpty(nodes)) {
            // Mirrors the legacy OCR join: fragments that contain only blank
            // text nodes are dropped; any non-text node is preserved.
            break;
          }
          final target =
              nodesByField.putIfAbsent(fragment.field, () => <ContentNode>[]);
          if (target.isNotEmpty) {
            // Preserve the stable legacy fragment boundary.
            target.add(const TextNode('\n'));
          }
          target.addAll(nodes);
        case SourceAssetPart():
          throw QuestionRegionUnsupportedException(
            kindCode: 'source_asset',
            field: fragment.field,
            message: 'Asset identity and field position cannot be projected '
                'losslessly by QuestionDraftV2.',
          );
        case SourceTablePart():
          throw QuestionRegionUnsupportedException(
            kindCode: 'source_table',
            field: fragment.field,
            message: 'Table content cannot be expressed losslessly by '
                'QuestionDraftV2.',
          );
        case UnsupportedSourcePart(:final kindCode):
          throw QuestionRegionUnsupportedException(
            kindCode: kindCode,
            field: fragment.field,
            message: 'Unsupported source content cannot be expressed '
                'losslessly by QuestionDraftV2.',
          );
      }
    }

    final stemNodes =
        nodesByField[QuestionRegionField.stem] ?? const <ContentNode>[];
    final answerNodes =
        nodesByField[QuestionRegionField.answer] ?? const <ContentNode>[];
    final explanationNodes =
        nodesByField[QuestionRegionField.explanation] ?? const <ContentNode>[];

    final stemText = _joinedText(stemNodes);
    final answerText = _joinedText(answerNodes);
    final explanationText = _joinedText(explanationNodes);

    var stemContent = RichContent(nodes: stemNodes);
    var extractedOptions = const <_ExtractedOption>[];
    String? inlineAnswer;
    String? inlineExplanation;
    var cleanedStemEmpty = false;
    if (stemText != null) {
      final extraction = _extractLegacyFields(stemText);
      cleanedStemEmpty = extraction.stem.isEmpty;
      if (cleanedStemEmpty) {
        final fallback = stemText.trim();
        stemContent = fallback.isEmpty
            ? RichContent(nodes: const <ContentNode>[])
            : RichContent(nodes: <ContentNode>[TextNode(fallback)]);
      } else if (extraction.stem != stemText) {
        stemContent =
            RichContent(nodes: <ContentNode>[TextNode(extraction.stem)]);
      }
      extractedOptions = extraction.options;
      inlineAnswer = extraction.inlineAnswer;
      inlineExplanation = extraction.inlineExplanation;
    }

    final options = <QuestionOption>[
      for (final option in extractedOptions)
        QuestionOption(
          optionId: option.key,
          label: option.key,
          content: RichContent(nodes: <ContentNode>[TextNode(option.value)]),
        ),
    ];

    final kind = _mapKind(
      region.kindHint,
      optionCount: options.length,
      stemSearchText: _searchText(stemNodes),
    );

    RichContent? explanationContent;
    if (explanationText != null && explanationText.trim().isNotEmpty) {
      explanationContent = RichContent(
        nodes: <ContentNode>[TextNode(_stripFieldLabels(explanationText))],
      );
    } else if (inlineExplanation != null &&
        inlineExplanation.trim().isNotEmpty) {
      explanationContent = RichContent(
        nodes: <ContentNode>[TextNode(inlineExplanation.trim())],
      );
    } else if (explanationNodes.isNotEmpty && explanationText == null) {
      explanationContent = RichContent(nodes: explanationNodes);
    }
    final effectiveExplanation =
        explanationContent == null ? '' : _searchText(explanationContent.nodes);

    final isChoice = kind == QuestionKind.singleChoice;
    final sourceAnswerText = answerText ?? inlineAnswer;
    final normalizedAnswer = _normalizeAnswerText(
      sourceAnswerText ?? '',
      isChoice: isChoice,
    );
    QuestionAnswer? answer;
    if (normalizedAnswer.isNotEmpty) {
      if (isChoice) {
        final ids = _choiceOptionIds(normalizedAnswer);
        if (ids != null) {
          answer = ChoiceAnswer(optionIds: ids);
        } else if (answerText != null || sourceAnswerText != null) {
          answer = ContentAnswer(
            content: RichContent(
              nodes: <ContentNode>[TextNode(normalizedAnswer)],
            ),
          );
        } else {
          answer = ContentAnswer(content: RichContent(nodes: answerNodes));
        }
      } else {
        answer = answerText != null
            ? ContentAnswer(
                content: RichContent(
                  nodes: <ContentNode>[TextNode(normalizedAnswer)],
                ),
              )
            : answerNodes.isNotEmpty
                ? ContentAnswer(content: RichContent(nodes: answerNodes))
                : ContentAnswer(
                    content: RichContent(
                      nodes: <ContentNode>[TextNode(normalizedAnswer)],
                    ),
                  );
      }
    } else if (answerNodes.isNotEmpty && answerText == null) {
      answer = ContentAnswer(content: RichContent(nodes: answerNodes));
    }
    if (answer == null && isChoice) {
      final fromExplanation = RegExp(r'(?:应选|故选|答案为?)\s*([A-D])')
          .firstMatch(effectiveExplanation)
          ?.group(1);
      if (fromExplanation != null) {
        answer =
            ChoiceAnswer(optionIds: <String>[fromExplanation.toUpperCase()]);
      }
    }

    final issues = <ImportIssue>[...region.issues];
    void addIssue(
      String code,
      ImportIssueSeverity severity,
      ImportIssueField? field,
    ) {
      if (issues.any((issue) => issue.code == code)) return;
      issues.add(ImportIssue(code: code, severity: severity, field: field));
    }

    if (cleanedStemEmpty) {
      addIssue(
        'empty_content',
        ImportIssueSeverity.warning,
        ImportIssueField.stem,
      );
    }
    if (_isStructurallyEmpty(stemContent.nodes)) {
      addIssue(
        'missing_stem',
        ImportIssueSeverity.warning,
        ImportIssueField.stem,
      );
    }
    if (answer == null) {
      addIssue(
        'missing_answer',
        ImportIssueSeverity.warning,
        ImportIssueField.answer,
      );
    }
    if (kind == QuestionKind.singleChoice && options.length < 2) {
      addIssue(
        'choice_options_less_than_2',
        ImportIssueSeverity.warning,
        ImportIssueField.options,
      );
    }
    final finalTexts = <String>[
      _searchText(stemContent.nodes),
      if (answer != null) _answerSearchText(answer),
      effectiveExplanation,
      for (final option in options) _searchText(option.content.nodes),
    ];
    if (finalTexts.any(_hasDanglingLatex)) {
      addIssue('dangling_latex', ImportIssueSeverity.warning, null);
    }

    return QuestionDraftV2(
      questionId: questionId,
      kind: kind,
      questionNumber: region.questionNumber,
      stem: stemContent,
      options: options,
      answer: answer,
      explanation: explanationContent,
      sourceRefs: region.sourceRefs,
      assetRefs: region.assetRefs,
      issues: issues,
    );
  }
}

QuestionKind _mapKind(
  QuestionRegionKindHint hint, {
  required int optionCount,
  required String stemSearchText,
}) {
  return switch (hint) {
    QuestionRegionKindHint.singleChoice => QuestionKind.singleChoice,
    QuestionRegionKindHint.multipleChoice => QuestionKind.singleChoice,
    QuestionRegionKindHint.trueFalse => _inferKind(optionCount, stemSearchText),
    QuestionRegionKindHint.fillBlank => QuestionKind.fillBlank,
    QuestionRegionKindHint.shortAnswer => QuestionKind.shortAnswer,
    QuestionRegionKindHint.unknown => _inferKind(optionCount, stemSearchText),
  };
}

/// Mirrors the authoritative legacy final behavior: two or more options win,
/// blank markers win next, and everything else stays a short answer.
QuestionKind _inferKind(int optionCount, String stemSearchText) {
  if (optionCount >= 2) return QuestionKind.singleChoice;
  if (_hasBlankMarkers(stemSearchText)) return QuestionKind.fillBlank;
  return QuestionKind.shortAnswer;
}

bool _hasBlankMarkers(String text) {
  return RegExp(r'_{2,}|\(\s*\)|（\s*）|填空|空格').hasMatch(text);
}

String _normalizeAnswerText(String raw, {required bool isChoice}) {
  var value = _stripFieldLabels(raw)
      .trim()
      .replaceAll('Ａ', 'A')
      .replaceAll('Ｂ', 'B')
      .replaceAll('Ｃ', 'C')
      .replaceAll('Ｄ', 'D')
      .replaceAll('正确', '对')
      .replaceAll('错误', '错')
      .trim()
      .toUpperCase();
  if (value == '对') return '√';
  if (value == '错') return '×';
  if (!isChoice) {
    return value
        .replaceFirst(RegExp(r'^\s*(?:应填|填|答案为?)\s*[:：]?\s*'), '')
        .trim();
  }
  return value;
}

List<String>? _choiceOptionIds(String normalized) {
  final compact = normalized.replaceAll(RegExp(r'[。．.、，,；;\s]'), '');
  final match = RegExp(r'^([A-D]{1,4})$').firstMatch(compact);
  if (match == null) return null;
  return match.group(1)!.split('');
}

String _stripFieldLabels(String text) {
  return text
      .replaceFirst(RegExp(r'^\s*(?:标准答案|参考答案|答案)\s*[:：]?\s*'), '')
      .replaceFirst(RegExp(r'^\s*(?:答案解析|解析|分析|详解|解|证明)\s*[:：]?\s*'), '')
      .trim();
}

({
  String stem,
  List<_ExtractedOption> options,
  String? inlineAnswer,
  String? inlineExplanation
}) _extractLegacyFields(String text) {
  var working = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();

  final inlineAnswer = _extractInlineAnswer(working);
  working = inlineAnswer.remainingText;
  final inlineExplanation = _extractInlineExplanation(working);
  working = inlineExplanation.remainingText;
  final optionExtract = _extractOptions(working);

  return (
    stem: _cleanStem(optionExtract.stem),
    options: optionExtract.options,
    inlineAnswer: inlineAnswer.answer,
    inlineExplanation: inlineExplanation.explanation,
  );
}

_AnswerExtract _extractInlineAnswer(String text) {
  final regex = RegExp(
    r'(?:^|[\s\n。；;])(?:标准答案|正确答案|答案)\s*[:：]?\s*([A-DＡ-Ｄ]{1,4}|[√×]|对|错|正确|错误)(?=[\s，,。．.;；]|$)',
    caseSensitive: false,
  );
  final match = regex.firstMatch(text);
  if (match == null) return _AnswerExtract(null, text);
  return _AnswerExtract(
    match.group(1)?.trim(),
    text.replaceRange(match.start, match.end, ' ').trim(),
  );
}

_ExplanationExtract _extractInlineExplanation(String text) {
  final regex = RegExp(
    r'(?:^|[\n。；;]|[\.．]\s+)\s*(?:答案解析|解析|分析)\s*[:：]?\s*',
    caseSensitive: false,
    multiLine: true,
  );
  final match = regex.firstMatch(text);
  if (match == null) return _ExplanationExtract(null, text);
  final before = text.substring(0, match.start).trim();
  final matchText = match.group(0) ?? '';
  final explanation = text.substring(match.start + matchText.length).trim();
  return _ExplanationExtract(
    explanation.isEmpty ? null : explanation,
    before,
  );
}

_OptionExtract _extractOptions(String text) {
  final markerRegex = RegExp(
    r'(^|[\s\n])(?:[（(]?([A-DＡ-Ｄ])[）)]|([A-DＡ-Ｄ])[\.．、])\s*',
    multiLine: true,
  );
  final matches = markerRegex.allMatches(text).toList();
  if (matches.length < 2) {
    return _OptionExtract(
        stem: text.trim(), options: const <_ExtractedOption>[]);
  }

  final stem = text.substring(0, matches.first.start).trim();
  final options = <_ExtractedOption>[];
  for (var i = 0; i < matches.length; i++) {
    final match = matches[i];
    final rawKey = match.group(2) ?? match.group(3) ?? '';
    final key = _normalizeOptionKey(rawKey);
    if (key.isEmpty) continue;

    final valueStart = match.end;
    final valueEnd =
        i + 1 < matches.length ? matches[i + 1].start : text.length;
    var value = text.substring(valueStart, valueEnd).trim();
    value = value.replaceAll(RegExp(r'^[\.．、\s]+|[\.．、\s]+$'), '').trim();
    if (value.isEmpty) continue;

    options.add(_ExtractedOption(key: key, value: value));
  }
  return _OptionExtract(stem: stem, options: options);
}

String _normalizeOptionKey(String raw) {
  return raw
      .replaceAll('Ａ', 'A')
      .replaceAll('Ｂ', 'B')
      .replaceAll('Ｃ', 'C')
      .replaceAll('Ｄ', 'D')
      .trim()
      .toUpperCase();
}

String _cleanStem(String raw) {
  return raw
      .replaceFirst(
        RegExp(r'^\s*(?:第\s*)?\d{1,3}\s*(?:题|[\.、．）\)])?\s*'),
        '',
      )
      .trim();
}

/// Materializes the UTF-16 half-open node interval selected by [slice].
///
/// Text nodes may be trimmed at the interval edges; math and raw fallback
/// nodes are preserved whole because the slice constructor guarantees that
/// non-zero offsets fall strictly inside text nodes. Without a slice the
/// whole part is used.
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

/// Returns the joined text when every node is a [TextNode], otherwise null.
String? _joinedText(List<ContentNode> nodes) {
  final buffer = StringBuffer();
  for (final node in nodes) {
    if (node is! TextNode) return null;
    buffer.write(node.text);
  }
  return buffer.toString();
}

/// Lossless textual projection used for search and diagnostics; raw fallback
/// payloads are never exposed.
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
      case RawFallbackNode():
        break;
    }
  }
  return buffer.toString();
}

/// Returns true when [nodes] contains no content at all: an empty list or
/// only blank [TextNode]s. Non-text nodes are structural content even when
/// their searchable text projection is empty.
bool _isStructurallyEmpty(List<ContentNode> nodes) {
  return nodes.isEmpty ||
      nodes.every((node) => node is TextNode && node.text.trim().isEmpty);
}

String _answerSearchText(QuestionAnswer answer) {
  return switch (answer) {
    ChoiceAnswer(:final optionIds) => optionIds.join(),
    ContentAnswer(:final content) => _searchText(content.nodes),
  };
}

bool _hasDanglingLatex(String text) {
  return const LatexSanityChecker().hasDanglingDelimiters(text);
}

final class _ExtractedOption {
  const _ExtractedOption({required this.key, required this.value});

  final String key;
  final String value;
}

final class _AnswerExtract {
  const _AnswerExtract(this.answer, this.remainingText);

  final String? answer;
  final String remainingText;
}

final class _ExplanationExtract {
  const _ExplanationExtract(this.explanation, this.remainingText);

  final String? explanation;
  final String remainingText;
}

final class _OptionExtract {
  const _OptionExtract({required this.stem, required this.options});

  final String stem;
  final List<_ExtractedOption> options;
}
