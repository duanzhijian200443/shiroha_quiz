import 'text_question_region.dart';

class _Candidate {
  final int number;
  final int start;
  final int end;

  _Candidate({
    required this.number,
    required this.start,
    required this.end,
  });
}
class RegionizerResult {
  final List<TextQuestionRegion> regions;
  final Map<String, dynamic> diagnostics;

  const RegionizerResult(this.regions, this.diagnostics);
}

class TextQuestionRegionizer {
  const TextQuestionRegionizer();

  // 两阶段扫描候选题号正则：包含 (1) （1） 第1小题 1、 1) 等
  static final RegExp _questionCandidateRegex = RegExp(
    r'(^|\n|\s)(?:(?:第\s*)|[(（]\s*)?(\d{1,3})\s*(?:(?:小)?\s*题|[\.、．)）])?\s*(?=[^\d]|$)',
    multiLine: true,
  );

  RegionizerResult split(String rawText, Map<int, String> matchedAnswers) {
    final normalized = _normalize(rawText);
    final matches = _questionCandidateRegex.allMatches(normalized).toList();

    final diagnostics = <String, dynamic>{
      'candidateCount': 0,
      'acceptedRegionCount': 0,
      'rejectedCandidates': <int>[],
      'maxQuestionNumberDetected': 0,
      'missingNumbers': <int>[],
    };

    if (matches.isEmpty) return RegionizerResult(const [], diagnostics);

    final candidates = <_Candidate>[];
    final rejectedCandidates = <int>[];

    for (final match in matches) {
      final numStr = match.group(2);
      if (numStr == null) continue;
      final number = int.tryParse(numStr);
      if (number == null) continue;

      // Filter A/B/C/D option prefix
      int matchStart = match.start;
      if (matchStart < normalized.length && normalized[matchStart] == '\n') {
        matchStart++;
      }
      final lineStart = matchStart > 0 ? normalized.lastIndexOf('\n', matchStart - 1) : -1;
      final startOffset = lineStart == -1 ? 0 : lineStart + 1;
      final prefix = normalized.substring(startOffset, matchStart);
      if (RegExp(r'^\s*[A-DＡ-Ｄ][\.、．\)]').hasMatch(prefix)) {
        rejectedCandidates.add(number);
        continue;
      }

      candidates.add(_Candidate(
        number: number,
        start: match.start,
        end: match.end,
      ));
    }

    diagnostics['candidateCount'] = candidates.length + rejectedCandidates.length;

    if (candidates.isEmpty) {
      diagnostics['rejectedCandidates'] = rejectedCandidates;
      return RegionizerResult(const [], diagnostics);
    }

    // 动态规划序列筛选：选择最优单调递增序列
    final score = List<double>.filled(candidates.length, 0.0);
    final parent = List<int>.filled(candidates.length, -1);

    for (int i = 0; i < candidates.length; i++) {
      final current = candidates[i];
      final currentLen = _getTentativeLength(i, candidates, normalized.length);

      // 起点基础分数：每个题目基础分数 10000.0，加上该题 tentative 长度的 1.0 倍权重，以支持相同题号时保留最长 text
      score[i] = 10000.0 + currentLen * 1.0;
      parent[i] = -1;

      for (int j = 0; j < i; j++) {
        final prev = candidates[j];
        if (current.number > prev.number) {
          double val = score[j] + 10000.0 + currentLen * 1.0;
          if (current.number == prev.number + 1) {
            val += 5000.0; // 连续题号奖励
          } else {
            // 跳号惩罚，防止跳过过多题目
            val -= 100.0 * (current.number - prev.number - 1);
          }

          if (val > score[i]) {
            score[i] = val;
            parent[i] = j;
          }
        }
      }
    }

    int bestIndex = -1;
    double maxScore = -1.0;
    for (int i = 0; i < candidates.length; i++) {
      if (score[i] > maxScore) {
        maxScore = score[i];
        bestIndex = i;
      }
    }

    if (bestIndex == -1) {
      diagnostics['rejectedCandidates'] = candidates.map((c) => c.number).toList()..addAll(rejectedCandidates);
      return RegionizerResult(const [], diagnostics);
    }

    final selectedIndices = <int>[];
    int curr = bestIndex;
    while (curr != -1) {
      selectedIndices.add(curr);
      curr = parent[curr];
    }
    final chronologicalIndices = selectedIndices.reversed.toList();
    
    final acceptedIndicesSet = chronologicalIndices.toSet();
    for (int i = 0; i < candidates.length; i++) {
      if (!acceptedIndicesSet.contains(i)) {
        rejectedCandidates.add(candidates[i].number);
      }
    }

    final regions = <TextQuestionRegion>[];
    final acceptedNumbers = <int>{};
    int maxNumber = 0;

    for (int i = 0; i < chronologicalIndices.length; i++) {
      final idx = chronologicalIndices[i];
      final candidate = candidates[idx];
      final startOffset = candidate.start;
      final endOffset = (i + 1 < chronologicalIndices.length)
          ? candidates[chronologicalIndices[i + 1]].start
          : normalized.length;
      final text = normalized.substring(startOffset, endOffset).trim();

      acceptedNumbers.add(candidate.number);
      if (candidate.number > maxNumber) {
        maxNumber = candidate.number;
      }

      final kind = _detectKind(text);
      final regionDiagnostics = _diagnose(text, kind);

      // 允许跳号，但跳号要进入 warning
      if (i > 0) {
        final prevCandidate = candidates[chronologicalIndices[i - 1]];
        if (candidate.number > prevCandidate.number + 1) {
          regionDiagnostics.add('题号存在跳跃: 从 ${prevCandidate.number} 跳到 ${candidate.number}');
        }
      }

      final health = _determineHealth(text, kind, regionDiagnostics);

      regions.add(
        TextQuestionRegion(
          number: candidate.number,
          rawText: text,
          startOffset: startOffset,
          endOffset: endOffset,
          answerText: matchedAnswers[candidate.number],
          kind: kind,
          health: health,
          diagnostics: regionDiagnostics,
        ),
      );
    }

    final missingNumbers = <int>[];
    if (acceptedNumbers.isNotEmpty) {
      final minNumber = acceptedNumbers.reduce((a, b) => a < b ? a : b);
      for (int i = minNumber; i <= maxNumber; i++) {
        if (!acceptedNumbers.contains(i)) {
          missingNumbers.add(i);
        }
      }
    }

    diagnostics['acceptedRegionCount'] = regions.length;
    diagnostics['rejectedCandidates'] = rejectedCandidates;
    diagnostics['maxQuestionNumberDetected'] = maxNumber;
    diagnostics['missingNumbers'] = missingNumbers;

    return RegionizerResult(regions, diagnostics);
  }

