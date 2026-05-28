import os

# 1. Update ai_service.dart
file_path_ai = r"c:\Users\34331\shiroha_quiz\lib\services\ai_service.dart"
with open(file_path_ai, "r", encoding="utf-8") as f:
    content_ai = f.read()

target_ai = """      【致命警告：JSON转义】
      你输出的必须是标准 JSON。如果遇到 LaTeX 公式，所有的反斜杠必须经过严格的双重转义！
      例如 pi 符号必须写成两个反斜杠加 pi。绝对不允许在 JSON 中出现未转义的单反斜杠！"""

replacement_ai = """      【致命警告：JSON转义】
      你输出的必须是标准 JSON。如果遇到 LaTeX 公式，所有的反斜杠必须经过严格的双重转义！
      例如 pi 符号必须写成两个反斜杠加 pi。绝对不允许在 JSON 中出现未转义的单反斜杠！
      
      【LaTeX 渲染致命警告】
      1. 公式必须使用 \\$ 或 \\$\\$ 包裹。绝对禁止使用 \\\\( \\\\) 或 \\\\[ \\\\]。
      2. 绝对禁止在公式内部嵌套使用 \\$ 符号！例如 "\\$\\lim \\$x\\$\\$" 会导致解析崩溃，必须写成 "\\$\\lim x\\$"。"""

if target_ai in content_ai:
    content_ai = content_ai.replace(target_ai, replacement_ai)
    with open(file_path_ai, "w", encoding="utf-8") as f:
        f.write(content_ai)
    print("ai_service.dart updated.")
else:
    print("Error: target_ai not found.")

# 2. Update practice_page.dart
file_path_pp = r"c:\Users\34331\shiroha_quiz\lib\ui\pages\practice_page.dart"
with open(file_path_pp, "r", encoding="utf-8") as f:
    content_pp = f.read()

import_target = "import 'package:flutter_markdown_latex/flutter_markdown_latex.dart';\nimport 'package:markdown/markdown.dart' as md;"
import_replace = "import 'package:flutter_markdown_latex/flutter_markdown_latex.dart';\nimport 'package:flutter_math_fork/flutter_math.dart';\nimport 'package:markdown/markdown.dart' as md;"

builder_target = """      builders: {
        'latex': LatexElementBuilder(
          textStyle: TextStyle(color: textColor, fontWeight: fontWeight, fontSize: fontSize),
        ),
      },"""

builder_replace = """      builders: {
        'latex': RobustLatexElementBuilder(
          textStyle: TextStyle(color: textColor, fontWeight: fontWeight, fontSize: fontSize),
        ),
      },"""

if import_target in content_pp:
    content_pp = content_pp.replace(import_target, import_replace)
    print("practice_page import updated.")
else:
    if "import 'package:flutter_math_fork/flutter_math.dart';" not in content_pp:
        print("Error: import_target not found.")

if builder_target in content_pp:
    content_pp = content_pp.replace(builder_target, builder_replace)
    print("practice_page builder updated.")
else:
    print("Error: builder_target not found.")

class_definition = """
class RobustLatexElementBuilder extends md.MarkdownElementBuilder {
  final TextStyle textStyle;
  RobustLatexElementBuilder({required this.textStyle});

  @override
  Widget visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    // 1. 强力清洗：剔除 AI 错误嵌套的内部 $ 符号
    final String mathText = element.textContent.replaceAll('\\$', '');
    
    // 2. 优雅降级：如果公式依然解析失败，显示红色原文本，绝不崩溃
    return Math.tex(
      mathText,
      textStyle: textStyle,
      mathStyle: MathStyle.text,
      onErrorFallback: (err) => Text(
        '\\$${mathText}\\$',
        style: textStyle.copyWith(color: Colors.redAccent),
      ),
    );
  }
}
"""

if "class RobustLatexElementBuilder" not in content_pp:
    content_pp += class_definition
    print("practice_page class added.")

with open(file_path_pp, "w", encoding="utf-8") as f:
    f.write(content_pp)
    
print("practice_page.dart saved.")
