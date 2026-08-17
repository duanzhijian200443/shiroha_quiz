import 'import_question_field_policy.dart';
import 'latex_sanity_checker.dart';
import 'local_question_assembler.dart';
import 'ocr_question_regionizer.dart';
import 'text_question_region.dart';

class OcrQuestionAssembler {
  const OcrQuestionAssembler();

  LocalAssemblyResult assemble(OcrQuestionRegion region) {
    final diagnostics = <String>[...region.diagnostics];
    final stem = _cleanStem(region.stemText, region.number);
    final rawOptionExtract = _extractOptions(stem);
    final optionExtract = _shouldKeepOptions(
      declaredKind: region.declaredKind,
      rawOptionCount: rawOptionExtract.options.length,
    )
        ? rawOptionExtract
        : _OptionExtract(stem: stem.trim(), options: const []);
    final content =
        optionExtract.stem.trim().isEmpty ? stem : optionExtract.stem.trim();
    final type = _classifyType(
      content: content,
      options: optionExtract.options,
      declaredKind: region.declaredKind,
    );

    final answer = _normalizeAnswer(
      region.answerText,
      type: type,
      explanation: region.explanationText,
    );
    final explanation = _stripFieldLabels(region.explanationText);

    if (content.trim().isEmpty) diagnostics.add('empty_content');
    if (answer.trim().isEmpty) diagnostics.add('missing_answer');
    if (type != 3 && explanation.isNotEmpty) {
      diagnostics.add('dropped_non_subjective_explanation');
    }
    if (region.declaredKind != TextQuestionKind.unknown) {
      diagnostics.add('type_constrained_by_region:${region.declaredKind.name}');
    }
    if (region.declaredKind != TextQuestionKind.choice &&
        rawOptionExtract.options.isNotEmpty &&
        optionExtract.options.isEmpty) {
      diagnostics.add('ignored_options_due_to_region_type');
    }
    if (type == 0 && optionExtract.options.length < 2) {
      diagnostics.add('choice_options_less_than_2');
    }
    var question = const ImportQuestionFieldPolicy().applyToMap(
      {
        'q_num': region.number.toString(),
        'question_number': region.number,
        'type': type,
        'content': content.trim().isEmpty ? region.rawText : content.trim(),
        'options': optionExtract.options,
        'standard_answer': answer,
        'explanation': explanation,
        'raw_explanation': explanation.trim().isEmpty ? null : explanation,
        'source': 'glm_ocr_intermediate',
        'source_page_indices': region.sourcePageIndices,
        'source_block_ids': region.sourceBlockIds,
        'diagnostics': diagnostics.toSet().toList(),
      },
    );
    if (_hasDanglingLatexInFinalFields(question)) {
      diagnostics.add('dangling_latex');
    }

    final reasons = <String>[];
    if (region.isCrossPage) reasons.add('cross_page');
    if (content.trim().isEmpty) reasons.add('empty_content');
    if (type == 0 && optionExtract.options.length < 2) {
      reasons.add('choice_options_less_than_2');
    }
    if (type == 0 && answer.trim().isEmpty) {
      reasons.add('choice_missing_answer');
    }
    if (diagnostics.contains('dangling_latex')) {
      reasons.add('dangling_latex');
    }
    final repairRecommended = reasons.isNotEmpty;
    question = <String, dynamic>{
      ...question,
      'diagnostics': diagnostics.toSet().toList(),
    };

    return LocalAssemblyResult(
      question: question,
      diagnostics: diagnostics.toSet().toList(),
      repairRecommended: repairRecommended,
      rejected: content.trim().isEmpty && region.rawText.trim().length < 8,
      repairRecommendationReasons: reasons,
    );
  }

