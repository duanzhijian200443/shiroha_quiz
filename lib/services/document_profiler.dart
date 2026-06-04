class DocProfile {
  final bool hasInlineAnswers;
  final bool hasTailAnswerBlock;
  final int tailAnswerOffset; // -1 if not found
  final bool hasExplanation;

  DocProfile({
    required this.hasInlineAnswers,
    required this.hasTailAnswerBlock,
    required this.tailAnswerOffset,
    required this.hasExplanation,
  });

  @override
  String toString() {
    return 'DocProfile(inline: $hasInlineAnswers, tailBlock: $hasTailAnswerBlock, offset: $tailAnswerOffset, explanation: $hasExplanation)';
  }
}

DocProfile scanDocumentStructure(String rawText) {
  // 1. 动态阈值：对于短试卷放宽尾部扫描范围
  final isShortDoc = rawText.length < 2000;
  final tailThreshold = isShortDoc ? 0.5 : 0.8; // 短试卷扫后半部分，长试卷扫最后20%

  final tailStartIdx = (rawText.length * tailThreshold).toInt();
  final tail = rawText.substring(tailStartIdx);

  // 2. 尾部答案区检测（脱离 Markdown，纯净关键字匹配）
  // 考虑到 OCR 可能不带首尾换行符，用 (?:^|\n) 和 (?:\n|$) 来做边界保护
  final tailPattern =
      RegExp(r'(?:^|\n)\s*(参考答案|答案速查|答案汇总|标准答案|解析汇编)[^\n]*(?:\n|$)');
  final tailMatch = tailPattern.firstMatch(tail);
  final tailOffset = tailMatch != null ? tailStartIdx + tailMatch.start : -1;

  // 3. 行内答案检测（扫描前 50%）
  final headEndIdx = (rawText.length * 0.5).toInt();
  final head = rawText.substring(0, headEndIdx);
  final inlinePattern = RegExp(r'(答案|解析)[：:]\s*[A-Da-d√×\d]|【答案】|参考答案[：:]');
  final hasInline = inlinePattern.hasMatch(head);

  // 4. 解析存在检测
  final hasExplanation = rawText.contains('解析') || rawText.contains('分析');

  return DocProfile(
    hasInlineAnswers: hasInline,
    hasTailAnswerBlock: tailOffset != -1,
    tailAnswerOffset: tailOffset,
    hasExplanation: hasExplanation,
  );
}
