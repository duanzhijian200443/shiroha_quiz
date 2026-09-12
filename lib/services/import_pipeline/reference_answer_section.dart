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

const _referenceAnswerStandaloneDocumentTitles = <String>{
  '模拟试卷',
};

const _referenceAnswerScoringSuffixes = <String>{
  '及评分参考',
};

final _referenceAnswerYearLedDocumentTitle = RegExp(r'^(?:19|20)\d{2}(?:年)?');
final _referenceAnswerDocumentTokenRegex = RegExp(r'(?:试卷|试题|考试)');
final _referenceAnswerSubjectQualifierRegex = RegExp(
  r'^(?:'
  r'[（(]?(?:[文理工医]科|[甲乙丙]卷|[A-Da-d]卷|[一二三四五1-5I|A-D])[）)]?'
  r'|'
  r'(?:（[文理工医]科?）|\([文理工医]科?\)|文科|理科)?'
  r'(?:'
  r'数学|语文|英语|外语|外国语|俄语|日语|法语|德语|'
  r'物理|化学|生物|历史|地理|政治|思想政治理论|'
  r'文科数学|理科数学|文科综合|理科综合|文综|理综|综合能力|'
  r'专业基础|专业综合|业务课|专业课|'
  r'计算机(?:学科)?(?:专业基础)?|'
  r'管理类(?:联考)?综合能力|经济类(?:联考)?综合能力|'
  r'教育学(?:专业基础)?|心理学(?:专业基础)?|历史学(?:基础)?|'
  r'临床医学综合能力|西医综合|中医综合|西医|中医|'
  r'高等数学|线性代数|概率论(?:与数理统计)?|'
  r'[\u4e00-\u9fa5]{2,8}(?:学|论|原理|技术|工程|基础|综合|结构)'
  r')'
  r'(?:[（(]?(?:[一二三四五1-5I|A-Da-d]+(?:卷)?|[甲乙丙]卷|[文理]科)[）)]?|[一二三四五1-5]|[A-Da-d])?'
  r')$',
);

bool isReferenceAnswerSectionHeading(String text) {
  return _referenceAnswerSectionHeadings.contains(
    normalizeReferenceAnswerHeading(text),
  );
}

bool hasReferenceAnswerSectionHeadingSuffix(String text) {
  final normalized = normalizeReferenceAnswerHeading(text);
  return _referenceAnswerSectionHeadings.contains(normalized) ||
      _isDocumentTitledReferenceAnswerSectionHeading(normalized);
}

/// Whether a supported answer heading is qualified by a document title.
///
/// This stronger signal is used only when a heading appears after other text
/// in the same physical OCR block. A bare label there may still belong to the
/// current question and is not sufficient to end official content ownership.
bool isDocumentTitledReferenceAnswerSectionHeading(String text) {
  final normalized = normalizeReferenceAnswerHeading(text);
  return _isDocumentTitledReferenceAnswerSectionHeading(normalized);
}

bool _isDocumentTitledReferenceAnswerSectionHeading(String normalized) {
  for (final heading in _referenceAnswerSectionHeadings) {
    if (_hasSupportedDocumentTitlePrefix(normalized, heading)) {
      return true;
    }
    for (final scoringSuffix in _referenceAnswerScoringSuffixes) {
      if (_hasSupportedDocumentTitlePrefix(
        normalized,
        '$heading$scoringSuffix',
      )) {
        return true;
      }
    }
  }
  return false;
}

bool _hasSupportedDocumentTitlePrefix(
  String normalized,
  String ending,
) {
  if (!normalized.endsWith(ending)) return false;
  final title = normalized.substring(0, normalized.length - ending.length);
  if (title.isEmpty) return false;

  if (_referenceAnswerStandaloneDocumentTitles.contains(title)) {
    return true;
  }

  if (!_referenceAnswerYearLedDocumentTitle.hasMatch(title)) {
    return false;
  }

  // A supported title ending does not by itself make arbitrary prose a
  // document title. Preserve only year-led OCR titles and the bounded
  // standalone title vocabulary. Markdown is formatting, not title authority.
  //
  // Year-led titles must contain a document token (试卷, 试题, 考试), and may
  // end with it directly or be qualified by a bounded subject or paper
  // descriptor (e.g. 数学（一）, 英语（二）, 思想政治理论).
  final matches = _referenceAnswerDocumentTokenRegex.allMatches(title);
  if (matches.isEmpty) return false;

  final suffix = title.substring(matches.last.end);
  if (suffix.isEmpty) return true;

  return suffix.length <= 15 &&
      _referenceAnswerSubjectQualifierRegex.hasMatch(suffix);
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
