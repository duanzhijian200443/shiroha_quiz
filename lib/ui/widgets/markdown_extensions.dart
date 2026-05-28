import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path_provider/path_provider.dart';
import '../../utils/ai_data_sanitizer.dart';

//  LaTeX inline syntax: $...$ (produces 'latex' element with MathStyle=text)
// ================================================================

class LatexInlineSyntax extends md.InlineSyntax {
  // 匹配 $...$ 但不匹配 $$...$$
  // 也匹配 \(...\) 和历史遗留的脏数据 \\( ... \\)，不允许跨行
  LatexInlineSyntax() : super(r'(?:\$(?!\$)([^$\n]+?)\$(?!\$))|(?:\\{1,2}\((.+?)\\{1,2}\))');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final tex = match.group(1) ?? match.group(2);
    if (tex == null) return false;
    final element = md.Element.text('latex', tex);
    element.attributes['MathStyle'] = 'text'; // 行内模式
    parser.addNode(element);
    return true;
  }
}

// ================================================================
//  LaTeX block syntax: $$...$$ (single-line AND multi-line)
//  产生 'latex' 元素配平 flutter_markdown_latex 的 LatexElementBuilder
// ================================================================

class LatexBlockSyntax extends md.BlockSyntax {
  // 匹配以 $$ 或 \[ 或 \\[ 开头的行
  static final RegExp _pattern = RegExp(r'^(\$\$|\\{1,2}\[)');
  // 匹配单行完整的 $$...$$ 或 \[...\] 或 \\[...\\] 块
  static final RegExp _singleLine = RegExp(r'^(\$\$|\\{1,2}\[)(.+?)(\$\$|\\{1,2}\])\s*$');

  @override
  RegExp get pattern => _pattern;

  @override
  bool canEndBlock(md.BlockParser parser) => false;

  @override
  bool canParse(md.BlockParser parser) {
    return _pattern.hasMatch(parser.current.content);
  }

  @override
  md.Node parse(md.BlockParser parser) {
    final firstLine = parser.current.content;
    final isBracket = firstLine.contains(r'\[');

    // 情况1：单行 $$...$$ 格式（e.g., $$\frac{1}{2}$$）
    final singleMatch = _singleLine.firstMatch(firstLine);
    if (singleMatch != null) {
      parser.advance();
      final el = md.Element.text('latex', singleMatch[2]!);
      el.attributes['MathStyle'] = 'display';
      return md.Element('p', [el]);
    }

    // 情况2：多行块
    final StringBuffer buffer = StringBuffer();
    int openEnd = 2; // for $$ or \[
    if (firstLine.startsWith(r'\\[')) openEnd = 3;
    final openContent = firstLine.substring(openEnd).trim(); 
    if (openContent.isNotEmpty) buffer.write(openContent);
    parser.advance();

    while (!parser.isDone) {
      final line = parser.current.content;
      bool isCloseLine = false;
      String trailing = '';

      if (!isBracket && (line.trim() == r'$$' || line.trim().endsWith(r'$$'))) {
        isCloseLine = true;
        trailing = line.substring(0, line.lastIndexOf(r'$$')).trim();
      } else if (isBracket && (line.trim() == r'\]' || line.trim().endsWith(r'\]'))) {
        isCloseLine = true;
        trailing = line.substring(0, line.lastIndexOf(r'\]')).trim();
      } else if (isBracket && (line.trim() == r'\\]' || line.trim().endsWith(r'\\]'))) {
        isCloseLine = true;
        trailing = line.substring(0, line.lastIndexOf(r'\\]')).trim();
      }

      if (isCloseLine) {
        if (trailing.isNotEmpty) {
          if (buffer.isNotEmpty) buffer.write('\n');
          buffer.write(trailing);
        }
        parser.advance();
        break;
      } else {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(line);
        parser.advance();
      }
    }

    final el = md.Element.text('latex', buffer.toString());
    el.attributes['MathStyle'] = 'display';
    return md.Element('p', [el]);
  }
}

// ================================================================
//  Combined ExtensionSet (LaTeX first, then GFM)
// ================================================================

