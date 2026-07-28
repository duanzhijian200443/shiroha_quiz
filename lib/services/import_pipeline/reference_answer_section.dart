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

bool isReferenceAnswerSectionHeading(String text) {
  return _referenceAnswerSectionHeadings.contains(
    normalizeReferenceAnswerHeading(text),
  );
}

bool hasReferenceAnswerSectionHeadingSuffix(String text) {
  final normalized = normalizeReferenceAnswerHeading(text);
  return _referenceAnswerSectionHeadings.any(normalized.endsWith);
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
