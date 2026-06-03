import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../../utils/content_normalizer.dart';
import '../../utils/content_tokenizer.dart';

typedef StructuredImageBuilder = Widget Function(
  BuildContext context,
  Uri uri,
  String? alt,
);

class StructuredContentRenderer extends StatelessWidget {
  final String text;
  final Color? textColor;
  final double fontSize;
  final FontWeight fontWeight;
  final StructuredImageBuilder? imageBuilder;

  const StructuredContentRenderer({
    super.key,
    required this.text,
    this.textColor,
    this.fontSize = 16.0,
    this.fontWeight = FontWeight.normal,
    this.imageBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        textColor ?? theme.textTheme.bodyLarge?.color ?? Colors.black87;
    final style = TextStyle(
      fontSize: fontSize,
      color: color,
      fontWeight: fontWeight,
      height: 1.65,
    );
    final normalized = ContentNormalizer.normalizeForRender(text);
    final tokens = ContentTokenizer.tokenize(normalized);
    if (tokens.isEmpty) return const SizedBox.shrink();

    final widgets = <Widget>[];
    final inlineTokens = <ContentToken>[];

    void flushInline() {
      if (inlineTokens.isEmpty) return;
      widgets.add(_InlineTokenParagraph(
        tokens: List<ContentToken>.from(inlineTokens),
        style: style,
        color: color,
        fontSize: fontSize,
      ));
      inlineTokens.clear();
    }

    for (final token in tokens) {
      if (token is BlockMathToken) {
        flushInline();
        widgets.add(_BlockMathView(
          tex: token.tex,
          style: style,
          color: color,
          fontSize: fontSize,
        ));
      } else if (token is ImageToken) {
        flushInline();
        widgets.add(_buildImage(context, token));
      } else if (token is ParseErrorToken) {
        flushInline();
        widgets.add(_ParseErrorView(token: token, style: style));
      } else if (token is TextToken && token.text.contains('\n')) {
        _appendSplitTextToken(token, inlineTokens, flushInline, widgets);
      } else {
        inlineTokens.add(token);
      }
    }
    flushInline();

    if (widgets.length == 1) return widgets.single;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < widgets.length; i++) ...[
          widgets[i],
          if (i != widgets.length - 1) SizedBox(height: fontSize * 0.35),
        ],
      ],
    );
  }

  Widget _buildImage(BuildContext context, ImageToken token) {
    final builder = imageBuilder;
    if (builder != null) {
      return builder(context, token.uri, token.alt);
    }
    return Text(token.raw);
  }

  void _appendSplitTextToken(
    TextToken token,
    List<ContentToken> inlineTokens,
    VoidCallback flushInline,
    List<Widget> widgets,
  ) {
    final parts = token.text.split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isNotEmpty) {
        inlineTokens.add(TextToken(parts[i]));
      }
      if (i != parts.length - 1) {
        flushInline();
        if (parts[i].isEmpty) {
          widgets.add(SizedBox(height: fontSize * 0.35));
        }
      }
    }
  }
}

class BlankTokenWidget extends StatelessWidget {
  final int length;
  final Color color;
  final double fontSize;

  const BlankTokenWidget({
    super.key,
    required this.length,
    required this.color,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    final width =
        (fontSize * (2.8 + (length - 3) * 0.35)).clamp(44.0, 120.0).toDouble();
    return SizedBox(
      width: width,
      height: fontSize * 1.15,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: color, width: 1.4),
          ),
        ),
      ),
    );
  }
}

class _InlineTokenParagraph extends StatelessWidget {
  final List<ContentToken> tokens;
  final TextStyle style;
  final Color color;
  final double fontSize;

  const _InlineTokenParagraph({
    required this.tokens,
    required this.style,
    required this.color,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    for (final token in tokens) {
      if (token is TextToken) {
        spans.addAll(_MarkdownLiteSpans.parse(token.text, style));
      } else if (token is InlineMathToken) {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _InlineMathView(
            tex: token.tex,
            style: style,
            color: color,
            fontSize: fontSize,
          ),
        ));
      } else if (token is BlankToken) {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: BlankTokenWidget(
            length: token.length,
            color: color,
            fontSize: fontSize,
          ),
        ));
      } else if (token is ParseErrorToken) {
        spans.add(TextSpan(
          text: token.raw,
          style: style.copyWith(
            color: Colors.deepOrange,
            backgroundColor: Colors.orange.withValues(alpha: 0.08),
          ),
        ));
      }
    }

    return RichText(
      textScaler: MediaQuery.textScalerOf(context),
      text: TextSpan(style: style, children: spans),
    );
  }
}

