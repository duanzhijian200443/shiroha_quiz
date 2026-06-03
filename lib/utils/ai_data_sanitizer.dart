import 'dart:convert';

import 'content_normalizer.dart';

class AiDataSanitizer {
  const AiDataSanitizer._();

  static List<Map<String, dynamic>> cleanAndParseJson(String rawText) {
    if (rawText.trim().isEmpty) {
      throw Exception('AI returned an empty response.');
    }

    final candidate = _extractJsonCandidate(rawText);
    final repaired = _repairJsonStringEscapes(candidate);
    final decoded = _decodeJsonWithTailRepair(repaired);
    final questions = _extractQuestionList(decoded);

    final finalQuestions = <Map<String, dynamic>>[];
    for (final item in questions) {
      if (item is! Map) continue;

      final q = Map<String, dynamic>.from(item);
      var currentType = _readInt(q['type']) ?? 0;

      _ensureFallbackContent(q);
      _normalizeQuestionFields(q);
      q.remove('sub_questions');

      currentType = _extractOptionsFromContentIfNeeded(q, currentType);
      _normalizeQuestionType(q, currentType);
      finalQuestions.add(q);
    }

    return finalQuestions;
  }

  static String cleanLatexBeforeDB(String text) {
    if (text.isEmpty) return text;
    return ContentNormalizer.normalizeForStorage(_decodeLiteralControls(text));
  }

  static String formatLatex(String text) {
    if (text.isEmpty) return text;
    return ContentNormalizer.normalizeForRender(_decodeLiteralControls(text));
  }

  static String normalizeDelimiters(String text) {
    if (text.isEmpty) return text;
    return ContentNormalizer.normalizeForStorage(_decodeLiteralControls(text));
  }

  static List<String> findBareLatexCommands(String text) {
    return ContentNormalizer.findBareLatexCommands(text);
  }

  // Kept as a compatibility shim for older callers. It is diagnostic only and
  // must not be used to auto-wrap formulas at runtime.
  static bool isLikelyMathFormula(String tex) {
    return ContentNormalizer.findBareLatexCommands(tex).isNotEmpty;
  }

  static String _extractJsonCandidate(String rawText) {
    final codeBlock = RegExp(
      r'```(?:json)?\s*([\s\S]*?)```',
      caseSensitive: false,
    ).firstMatch(rawText);
    final source = (codeBlock?.group(1) ?? rawText).trim();

    final start = _findJsonStart(source);
    if (start == -1) {
      throw Exception('No JSON object or array found in AI response.');
    }

    final end = _findJsonEnd(source, start);
    if (end == -1) {
      throw Exception('JSON brackets are not balanced.');
    }

    return source.substring(start, end + 1);
  }

  static int _findJsonStart(String source) {
    for (var i = 0; i < source.length; i++) {
      final char = source[i];
      if (char == '{') return i;
      if (char == '[') {
        var j = i + 1;
        while (j < source.length && source[j].trim().isEmpty) {
          j++;
        }
        if (j < source.length && source[j] == '{') return i;
      }
    }
    return -1;
  }

  static int _findJsonEnd(String source, int start) {
    final stack = <String>[];
    var inString = false;
    var escaped = false;

    for (var i = start; i < source.length; i++) {
      final char = source[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (char == '\\') {
          escaped = true;
        } else if (char == '"') {
          inString = false;
        }
        continue;
      }

      if (char == '"') {
        inString = true;
      } else if (char == '{') {
        stack.add('}');
      } else if (char == '[') {
        stack.add(']');
      } else if (char == '}' || char == ']') {
        if (stack.isEmpty || stack.last != char) return -1;
        stack.removeLast();
        if (stack.isEmpty) return i;
      }
    }
    return -1;
  }

  static String _repairJsonStringEscapes(String input) {
    final buffer = StringBuffer();
    var inString = false;
    var i = 0;

    while (i < input.length) {
      final char = input[i];

      if (!inString) {
        buffer.write(char);
        if (char == '"') inString = true;
        i++;
        continue;
      }

      if (char == '"') {
        buffer.write(char);
        inString = false;
        i++;
        continue;
      }

      if (char == '\n') {
        buffer.write(r'\n');
        i++;
        continue;
      }
      if (char == '\t') {
        buffer.write(r'\t');
        i++;
        continue;
      }

      if (char == '\\') {
        if (i + 1 >= input.length) {
          buffer.write(r'\\');
          i++;
          continue;
        }

        final next = input[i + 1];
        if (next == '"' || next == '\\' || next == '/') {
          buffer.write(char);
          buffer.write(next);
          i += 2;
          continue;
        }

        if (next == 'u' && _hasValidUnicodeEscape(input, i + 2)) {
          buffer.write(input.substring(i, i + 6));
          i += 6;
          continue;
        }

        buffer.write(r'\\');
        i++;
        continue;
      }

      buffer.write(char);
      i++;
    }

    return buffer.toString();
  }

