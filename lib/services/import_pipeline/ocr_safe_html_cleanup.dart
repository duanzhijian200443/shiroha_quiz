class OcrSafeHtmlCleanupResult {
  const OcrSafeHtmlCleanupResult({
    required this.text,
    required this.diagnostics,
  });

  final String text;
  final List<String> diagnostics;
}

const _safeWrapperTags = {'div', 'span', 'p', 'br'};
const _blockTags = {'div', 'p'};
const _dangerousContainerTags = {
  'script',
  'style',
  'iframe',
  'object',
  'embed',
};

OcrSafeHtmlCleanupResult stripSafeHtmlWrappers(String input) {
  if (input.isEmpty) {
    return const OcrSafeHtmlCleanupResult(text: '', diagnostics: []);
  }

  final decodedInput = _decodeSafeEntities(input);
  final output = _MarkupOutput();
  final diagnostics = <String>{};
  var changedMarkup = false;
  var index = 0;

  while (index < decodedInput.length) {
    if (decodedInput.codeUnitAt(index) != 60) {
      output.write(decodedInput[index]);
      index++;
      continue;
    }

    final tag = _readHtmlTag(decodedInput, index);
    if (tag == null) {
      output.write(decodedInput[index]);
      index++;
      continue;
    }

    if (_dangerousContainerTags.contains(tag.name)) {
      changedMarkup = true;
      diagnostics.add('unsafe_html_content_removed');
      index = tag.isClosing
          ? tag.end
          : _findDangerousContainerEnd(decodedInput, tag);
      continue;
    }

    if (!_safeWrapperTags.contains(tag.name)) {
      output.write(tag.raw);
      diagnostics.add('unsupported_html_tag_preserved');
      index = tag.end;
      continue;
    }

    changedMarkup = true;
    if (tag.name == 'br') {
      output.writeLineBreak();
    } else if (_blockTags.contains(tag.name)) {
      output.writeLineBreak();
    }
    index = tag.end;
  }

  var text = output.toString();
  if (changedMarkup) {
    text = text
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n[ \t]+'), '\n')
        .trim();
  }
  return OcrSafeHtmlCleanupResult(
    text: text,
    diagnostics: diagnostics.toList(),
  );
}

bool containsRawHtmlTag(String input) {
  var index = 0;
  while (index < input.length) {
    final tagStart = input.indexOf('<', index);
    if (tagStart < 0) return false;
    final tag = _readHtmlTag(input, tagStart);
    if (tag != null) return true;
    index = tagStart + 1;
  }
  return false;
}

String _decodeSafeEntities(String input) {
  return input.replaceAllMapped(
    RegExp(
      r'&(?:lt|gt|amp|quot|apos|nbsp|#39);',
      caseSensitive: false,
    ),
    (match) {
      switch (match.group(0)!.toLowerCase()) {
        case '&lt;':
          return '<';
        case '&gt;':
          return '>';
        case '&amp;':
          return '&';
        case '&quot;':
          return '"';
        case '&apos;':
        case '&#39;':
          return "'";
        case '&nbsp;':
          return ' ';
      }
      return match.group(0)!;
    },
  );
}

_HtmlTag? _readHtmlTag(String input, int start) {
  var index = start + 1;
  if (index >= input.length) return null;

  var isClosing = false;
  if (input[index] == '/') {
    isClosing = true;
    index++;
  }
  if (index >= input.length || !_isAsciiLetter(input.codeUnitAt(index))) {
    return null;
  }

  final nameStart = index;
  while (index < input.length && _isTagNameCodeUnit(input.codeUnitAt(index))) {
    index++;
  }
  final name = input.substring(nameStart, index).toLowerCase();
  if (index >= input.length || !_isTagNameBoundary(input.codeUnitAt(index))) {
    return null;
  }

  String? quote;
  while (index < input.length) {
    final char = input[index];
    if (quote != null) {
      if (char == quote) quote = null;
    } else if (char == '"' || char == "'") {
      quote = char;
    } else if (char == '>') {
      final end = index + 1;
      return _HtmlTag(
        name: name,
        isClosing: isClosing,
        start: start,
        end: end,
        raw: input.substring(start, end),
      );
    }
    index++;
  }
  return null;
}

int _findDangerousContainerEnd(String input, _HtmlTag openingTag) {
  final lowerInput = input.toLowerCase();
  final closingPrefix = '</${openingTag.name}';
  var searchFrom = openingTag.end;

  while (searchFrom < input.length) {
    final closingStart = lowerInput.indexOf(closingPrefix, searchFrom);
    if (closingStart < 0) return input.length;
    final closingTag = _readHtmlTag(input, closingStart);
    if (closingTag != null &&
        closingTag.isClosing &&
        closingTag.name == openingTag.name) {
      return closingTag.end;
    }
    searchFrom = closingStart + closingPrefix.length;
  }
  return input.length;
}

bool _isAsciiLetter(int codeUnit) =>
    (codeUnit >= 65 && codeUnit <= 90) || (codeUnit >= 97 && codeUnit <= 122);

bool _isTagNameCodeUnit(int codeUnit) =>
    _isAsciiLetter(codeUnit) ||
    (codeUnit >= 48 && codeUnit <= 57) ||
    codeUnit == 45 ||
    codeUnit == 58;

bool _isTagNameBoundary(int codeUnit) =>
    codeUnit == 32 ||
    codeUnit == 9 ||
    codeUnit == 10 ||
    codeUnit == 13 ||
    codeUnit == 47 ||
    codeUnit == 62;

class _HtmlTag {
  const _HtmlTag({
    required this.name,
    required this.isClosing,
    required this.start,
    required this.end,
    required this.raw,
  });

  final String name;
  final bool isClosing;
  final int start;
  final int end;
  final String raw;
}

class _MarkupOutput {
  final StringBuffer _buffer = StringBuffer();
  var _hasContent = false;
  var _endsWithNewline = false;

  void write(String value) {
    if (value.isEmpty) return;
    _buffer.write(value);
    _hasContent = true;
    _endsWithNewline = value.endsWith('\n');
  }

  void writeLineBreak() {
    if (_hasContent && !_endsWithNewline) {
      write('\n');
    }
  }

  @override
  String toString() => _buffer.toString();
}

/// Checks whether [raw] and [explanation] are semantically equivalent after
/// stripping benign HTML wrappers (div, span, p, br).
///
/// Returns `true` if and only if:
/// 1. Stripping benign HTML wrappers from [raw] yields the same text as
///    stripping benign HTML wrappers from [explanation];
/// 2. Neither [raw] nor [explanation] contained dangerous HTML tags
///    (e.g., script, style, iframe, object, embed) that were removed;
/// 3. Neither [raw] nor [explanation] contained unsupported HTML tags
///    (e.g., table, svg, custom tags) that were preserved as markup.
bool isSafeHtmlNormalizedExplanationEqual(String raw, String explanation) {
  if (raw == explanation) return true;
  final cleanedRaw = stripSafeHtmlWrappers(raw);
  if (cleanedRaw.diagnostics.isNotEmpty) return false;
  final cleanedExpl = stripSafeHtmlWrappers(explanation);
  if (cleanedExpl.diagnostics.isNotEmpty) return false;
  return cleanedRaw.text == cleanedExpl.text;
}