class _InlineMathView extends StatelessWidget {
  final String tex;
  final TextStyle style;
  final Color color;
  final double fontSize;

  const _InlineMathView({
    required this.tex,
    required this.style,
    required this.color,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.sizeOf(context).width * 0.82;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: _MathTexView(
          tex: tex,
          style: style,
          color: color,
          fontSize: fontSize,
          inline: true,
        ),
      ),
    );
  }
}

class _BlockMathView extends StatelessWidget {
  final String tex;
  final TextStyle style;
  final Color color;
  final double fontSize;

  const _BlockMathView({
    required this.tex,
    required this.style,
    required this.color,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
        },
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _MathTexView(
            tex: tex,
            style: style,
            color: color,
            fontSize: fontSize,
            inline: false,
          ),
        ),
      ),
    );
  }
}

class _MathTexView extends StatelessWidget {
  final String tex;
  final TextStyle style;
  final Color color;
  final double fontSize;
  final bool inline;

  const _MathTexView({
    required this.tex,
    required this.style,
    required this.color,
    required this.fontSize,
    required this.inline,
  });

  @override
  Widget build(BuildContext context) {
    final safeTex = _MathTexSanitizer.sanitize(tex);
    return Math.tex(
      safeTex,
      textStyle: style.copyWith(color: color, fontSize: fontSize),
      mathStyle: inline ? MathStyle.text : MathStyle.display,
      textScaleFactor: 1.0,
      settings: const TexParserSettings(strict: Strict.ignore),
      onErrorFallback: (err) {
        if (kDebugMode) {
          debugPrint(
            'Structured LaTeX ParseException: $err\nFormula: $safeTex',
          );
        }
        return _LatexErrorChip(
          tex: tex,
          style: style,
          inline: inline,
        );
      },
    );
  }
}

class _LatexErrorChip extends StatelessWidget {
  final String tex;
  final TextStyle style;
  final bool inline;

  const _LatexErrorChip({
    required this.tex,
    required this.style,
    required this.inline,
  });

  @override
  Widget build(BuildContext context) {
    final child = Text(
      tex,
      style: style.copyWith(
        fontFamily: 'monospace',
        fontSize: (style.fontSize ?? 14) * 0.86,
        color: Colors.deepOrange.shade900,
      ),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      margin: EdgeInsets.symmetric(vertical: inline ? 0 : 4),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.08),
        border: Border.all(color: Colors.orange.shade300),
        borderRadius: BorderRadius.circular(4),
      ),
      child: child,
    );
  }
}

class _ParseErrorView extends StatelessWidget {
  final ParseErrorToken token;
  final TextStyle style;

  const _ParseErrorView({required this.token, required this.style});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.08),
        border: Border.all(color: Colors.orange.shade300),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '${token.raw}\n${token.reason}',
        style: style.copyWith(
          fontFamily: 'monospace',
          fontSize: (style.fontSize ?? 14) * 0.86,
          color: Colors.deepOrange.shade900,
        ),
      ),
    );
  }
}

class _MathTexSanitizer {
  const _MathTexSanitizer._();

  static String sanitize(String tex) {
    var result = tex.trim();
    result = _replaceUnsupportedCommands(result);
    result = _normalizeUnicodeMathSymbols(result);
    return result;
  }

  static String _replaceUnsupportedCommands(String tex) {
    return tex.replaceAllMapped(
      RegExp(r'\\xlongequal(?:\[[^\]]*\])?\{((?:[^{}]|\{[^{}]*\})*)\}'),
      (match) => r'\overset{' + match.group(1)! + r'}{=}',
    );
  }

