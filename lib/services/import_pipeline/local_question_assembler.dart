import 'text_question_region.dart';

class LocalAssemblyResult {
  const LocalAssemblyResult({
    required this.question,
    required this.diagnostics,
    required this.repairRecommended,
    required this.rejected,
  });

  final Map<String, dynamic> question;
  final List<String> diagnostics;
  final bool repairRecommended;
  final bool rejected;
}

class LocalQuestionAssembler {
  const LocalQuestionAssembler();

  LocalAssemblyResult assemble(TextQuestionRegion region) {
    final diagnostics = <String>[
      ...region.diagnostics,
    ];
    var working = _normalizeText(region.rawText);

    final inlineAnswer = _extractInlineAnswer(working);
    working = inlineAnswer.remainingText;

    final inlineExplanation = _extractInlineExplanation(working);
    working = inlineExplanation.remainingText;

    final optionExtract = _extractOptions(working);

    final answer = _normalizeAnswer(
      inlineAnswer.answer ?? region.answerText ?? '',
    );

    final explanation = inlineExplanation.explanation?.trim() ?? '';
    final content = _cleanStem(optionExtract.stem);

    final type = _classifyType(
      content: content,
      options: optionExtract.options,
      answer: answer,
      kind: region.kind,
    );

    if (content.isEmpty) diagnostics.add('empty_content');
    if (answer.isEmpty) diagnostics.add('missing_answer');
    if (explanation.isEmpty) diagnostics.add('info_missing_explanation');

    if (type == 0 && optionExtract.options.length < 2) {
      diagnostics.add('choice_options_less_than_2');
    }

    if (_hasDanglingLatex(region.rawText)) {
      diagnostics.add('dangling_latex');
    }

    final repairRecommended = region.health == RegionHealth.repairable ||
        _shouldRecommendRepair(
      type: type,
      content: content,
      options: optionExtract.options,
      answer: answer,
      diagnostics: diagnostics,
      rawTextLength: region.rawText.length,
    );

    final rejected = content.isEmpty && region.rawText.trim().length < 8;

    return LocalAssemblyResult(
      question: {
        'question_number': region.number,
        'type': type,
        'content': content.isEmpty ? region.rawText.trim() : content,
        'options': optionExtract.options,
        'standard_answer': answer,
        'explanation': explanation,
        'raw_explanation': explanation.isEmpty ? null : explanation,
        'source': 'docx_text_deterministic',
        'diagnostics': diagnostics,
      },
      diagnostics: diagnostics,
      repairRecommended: repairRecommended,
      rejected: rejected,
    );
  }

  String _normalizeText(String input) {
    return input
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  _AnswerExtract _extractInlineAnswer(String text) {
    final regex = RegExp(
      r'(?:^|[\s\n。；;])(?:标准答案|正确答案|答案)\s*[:：]?\s*([A-DＡ-Ｄ]{1,4}|[√×]|对|错|正确|错误)(?=[\s，,。．.;；]|$)',
      caseSensitive: false,
    );

    final match = regex.firstMatch(text);
    if (match == null) return _AnswerExtract(null, text);

    final answer = match.group(1)?.trim();
    final remaining = text.replaceRange(match.start, match.end, ' ').trim();

    return _AnswerExtract(answer, remaining);
  }

  _ExplanationExtract _extractInlineExplanation(String text) {
    final regex = RegExp(
      r'(?:^|[\n。；;]|[\.．]\s+)\s*(?:答案解析|解析|分析)\s*[:：]?\s*',
      caseSensitive: false,
      multiLine: true,
    );

    final match = regex.firstMatch(text);
    if (match == null) return _ExplanationExtract(null, text);

    // boundary 之前的文本从 match.start 截取，去除边界空白
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
      return _OptionExtract(stem: text.trim(), options: const <String>[]);
    }

    final stem = text.substring(0, matches.first.start).trim();
    final options = <String>[];

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

      options.add('$key. $value');
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

  String _normalizeAnswer(String raw) {
    final value = raw
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

    return value;
  }

  String _cleanStem(String raw) {
    return raw
        .replaceFirst(
          RegExp(r'^\s*(?:第\s*)?\d{1,3}\s*(?:题|[\.、．）\)])?\s*'),
          '',
        )
        .trim();
  }

  int _classifyType({
    required String content,
    required List<String> options,
    required String answer,
    required TextQuestionKind kind,
  }) {
    // 现有 QuestionType 只有 singleChoice=0, fillBlank=2, shortAnswer=3。
    // 不要发明 multiChoice 枚举。多选答案如 AB 仍按 singleChoice code=0 存储。
    if (options.length >= 2 ||
        kind == TextQuestionKind.choice ||
        kind == TextQuestionKind.multiChoice) {
      return 0;
    }

    if (RegExp(r'_{2,}|\(\s*\)|（\s*）|填空|空格').hasMatch(content) ||
        kind == TextQuestionKind.fillBlank) {
      return 2;
    }

    return 3;
  }

  bool _hasDanglingLatex(String text) {
    final inlineOpen = r'\('.allMatches(text).length;
    final inlineClose = r'\)'.allMatches(text).length;
    final blockOpen = r'\['.allMatches(text).length;
    final blockClose = r'\]'.allMatches(text).length;

    if (inlineOpen != inlineClose) return true;
    if (blockOpen != blockClose) return true;

    final leftCount = RegExp(r'\\left').allMatches(text).length;
    final rightCount = RegExp(r'\\right').allMatches(text).length;

    return leftCount != rightCount;
  }

  bool _shouldRecommendRepair({
    required int type,
    required String content,
    required List<String> options,
    required String answer,
    required List<String> diagnostics,
    required int rawTextLength,
  }) {
    if (content.trim().length < 6 && rawTextLength > 20) return true;
    if (diagnostics.contains('dangling_latex')) return true;

    // 只有选择题才因选项不足触发修复。
    if (type == 0 && options.length < 2) return true;

    // 简答题没有 A/B/C/D 是正常情况，禁止因此触发 AI。
    if (type == 3 && !diagnostics.contains('dangling_latex')) return false;

    return false;
  }
}

class _AnswerExtract {
  const _AnswerExtract(this.answer, this.remainingText);

  final String? answer;
  final String remainingText;
}

class _ExplanationExtract {
  const _ExplanationExtract(this.explanation, this.remainingText);

  final String? explanation;
  final String remainingText;
}

class _OptionExtract {
  const _OptionExtract({
    required this.stem,
    required this.options,
  });

  final String stem;
  final List<String> options;
}