md.ExtensionSet latexExtensionSet = md.ExtensionSet(
  [LatexBlockSyntax(), ...md.ExtensionSet.gitHubFlavored.blockSyntaxes],
  [LatexInlineSyntax(), ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes],
);

// ================================================================
//  Markdown → Widget builders
// ================================================================

class MathElementBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final tex = element.textContent;
    return Math.tex(
      tex,
      mathStyle: MathStyle.text,
      textStyle: preferredStyle ?? const TextStyle(fontSize: 16),
      onErrorFallback: (e) => Text(
        tex,
        style: const TextStyle(
          color: Colors.red,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }
}

class MathBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final tex = element.textContent;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Math.tex(
          tex,
          mathStyle: MathStyle.display,
          textStyle: const TextStyle(fontSize: 17),
          onErrorFallback: (e) => Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(tex, style: const TextStyle(color: Colors.red)),
          ),
        ),
      ),
    );
  }
}

class CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final code = element.textContent;
    final lang = element.attributes['class'] ?? 'plaintext';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.3),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(10)),
            ),
            child: Text(
              lang,
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade400,
                fontFamily: 'monospace',
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: SelectableText(
              code,
              style: const TextStyle(
                fontSize: 13,
                fontFamily: 'Courier',
                color: Color(0xFFD4D4D4),
                height: 1.55,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ================================================================
//  Shared style sheet
// ================================================================

MarkdownStyleSheet markdownSheet(BuildContext context) => MarkdownStyleSheet(
  p: TextStyle(
    fontSize: 16,
    height: 1.65,
    color:
        Theme.of(context).textTheme.bodyLarge?.color ?? Colors.grey.shade900,
  ),
  code: const TextStyle(
    fontSize: 13,
    fontFamily: 'Courier',
    backgroundColor: Color(0xFFF0F0F0),
    color: Color(0xFFC7254E),
  ),
  codeblockDecoration: BoxDecoration(
    color: const Color(0xFF1E1E1E),
    borderRadius: BorderRadius.circular(10),
  ),
  blockquoteDecoration: BoxDecoration(
    color: const Color(0xFFEDF1FD),
    border:
        const Border(left: BorderSide(color: Color(0xFF4C6ED7), width: 3)),
  ),
);

// ================================================================
//  Sandbox Image Support for ZIP Imports
// ================================================================

class SandboxImageWidget extends StatelessWidget {
  final Uri uri;
  final String? alt;

  const SandboxImageWidget({Key? key, required this.uri, this.alt}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Directory>(
      future: getApplicationDocumentsDirectory(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox(
            height: 60,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        
        final docDir = snapshot.data!;
        // uri.host is folderId, uri.path is /subdir/img.png or /img.png
        final relativePath = 'media/${uri.host}${uri.path}';
        File file = File('${docDir.path}/$relativePath');

        // 容错备用：如果精确路径找不到（如旧数据库存储了平层路径），就递归搜索同名文件
        if (!file.existsSync()) {
          final filename = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
          final mediaDir = Directory('${docDir.path}/media/${uri.host}');
          if (filename.isNotEmpty && mediaDir.existsSync()) {
            final found = mediaDir.listSync(recursive: true)
                .whereType<File>()
                .where((f) => f.path.replaceAll('\\', '/').endsWith(filename))
                .toList();
            if (found.isNotEmpty) file = found.first;
          }
        }
        
        if (!file.existsSync()) {
          return Container(
            color: Colors.grey.shade200,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            margin: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.broken_image, color: Colors.grey, size: 20),
                const SizedBox(width: 8),
                Flexible(child: Text('图片丢失: ${alt ?? relativePath}', style: const TextStyle(color: Colors.grey, fontSize: 13))),
              ],
            ),
          );
        }

        return Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              file,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image, color: Colors.red),
            ),
          ),
        );
      },
    );
  }
}

Widget buildMarkdownImage(Uri uri, String? title, String? alt) {
  if (uri.scheme == 'sandbox') {
    return SandboxImageWidget(uri: uri, alt: alt);
  } else if (uri.scheme == 'http' || uri.scheme == 'https') {
    return Image.network(uri.toString(), errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image, color: Colors.grey));
  }
  return Text('Unsupported image: ${uri.toString()}');
}

