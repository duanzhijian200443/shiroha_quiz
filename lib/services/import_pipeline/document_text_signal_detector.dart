import 'document_part.dart';

class DocumentTextSignalDetector {
  /// Detects the TextRole of a given text segment, considering an optional markdown tag.
  static TextRole detectRole(String text, {String? markdownTag}) {
    if (markdownTag != null && markdownTag.startsWith('h')) {
      return TextRole.heading;
    }
    final trimmed = text.trim();
    if (hasAnswerMarker(trimmed)) {
      return TextRole.answerBlock;
    }
    return TextRole.paragraph;
  }

  /// Checks if the text starts with a recognized question marker.
  /// Supports: 第1题, 第 1 题, 1., 1、, 1), （1）, (1), and 一、
  static bool hasQuestionMarker(String text) {
    final trimmed = text.trim();
    final qMarkerRegex = RegExp(
      r'^((第?\s*\d+\s*[题\.\、\)])|(\(\d+\))|（\d+）|(?:[一二三四五六七八九十]+[、]))',
    );
    return qMarkerRegex.hasMatch(trimmed);
  }

  /// Checks if the text starts with a recognized answer/explanation marker.
  /// Supports: 答案, 答案：, 参考答案, 参考答案：, 解析, 解析：, 详解, 解：
  /// Ensures that these keywords must appear at the beginning of the text to be counted.
  /// Note: The single-character '解' must be followed by a separator (colon/space) or end of string.
  static bool hasAnswerMarker(String text) {
    final trimmed = text.trim();
    final ansMarkerRegex = RegExp(
      r'^(答案|参考答案|解析|详解)[:：\s]*|^(解)([:：\s]+|$)',
    );
    return ansMarkerRegex.hasMatch(trimmed);
  }

  /// Checks if the text contains LaTeX-like formulas or formula signals.
  /// Supports: \frac, \sqrt, \begin, \sum, \int, λ, 矩阵, 方程, x^2
  static bool hasFormulaLikeSignal(String text) {
    final formulaRegex = RegExp(r'(\\(frac|sqrt|begin|sum|int)|x\^2|λ|矩阵|方程)');
    return formulaRegex.hasMatch(text);
  }

  /// Checks if a text block looks like a tail answer block (e.g. centralized answer table/list at the end).
  static bool looksLikeTailAnswerBlock(String text) {
    final trimmed = text.trim();
    return trimmed.startsWith(RegExp(r'^(答案|参考答案|参考答案表)[:：\s]*'));
  }
}
