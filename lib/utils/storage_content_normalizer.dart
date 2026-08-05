import 'content_normalizer.dart';

/// Pure storage-normalization projection extracted from the legacy
/// AiDataSanitizer.cleanLatexBeforeDB behavior.
///
/// This layer must stay free of import-pipeline, service, Flutter, IO,
/// database, MCP, and provider dependencies.
final class StorageContentNormalizer {
  const StorageContentNormalizer._();

  /// Byte-for-byte equivalent of the legacy storage normalization performed
  /// by AiDataSanitizer.cleanLatexBeforeDB.
  static String normalizeLegacyProjection(String text) {
    if (text.isEmpty) return text;
    final decoded = _decodeLiteralControls(text);
    return ContentNormalizer.normalizeForStorage(
      _normalizeJsonEscapedKnownLatexCommands(decoded),
    );
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

  static String _decodeLiteralControls(String text) {
    return text
        .replaceAllMapped(RegExp(r'\\n(?![A-Za-z])'), (_) => '\n')
        .replaceAllMapped(RegExp(r'\\t(?![A-Za-z])'), (_) => '\t');
  }
}
