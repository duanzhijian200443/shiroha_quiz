import os

file_path = r"c:\Users\34331\shiroha_quiz\lib\ui\pages\question_list_screen.dart"
with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

import_target = "import 'package:flutter_markdown_latex/flutter_markdown_latex.dart';\nimport 'package:markdown/markdown.dart' as md;"
import_replace = "import 'package:flutter_markdown_latex/flutter_markdown_latex.dart';\nimport 'package:flutter_math_fork/flutter_math.dart';\nimport 'package:markdown/markdown.dart' as md;"

builder_target = """            builders: {
                'latex': LatexElementBuilder(
                    textStyle: baseStyle,
                ),
            },"""

builder_replace = """            builders: {
                'latex': RobustLatexElementBuilder(
                    textStyle: baseStyle,
                ),
            },"""

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

if import_target in content:
    content = content.replace(import_target, import_replace)
    print("question_list_screen import updated.")

if builder_target in content:
    content = content.replace(builder_target, builder_replace)
    print("question_list_screen builder updated.")

if "class RobustLatexElementBuilder" not in content:
    content += class_definition
    print("question_list_screen class added.")

with open(file_path, "w", encoding="utf-8") as f:
    f.write(content)
    
print("question_list_screen.dart saved.")
