import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide TableCell;
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter/rendering.dart';

import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/content/rich_content_text_projection.dart';
import '../../application/content/content_asset_authority.dart';
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
    this.assetResolver,
  });

  final RichContent content;
  final Color? textColor;
  final double fontSize;
  final FontWeight fontWeight;
  final ContentAssetResolver? assetResolver;

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
    final resolver =
        assetResolver ?? ContentAssetResolverScope.maybeOf(context);

    final widgets = <Widget>[];
    final inlineTokens = <ContentToken>[];

    void flushInline() {
      if (inlineTokens.isEmpty) return;
      widgets.add(_InlineTokenParagraph(
        tokens: List<ContentToken>.from(inlineTokens),
        style: style,
        color: color,
        fontSize: fontSize,
        literalText: true,
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
        case ImageNode(
            :final sourceId,
            :final localAssetId,
            :final alternativeText,
          ):
          flushInline();
          widgets.add(
            _ImageNodeView(
              sourceId: sourceId,
              localAssetId: localAssetId,
              alternativeText: alternativeText,
              resolver: resolver,
              style: style,
            ),
          );
        case TableNode(:final structure):
          flushInline();
          widgets.add(_TableNodeView(
            structure: structure,
            textColor: color,
            fontSize: fontSize,
            fontWeight: fontWeight,
            resolver: resolver,
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
    final parts = text.split('\n');
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

final class ContentAssetResolverScope extends InheritedWidget {
  const ContentAssetResolverScope({
    super.key,
    required this.resolver,
    required super.child,
  });

  final ContentAssetResolver resolver;

  static ContentAssetResolver? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ContentAssetResolverScope>()
        ?.resolver;
  }

  @override
  bool updateShouldNotify(ContentAssetResolverScope oldWidget) =>
      resolver != oldWidget.resolver;
}

class _ImageNodeView extends StatefulWidget {
  const _ImageNodeView({
    required this.sourceId,
    required this.localAssetId,
    required this.alternativeText,
    required this.resolver,
    required this.style,
  });

  final String sourceId;
  final String localAssetId;
  final RichContent? alternativeText;
  final ContentAssetResolver? resolver;
  final TextStyle style;

  @override
  State<_ImageNodeView> createState() => _ImageNodeViewState();
}

class _ImageNodeViewState extends State<_ImageNodeView> {
  Future<List<int>?>? _bytesFuture;

  @override
  void initState() {
    super.initState();
    _bytesFuture = _resolveBytes();
  }

  @override
  void didUpdateWidget(covariant _ImageNodeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resolver != widget.resolver ||
        oldWidget.sourceId != widget.sourceId ||
        oldWidget.localAssetId != widget.localAssetId) {
      _bytesFuture = _resolveBytes();
    }
  }

  Future<List<int>?> _resolveBytes() async {
    final resolver = widget.resolver;
    if (resolver == null) return null;
    try {
      return await resolver.resolveAssetBytesAsync(
        sourceId: widget.sourceId,
        localAssetId: widget.localAssetId,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final fallback = _RichContentTextPlaceholder(
      text: _alternativeTextOrPlaceholder(widget.alternativeText),
      style: widget.style,
    );
    return FutureBuilder<List<int>?>(
      future: _bytesFuture,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done ||
            bytes == null ||
            bytes.isEmpty) {
          return fallback;
        }
        return Semantics(
          image: true,
          label: _alternativeTextOrPlaceholder(widget.alternativeText),
          child: Image.memory(
            Uint8List.fromList(bytes),
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => fallback,
          ),
        );
      },
    );
  }
}

class _TableNodeView extends StatelessWidget {
  const _TableNodeView({
    required this.structure,
    required this.textColor,
    required this.fontSize,
    required this.fontWeight,
    required this.resolver,
  });

  final TableStructure structure;
  final Color textColor;
  final double fontSize;
  final FontWeight fontWeight;
  final ContentAssetResolver? resolver;

  @override
  Widget build(BuildContext context) {
    final borderColor = Theme.of(context).dividerColor;
    final anchors = _tableAnchors(structure);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: borderColor),
      ),
      child: _SpannedTableLayout(
        rowCount: structure.rows.length,
        columnCount: structure.columnCount,
        anchors: anchors,
        children: [
          for (final anchor in anchors)
            Container(
              key: ValueKey<String>(
                'rich-table-anchor-${anchor.row}-${anchor.column}',
              ),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                border: Border.all(color: borderColor),
              ),
              child: RichContentRenderer(
                content: anchor.cell.content,
                textColor: textColor,
                fontSize: fontSize,
                fontWeight: fontWeight,
                assetResolver: resolver,
              ),
            ),
        ],
      ),
    );
  }
}

final class _TableAnchor {
  const _TableAnchor({
    required this.row,
    required this.column,
    required this.cell,
  });

  final int row;
  final int column;
  final TableCell cell;

  int get rowSpan => cell.rowSpan;
  int get columnSpan => cell.columnSpan;
}

List<_TableAnchor> _tableAnchors(TableStructure structure) {
  final occupied = <List<TableCell?>>[
    for (var row = 0; row < structure.rows.length; row++)
      List<TableCell?>.filled(structure.columnCount, null),
  ];
  final anchors = <_TableAnchor>[];

  for (var rowIndex = 0; rowIndex < structure.rows.length; rowIndex++) {
    var cursor = 0;
    for (final cell in structure.rows[rowIndex].cells) {
      while (cursor < structure.columnCount &&
          occupied[rowIndex][cursor] != null) {
        cursor++;
      }
      final column = cursor;
      anchors.add(_TableAnchor(row: rowIndex, column: column, cell: cell));
      for (var row = rowIndex; row < rowIndex + cell.rowSpan; row++) {
        for (var columnIndex = column;
            columnIndex < column + cell.columnSpan;
            columnIndex++) {
          occupied[row][columnIndex] = cell;
        }
      }
      cursor += cell.columnSpan;
    }
  }
  return List<_TableAnchor>.unmodifiable(anchors);
}

