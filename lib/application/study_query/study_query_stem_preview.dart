/// Safe stem preview projection and grapheme-cluster truncation.
///
/// Preview rules (frozen): consecutive whitespace collapses to one U+0020
/// space, the result is trimmed, and the maximum is 160 Unicode grapheme
/// clusters (over the limit: the first 159 clusters plus `...`). Preview is
/// never derived from a `RawFallbackNode` payload.
library;

import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/content/rich_content_text_projection.dart';
import 'study_query_dtos.dart';

final class StemPreviewNormalizer {
  const StemPreviewNormalizer();

  static const int maxClusters = 160;
  static const String ellipsis = '\u2026';
  static final RegExp _collapsibleWhitespace = RegExp(r'\s+', unicode: true);

  /// Collapses whitespace, trims, and truncates plain text.
  String normalizeText(String value) {
    return _truncate(value.replaceAll(_collapsibleWhitespace, ' ').trim());
  }

  /// Projects a typed stem to preview text. Text and math nodes contribute
  /// their safe text/latex; `RawFallbackNode` contributes nothing.
  String fromRichContent(RichContent content) {
    final buffer = StringBuffer();
    for (final node in content.nodes) {
      switch (node) {
        case TextNode(:final text):
          buffer.write(text);
        case InlineMathNode(:final latex):
          buffer.write(latex);
        case BlockMathNode(:final latex):
          buffer.write(latex);
        case ImageNode() || TableNode():
          buffer.write(
            const RichContentTextProjection().project(
              RichContent(nodes: <ContentNode>[node]),
            ),
          );
        case RawFallbackNode():
          break;
      }
    }
    return normalizeText(buffer.toString());
  }

  /// Projects a typed content value to safe detail nodes. `RawFallbackNode`
  /// projects only to [StudyUnsupportedNode]; its payload never leaves the
  /// application layer.
  static List<StudyContentNode> projectNodes(RichContent content) {
    return <StudyContentNode>[
      for (final node in content.nodes)
        switch (node) {
          TextNode(:final text) => StudyTextNode(text),
          InlineMathNode(:final latex) => StudyInlineMathNode(latex),
          BlockMathNode(:final latex) => StudyBlockMathNode(latex),
          ImageNode() || TableNode() => const StudyUnsupportedNode(),
          RawFallbackNode() => const StudyUnsupportedNode(),
        },
    ];
  }

  String _truncate(String value) {
    final clusters = splitGraphemeClusters(value);
    if (clusters.length <= maxClusters) return value;
    return clusters.take(maxClusters - 1).join() + ellipsis;
  }
}

/// Splits [value] into Unicode grapheme clusters using a bounded UAX #29
/// subset: CRLF, combining marks, variation selectors, ZWJ sequences,
/// skin-tone modifiers, regional-indicator flags, and Hangul jamo. This is a
/// deterministic approximation, not a full Unicode segmentation engine.
List<String> splitGraphemeClusters(String value) {
  final runes = value.runes.toList(growable: false);
  if (runes.isEmpty) return const <String>[];
  final clusters = <String>[];
  var start = 0;
  for (var index = 1; index <= runes.length; index++) {
    if (index == runes.length || _startsNewCluster(runes, index)) {
      clusters.add(String.fromCharCodes(runes.sublist(start, index)));
      start = index;
    }
  }
  return clusters;
}

bool _startsNewCluster(List<int> runes, int index) {
  final current = runes[index];
  final previous = runes[index - 1];
  if (previous == 0x0D && current == 0x0A) return false;
  if (_isCombiningMark(current) || _isVariationSelector(current)) return false;
  if (current == 0x200D) return false;
  if (previous == 0x200D) return false;
  if (current >= 0x1F3FB && current <= 0x1F3FF) return false;
  if (_isRegionalIndicator(previous) && _isRegionalIndicator(current)) {
    return false;
  }
  if (_isHangulL(previous) && _isHangulV(current)) return false;
  if ((_isHangulL(previous) || _isHangulV(previous)) && _isHangulT(current)) {
    return false;
  }
  if (_isHangulV(previous) && _isHangulV(current)) return false;
  if (_isHangulT(previous) && _isHangulT(current)) return false;
  return true;
}

bool _isVariationSelector(int codePoint) {
  return (codePoint >= 0xFE00 && codePoint <= 0xFE0F) ||
      (codePoint >= 0xE0100 && codePoint <= 0xE01EF);
}