  static String _normalizeUnicodeMathSymbols(String tex) {
    var result = tex;
    const replacements = {
      '\u2212': '-',
      '\u2264': r'\leq ',
      '\u2265': r'\geq ',
      '\u2260': r'\neq ',
      '\u2248': r'\approx ',
      '\u221e': r'\infty ',
      '\u2202': r'\partial ',
      '\u222f': r'\iint ',
      '\u222c': r'\iint ',
      '\u222d': r'\iiint ',
      '\u222e': r'\oint ',
      '\u222b': r'\int ',
      '\u03a3': r'\Sigma ',
      '\u03a9': r'\Omega ',
      '\u03c0': r'\pi ',
      '\u03b8': r'\theta ',
      '\u03bc': r'\mu ',
      '\u03b1': r'\alpha ',
      '\u03b2': r'\beta ',
      '\u03b3': r'\gamma ',
      '\u222a': r'\cup ',
      '\u2229': r'\cap ',
    };
    for (final entry in replacements.entries) {
      result = result.replaceAll(entry.key, entry.value);
    }
    result = result.replaceAllMapped(
      RegExp(r'\\(iint|iiint|oint|int)_\\Sigma_([A-Za-z0-9]+)'),
      (match) => '\\${match.group(1)!}_{\\Sigma_${match.group(2)!}}',
    );
    result = result.replaceAllMapped(
      RegExp(r'\\(Sigma|Omega|pi|theta|mu|alpha|beta|gamma|cup|cap) +(?=_)'),
      (match) => '\\${match.group(1)!}',
    );
    result = result.replaceAllMapped(
      RegExp(
          r'\\(leq|geq|neq|approx|infty|partial|iint|iiint|oint|int) +(?=_)'),
      (match) => '\\${match.group(1)!}',
    );
    result = result.replaceAllMapped(
      RegExp(r'\\(iint|iiint|oint|int)_\\Sigma_([A-Za-z0-9]+)'),
      (match) => '\\${match.group(1)!}_{\\Sigma_${match.group(2)!}}',
    );
    return result;
  }
}

class _MarkdownLiteSpans {
  const _MarkdownLiteSpans._();

  static List<InlineSpan> parse(String text, TextStyle baseStyle) {
    final spans = <InlineSpan>[];
    var i = 0;
    while (i < text.length) {
      if (_startsWith(text, i, '**')) {
        final end = text.indexOf('**', i + 2);
        if (end != -1) {
          spans.add(TextSpan(
            text: text.substring(i + 2, end),
            style: baseStyle.copyWith(fontWeight: FontWeight.bold),
          ));
          i = end + 2;
          continue;
        }
      }

      if (text[i] == '`') {
        final end = text.indexOf('`', i + 1);
        if (end != -1) {
          spans.add(TextSpan(
            text: text.substring(i + 1, end),
            style: baseStyle.copyWith(
              fontFamily: 'monospace',
              backgroundColor: Colors.black.withValues(alpha: 0.05),
            ),
          ));
          i = end + 1;
          continue;
        }
      }

      if (text[i] == '*' &&
          !_startsWith(text, i, '**') &&
          (i == 0 || text[i - 1] != '*')) {
        final end = _findSingleAsterisk(text, i + 1);
        if (end != -1) {
          spans.add(TextSpan(
            text: text.substring(i + 1, end),
            style: baseStyle.copyWith(fontStyle: FontStyle.italic),
          ));
          i = end + 1;
          continue;
        }
      }

      final next = _nextMarkupStart(text, i + 1);
      spans.add(TextSpan(text: text.substring(i, next), style: baseStyle));
      i = next;
    }
    return spans;
  }

  static int _findSingleAsterisk(String text, int start) {
    var i = start;
    while (i < text.length) {
      if (text[i] == '*' &&
          !_startsWith(text, i, '**') &&
          (i == 0 || text[i - 1] != '*')) {
        return i;
      }
      i++;
    }
    return -1;
  }

  static int _nextMarkupStart(String text, int start) {
    var i = start;
    while (i < text.length) {
      if (_startsWith(text, i, '**') || text[i] == '`' || text[i] == '*') {
        return i;
      }
      i++;
    }
    return text.length;
  }

  static bool _startsWith(String input, int index, String needle) {
    if (index < 0 || index + needle.length > input.length) return false;
    for (var i = 0; i < needle.length; i++) {
      if (input.codeUnitAt(index + i) != needle.codeUnitAt(i)) {
        return false;
      }
    }
    return true;
  }
}