  String _cleanStem(String text, int number) {
    final withoutQuestionNumber = text.replaceFirst(
      RegExp('^\\s*(?:第\\s*)?$number\\s*(?:题|[\\.、．])?\\s*'),
      '',
    );
    return _stripFieldLabels(withoutQuestionNumber)
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  String _stripFieldLabels(String text) {
    return text
        .replaceFirst(RegExp(r'^\s*(?:标准答案|参考答案|答案)\s*[:：]?\s*'), '')
        .replaceFirst(RegExp(r'^\s*(?:答案解析|解析|分析|详解|解|证明)\s*[:：]?\s*'), '')
        .trim();
  }

  _OptionExtract _extractOptions(String text) {
    final markerRegex = RegExp(
      r'(?:[（(]\s*([A-D])\s*[）)]|(?:^|\n)[ \t]*([A-D])\s*[\.．、])[ \t\r\n]*',
      multiLine: true,
    );
    final matches = markerRegex.allMatches(text).toList();
    const expectedKeys = ['A', 'B', 'C', 'D'];
    final keys = matches
        .map((match) => (match.group(1) ?? match.group(2) ?? '').toUpperCase())
        .toList();
    if (keys.length != expectedKeys.length ||
        !_hasExpectedOptionSequence(keys, expectedKeys)) {
      return _OptionExtract(stem: text.trim(), options: const []);
    }

    final stem = text.substring(0, matches.first.start).trim();
    final options = <String>[];
    for (var i = 0; i < matches.length; i++) {
      final match = matches[i];
      final start = match.end;
      final end = i + 1 < matches.length ? matches[i + 1].start : text.length;
      final optionText = text.substring(start, end).trim();
      if (optionText.isEmpty) {
        return _OptionExtract(stem: text.trim(), options: const []);
      }
      options.add('${keys[i]}. $optionText');
    }

    return _OptionExtract(stem: stem, options: options);
  }

  bool _hasExpectedOptionSequence(
    List<String> actual,
    List<String> expected,
  ) {
    for (var i = 0; i < expected.length; i++) {
      if (actual[i] != expected[i]) return false;
    }
    return true;
  }

  int _classifyType({
    required String content,
    required List<String> options,
    required TextQuestionKind declaredKind,
  }) {
    if (declaredKind == TextQuestionKind.choice ||
        declaredKind == TextQuestionKind.multiChoice) {
      return 0;
    }
    if (declaredKind == TextQuestionKind.fillBlank) return 2;
    if (declaredKind == TextQuestionKind.subjective) return 3;

    if (options.length >= 2) return 0;
    if (_hasBlankMarkers(content)) return 2;
    if (RegExp(r'填空|应填').hasMatch(content)) {
      return 2;
    }
    return 3;
  }

  bool _shouldKeepOptions({
    required TextQuestionKind declaredKind,
    required int rawOptionCount,
  }) {
    if (declaredKind == TextQuestionKind.choice ||
        declaredKind == TextQuestionKind.multiChoice) {
      return true;
    }
    if (declaredKind == TextQuestionKind.fillBlank ||
        declaredKind == TextQuestionKind.subjective) {
      return false;
    }
    return rawOptionCount >= 2;
  }

  bool _hasBlankMarkers(String content) {
    return RegExp(r'[_＿—–－﹏]{2,}|（\s*）|\(\s*\)|____').hasMatch(content);
  }

  String _normalizeAnswer(
    String answerText, {
    required int type,
    required String explanation,
  }) {
    final raw = _stripFieldLabels(answerText).trim();
    if (type == 0) {
      final choice = RegExp(r'(?:^|答案|应选|选)\s*([A-D])(?:\b|[。．.、，,；;])')
          .firstMatch(raw)
          ?.group(1);
      if (choice != null) return choice.toUpperCase();

      final explanationChoice =
          RegExp(r'(?:应选|故选|答案为?)\s*([A-D])').firstMatch(explanation)?.group(1);
      if (explanationChoice != null) return explanationChoice.toUpperCase();
    }

    return raw.replaceFirst(RegExp(r'^\s*(?:应填|填|答案为?)\s*[:：]?\s*'), '').trim();
  }

  bool _hasDanglingLatex(String text) {
    return const LatexSanityChecker().hasDanglingDelimiters(text);
  }

  bool _hasDanglingLatexInFinalFields(Map<String, dynamic> question) {
    for (final key in const ['content', 'standard_answer', 'explanation']) {
      final value = question[key];
      if (value is String && _hasDanglingLatex(value)) return true;
    }
    final options = question['options'];
    return options is List &&
        options.whereType<String>().any(_hasDanglingLatex);
  }
}

class _OptionExtract {
  const _OptionExtract({
    required this.stem,
    required this.options,
  });

  final String stem;
  final List<String> options;
}