  int _getTentativeLength(int index, List<_Candidate> candidates, int totalLength) {
    final start = candidates[index].start;
    final end = (index + 1 < candidates.length) ? candidates[index + 1].start : totalLength;
    return end - start;
  }

  String _normalize(String input) {
    var text = input
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();

    // 替换中文一到十为数字，以便题号解析
    const numberMap = {
      '一、': '1、', '二、': '2、', '三、': '3、', '四、': '4、', '五、': '5、',
      '六、': '6、', '七、': '7、', '八、': '8、', '九、': '9、', '十、': '10、',
    };
    for (final entry in numberMap.entries) {
      text = text.replaceAll(RegExp('^\\s*${entry.key}', multiLine: true), entry.value);
    }
    return text;
  }

  TextQuestionKind _detectKind(String text) {
    final hasOptionA = RegExp(r'(^|\n)\s*A[\.、．\)]\s*').hasMatch(text) ||
        RegExp(r'[\(（]A[\)）]').hasMatch(text);
    if (hasOptionA) {
      return TextQuestionKind.choice;
    }

    final hasBlankSignal = text.contains('___') || text.contains('___') || RegExp(r'（\s{2,}）|\(\s{2,}\)').hasMatch(text);
    if (hasBlankSignal) {
      return TextQuestionKind.fillBlank;
    }

    final hasTrueFalseSignal = RegExp(r'[(（]\s*[√×TFM]\s*[)）]').hasMatch(text);
    if (hasTrueFalseSignal) {
      return TextQuestionKind.trueFalse;
    }

    return TextQuestionKind.subjective;
  }

  List<String> _diagnose(String text, TextQuestionKind kind) {
    final diagnostics = <String>[];

    if (kind == TextQuestionKind.choice) {
      final hasA = RegExp(r'(^|\n)\s*A[\.、．\)]\s*').hasMatch(text) || RegExp(r'[\(（]A[\)）]').hasMatch(text);
      final hasB = RegExp(r'(^|\n)\s*B[\.、．\)]\s*').hasMatch(text) || RegExp(r'[\(（]B[\)）]').hasMatch(text);
      if (!hasA) {
        diagnostics.add('缺少 A 选项');
      }
      if (!hasB) {
        diagnostics.add('缺少 B 选项');
      }
    }

    if (text.contains(r'\(') && !text.contains(r'\)')) {
      diagnostics.add('疑似未闭合行内公式 \\(');
    }
    if (text.contains(r'\[') && !text.contains(r'\]')) {
      diagnostics.add('疑似未闭合块级公式 \\[');
    }

    return diagnostics;
  }

  RegionHealth _determineHealth(String text, TextQuestionKind kind, List<String> diagnostics) {
    // 只有涉及内容的诊断异常（如缺失选项、未闭合公式）才触发 AI 修复流程
    final hasContentIssue = diagnostics.any((d) =>
        d.contains('缺少') || d.contains('未闭合')
    );
    if (hasContentIssue) {
      return RegionHealth.repairable;
    }

    return RegionHealth.clean;
  }
}
