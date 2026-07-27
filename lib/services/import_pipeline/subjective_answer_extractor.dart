import '../../data/models/import_question_validation.dart';

class SubjectiveAnswerExtractionResult {
  const SubjectiveAnswerExtractionResult.matched({
    required this.answer,
    required this.reasonCode,
  }) : matched = true;

  const SubjectiveAnswerExtractionResult.notMatched(this.reasonCode)
      : matched = false,
        answer = null;

  final bool matched;
  final String? answer;
  final String reasonCode;
}

class SubjectiveAnswerExtractor {
  const SubjectiveAnswerExtractor();

  SubjectiveAnswerExtractionResult extract({
    required int questionNumber,
    required String content,
    required String standardAnswer,
    required String explanation,
  }) {
    if (isMeaningfulAnswer(standardAnswer)) {
      return const SubjectiveAnswerExtractionResult.notMatched(
        'subjective_answer_existing',
      );
    }
    final source = explanation.trim();
    if (source.isEmpty) {
      return const SubjectiveAnswerExtractionResult.notMatched(
        'subjective_answer_explanation_empty',
      );
    }

    final lines = source.split(RegExp(r'\r?\n'));
    for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      final line = lines[lineIndex];
      for (final pattern in _labelledAnswers) {
        final labelled = pattern.firstMatch(line);
        if (labelled == null ||
            !_isTerminalLine(lines, lineIndex) ||
            _hasUnsafePrefix(line.substring(0, labelled.start))) {
          continue;
        }
        final answer = _sanitizeCandidate(labelled.group(1), source);
        if (answer != null) {
          return SubjectiveAnswerExtractionResult.matched(
            answer: answer,
            reasonCode: 'subjective_answer_extracted_label',
          );
        }
      }
    }

    for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      if (!_isTerminalLine(lines, lineIndex)) continue;
      final conclusion = _explicitEquationConclusion.firstMatch(
        lines[lineIndex],
      );
      if (conclusion == null) continue;
      final answer = _sanitizeCandidate(conclusion.group(1), source);
      if (answer != null && answer.contains('=')) {
        return SubjectiveAnswerExtractionResult.matched(
          answer: answer,
          reasonCode: 'subjective_answer_extracted_conclusion',
        );
      }
    }

    return const SubjectiveAnswerExtractionResult.notMatched(
      'subjective_answer_not_deterministic',
    );
  }

  static final List<RegExp> _labelledAnswers = [
    RegExp(r'(?:标准答案|参考答案|答案)\s*[:：]\s*([^\r\n]+)'),
    RegExp(r'(?:最终结果为|故答案为|答案为|应填|所求为)\s*[:：]?\s*([^\r\n]+)'),
  ];

  static final RegExp _explicitEquationConclusion = RegExp(
    r'^\s*因此\s+([^。；]+(?:[。；]|$))',
  );

  String? _sanitizeCandidate(String? raw, String explanation) {
    if (raw == null) return null;
    var answer = raw.trim();
    if (answer.isEmpty) return null;

    final unsafeTail = RegExp(
      r'\s*(?:备注|另解|另一种解法|第二种解法|方法二|例题|示例|说明)\s*[:：]?',
    );
    final unsafeTailMatch = unsafeTail.firstMatch(answer);
    if (unsafeTailMatch != null) {
      answer = answer.substring(0, unsafeTailMatch.start).trim();
    }
    answer = answer.replaceFirst(RegExp(r'[。；]\s*$'), '').trim();

    if (!isMeaningfulAnswer(answer) ||
        const {'命题得证', '结论成立'}.contains(answer) ||
        RegExp(r'(?:标准答案|参考答案|答案)\s*[:：]').hasMatch(answer) ||
        _hasIncompleteLatexEnvironment(answer) ||
        answer.runes.length > 240) {
      return null;
    }

    final normalizedAnswer = _normalize(answer);
    final normalizedExplanation = _normalize(explanation);
    if (normalizedAnswer == normalizedExplanation) return null;
    if (normalizedExplanation.length >= 80 &&
        normalizedAnswer.length * 5 >= normalizedExplanation.length * 4) {
      return null;
    }
    return answer;
  }

  String _normalize(String value) => value.replaceAll(RegExp(r'\s+'), '');

  bool _isTerminalLine(List<String> lines, int lineIndex) {
    return lines.skip(lineIndex + 1).every((line) => line.trim().isEmpty);
  }

  bool _hasUnsafePrefix(String prefix) {
    return RegExp(r'(?:例题|示例|例如|备注|另解|解法)').hasMatch(prefix);
  }

  bool _hasIncompleteLatexEnvironment(String answer) {
    final begins = RegExp(r'\\begin\{([^}]+)\}').allMatches(answer).toList();
    if (begins.isEmpty) return false;
    for (final begin in begins) {
      final environment = begin.group(1);
      if (environment == null || !answer.contains('\\end{$environment}')) {
        return true;
      }
    }
    return false;
  }
}