class RobustLatexElementBuilder extends MarkdownElementBuilder {
  final TextStyle textStyle;
  RobustLatexElementBuilder({required this.textStyle});

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    String mathText = element.textContent;
    if (mathText.isEmpty) return const SizedBox();

    // ==========================================
    // 🧬 终极 LaTeX 免疫抗体 (repairLatex)
    // ==========================================
    // 1. 强制剥离残留的 $ 符号
    mathText = mathText.replaceAll(r'$', '').trim();
    // 2. 修复双杠污染（白名单机制）：大模型可能过度转义 \alpha 为 \\alpha。
    // 使用 Set 匹配以避免正则表达式中 \b 遇到下划线（如 \\int_）时失效的问题。
    const knownCmdsSet = {'frac', 'sum', 'int', 'oint', 'iint', 'iiint', 'prod', 'coprod', 'alpha', 'beta', 'gamma', 'delta', 'epsilon', 'varepsilon', 'zeta', 'eta', 'theta', 'vartheta', 'iota', 'kappa', 'lambda', 'mu', 'nu', 'xi', 'pi', 'varpi', 'rho', 'varrho', 'sigma', 'varsigma', 'tau', 'upsilon', 'phi', 'varphi', 'chi', 'psi', 'omega', 'Gamma', 'Delta', 'Theta', 'Lambda', 'Xi', 'Pi', 'Sigma', 'Upsilon', 'Phi', 'Psi', 'Omega', 'infty', 'limits', 'left', 'right', 'begin', 'end', 'sin', 'cos', 'tan', 'cot', 'sec', 'csc', 'log', 'ln', 'max', 'min', 'lim', 'sqrt', 'cdot', 'cdots', 'ldots', 'times', 'div', 'pm', 'mp', 'neq', 'leq', 'geq', 'approx', 'equiv', 'propto', 'in', 'notin', 'subset', 'supset', 'cup', 'cap', 'emptyset', 'forall', 'exists', 'nabla', 'partial', 'mathbf', 'mathrm', 'mathit', 'mathbb', 'mathcal', 'text', 'textbf', 'textit', 'underline', 'overline', 'hat', 'tilde', 'vec', 'dot', 'ddot', 'overbrace', 'underbrace', 'cases', 'matrix', 'pmatrix', 'bmatrix', 'vmatrix', 'Vmatrix', 'array', 'boldsymbol', 'widehat', 'widetilde', 'operatorname', 'DeclareMathOperator', 'mid', 'nmid', 'to', 'gets', 'rightarrow', 'leftarrow', 'Rightarrow', 'Leftarrow', 'iff', 'implies', 'xrightarrow', 'xleftarrow', 'bigoplus', 'bigotimes', 'bigcup', 'bigcap', 'biguplus', 'bigwedge', 'bigvee', 'lfloor', 'rfloor', 'lceil', 'rceil', 'langle', 'rangle', 'binom', 'dbinom', 'tbinom', 'stackrel', 'overset', 'underset', 'pmod', 'because', 'therefore', 'ell', 'perp', 'parallel', 'angle', 'Im', 'Re', 'not', 'quad', 'qquad', 'sim', 'simeq', 'cong', 'geqslant', 'leqslant', 'ge', 'le', 'd'};
    mathText = mathText.replaceAllMapped(RegExp(r'\\\\([a-zA-Z]+)'), (match) {
      final cmd = match.group(1)!;
      if (knownCmdsSet.contains(cmd)) {
        return r'\' + cmd;
      }
      return match.group(0)!;
    });
    // 另外还需要补充针对特殊括号 \{ \} \[ \] \| 的降级
    mathText = mathText.replaceAllMapped(RegExp(r'\\\\([{(}\[\]|])'), (match) {
      return r'\' + match.group(1)!;
    });
    // 3. 修复矩阵换行符：Markdown 解析器经常把矩阵里的 \\ 吞成 \，如果遇到单杠结尾或单杠空格，强制恢复为 \\
    mathText = mathText.replaceAllMapped(RegExp(r'(?<!\\)\\(\s|$)'), (m) => r'\\' + m.group(1)!);
    // 4. 防崩溃：强制把内嵌的中文字符包裹进 \text{}，避免 parser 崩溃报错变红（尤其针对历史遗留数据）
    mathText = mathText.replaceAllMapped(RegExp(r'(?<!\\text\{)([\u4e00-\u9fa5]+)'), (m) {
      return r'\text{' + m.group(1)! + r'}';
    });
    
