import 'dart:convert';

import 'content_normalizer.dart';
import '../services/import_pipeline/ai_question_normalizer.dart';

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

    // Call Normalizer to sanitize structures, options parsing, type mappings, drop invalid items
    final normalizedResult = AiQuestionNormalizer.normalizeAll(questions);

    // Now perform LaTeX storage normalization on the normalized items
    final finalQuestions = <Map<String, dynamic>>[];
    for (final q in normalizedResult.questions) {
      if (q['content'] != null) {
        q['content'] = cleanLatexBeforeDB(q['content'].toString());
      }
      if (q['standard_answer'] != null) {
        q['standard_answer'] =
            cleanLatexBeforeDB(q['standard_answer'].toString());
      }
      if (q['explanation'] != null) {
        q['explanation'] = cleanLatexBeforeDB(q['explanation'].toString());
      }
      if (q['raw_explanation'] != null) {
        q['raw_explanation'] =
            cleanLatexBeforeDB(q['raw_explanation'].toString());
      }
      if (q['options'] is List) {
        final opts = q['options'] as List;
        q['options'] =
            opts.map((o) => cleanLatexBeforeDB(o.toString())).toList();
      }
      finalQuestions.add(q);
    }

    return finalQuestions;
  }

  static String cleanLatexBeforeDB(String text) {
    if (text.isEmpty) return text;
    final decoded = _decodeLiteralControls(text);
    return ContentNormalizer.normalizeForStorage(
      _normalizeJsonEscapedKnownLatexCommands(decoded),
    );
  }

  static String formatLatex(String text) {
    if (text.isEmpty) return text;
    final decoded = _decodeLiteralControls(text);
    return ContentNormalizer.normalizeForRender(
      _normalizeJsonEscapedKnownLatexCommands(decoded),
    );
  }

  static String normalizeDelimiters(String text) {
    if (text.isEmpty) return text;
    return ContentNormalizer.normalizeForStorage(_decodeLiteralControls(text));
  }

  static List<String> findBareLatexCommands(String text) {
    return ContentNormalizer.findBareLatexCommands(text);
  }

  static String _normalizeJsonEscapedKnownLatexCommands(String text) {
    return text.replaceAllMapped(
      RegExp(
        r'\\\\(?=(?:begin|end|frac|sqrt|sum|int|lim|left|right|mathrm|mathbf|'
        r'mathbb|mathcal|text|hat|bar|vec|dot|ddot|overline|underline|'
        r'xlongequal|overset|underset|rightarrow|leftarrow|geq|leq|neq|'
        r'approx|infty|partial|sin|cos|tan|ln|log)\b)',
      ),
      (_) => '\\',
    );
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

  static String _decodeLiteralControls(String text) {
    return text
        .replaceAllMapped(RegExp(r'\\n(?![A-Za-z])'), (_) => '\n')
        .replaceAllMapped(RegExp(r'\\t(?![A-Za-z])'), (_) => '\t');
  }
}