bool _isRegionalIndicator(int codePoint) {
  return codePoint >= 0x1F1E6 && codePoint <= 0x1F1FF;
}

bool _isHangulL(int codePoint) {
  return (codePoint >= 0x1100 && codePoint <= 0x115F) ||
      (codePoint >= 0xA960 && codePoint <= 0xA97C);
}

bool _isHangulV(int codePoint) {
  return (codePoint >= 0x1160 && codePoint <= 0x11A7) ||
      (codePoint >= 0xD7B0 && codePoint <= 0xD7C6);
}

bool _isHangulT(int codePoint) {
  return (codePoint >= 0x11A8 && codePoint <= 0x11FF) ||
      (codePoint >= 0xD7CB && codePoint <= 0xD7FB);
}

bool _isCombiningMark(int codePoint) {
  // Common combining-mark ranges (bounded UAX #29 subset).
  if (codePoint >= 0x0300 && codePoint <= 0x036F) return true;
  if (codePoint >= 0x0483 && codePoint <= 0x0489) return true;
  if (codePoint >= 0x0591 && codePoint <= 0x05BD) return true;
  if (codePoint == 0x05BF) return true;
  if (codePoint >= 0x05C1 && codePoint <= 0x05C2) return true;
  if (codePoint >= 0x05C4 && codePoint <= 0x05C5) return true;
  if (codePoint == 0x05C7) return true;
  if (codePoint >= 0x0610 && codePoint <= 0x061A) return true;
  if (codePoint >= 0x064B && codePoint <= 0x065F) return true;
  if (codePoint == 0x0670) return true;
  if (codePoint >= 0x06D6 && codePoint <= 0x06DC) return true;
  if (codePoint >= 0x06DF && codePoint <= 0x06E4) return true;
  if (codePoint >= 0x06E7 && codePoint <= 0x06E8) return true;
  if (codePoint >= 0x06EA && codePoint <= 0x06ED) return true;
  if (codePoint == 0x0711) return true;
  if (codePoint >= 0x0730 && codePoint <= 0x074A) return true;
  if (codePoint >= 0x07A6 && codePoint <= 0x07B0) return true;
  if (codePoint >= 0x07EB && codePoint <= 0x07F3) return true;
  if (codePoint >= 0x0816 && codePoint <= 0x0823) return true;
  if (codePoint >= 0x0825 && codePoint <= 0x0827) return true;
  if (codePoint >= 0x0829 && codePoint <= 0x082D) return true;
  if (codePoint >= 0x0859 && codePoint <= 0x085B) return true;
  if (codePoint >= 0x08D3 && codePoint <= 0x0902) return true;
  if (codePoint >= 0x093A && codePoint <= 0x093C) return true;
  if (codePoint >= 0x093E && codePoint <= 0x094F) return true;
  if (codePoint >= 0x0951 && codePoint <= 0x0957) return true;
  if (codePoint >= 0x0962 && codePoint <= 0x0963) return true;
  if (codePoint >= 0x0981 && codePoint <= 0x0983) return true;
  if (codePoint == 0x09BC) return true;
  if (codePoint >= 0x09BE && codePoint <= 0x09C4) return true;
  if (codePoint >= 0x09C7 && codePoint <= 0x09C8) return true;
  if (codePoint >= 0x09CB && codePoint <= 0x09CC) return true;
  if (codePoint == 0x09D7) return true;
  if (codePoint >= 0x09E2 && codePoint <= 0x09E3) return true;
  if (codePoint >= 0x0A01 && codePoint <= 0x0A03) return true;
  if (codePoint == 0x0A3C) return true;
  if (codePoint >= 0x0A3E && codePoint <= 0x0A42) return true;
  if (codePoint >= 0x0A47 && codePoint <= 0x0A48) return true;
  if (codePoint >= 0x0A4B && codePoint <= 0x0A4D) return true;
  if (codePoint == 0x0A51) return true;
  if (codePoint >= 0x0A70 && codePoint <= 0x0A71) return true;
  if (codePoint == 0x0A75) return true;
  if (codePoint >= 0x0A81 && codePoint <= 0x0A83) return true;
  if (codePoint == 0x0ABC) return true;
  if (codePoint >= 0x0ABE && codePoint <= 0x0AC5) return true;
  if (codePoint >= 0x0AC7 && codePoint <= 0x0AC9) return true;
  if (codePoint >= 0x0ACB && codePoint <= 0x0ACD) return true;
  if (codePoint >= 0x0AE2 && codePoint <= 0x0AE3) return true;
  if (codePoint >= 0x0B01 && codePoint <= 0x0B03) return true;
  if (codePoint == 0x0B3C) return true;
  if (codePoint >= 0x0B3E && codePoint <= 0x0B44) return true;
  if (codePoint >= 0x0B47 && codePoint <= 0x0B48) return true;
  if (codePoint >= 0x0B4B && codePoint <= 0x0B4D) return true;
  if (codePoint >= 0x0B56 && codePoint <= 0x0B57) return true;
  if (codePoint >= 0x0B62 && codePoint <= 0x0B63) return true;
  if (codePoint == 0x0B82) return true;
  if (codePoint >= 0x0BBE && codePoint <= 0x0BC2) return true;
  if (codePoint >= 0x0BC6 && codePoint <= 0x0BC8) return true;
  if (codePoint >= 0x0BCA && codePoint <= 0x0BCD) return true;
  if (codePoint == 0x0BD7) return true;
  if (codePoint >= 0x0C00 && codePoint <= 0x0C04) return true;
  if (codePoint >= 0x0C3E && codePoint <= 0x0C44) return true;
  if (codePoint >= 0x0C46 && codePoint <= 0x0C48) return true;
  if (codePoint >= 0x0C4A && codePoint <= 0x0C4D) return true;
  if (codePoint >= 0x0C55 && codePoint <= 0x0C56) return true;
  if (codePoint >= 0x0C62 && codePoint <= 0x0C63) return true;
  if (codePoint >= 0x0C81 && codePoint <= 0x0C83) return true;
  if (codePoint == 0x0CBC) return true;
  if (codePoint >= 0x0CBE && codePoint <= 0x0CC4) return true;
  if (codePoint >= 0x0CC6 && codePoint <= 0x0CC8) return true;
  if (codePoint >= 0x0CCA && codePoint <= 0x0CCD) return true;
  if (codePoint >= 0x0CD5 && codePoint <= 0x0CD6) return true;
  if (codePoint >= 0x0CE2 && codePoint <= 0x0CE3) return true;
  if (codePoint >= 0x0D00 && codePoint <= 0x0D03) return true;
  if (codePoint >= 0x0D3B && codePoint <= 0x0D3C) return true;
  if (codePoint >= 0x0D3E && codePoint <= 0x0D44) return true;
  if (codePoint >= 0x0D46 && codePoint <= 0x0D48) return true;
  if (codePoint >= 0x0D4A && codePoint <= 0x0D4D) return true;
  if (codePoint == 0x0D57) return true;
  if (codePoint >= 0x0D62 && codePoint <= 0x0D63) return true;
  if (codePoint >= 0x0D81 && codePoint <= 0x0D83) return true;
  if (codePoint == 0x0DCA) return true;
  if (codePoint >= 0x0DCF && codePoint <= 0x0DD4) return true;
  if (codePoint == 0x0DD6) return true;
  if (codePoint >= 0x0DD8 && codePoint <= 0x0DDF) return true;
  if (codePoint >= 0x0DF2 && codePoint <= 0x0DF3) return true;
  if (codePoint == 0x0E31) return true;
  if (codePoint >= 0x0E34 && codePoint <= 0x0E3A) return true;
  if (codePoint >= 0x0E47 && codePoint <= 0x0E4E) return true;
  if (codePoint == 0x0EB1) return true;
  if (codePoint >= 0x0EB4 && codePoint <= 0x0EBC) return true;
  if (codePoint >= 0x0EC8 && codePoint <= 0x0ECD) return true;
  if (codePoint >= 0x0F18 && codePoint <= 0x0F19) return true;
  if (codePoint == 0x0F35) return true;
  if (codePoint == 0x0F37) return true;
  if (codePoint == 0x0F39) return true;
  if (codePoint >= 0x0F3E && codePoint <= 0x0F3F) return true;
  if (codePoint >= 0x0F71 && codePoint <= 0x0F84) return true;
  if (codePoint >= 0x0F86 && codePoint <= 0x0F87) return true;
  if (codePoint >= 0x0F8D && codePoint <= 0x0F97) return true;
  if (codePoint >= 0x0F99 && codePoint <= 0x0FBC) return true;
  if (codePoint == 0x0FC6) return true;
  if (codePoint >= 0x102B && codePoint <= 0x103E) return true;
  if (codePoint >= 0x1056 && codePoint <= 0x1059) return true;
  if (codePoint >= 0x105E && codePoint <= 0x1060) return true;
  if (codePoint >= 0x1062 && codePoint <= 0x1064) return true;
  if (codePoint >= 0x1067 && codePoint <= 0x106D) return true;
  if (codePoint >= 0x1071 && codePoint <= 0x1074) return true;
  if (codePoint >= 0x1082 && codePoint <= 0x108D) return true;
  if (codePoint == 0x108F) return true;
  if (codePoint >= 0x109A && codePoint <= 0x109D) return true;
  if (codePoint >= 0x135D && codePoint <= 0x135F) return true;
  if (codePoint >= 0x1712 && codePoint <= 0x1714) return true;
  if (codePoint >= 0x1732 && codePoint <= 0x1734) return true;
  if (codePoint >= 0x1752 && codePoint <= 0x1753) return true;
  if (codePoint >= 0x1772 && codePoint <= 0x1773) return true;
  if (codePoint >= 0x17B4 && codePoint <= 0x17D3) return true;
  if (codePoint == 0x17DD) return true;
  if (codePoint >= 0x180B && codePoint <= 0x180D) return true;
  if (codePoint >= 0x1885 && codePoint <= 0x1886) return true;
  if (codePoint == 0x18A9) return true;
  if (codePoint >= 0x1920 && codePoint <= 0x192B) return true;
  if (codePoint >= 0x1930 && codePoint <= 0x193B) return true;
  if (codePoint >= 0x1A17 && codePoint <= 0x1A1B) return true;
  if (codePoint >= 0x1A55 && codePoint <= 0x1A5E) return true;
  if (codePoint >= 0x1A60 && codePoint <= 0x1A7C) return true;
  if (codePoint == 0x1A7F) return true;
  if (codePoint >= 0x1AB0 && codePoint <= 0x1AFF) return true;
  if (codePoint >= 0x1B00 && codePoint <= 0x1B04) return true;
  if (codePoint >= 0x1B34 && codePoint <= 0x1B44) return true;
  if (codePoint >= 0x1B6B && codePoint <= 0x1B73) return true;
  if (codePoint >= 0x1B80 && codePoint <= 0x1B82) return true;
  if (codePoint >= 0x1BA1 && codePoint <= 0x1BAD) return true;
  if (codePoint >= 0x1BE6 && codePoint <= 0x1BF3) return true;
  if (codePoint >= 0x1C24 && codePoint <= 0x1C37) return true;
  if (codePoint >= 0x1CD0 && codePoint <= 0x1CD2) return true;
  if (codePoint >= 0x1CD4 && codePoint <= 0x1CE8) return true;
  if (codePoint == 0x1CED) return true;
  if (codePoint >= 0x1CF2 && codePoint <= 0x1CF4) return true;
  if (codePoint >= 0x1CF7 && codePoint <= 0x1CF9) return true;
  if (codePoint >= 0x1DC0 && codePoint <= 0x1DFF) return true;
  if (codePoint == 0x200C) return true;
  if (codePoint >= 0x20D0 && codePoint <= 0x20FF) return true;
  if (codePoint >= 0x2CEF && codePoint <= 0x2CF1) return true;
  if (codePoint == 0x2D7F) return true;
  if (codePoint >= 0x2DE0 && codePoint <= 0x2DFF) return true;
  if (codePoint >= 0x302A && codePoint <= 0x302F) return true;
  if (codePoint >= 0x3099 && codePoint <= 0x309A) return true;
  if (codePoint >= 0xA66F && codePoint <= 0xA672) return true;
  if (codePoint >= 0xA674 && codePoint <= 0xA67D) return true;
  if (codePoint >= 0xA69E && codePoint <= 0xA69F) return true;
  if (codePoint >= 0xA6F0 && codePoint <= 0xA6F1) return true;
  if (codePoint == 0xA802) return true;
  if (codePoint == 0xA806) return true;
  if (codePoint == 0xA80B) return true;
  if (codePoint >= 0xA823 && codePoint <= 0xA827) return true;
  if (codePoint >= 0xA880 && codePoint <= 0xA881) return true;
  if (codePoint >= 0xA8B4 && codePoint <= 0xA8C5) return true;
  if (codePoint >= 0xA8E0 && codePoint <= 0xA8F1) return true;
  if (codePoint >= 0xA926 && codePoint <= 0xA92D) return true;
  if (codePoint >= 0xA947 && codePoint <= 0xA953) return true;
  if (codePoint >= 0xA980 && codePoint <= 0xA983) return true;
  if (codePoint >= 0xA9B3 && codePoint <= 0xA9C0) return true;
  if (codePoint == 0xA9E5) return true;
  if (codePoint >= 0xAA29 && codePoint <= 0xAA36) return true;
  if (codePoint == 0xAA43) return true;
  if (codePoint >= 0xAA4C && codePoint <= 0xAA4D) return true;
  if (codePoint >= 0xAA7B && codePoint <= 0xAA7D) return true;
  if (codePoint == 0xAAB0) return true;
  if (codePoint >= 0xAAB2 && codePoint <= 0xAAB4) return true;
  if (codePoint >= 0xAAB7 && codePoint <= 0xAAB8) return true;
  if (codePoint >= 0xAABE && codePoint <= 0xAABF) return true;
  if (codePoint == 0xAAC1) return true;
  if (codePoint >= 0xAAEB && codePoint <= 0xAAEF) return true;
  if (codePoint >= 0xAAF5 && codePoint <= 0xAAF6) return true;
  if (codePoint >= 0xABE3 && codePoint <= 0xABEA) return true;
  if (codePoint >= 0xABEC && codePoint <= 0xABED) return true;
  if (codePoint == 0xFB1E) return true;
  if (codePoint >= 0xFE20 && codePoint <= 0xFE2F) return true;
  if (codePoint >= 0xFF9E && codePoint <= 0xFF9F) return true;
  if (codePoint == 0x101FD) return true;
  if (codePoint == 0x102E0) return true;
  if (codePoint >= 0x10376 && codePoint <= 0x1037A) return true;
  if (codePoint >= 0x10A01 && codePoint <= 0x10A03) return true;
  if (codePoint >= 0x10A05 && codePoint <= 0x10A06) return true;
  if (codePoint >= 0x10A0C && codePoint <= 0x10A0F) return true;
  if (codePoint >= 0x10A38 && codePoint <= 0x10A3A) return true;
  if (codePoint == 0x10A3F) return true;
  if (codePoint >= 0x10AE5 && codePoint <= 0x10AE6) return true;
  if (codePoint >= 0x11000 && codePoint <= 0x11001) return true;
  if (codePoint >= 0x11038 && codePoint <= 0x11046) return true;
  if (codePoint >= 0x1107F && codePoint <= 0x11081) return true;
  if (codePoint >= 0x110B3 && codePoint <= 0x110B6) return true;
  if (codePoint >= 0x110B9 && codePoint <= 0x110BA) return true;
  if (codePoint >= 0x11100 && codePoint <= 0x11102) return true;
  if (codePoint >= 0x11127 && codePoint <= 0x11134) return true;
  if (codePoint == 0x11173) return true;
  if (codePoint >= 0x11180 && codePoint <= 0x11182) return true;
  if (codePoint >= 0x111B3 && codePoint <= 0x111C0) return true;
  if (codePoint >= 0x111C9 && codePoint <= 0x111CC) return true;
  if (codePoint >= 0x1122C && codePoint <= 0x11237) return true;
  if (codePoint == 0x1123E) return true;
  if (codePoint == 0x112DF) return true;
  if (codePoint >= 0x112E3 && codePoint <= 0x112EA) return true;
  if (codePoint >= 0x11300 && codePoint <= 0x11303) return true;
  if (codePoint >= 0x1133B && codePoint <= 0x1133C) return true;
  if (codePoint >= 0x1133E && codePoint <= 0x11344) return true;
  if (codePoint >= 0x11347 && codePoint <= 0x11348) return true;
  if (codePoint >= 0x1134B && codePoint <= 0x1134D) return true;
  if (codePoint == 0x11357) return true;
  if (codePoint >= 0x11362 && codePoint <= 0x11363) return true;
  if (codePoint >= 0x11366 && codePoint <= 0x1136C) return true;
  if (codePoint >= 0x11370 && codePoint <= 0x11374) return true;
  if (codePoint >= 0x11435 && codePoint <= 0x11446) return true;
  if (codePoint >= 0x114B0 && codePoint <= 0x114C3) return true;
  if (codePoint >= 0x114D0 && codePoint <= 0x114D4) return true;
  if (codePoint >= 0x115AF && codePoint <= 0x115B5) return true;
  if (codePoint >= 0x115B8 && codePoint <= 0x115C0) return true;
  if (codePoint >= 0x115DC && codePoint <= 0x115DD) return true;
  if (codePoint >= 0x11630 && codePoint <= 0x11640) return true;
  if (codePoint >= 0x116AB && codePoint <= 0x116B7) return true;
  return false;
}
