const _referenceAnswerSectionHeadings = <String>{
  '参考答案',
  '参考答案汇总',
  '参考答案速查',
  '参考答案速览',
  '参考答案一览',
  '答案汇总',
  '答案速查',
  '答案速览',
  '答案一览',
  '试题答案',
  '全卷答案',
};

const _referenceAnswerStopHeadings = <String>{
  '参考解析',
  '详细解析',
  '评分标准',
  '附录',
};

const _referenceAnswerDocumentTitleEndings = <String>{
  '试卷',
  '试题',
  '考试',
};

bool isReferenceAnswerSectionHeading(String text) {
  return _referenceAnswerSectionHeadings.contains(
    normalizeReferenceAnswerHeading(text),
  );
}

bool hasReferenceAnswerSectionHeadingSuffix(String text) {
  final normalized = normalizeReferenceAnswerHeading(text);
  return _referenceAnswerSectionHeadings.any(normalized.endsWith);
}

/// Whether a supported answer heading is qualified by a document title.
///
/// This stronger signal is used only when a heading appears after other text
/// in the same physical OCR block. A bare label there may still belong to the
/// current question and is not sufficient to end official content ownership.
bool isDocumentTitledReferenceAnswerSectionHeading(String text) {
  final normalized = normalizeReferenceAnswerHeading(text);
  for (final heading in _referenceAnswerSectionHeadings) {
    if (!normalized.endsWith(heading)) continue;
    final title = normalized.substring(0, normalized.length - heading.length);
    if (title.isEmpty) return false;
    return _referenceAnswerDocumentTitleEndings.any(title.endsWith);
  }
  return false;
}

bool isReferenceAnswerStopHeading(String text) {
  return _referenceAnswerStopHeadings.contains(
    normalizeReferenceAnswerHeading(text),
  );
}

String normalizeReferenceAnswerHeading(String text) {
  var value = text.trim();
  while (true) {
    final stripped =
        value.replaceFirst(RegExp(r'^(?:#{1,6}\s+|>\s*)'), '').trim();
    if (stripped == value) break;
    value = stripped;
  }
  return value
      .replaceAll(RegExp(r'\s+'), '')
      .replaceFirst(RegExp(r'[:：]$'), '');
}
