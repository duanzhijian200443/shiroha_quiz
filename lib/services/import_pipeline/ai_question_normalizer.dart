import 'dart:convert';

class AiQuestionNormalizationResult {
  final List<Map<String, dynamic>> questions;
  final List<String> warnings;
  final Map<String, dynamic> diagnostics;
  final int repairedCount;
  final int droppedCount;

  const AiQuestionNormalizationResult({
    required this.questions,
    required this.warnings,
    required this.diagnostics,
    required this.repairedCount,
    required this.droppedCount,
  });
}

class AiQuestionNormalizer {
  /// Normalizes AI responses into the import contract:
  /// - choice question: original stem must contain explicit choice evidence;
  /// - fill blank: no explanation;
  /// - short answer: content + standard_answer + explanation, options always [].
  static AiQuestionNormalizationResult normalizeAll(List<dynamic> rawList) {
    final normalizedQuestions = <Map<String, dynamic>>[];
    final warnings = <String>[];
    final dropLogs = <Map<String, dynamic>>[];
    final repairLogs = <Map<String, dynamic>>[];
    var repairedCount = 0;
    var droppedCount = 0;

    for (var idx = 0; idx < rawList.length; idx++) {
      final item = rawList[idx];

      if (item == null) {
        droppedCount++;
        dropLogs.add({'index': idx, 'reason': 'Item is null'});
        continue;
      }

      if (item is! Map) {
        droppedCount++;
        dropLogs.add({
          'index': idx,
          'reason': 'Item is not a Map',
          'type': item.runtimeType.toString(),
          'value': item.toString(),
        });
        continue;
      }

      final rawMap = Map<String, dynamic>.from(item);
      if (rawMap.isEmpty) {
        droppedCount++;
        dropLogs.add({'index': idx, 'reason': 'Map is empty'});
        continue;
      }

      var isRepaired = false;
      final normalized = <String, dynamic>{};

      final rawContent = rawMap['content'];
      var content = rawContent?.toString().trim() ?? '';
      final strippedContent = _stripHallucinatedChoiceBlock(content);
      if (strippedContent != content) {
        content = strippedContent;
        isRepaired = true;
        warnings.add('第 ${idx + 1} 题疑似简答题被脑补为 A/B/C/D，已清理伪选项');
      }
      normalized['content'] = content;
      if (rawContent != null && rawContent is! String) {
        isRepaired = true;
      }

      var standardAnswer =
          (rawMap['standard_answer'] ?? rawMap['answer'])?.toString().trim() ??
              '';
      if (_isInvalidAnswer(standardAnswer)) {
        standardAnswer = '';
        isRepaired = true;
      }
      normalized['standard_answer'] = standardAnswer;
      if (rawMap.containsKey('answer') &&
          !rawMap.containsKey('standard_answer')) {
        isRepaired = true;
      }

      var explanation = rawMap['explanation']?.toString().trim() ?? '';
      normalized['explanation'] = explanation;
      if (rawMap.containsKey('raw_explanation')) {
        normalized['raw_explanation'] =
            rawMap['raw_explanation']?.toString().trim();
      }

      final rawOptions = rawMap['options'];
      var parsedOptions = _parseOptions(rawOptions);
      if (_optionsLookLikeHallucinatedAnalysis(parsedOptions, content)) {
        parsedOptions = const <String>[];
        isRepaired = true;
        warnings.add('第 ${idx + 1} 题选项缺少原文依据，已按简答题处理');
      }
      normalized['options'] = parsedOptions;
      if (rawOptions != null && rawOptions is! List) {
        isRepaired = true;
      }

      final rawType = rawMap['type'];
      final parsedTypeCode = _parseTypeCode(rawType);
      final hasChoiceEvidence = _hasChoiceEvidence(content);
      final hasChoiceAnswer = _isChoiceAnswer(standardAnswer);
      final hasChoiceSignal = hasChoiceEvidence ||
          (hasChoiceAnswer && _hasChoiceAnswerSlot(content));

      int finalType;
      if (parsedTypeCode == 2) {
        finalType = 2;
      } else if (hasChoiceAnswer && _hasChoiceAnswerSlot(content)) {
        finalType = 0;
        if (parsedTypeCode != 0) {
          isRepaired = true;
        }
      } else if (parsedTypeCode == 3) {
        finalType = 3;
      } else if (parsedTypeCode == 0) {
        if (hasChoiceSignal) {
          finalType = 0;
        } else {
          finalType = 3;
          parsedOptions = const <String>[];
          normalized['options'] = parsedOptions;
          isRepaired = true;
          warnings.add('第 ${idx + 1} 题不具备选择题原文证据，已降级为简答题');
        }
      } else if (parsedOptions.isNotEmpty && hasChoiceSignal) {
        finalType = 0;
        isRepaired = true;
      } else if (_looksLikeFillBlank(content)) {
        finalType = 2;
        isRepaired = true;
      } else {
        finalType = 3;
        parsedOptions = const <String>[];
        normalized['options'] = parsedOptions;
        isRepaired = true;
      }

      if (finalType != 0 && parsedOptions.isNotEmpty) {
        parsedOptions = const <String>[];
        normalized['options'] = parsedOptions;
        isRepaired = true;
      }

      if (finalType != 3 && explanation.isNotEmpty) {
        explanation = '';
        normalized['explanation'] = explanation;
        isRepaired = true;
        warnings.add('第 ${idx + 1} 题不是简答题，已移除解析字段');
      }

      normalized['type'] = finalType;
      if (rawType != finalType) {
        isRepaired = true;
      }

      if (rawMap.containsKey('sub_questions')) {
        rawMap.remove('sub_questions');
        isRepaired = true;
      }

      for (final key in rawMap.keys) {
        if (key != 'content' &&
            key != 'standard_answer' &&
            key != 'answer' &&
            key != 'explanation' &&
            key != 'raw_explanation' &&
            key != 'options' &&
            key != 'type') {
          normalized[key] = rawMap[key];
        }
      }

      if (isRepaired) {
        repairedCount++;
        repairLogs.add({
          'index': idx,
          'original': item.toString(),
          'normalized': normalized.toString(),
        });
      }

      normalizedQuestions.add(normalized);
    }

    final diagnostics = {
      'total': rawList.length,
      'normalizedCount': normalizedQuestions.length,
      'repairedCount': repairedCount,
      'droppedCount': droppedCount,
      if (dropLogs.isNotEmpty) 'dropLogs': dropLogs,
      if (repairLogs.isNotEmpty) 'repairLogs': repairLogs,
    };

    return AiQuestionNormalizationResult(
      questions: normalizedQuestions,
      warnings: warnings,
      diagnostics: diagnostics,
      repairedCount: repairedCount,
      droppedCount: droppedCount,
    );
  }

