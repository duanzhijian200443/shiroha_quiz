import os

files = [
    r"c:\Users\34331\shiroha_quiz\lib\ui\pages\practice_page.dart",
    r"c:\Users\34331\shiroha_quiz\lib\ui\pages\question_list_screen.dart"
]

old_class = """class RobustLatexElementBuilder extends MarkdownElementBuilder {
  final TextStyle textStyle;
  RobustLatexElementBuilder({required this.textStyle});

  @override
  Widget visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    // 1. 强力清洗：剔除 AI 错误嵌套的内部 $ 符号
    final String mathText = element.textContent.replaceAll('$', '');
    
    // 2. 优雅降级：如果公式依然解析失败，显示红色原文本，绝不崩溃
    return Math.tex(
      mathText,
      textStyle: textStyle,
      mathStyle: MathStyle.text,
      onErrorFallback: (err) => Text(
        '$${mathText}$',
        style: textStyle.copyWith(color: Colors.redAccent),
      ),
    );
  }
}"""

new_class = """class RobustLatexElementBuilder extends MarkdownElementBuilder {
  final TextStyle textStyle;
  RobustLatexElementBuilder({required this.textStyle});

  @override
  Widget visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final String mathText = element.textContent.replaceAll('$', '');
    
    // 核心热修复：注入横向滚动视图，防止超长公式撑爆屏幕
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Math.tex(
        mathText,
        textStyle: textStyle,
        mathStyle: MathStyle.text,
        onErrorFallback: (err) => Text(
          '$${mathText}$',
          style: textStyle.copyWith(color: Colors.redAccent),
        ),
      ),
    );
  }
}"""

for file_path in files:
    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()

    if "class RobustLatexElementBuilder extends MarkdownElementBuilder {" in content:
        # replace everything from class definition to the end of file, since it's at the end
        import re
        content = re.sub(r'class RobustLatexElementBuilder extends MarkdownElementBuilder \{[\s\S]*\}\n*', new_class + '\n', content)
        with open(file_path, "w", encoding="utf-8") as f:
            f.write(content)
        print(f"Updated {file_path}")
    else:
        print(f"Error: class not found in {file_path}")
