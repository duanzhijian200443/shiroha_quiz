import 'dart:io';

String formatLatexSafe(String text) {
  if (text.isEmpty) return text;

  // 1. 定义保护块的正则表达式（代码块、环境块、已有的各种数学公式块）
  final tokenRegex = RegExp(
    r'('
    r'```[\s\S]*?```|' // 多行代码块
    r'`[^`\n]+?`|' // 单行代码块
    r'\$\$[\s\S]*?\$\$|' // 双 $ 公式块
    r'\\\[[\s\S]*?\\\]|' // \[ \] 块级公式
    r'(?<!\$)\$[^\$\n]+?\$(?!\$)|' // 单 $ 行内公式
    r'\\\(.*?\\\)|' // \( \) 行内公式
    r'\\begin\{[a-zA-Z\*]+\}[\s\S]*?\\end\{[a-zA-Z\*]+\}' // 环境块
    r')',
    dotAll: true,
  );

  final List<String> resultParts = [];
  int lastMatchEnd = 0;

  // 遍历所有匹配的保护块
  for (final match in tokenRegex.allMatches(text)) {
    // 提取保护块之前的普通文本
    if (match.start > lastMatchEnd) {
      final plainText = text.substring(lastMatchEnd, match.start);
      resultParts.add(_processPlainText(plainText));
    }
    // 保护块原样保留
    resultParts.add(match.group(1)!);
    lastMatchEnd = match.end;
  }

  // 提取最后一个保护块之后的普通文本
  if (lastMatchEnd < text.length) {
    final plainText = text.substring(lastMatchEnd);
    resultParts.add(_processPlainText(plainText));
  }

  String result = resultParts.join('');

  // 4. 统一转换为 gpt_markdown 原生渲染格式
  // 先处理双 $（必须在单 $ 之前）
  result = result.replaceAllMapped(
    RegExp(r'\$\$([\s\S]*?)\$\$', dotAll: true),
    (match) => '\n\\[${match.group(1)!.trim()}\\]\n',
  );
  // 再处理单 $
  result = result.replaceAllMapped(
    RegExp(r'(?<!\$)\$([^\$]+?)\$(?!\$)'),
    (match) => '\\(${match.group(1)!.trim()}\\)',
  );

  return result;
}

String _processPlainText(String plainText) {
  if (plainText.isEmpty) return plainText;

  // 以中文、中文标点和换行符为界限进行拆分，保留分割符本身
  final splitRegex = RegExp(r'([\u4e00-\u9fa5，。、！？：；（）“”《》\n]+)');
  final parts = <String>[];
  int lastEnd = 0;

  for (final match in splitRegex.allMatches(plainText)) {
    if (match.start > lastEnd) {
      parts.add(plainText.substring(lastEnd, match.start));
    }
    parts.add(match.group(1)!);
    lastEnd = match.end;
  }
  if (lastEnd < plainText.length) {
    parts.add(plainText.substring(lastEnd));
  }

  // 处理每个拆分出的非中文片段
  final processedParts = parts.map((part) {
    // 如果是中文、中文标点或换行符，原样保留
    if (splitRegex.hasMatch(part)) {
      return part;
    }

    // 保护图片标签和URL
    if (part.contains('![')) return part;

    // 检查是否包含数学公式触发器
    final hasBackslash = part.contains('\\');
    final partNoUrl = part.replaceAll(RegExp(r'https?://\S+|sandbox://\S+'), '');
    final hasSubSuper = partNoUrl.contains('_') || partNoUrl.contains('^');

    if (hasBackslash || hasSubSuper) {
      // 提取前导和尾随的空白字符，保证公式包裹的纯净度
      final trimmed = part.trim();
      final leadingSpace = part.substring(0, part.indexOf(trimmed));
      final trailingSpace = part.substring(part.indexOf(trimmed) + trimmed.length);
      return '$leadingSpace\$$trimmed\$$trailingSpace';
    }

    return part;
  }).toList();

  return processedParts.join('');
}

void main() {
  final inputs = [
    r"设 A,B,C 为随机事件,且 A 与 B 互不相容,A 与 C 互不相容,B 与 C 相互独立," + "\n" + r"P(A) = P(B) = P(C) = \frac{1}{3}" + "\n" + r",则 $P(B \cup C \mid A \cup B \cup C) = $ ____.",
    r"已知 a_n < b_n $$n=1,2,\cdots$$ , 若 \sum a_n 与 \sum b_n 均收敛",
    r"取 $A = \begin{pmatrix} 0 & 0 & 1 \\ 0 & 0 & 0 \\ 0 & 0 & 0 \end{pmatrix}$, 则 $0$ 是 $A$ 的 $3$ 重特征值",
    r"在图片 ![](sandbox://1779796026238/_page_3_Figure_5.jpeg) 中所示",
    r"A. A有3个不同的特征值.",
  ];

  for (var i = 0; i < inputs.length; i++) {
    print('--- Case ${i + 1} ---');
    print('Input:\n${inputs[i]}');
    print('Output:\n${formatLatexSafe(inputs[i])}');
    print('=' * 40);
  }
}
