class ChoiceAnswerParseResult {
  const ChoiceAnswerParseResult._({
    required this.parsed,
    required this.labels,
  });

  const ChoiceAnswerParseResult.parsed(List<String> labels)
      : this._(parsed: true, labels: labels);

  const ChoiceAnswerParseResult.unparsed()
      : this._(parsed: false, labels: const []);

  final bool parsed;
  final List<String> labels;
}

bool isMeaningfulAnswer(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return false;

  final lower = text.toLowerCase();
  const placeholders = {
    'null',
    'none',
    '无',
    '暂无',
    '暂无答案',
    '未知',
    '未提供',
    '未给出',
    '未见答案',
    '见解析',
    '详见解析',
    '答案见解析',
  };
  if (placeholders.contains(lower) || placeholders.contains(text)) {
    return false;
  }

  return !text.contains('未见答案') &&
      !text.contains('暂无') &&
      !text.contains('未提供') &&
      !text.contains('未给出') &&
      !text.contains('见解析');
}

List<String> meaningfulOptions(Iterable<Object?>? options) {
  if (options == null) return const [];
  return options
      .map((option) => option?.toString().trim() ?? '')
      .where((option) => option.isNotEmpty)
      .toList(growable: false);
}

bool hasAtLeastTwoMeaningfulOptions(Iterable<Object?>? options) =>
    meaningfulOptions(options).length >= 2;

ChoiceAnswerParseResult parseChoiceAnswerLabels(String value) {
  var candidate = value.trim();
  if (candidate.isEmpty) return const ChoiceAnswerParseResult.unparsed();

  final prefixed = RegExp(
    r'^(?:答案|answer)\s*[:：]?\s*(.+)$',
    caseSensitive: false,
  ).firstMatch(candidate);
  if (prefixed != null) {
    candidate = prefixed.group(1)!.trim();
  } else {
    final option = RegExp(
      r'^option\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(candidate);
    if (option != null) candidate = option.group(1)!.trim();
  }

  final wrapped = RegExp(r'^[（(]\s*([A-Z])\s*[）)]$', caseSensitive: false)
      .firstMatch(candidate);
  if (wrapped != null) {
    return ChoiceAnswerParseResult.parsed(
      List.unmodifiable([wrapped.group(1)!.toUpperCase()]),
    );
  }

  final compact = RegExp(r'^[A-Z]+$', caseSensitive: false);
  if (compact.hasMatch(candidate)) {
    final labels = candidate.toUpperCase().split('');
    final isUnambiguousCompactSequence = labels.length == 1 ||
        List.generate(
          labels.length - 1,
          (index) =>
              labels[index].codeUnitAt(0) < labels[index + 1].codeUnitAt(0),
        ).every((isIncreasing) => isIncreasing);
    if (isUnambiguousCompactSequence) {
      return ChoiceAnswerParseResult.parsed(List.unmodifiable(labels));
    }
    return const ChoiceAnswerParseResult.unparsed();
  }

  final delimited = RegExp(
    r'^[A-Z](?:\s*[,，、;/；]\s*[A-Z])+$',
    caseSensitive: false,
  );
  if (!delimited.hasMatch(candidate)) {
    return const ChoiceAnswerParseResult.unparsed();
  }

  return ChoiceAnswerParseResult.parsed(
    List.unmodifiable(
      candidate
          .toUpperCase()
          .split(RegExp(r'\s*[,，、;/；]\s*'))
          .where((label) => label.isNotEmpty)
          .toList(growable: false),
    ),
  );
}
