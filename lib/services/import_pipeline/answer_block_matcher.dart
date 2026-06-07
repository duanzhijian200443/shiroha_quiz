class AnswerBlockMatcher {
  const AnswerBlockMatcher();

  static final RegExp _answerStart = RegExp(
    r'^(参考答案|答案与解析|答案及解析|答案|解析)[\s:：]*$',
    multiLine: true,
  );

  // 选择/判断题答案：A-D、√×、对/错/正确/错误
  static final RegExp _choiceAnswerLine = RegExp(
    r'^\s*(?:第\s*)?(\d{1,3})\s*(?:题|[\.、．])?\s*'
    r'(?:答案|正确答案)?\s*[:：]?\s*'
    r'([A-DＡ-Ｄ]{1,4}|[√×]|对|错|正确|错误)'
    r'(?:[\s，,。．.;；]|$)(.*)$',
    multiLine: true,
  );

  // 填空/计算/简答题答案：紧跟"答案:"的短文本，长度限制 80 字，后面必须有"解析"/"分析"或行尾
  static final RegExp _subjectiveAnswerLine = RegExp(
    r'^\s*(?:第\s*)?(\d{1,3})\s*(?:题|[\.、．])?\s*'
    r'(?:答案|正确答案)?\s*[:：]?\s*'
    r'(.{1,80}?)(?=\s*(?:解析|分析)[:：]|$)',
    multiLine: true,
  );

  ({String questionBodyText, Map<int, String> answers, String answerBlockText}) splitAnswerBlock(
    String rawText,
  ) {
    final matches = _answerStart.allMatches(rawText).toList();
    if (matches.isEmpty) {
      return (questionBodyText: rawText, answers: const <int, String>{}, answerBlockText: '');
    }

    // 从后往前找，找到第一个包含连续答案序列的块。如果没有，就认为没有独立的答案块。
    for (final match in matches.reversed) {
      final answerTextCandidate = rawText.substring(match.start);
      final questionTextCandidate = rawText.substring(0, match.start).trim();

      final answers = <int, String>{};
      int maxConsecutive = 0;
      int currentConsecutive = 0;
      int lastNum = -1;

      for (final m in _choiceAnswerLine.allMatches(answerTextCandidate)) {
        final number = int.tryParse(m.group(1) ?? '');
        final answer = m.group(2)?.trim();
        if (number != null && answer != null && answer.isNotEmpty) {
          answers[number] = answer;
          if (number == lastNum + 1 || lastNum == -1) {
            currentConsecutive++;
            if (currentConsecutive > maxConsecutive) {
              maxConsecutive = currentConsecutive;
            }
          } else {
            currentConsecutive = 1;
          }
          lastNum = number;
        }
      }

      // 选择/判断没命中时，尝试填空/简答答案行
      if (answers.isEmpty) {
        lastNum = -1;
        currentConsecutive = 0;
        maxConsecutive = 0;
        for (final m in _subjectiveAnswerLine.allMatches(answerTextCandidate)) {
          final number = int.tryParse(m.group(1) ?? '');
          final answer = m.group(2)?.trim();
          if (number != null &&
              answer != null &&
              answer.isNotEmpty &&
              _isSafeSubjectiveAnswer(answer)) {
            answers[number] = answer;
            if (number == lastNum + 1 || lastNum == -1) {
              currentConsecutive++;
              if (currentConsecutive > maxConsecutive) {
                maxConsecutive = currentConsecutive;
              }
            } else {
              currentConsecutive = 1;
            }
            lastNum = number;
          }
        }
      }

      // 只要匹配到了明确的答案区块标志，且能提取出至少 1 个有效答案，就认为是有效块。
      if (answers.isNotEmpty) {
        return (
          questionBodyText: questionTextCandidate,
          answers: answers,
          answerBlockText: answerTextCandidate,
        );
      }
    }

    // 没找到合理的序列，退化为无单独答案块
    return (questionBodyText: rawText, answers: const <int, String>{}, answerBlockText: '');
  }

  bool _isSafeSubjectiveAnswer(String value) {
    final text = value.trim();
    if (text.isEmpty || text.length > 80) return false;
    if (RegExp(r'(本题|因为|所以|解析|分析|考查)').hasMatch(text)) {
      return false;
    }
    return true;
  }
}