  static bool _isInvalidAnswer(String answer) {
    final trimmed = answer.trim();
    final lower = trimmed.toLowerCase();
    const invalidAnswers = {
      '无',
      '未提供',
      '未见答案',
      '暂无',
      'null',
      'none',
      'NULL',
      'NONE',
    };
    return trimmed.isEmpty == false &&
        (invalidAnswers.contains(trimmed) ||
            invalidAnswers.contains(lower) ||
            trimmed.contains('未见答案') ||
            trimmed.contains('暂无'));
  }

  static String _stripHallucinatedChoiceBlock(String content) {
    if (content.isEmpty) return content;
    if (_hasChoiceInstruction(content)) return content;

    final firstMarker =
        RegExp(r'(^|\n)\s*[A-D][\.\、\)]\s*').firstMatch(content);
    if (firstMarker == null) return content;

    final tail = content.substring(firstMarker.start);
    final markerCount =
        RegExp(r'(^|\n)\s*[A-D][\.\、\)]\s*').allMatches(tail).length;
    if (markerCount < 2) return content;

    return content.substring(0, firstMarker.start).trim();
  }

  static bool _optionsLookLikeHallucinatedAnalysis(
    List<String> options,
    String content,
  ) {
    if (options.isEmpty) return false;
    if (_hasChoiceEvidence(content)) return false;
    if (_looksLikeSubjectiveStem(content)) return true;

    final longReasoningOptions = options.where((option) {
      final text = option.replaceFirst(RegExp(r'^[A-Da-d][\.\、\)]\s*'), '');
      return text.length >= 18 &&
          RegExp(r'(充分|必要|条件|特征值|特征向量|对角化|证明|因为|所以|反之|可得|应选)').hasMatch(text);
    }).length;
    return longReasoningOptions >= 2;
  }

  static bool _hasChoiceEvidence(String content) {
    if (content.isEmpty) return false;
    if (_hasChoiceInstruction(content)) return true;
    if (_looksLikeSubjectiveStem(content)) return false;
    final optionMarkers =
        RegExp(r'(^|\n|\s)[A-D][\.\、\)]\s*\S').allMatches(content).length;
    return optionMarkers >= 2;
  }

  static bool _hasChoiceInstruction(String content) {
    return RegExp(r'(选择|单选|下列|哪一项|正确的是|错误的是|应选|选项)').hasMatch(content);
  }

  static bool _looksLikeSubjectiveStem(String content) {
    return RegExp(r'(求|写出|证明|计算|化为|解方程|通解|矩阵|二次型|正交变换|标准形)').hasMatch(content);
  }

  static bool _isChoiceAnswer(String answer) {
    return RegExp(r'^[A-Da-d]$').hasMatch(answer.trim());
  }

  static bool _hasChoiceAnswerSlot(String content) {
    return RegExp(r'[则,，]\s*[\(（]\s*[\)）]').hasMatch(content) ||
        RegExp(r'[\(（]\s*[\)）]').hasMatch(content);
  }

  static bool _looksLikeFillBlank(String content) {
    return content.contains('___') || content.contains('____');
  }

  static List<String> _parseOptions(dynamic value) {
    if (value == null) return const <String>[];
    if (value is List) {
      return value
          .map((option) => option?.toString().trim() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
    }

    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return const <String>[];

      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List) return _parseOptions(decoded);
      } catch (_) {}

      final lines = trimmed
          .split(RegExp(r'\r?\n'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (lines.length > 1) return lines;

      final markers = RegExp(r'\b([A-D]|[a-d])[\.\、\)]\s*');
      if (markers.hasMatch(trimmed)) {
        final matches = markers.allMatches(trimmed).toList();
        final parsed = <String>[];
        for (var i = 0; i < matches.length; i++) {
          final start = matches[i].start;
          final end =
              (i + 1 < matches.length) ? matches[i + 1].start : trimmed.length;
          parsed.add(trimmed.substring(start, end).trim());
        }
        if (parsed.isNotEmpty) return parsed;
      }

      return [trimmed];
    }

    return [value.toString().trim()];
  }

  static int? _parseTypeCode(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final s = value.trim();
      final parsed = int.tryParse(s);
      if (parsed != null) return parsed;

      final lower = s.toLowerCase();
      if (lower.contains('选择') ||
          lower.contains('choice') ||
          lower.contains('单选') ||
          lower.contains('多选')) {
        return 0;
      }
      if (lower.contains('填空') || lower.contains('blank')) {
        return 2;
      }
      if (lower.contains('解答') ||
          lower.contains('简答') ||
          lower.contains('subjective') ||
          lower.contains('essay')) {
        return 3;
      }
    }
    return null;
  }
}
