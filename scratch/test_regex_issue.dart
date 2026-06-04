import '../lib/utils/ai_data_sanitizer.dart';

String testAutoWrapBareLatex(String text) {
  if (text.isEmpty || !text.contains(r'\')) return text;

  final List<String> saved = [];
  String s = text;

  // Phase 1: 保护已经包裹好的块，防止被二次处理
  s = s.replaceAllMapped(RegExp(r'\$\$[\s\S]*?\$\$'), (m) {
    saved.add(m.group(0)!);
    return '⁕${saved.length - 1}⁕';
  });
  s = s.replaceAllMapped(RegExp(r'\$(?!\$)[\s\S]*?\$'), (m) {
    saved.add(m.group(0)!);
    return '⁕${saved.length - 1}⁕';
  });
  s = s.replaceAllMapped(RegExp(r'\\\([\s\S]*?\\\)'), (m) {
    saved.add(m.group(0)!);
    return '⁕${saved.length - 1}⁕';
  });
  s = s.replaceAllMapped(RegExp(r'\\\[[\s\S]*?\\\]'), (m) {
    saved.add(m.group(0)!);
    return '⁕${saved.length - 1}⁕';
  });

  // Phase 1.5: 把裸露的大型多行环境整体包裹进 $...$
  s = s.replaceAllMapped(RegExp(r'\\begin\{([a-zA-Z*]+)\}[\s\S]*?\\end\{\1\}'),
      (m) {
    saved.add('\$${m.group(0)!}\$');
    return '⁕${saved.length - 1}⁕';
  });
  // Phase 2: 把裸 LaTeX 连贯数学公式块包裹进 \$...\$
  s = s.replaceAllMapped(
    RegExp(
        r'(\\[a-zA-Z]+|\\[{}_|])[^⁕\$\u4e00-\u9fa5，。：；！？（）\r\n]*' // Modified to include escaped special characters
        ),
    (m) {
      final full = m.group(0)!;
      if (full.contains('⁕')) return full; // 保护占位符

      // 去除尾部可能误匹配的标点符号及空格
      String trimmed = full;
      String trail = '';
      final endPunct = RegExp(r'[\s,，.。\s]+$');
      final punctMatch = endPunct.firstMatch(trimmed);
      if (punctMatch != null) {
        trimmed = trimmed.substring(0, punctMatch.start);
        trail = punctMatch.group(0)!;
      }

      if (trimmed.isEmpty || trimmed == r'\') return full;

      // 过滤非公式，比如单独的转义符号
      if (RegExp(r'^\\[{}]\s*$').hasMatch(trimmed)) return full;

      return '\$$trimmed\$$trail';
    },
  );

  // Phase 3: 恢复已保护的块
  for (int i = 0; i < saved.length; i++) {
    s = s.replaceFirst('⁕$i⁕', saved[i]);
  }
  return s;
}

String testFormatLatex(String text) {
  if (text.isEmpty) return text;
  String result = AiDataSanitizer.normalizeDelimiters(text);

  result = result.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
  result = result.replaceAllMapped(RegExp(r'\\n(?![a-zA-Z])'), (m) => '\n');
  result = result.replaceAllMapped(RegExp(r'\\t(?![a-zA-Z])'), (m) => '\t');

  result = result.replaceAllMapped(RegExp(r'(\\_){2,}'), (match) {
    return '_' * (match.group(0)!.length ~/ 2);
  });

  // Call testAutoWrapBareLatex
  result = testAutoWrapBareLatex(result);

  // New absorption rule: absorb coefficients tightly bound to inline math blocks
  result = result.replaceAllMapped(
    RegExp(r'(?<!\$)\b([a-zA-Z_]\w*|[+-]?\d+(?:\.\d+)?)\s*\$(?!\$)([^$]+?)\$'),
    (m) => '\$${m.group(1)!}${m.group(2)!}\$',
  );

  // Merge adjacent inline math blocks separated by small operators
  bool merged = true;
  while (merged) {
    String newResult = result.replaceAllMapped(
      RegExp(r'\$(?!\$)([^$]+)\$\s*([+\-=><,\s]+)\s*\$(?!\$)([^$]+)\$'),
      (m) => '\$${m.group(1)}${m.group(2)}${m.group(3)}\$',
    );
    if (newResult == result) {
      merged = false;
    } else {
      result = newResult;
    }
  }

  // Merge adjacent block math blocks separated by small operators (for historical data)
  bool mergedBlock = true;
  while (mergedBlock) {
    String newResult = result.replaceAllMapped(
      RegExp(r'\$\$(?!\$)([^$]+)\$\$\s*([+\-=><,\s]+)\s*\$\$(?!\$)([^$]+)\$\$'),
      (m) => '\$\$${m.group(1)}${m.group(2)}${m.group(3)}\$\$',
    );
    if (newResult == result) {
      mergedBlock = false;
    } else {
      result = newResult;
    }
  }

  result =
      result.replaceAllMapped(RegExp(r'\$(?!\$)([^$]{100,})\$(?!\$)'), (m) {
    final content = m.group(1)!;
    if (AiDataSanitizer.isLikelyMathFormula(content)) {
      return '\n\$\$$content\$\$\n';
    }
    return m.group(0)!;
  });

  // Upgrade rule
  result = result.replaceAllMapped(
    RegExp(r'\$(?!\$)([^$]*\\begin\{(?:pmatrix|bmatrix|matrix|cases|vmatrix)'
        r'[\s\S]*?\\end\{(?:pmatrix|bmatrix|matrix|cases|vmatrix)\}[^$]*)\$(?!\$)'),
    (m) => '\$\$${m.group(1)}\$\$',
  );

  result = result.replaceAll(RegExp(r'(?<!\n)\$\$'), '\n\$\$');
  result = result.replaceAll(RegExp(r'\$\$(?!\n)'), '\$\$\n');

  return result;
}

void main() {
  const text1 =
      r'(III)f(x1,x2,x3) = 0的通解可以取为k_1\begin{pmatrix} -2 \\ 1 \\ 0 \end{pmatrix} + k_2\begin{pmatrix} -3 \\ 0 \\ 1 \end{pmatrix}';
  print('Original 1: $text1');
  print('Formatted 1: ${testFormatLatex(text1)}');
  print('========================');

  const text2 = r'已知平面区域D=\{(x,y)|y-2\le x\le \sqrt{4-y^2},0\le y\le2\}';
  print('Original 2: $text2');
  print('Formatted 2: ${testFormatLatex(text2)}');
  print('========================');

  const text3 =
      r'通解为$$ k_1 \begin{pmatrix} -2 \\ 1 \\ 0 \end{pmatrix} $$ + $$ k_2 \begin{pmatrix} -3 \\ 0 \\ 1 \end{pmatrix} $$';
  print('Original 3: $text3');
  print('Formatted 3: ${testFormatLatex(text3)}');
}