    // flutter_math_fork 严格模式下，公式外部的非法字符（如末尾的 y）会导致崩溃。
    // 这超出了正则可控范围，因此保留 onErrorFallback 作为最后一道防线。

    MathStyle mathStyle;
    switch (element.attributes['MathStyle']) {
      case 'display':
        mathStyle = MathStyle.display;
        break;
      default:
        mathStyle = MathStyle.text;
    }

    // flutter_math_fork 在宽度约束为 0时会产生 RenderResetDimension 崩溃。
    // 用 LayoutBuilder 确保传入布局的宽度永远大于 0。
    return LayoutBuilder(builder: (context, constraints) {
      final safeWidth = constraints.maxWidth > 0
          ? constraints.maxWidth
          : MediaQuery.of(context).size.width - 32;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: safeWidth),
          child: Math.tex(
            mathText,
            textStyle: textStyle,
            mathStyle: mathStyle,
            onErrorFallback: (err) => SelectableText(
              '\$ $mathText \$',
              style: textStyle.copyWith(color: Colors.redAccent),
            ),
          ),
        ),
      );
    });
  }
}

// ================================================================
//  统一 LaTeX 渲染入口 — 基于 gpt_markdown
//  所有题目内容渲染请调用此函数，不要直接使用 MarkdownBody
//
//  gpt_markdown 天然支持：
//    \( \)  行内公式
//    \[ \]  块级公式
//    $ $    行内（需 useDollarSignsForLatex: true）
//    $$ $$  块级（需 useDollarSignsForLatex: true）
//    \begin{...}...\end{...} 环境
// ================================================================

/// 渲染含 LaTeX 的 Markdown 文本。
/// - [text] 原始内容，会先经过 [AiDataSanitizer.formatLatex] 清洗
/// - [textColor] 覆盖文字颜色（选中/高亮选项使用）
/// - [fontSize] 字体大小，默认 16
/// - [fontWeight] 字重，默认 normal

Widget buildLatexWidget(
  BuildContext context,
  String text, {
  Color? textColor,
  double fontSize = 16.0,
  FontWeight fontWeight = FontWeight.normal,
}) {
  final theme = Theme.of(context);
  final color = textColor ?? theme.textTheme.bodyLarge?.color ?? Colors.black87;
  final cleaned = AiDataSanitizer.formatLatex(text);

  return GptMarkdown(
    cleaned,
    style: TextStyle(fontSize: fontSize, color: color, fontWeight: fontWeight, height: 1.65),
    imageBuilder: (context, url, width, height) {
      return buildMarkdownImage(Uri.parse(url), null, null);
    },
    latexBuilder: (context, tex, textStyle, inline) {
      final mathWidget = Math.tex(
        tex,
        textStyle: textStyle.copyWith(color: color, fontSize: fontSize),
        mathStyle: inline ? MathStyle.text : MathStyle.display,
        textScaleFactor: 1.0,
        settings: const TexParserSettings(strict: Strict.ignore),
        onErrorFallback: (err) => SelectableText(
          inline ? '\$$tex\$' : '\$\$$tex\$\$',
          style: textStyle.copyWith(color: Colors.orangeAccent),
        ),
      );

      if (inline) {
        // 内联公式直接放在 WidgetSpan 中，保留最原生的基线对齐
        // 使用 ConstrainedBox + FittedBox 防止超长公式溢出屏幕，同时保持基线对齐
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.85,
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: mathWidget,
          ),
        );
      } else {
        // 块级公式可以直接使用 ScrollView 以支持横向滑动
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
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 4.0),
              child: mathWidget,
            ),
          ),
        );
      }
    },
  );
}
