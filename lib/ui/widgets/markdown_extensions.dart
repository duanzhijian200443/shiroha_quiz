import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:path_provider/path_provider.dart';
import '../../utils/ai_data_sanitizer.dart';

// ================================================================
//  Sandbox Image Support for ZIP Imports
// ================================================================

class SandboxImageWidget extends StatelessWidget {
  final Uri uri;
  final String? alt;

  const SandboxImageWidget({super.key, required this.uri, this.alt});

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
    useDollarSignsForLatex: true,
    style: TextStyle(fontSize: fontSize, color: color, fontWeight: fontWeight, height: 1.65),
    imageBuilder: (context, url, width, height) {
      return buildMarkdownImage(Uri.parse(url), null, null);
    },
    latexBuilder: (context, tex, textStyle, inline) {
      // 针对 flutter_math_fork 的引擎限制，在渲染前做最后的自保清洗
      const knownCmdsSet = {'frac', 'sum', 'int', 'oint', 'iint', 'iiint', 'prod', 'coprod', 'alpha', 'beta', 'gamma', 'delta', 'epsilon', 'varepsilon', 'zeta', 'eta', 'theta', 'vartheta', 'iota', 'kappa', 'lambda', 'mu', 'nu', 'xi', 'pi', 'varpi', 'rho', 'varrho', 'sigma', 'varsigma', 'tau', 'upsilon', 'phi', 'varphi', 'chi', 'psi', 'omega', 'Gamma', 'Delta', 'Theta', 'Lambda', 'Xi', 'Pi', 'Sigma', 'Upsilon', 'Phi', 'Psi', 'Omega', 'infty', 'limits', 'left', 'right', 'begin', 'end', 'sin', 'cos', 'tan', 'cot', 'sec', 'csc', 'log', 'ln', 'max', 'min', 'lim', 'sqrt', 'cdot', 'cdots', 'ldots', 'times', 'div', 'pm', 'mp', 'neq', 'leq', 'geq', 'approx', 'equiv', 'propto', 'in', 'notin', 'subset', 'supset', 'cup', 'cap', 'emptyset', 'forall', 'exists', 'nabla', 'partial', 'mathbf', 'mathrm', 'mathit', 'mathbb', 'mathcal', 'text', 'textbf', 'textit', 'underline', 'overline', 'hat', 'tilde', 'vec', 'dot', 'ddot', 'overbrace', 'underbrace', 'cases', 'matrix', 'pmatrix', 'bmatrix', 'vmatrix', 'Vmatrix', 'array', 'boldsymbol', 'widehat', 'widetilde', 'operatorname', 'DeclareMathOperator', 'mid', 'nmid', 'to', 'gets', 'rightarrow', 'leftarrow', 'Rightarrow', 'Leftarrow', 'iff', 'implies', 'xrightarrow', 'xleftarrow', 'bigoplus', 'bigotimes', 'bigcup', 'bigcap', 'biguplus', 'bigwedge', 'bigvee', 'lfloor', 'rfloor', 'lceil', 'rceil', 'langle', 'rangle', 'binom', 'dbinom', 'tbinom', 'stackrel', 'overset', 'underset', 'pmod', 'because', 'therefore', 'ell', 'perp', 'parallel', 'angle', 'Im', 'Re', 'not', 'quad', 'qquad', 'sim', 'simeq', 'cong', 'geqslant', 'leqslant', 'ge', 'le', 'd'};
      String safeTex = tex.replaceAll(r'\boldsymbol', r'\mathbf');
      
      // 自动修复矩阵/cases中被 JSON 转义丢失的行分隔符（\\ 变成 \）
      safeTex = safeTex.replaceAllMapped(
        RegExp(r'\\begin\{(pmatrix|bmatrix|matrix|cases|vmatrix|array)\}([\s\S]*?)\\end\{\1\}'),
        (match) {
          final env = match.group(1)!;
          String body = match.group(2)!;
          
          // 将可能由于 JSON 转义丢失的 row break（双反斜杠 \\ 变成了单反斜杠 \）修复回来
          // 规则：如果反斜杠后面的内容既不是特殊转义字符（如 \{, \}, \[, \], \| 等），
          // 也不属于已知命令（如 \frac, \xi, \text 等）及 \begin/\end，
          // 则应该将其恢复为 \\。
          body = body.replaceAllMapped(RegExp(r'\\\\|\\([a-zA-Z0-9]+|.)'), (m) {
            final matchedStr = m.group(0)!;
            if (matchedStr == r'\\') {
              return r'\\'; // 已有双反斜杠，原样保留
            }
            final content = m.group(1)!;
            if (RegExp(r'^[{}|\[\]]$').hasMatch(content)) return matchedStr;
            
            final cmdMatch = RegExp(r'^[a-zA-Z]+').firstMatch(content);
            if (cmdMatch != null) {
              final cmd = cmdMatch.group(0)!;
              if (cmd == 'begin' || cmd == 'end' || knownCmdsSet.contains(cmd)) {
                return matchedStr;
              }
            }
            return '\\\\$content';
          });
          
          return '\\begin{$env}$body\\end{$env}';
        }
      );

      // 修复填空题下划线 ___ 导致 LaTeX 引擎解析下标崩溃的问题
      safeTex = safeTex.replaceAllMapped(RegExp(r'(?<!\\)_{2,}'), (m) => r'\_' * m.group(0)!.length);

      // 修复双杠污染（白名单机制）：大模型可能过度转义 \alpha 为 \\alpha。
      safeTex = safeTex.replaceAllMapped(RegExp(r'\\\\([a-zA-Z]+)'), (match) {
        final cmd = match.group(1)!;
        if (knownCmdsSet.contains(cmd)) {
          return r'\' + cmd;
        }
        return match.group(0)!;
      });
      // 补充针对特殊括号 \{ \} \[ \] \| 的降级
      safeTex = safeTex.replaceAllMapped(RegExp(r'\\\\([{(}\[\]|])'), (match) {
        return r'\' + match.group(1)!;
      });
      
      // 防崩溃：强制把内嵌的中文字符包裹进 \text{}，避免 parser 崩溃报错变红（尤其针对历史遗留数据）
      safeTex = safeTex.replaceAllMapped(RegExp(r'(?<!\\text\{)([\u4e00-\u9fa5]+)'), (m) {
        return r'\text{' + m.group(1)! + r'}';
      });

      final mathWidget = Math.tex(
        safeTex,
        textStyle: textStyle.copyWith(color: color, fontSize: fontSize),
        mathStyle: inline ? MathStyle.text : MathStyle.display,
        textScaleFactor: 1.0,
        settings: const TexParserSettings(strict: Strict.ignore),
        onErrorFallback: (err) {
          debugPrint('LaTeX ParseException: [Hash: ${tex.hashCode}] err: $err\nFormula: $tex');
          return Container(
            padding: const EdgeInsets.all(4),
            margin: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: Colors.orange.shade50.withOpacity(0.5),
              border: Border.all(color: Colors.orange.shade300, width: 1.0),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    tex,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Colors.black87),
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  '[LaTeX fallback]',
                  style: TextStyle(fontSize: 9, color: Colors.grey),
                ),
              ],
            ),
          );
        },
      );

      if (inline) {
        // 内联公式直接放在 WidgetSpan 中，保留最原生的基线对齐
        // 安全防御：如果公式超过 200 个字符，且没有包含常见的数学公式命令特征，
        // 则很可能是整段正文被误判为公式（第21题Bug）
        // 这种情况下用普通文本显示而不是压缩到一行
        if (tex.length > 200 && !AiDataSanitizer.isLikelyMathFormula(tex)) {
          return SelectableText(
            tex,
            style: textStyle.copyWith(color: color, fontSize: fontSize),
          );
        }
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