final class _SpannedTableLayout extends MultiChildRenderObjectWidget {
  const _SpannedTableLayout({
    required this.rowCount,
    required this.columnCount,
    required this.anchors,
    required super.children,
  });

  final int rowCount;
  final int columnCount;
  final List<_TableAnchor> anchors;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _SpannedTableRenderBox(
      rowCount: rowCount,
      columnCount: columnCount,
      anchors: anchors,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _SpannedTableRenderBox renderObject,
  ) {
    renderObject
      ..rowCount = rowCount
      ..columnCount = columnCount
      ..anchors = anchors
      ..markNeedsLayout();
  }

  @override
  void didUnmountRenderObject(covariant _SpannedTableRenderBox renderObject) {}
}

final class _SpannedTableParentData extends ContainerBoxParentData<RenderBox> {
  late _TableAnchor anchor;
}

final class _SpannedTableRenderBox extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _SpannedTableParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _SpannedTableParentData> {
  _SpannedTableRenderBox({
    required int rowCount,
    required int columnCount,
    required List<_TableAnchor> anchors,
  })  : _rowCount = rowCount,
        _columnCount = columnCount,
        _anchors = anchors;

  int _rowCount;
  int _columnCount;
  List<_TableAnchor> _anchors;

  set rowCount(int value) => _rowCount = value;
  set columnCount(int value) => _columnCount = value;
  set anchors(List<_TableAnchor> value) => _anchors = value;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _SpannedTableParentData) {
      child.parentData = _SpannedTableParentData();
    }
  }

  @override
  void performLayout() {
    final width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : _columnCount * 120.0;
    final columnWidth = width / _columnCount;
    final rowHeights = List<double>.filled(_rowCount, 12.0);
    final childByAnchor = <_TableAnchor, RenderBox>{};

    var child = firstChild;
    var childIndex = 0;
    while (child != null) {
      final data = child.parentData! as _SpannedTableParentData;
      final anchor = _anchors[childIndex++];
      data.anchor = anchor;
      childByAnchor[anchor] = child;
      final cellWidth = columnWidth * anchor.columnSpan;
      child.layout(
        BoxConstraints(maxWidth: cellWidth),
        parentUsesSize: true,
      );
      if (anchor.rowSpan == 1) {
        rowHeights[anchor.row] = rowHeights[anchor.row]
            .clamp(child.size.height, double.infinity)
            .toDouble();
      }
      child = data.nextSibling;
    }

    for (final anchor in _anchors.where((anchor) => anchor.rowSpan > 1)) {
      final child = childByAnchor[anchor]!;
      final start = anchor.row;
      final end = start + anchor.rowSpan;
      final currentHeight = rowHeights
          .sublist(start, end)
          .fold<double>(0, (sum, height) => sum + height);
      if (child.size.height > currentHeight) {
        rowHeights[end - 1] += child.size.height - currentHeight;
      }
    }

    final totalHeight =
        rowHeights.fold<double>(0, (sum, height) => sum + height);
    size = constraints.constrain(Size(width, totalHeight));

    child = firstChild;
    childIndex = 0;
    while (child != null) {
      final data = child.parentData! as _SpannedTableParentData;
      final anchor = _anchors[childIndex++];
      final left = anchor.column * columnWidth;
      final top = rowHeights
          .take(anchor.row)
          .fold<double>(0, (sum, height) => sum + height);
      final height = rowHeights
          .sublist(anchor.row, anchor.row + anchor.rowSpan)
          .fold<double>(0, (sum, value) => sum + value);
      child.layout(
        BoxConstraints.tightFor(
          width: columnWidth * anchor.columnSpan,
          height: height,
        ),
      );
      data.offset = Offset(left, top);
      child = data.nextSibling;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }
}

String _alternativeTextOrPlaceholder(RichContent? alternativeText) {
  if (alternativeText == null) return '[图片]';
  try {
    final projected =
        const RichContentTextProjection().project(alternativeText);
    return projected.trim().isEmpty ? '[图片]' : projected;
  } on FormatException {
    return '[图片]';
  }
}

class _RichContentTextPlaceholder extends StatelessWidget {
  const _RichContentTextPlaceholder({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: style);
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
    this.assetResolver,
  });

  final RichContent? content;
  final String legacyText;
  final Color? textColor;
  final double fontSize;
  final FontWeight fontWeight;
  final StructuredImageBuilder? imageBuilder;
  final ContentAssetResolver? assetResolver;

  @override
  Widget build(BuildContext context) {
    final typed = content;
    if (typed != null) {
      return RichContentRenderer(
        content: typed,
        textColor: textColor,
        fontSize: fontSize,
        fontWeight: fontWeight,
        assetResolver: assetResolver,
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
  final bool literalText;

  const _InlineTokenParagraph({
    required this.tokens,
    required this.style,
    required this.color,
    required this.fontSize,
    this.literalText = false,
  });

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    for (final token in tokens) {
      if (token is TextToken) {
        if (literalText) {
          spans.add(TextSpan(text: token.text, style: style));
        } else {
          spans.addAll(_MarkdownLiteSpans.parse(token.text, style));
        }
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