  static bool _hasValidUnicodeEscape(String input, int start) {
    if (start + 4 > input.length) return false;
    for (var i = start; i < start + 4; i++) {
      final code = input.codeUnitAt(i);
      final isHex = (code >= 48 && code <= 57) ||
          (code >= 65 && code <= 70) ||
          (code >= 97 && code <= 102);
      if (!isHex) return false;
    }
    return true;
  }

  static dynamic _decodeJsonWithTailRepair(String text) {
    try {
      return jsonDecode(text);
    } catch (error) {
      final lastObject = text.lastIndexOf('}');
      final lastArray = text.lastIndexOf(']');
      final lastValid = lastObject > lastArray ? lastObject : lastArray;
      if (lastValid == -1) rethrow;
      try {
        return jsonDecode(text.substring(0, lastValid + 1));
      } catch (repairError) {
        throw Exception(
          'JSON parse failed: $error; tail repair failed: $repairError',
        );
      }
    }
  }

  static List<dynamic> _extractQuestionList(dynamic decoded) {
    if (decoded is List) return decoded;
    if (decoded is Map<String, dynamic>) {
      final questions = decoded['questions'];
      if (questions is List) return questions;
      final anchors = decoded['anchors'];
      if (anchors is List) return anchors;
      return [decoded];
    }
    return const <dynamic>[];
  }

  static void _ensureFallbackContent(Map<String, dynamic> q) {
    final content = q['content']?.toString().trim() ?? '';
    if (content.isNotEmpty) return;

    final answer = q['standard_answer']?.toString().trim();
    final explanation = q['explanation']?.toString().trim();
    if (answer != null && answer.isNotEmpty) {
      q['content'] = '[Answer extracted]\n$answer';
    } else if (explanation != null && explanation.isNotEmpty) {
      q['content'] = '[Explanation extracted]\n$explanation';
    } else {
      q['content'] = 'No question content';
    }
  }

  static void _normalizeQuestionFields(Map<String, dynamic> q) {
    final content = q['content'];
    if (content != null) {
      q['content'] = cleanLatexBeforeDB(content.toString());
    }

    final standardAnswer = q['standard_answer'];
    if (standardAnswer != null) {
      q['standard_answer'] = cleanLatexBeforeDB(standardAnswer.toString());
    }

    final answer = q['answer'];
    if (answer != null) {
      q['answer'] = cleanLatexBeforeDB(answer.toString());
    }

    final explanation = q['explanation'];
    if (explanation != null) {
      q['explanation'] = cleanLatexBeforeDB(explanation.toString());
    }

    final rawExplanation = q['raw_explanation'];
    if (rawExplanation != null) {
      q['raw_explanation'] = cleanLatexBeforeDB(rawExplanation.toString());
    }

    final options = q['options'];
    if (options is List) {
      q['options'] = options
          .map((option) => cleanLatexBeforeDB(option.toString()))
          .toList(growable: false);
    }
  }

  static int _extractOptionsFromContentIfNeeded(
    Map<String, dynamic> q,
    int currentType,
  ) {
    final content = q['content']?.toString() ?? '';
    final optionMatch = RegExp(
      r'(?:^|\s)(?:\(?A\)?|A)[\.、．]\s*(.*?)'
      r'(?:\s)(?:\(?B\)?|B)[\.、．]\s*(.*?)'
      r'(?:\s)(?:\(?C\)?|C)[\.、．]\s*(.*?)'
      r'(?:\s)(?:\(?D\)?|D)[\.、．]\s*(.*)$',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(content);

    if (optionMatch == null) return currentType;

    final existingOptions = q['options'];
    final hasExistingOptions = existingOptions is List &&
        existingOptions.any((option) => option.toString().trim().isNotEmpty);
    if (hasExistingOptions) return currentType;

    q['content'] = content.substring(0, optionMatch.start).trim();
    q['options'] = [
      'A. ${cleanLatexBeforeDB(optionMatch.group(1)!.trim())}',
      'B. ${cleanLatexBeforeDB(optionMatch.group(2)!.trim())}',
      'C. ${cleanLatexBeforeDB(optionMatch.group(3)!.trim())}',
      'D. ${cleanLatexBeforeDB(optionMatch.group(4)!.trim())}',
    ];

    if (currentType == 3) return 0;
    return currentType;
  }

  static void _normalizeQuestionType(Map<String, dynamic> q, int currentType) {
    if (currentType == 2 || currentType == 3) {
      q['type'] = currentType;
      q['options'] = const <String>[];
      return;
    }

    final options = q['options'];
    final hasOptions = options is List &&
        options.any((option) => option.toString().trim().isNotEmpty);
    if (hasOptions) {
      q['type'] = currentType == 1 ? 1 : 0;
    } else {
      q['type'] = 3;
      q['options'] = const <String>[];
    }
  }

  static int? _readInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static String _decodeLiteralControls(String text) {
    return text
        .replaceAllMapped(RegExp(r'\\n(?![A-Za-z])'), (_) => '\n')
        .replaceAllMapped(RegExp(r'\\t(?![A-Za-z])'), (_) => '\t');
  }
}
