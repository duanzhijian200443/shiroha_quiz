import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../services/file_library/managed_content_asset_store.dart';
import '../../services/import_pipeline/latex_block_environment_normalizer.dart';
import '../../services/import_pipeline/latex_renderability_checker.dart';
import '../../utils/content_normalizer.dart';
import '../../utils/content_tokenizer.dart';
import '../../utils/latex_complexity_classifier.dart';

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
    final blockNormalized =
        const LatexBlockEnvironmentNormalizer().normalize(text);
    final normalized =
        ContentNormalizer.normalizeForRender(blockNormalized.text);
    final tokens = ContentTokenizer.tokenize(normalized);
    if (!blockNormalized.renderability.isRenderable &&
        !_canSafelyLocalizeStructuralFailure(tokens)) {
      if (kDebugMode) {
        debugPrint('Structured LaTeX render fallback: structurally_unsafe');
      }
      return _LatexErrorChip(
        tex: text,
        style: style,
        inline: false,
      );
    }
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
      } else if (token is InlineMathToken &&
          LatexComplexityClassifier.shouldRenderAsBlock(token.tex)) {
        flushInline();
        widgets.add(_BlockMathView(
          tex: token.tex,
          style: style,
          color: color,
          fontSize: fontSize,
        ));
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

  bool _canSafelyLocalizeStructuralFailure(List<ContentToken> tokens) {
    const checker = LatexRenderabilityChecker();
    var foundLocalizedFailure = false;

    for (final token in tokens) {
      if (token is InlineMathToken || token is BlockMathToken) {
        final tex = switch (token) {
          final InlineMathToken inline => inline.tex,
          final BlockMathToken block => block.tex,
          _ => '',
        };
        if (!checker
            .check(
              tex,
              requireMathContext: false,
              assumeMathContext: true,
            )
            .isRenderable) {
          foundLocalizedFailure = true;
        }
        continue;
      }
      if (token is ParseErrorToken) {
        foundLocalizedFailure = true;
        continue;
      }
      if (token is TextToken &&
          !checker.check(token.text, requireMathContext: false).isRenderable) {
        return false;
      }
    }

    return foundLocalizedFailure;
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

class RichContentRenderer extends StatelessWidget {
  const RichContentRenderer({
    super.key,
    required this.content,
    this.textColor,
    this.fontSize = 16.0,
    this.fontWeight = FontWeight.normal,
  });

  final RichContent content;
  final Color? textColor;
  final double fontSize;
  final FontWeight fontWeight;

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
    final nodes = content.nodes;
    if (nodes.isEmpty) return const SizedBox.shrink();

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

    for (final node in nodes) {
      switch (node) {
        case TextNode(:final text):
          _appendTypedText(text, inlineTokens, flushInline, widgets);
        case InlineMathNode(:final latex):
          inlineTokens.add(InlineMathToken(tex: latex, raw: latex));
        case BlockMathNode(:final latex):
          flushInline();
          widgets.add(_BlockMathView(
            tex: latex,
            style: style,
            color: color,
            fontSize: fontSize,
          ));
        case ImageNode(:final assetRef, :final altText):
          flushInline();
          widgets.add(_ImageView(
            assetRef: assetRef,
            altText: altText,
            style: style,
          ));
        case RawFallbackNode(:final rawJson):
          flushInline();
          widgets.add(_RawFallbackPlaceholder(rawJson: rawJson, style: style));
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

  void _appendTypedText(
    String text,
    List<ContentToken> inlineTokens,
    VoidCallback flushInline,
    List<Widget> widgets,
  ) {
    final tokens = _TypedTextTokenizer.tokenize(text);
    for (final token in tokens) {
      if (token is TextToken && token.text.contains('\n')) {
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
      } else {
        inlineTokens.add(token);
      }
    }
  }
}

class RichContentFieldRenderer extends StatelessWidget {
  const RichContentFieldRenderer({
    super.key,
    required this.legacyText,
    this.content,
    this.textColor,
    this.fontSize = 16.0,
    this.fontWeight = FontWeight.normal,
    this.imageBuilder,
  });

  final RichContent? content;
  final String legacyText;
  final Color? textColor;
  final double fontSize;
  final FontWeight fontWeight;
  final StructuredImageBuilder? imageBuilder;

  @override
  Widget build(BuildContext context) {
    final typed = content;
    if (typed != null) {
      return RichContentRenderer(
        content: typed,
        textColor: textColor,
        fontSize: fontSize,
        fontWeight: fontWeight,
      );
    }
    return StructuredContentRenderer(
      text: legacyText,
      textColor: textColor,
      fontSize: fontSize,
      fontWeight: fontWeight,
      imageBuilder: imageBuilder,
    );
  }
}

final _safeFallbackTypePattern = RegExp(r'^[A-Za-z0-9._-]{1,64}$');

class _RawFallbackPlaceholder extends StatelessWidget {
  final Map<String, Object?> rawJson;
  final TextStyle style;

  const _RawFallbackPlaceholder({required this.rawJson, required this.style});

  @override
  Widget build(BuildContext context) {
    if (kDebugMode) {
      debugPrint('RichContent render fallback: unsupported_node');
    }
    final type = rawJson['type'];
    final safeType = type is String ? type : null;
    final label =
        safeType != null && _safeFallbackTypePattern.hasMatch(safeType)
            ? 'Unsupported content: $safeType'
            : 'Unsupported content';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.10),
        border: Border.all(color: Colors.amber.shade300),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: style.copyWith(
          color: Colors.brown.shade800,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

class _ImageView extends StatelessWidget {
  const _ImageView({
    required this.assetRef,
    required this.altText,
    required this.style,
  });

  final String assetRef;
  final String? altText;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final file = DefaultContentAssetResolver.instance.resolveAsset(assetRef);
    if (file == null || !file.existsSync()) {
      return _placeholder(context, '图片不可用');
    }
    if (file.lengthSync() == 0) {
      return _placeholder(context, '图片格式错误');
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 600,
          maxHeight: 400,
        ),
        child: Image.file(
          file,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            return _placeholder(context, '图片加载失败');
          },
        ),
      ),
    );
  }

  Widget _placeholder(BuildContext context, String fallbackText) {
    final label = altText != null && altText!.trim().isNotEmpty
        ? altText!.trim()
        : fallbackText;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.broken_image_outlined, size: 20, color: Colors.grey),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              style: style.copyWith(
                color: Colors.grey.shade700,
                fontStyle: FontStyle.italic,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TypedTextTokenizer {
  const _TypedTextTokenizer._();

  /// Tokenizes typed text without re-parsing math delimiters, Markdown
  /// images, URLs, parse errors, or raw fallbacks. Only underscore runs of
  /// length >= 3 become blanks; everything else stays plain text.
  static List<ContentToken> tokenize(String input) {
    if (input.isEmpty) return const <ContentToken>[];
    final tokens = <ContentToken>[];
    final textBuffer = StringBuffer();

    void flushText() {
      if (textBuffer.isEmpty) return;
      tokens.add(TextToken(textBuffer.toString()));
      textBuffer.clear();
    }

    var i = 0;
    while (i < input.length) {
      if (input[i] == '_') {
        var end = i;
        while (end < input.length && input[end] == '_') {
          end++;
        }
        if (end - i >= 3) {
          flushText();
          tokens.add(BlankToken(end - i));
          i = end;
          continue;
        }
      }
      textBuffer.write(input[i]);
      i++;
    }
    flushText();
    return tokens;
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

    if (spans.length == 1 && spans.first is TextSpan) {
      final textSpan = spans.first as TextSpan;
      if (textSpan.children == null || textSpan.children!.isEmpty) {
        return Text(
          textSpan.text ?? '',
          style: textSpan.style ?? style,
          textScaler: MediaQuery.textScalerOf(context),
        );
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
    final renderability = const LatexRenderabilityChecker().check(
      safeTex,
      requireMathContext: false,
      assumeMathContext: true,
    );
    if (!renderability.isRenderable) {
      if (kDebugMode) {
        debugPrint('Structured LaTeX render fallback: structurally_unsafe');
      }
      return _LatexErrorChip(
        tex: tex,
        style: style,
        inline: inline,
      );
    }
    return Math.tex(
      safeTex,
      textStyle: style.copyWith(color: color, fontSize: fontSize),
      mathStyle: inline ? MathStyle.text : MathStyle.display,
      textScaleFactor: 1.0,
      settings: const TexParserSettings(strict: Strict.ignore),
      onErrorFallback: (err) {
        if (kDebugMode) {
          debugPrint('Structured LaTeX render fallback: parse_error');
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
    final fallback = _LatexErrorChip(
      tex: token.raw,
      style: style,
      inline: false,
    );
    if (!kDebugMode) return fallback;

    return Tooltip(message: token.reason, child: fallback);
  }
}

class _MathTexSanitizer {
  const _MathTexSanitizer._();

  static String sanitize(String tex) {
    var result = tex.trim();
    result = _normalizeJsonEscapedLatex(result);
    result = _stripNestedMathDelimiters(result);
    result = _replaceUnsupportedCommands(result);
    result = _normalizeUnicodeMathSymbols(result);
    return result;
  }

  static String _normalizeJsonEscapedLatex(String tex) {
    return tex
        .replaceAll(r'\\(', r'\(')
        .replaceAll(r'\\)', r'\)')
        .replaceAll(r'\\[', r'\[')
        .replaceAll(r'\\]', r'\]')
        .replaceAll(r'\\begin', r'\begin')
        .replaceAll(r'\\end', r'\end')
        .replaceAll(r'\\frac', r'\frac')
        .replaceAll(r'\\sqrt', r'\sqrt')
        .replaceAll(r'\\sum', r'\sum')
        .replaceAll(r'\\int', r'\int')
        .replaceAll(r'\\lim', r'\lim')
        .replaceAll(r'\\left', r'\left')
        .replaceAll(r'\\right', r'\right')
        .replaceAll(r'\\rightarrow', r'\rightarrow')
        .replaceAll(r'\\leftarrow', r'\leftarrow')
        .replaceAll(r'\\geq', r'\geq')
        .replaceAll(r'\\leq', r'\leq')
        .replaceAll(r'\\neq', r'\neq')
        .replaceAll(r'\\approx', r'\approx')
        .replaceAll(r'\\infty', r'\infty')
        .replaceAll(r'\\partial', r'\partial')
        .replaceAll(r'\\sin', r'\sin')
        .replaceAll(r'\\cos', r'\cos')
        .replaceAll(r'\\tan', r'\tan')
        .replaceAll(r'\\ln', r'\ln')
        .replaceAll(r'\\log', r'\log');
  }

  static String _stripNestedMathDelimiters(String tex) {
    var result = tex.trim();
    while (true) {
      final old = result;
      if (result.startsWith(r'\(') && result.endsWith(r'\)')) {
        result = result.substring(2, result.length - 2).trim();
      } else if (result.startsWith(r'\[') && result.endsWith(r'\]')) {
        result = result.substring(2, result.length - 2).trim();
      }
      result = result
          .replaceAll(r'{\(', '{')
          .replaceAll(r'\)}', '}')
          .replaceAll(r'{\[', '{')
          .replaceAll(r'\]}', '}');
      if (result == old) return result;
    }
  }

  static String _replaceUnsupportedCommands(String tex) {
    var result = tex.replaceAllMapped(
      RegExp(r'\\xlongequal(?:\[[^\]]*\])?\{((?:[^{}]|\{[^{}]*\})*)\}'),
      (match) => r'\overset{' + match.group(1)! + r'}{=}',
    );
    result = result.replaceAllMapped(
      RegExp(r'\\rightarrow\{([^{}]*)\}'),
      (match) => r'\overset{' + match.group(1)! + r'}{\longrightarrow}',
    );
    result = result.replaceAllMapped(
      RegExp(r'\\leftarrow\{([^{}]*)\}'),
      (match) => r'\overset{' + match.group(1)! + r'}{\longleftarrow}',
    );
    return result;
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
