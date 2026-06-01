void main() {
  final regex = RegExp(
    r'(\d*\.?\d+)?\s*'         // 可选数字前缀（如 2\pi）
    r'(\\[a-zA-Z]+)'           // LaTeX 命令（如 \frac, \pi）
    r'(?:\s*\{[^⁕{}]*(?:\{[^⁕{}]*\}[^⁕{}]*)*\})*' // {参数} 组，支持1级嵌套及可选空格
    r'(?:\s*[_^](?:\{[^⁕{}]*(?:\{[^⁕{}]*\}[^⁕{}]*)*\}|[a-zA-Z0-9]))*'  // 下标/上标
    r'(\s*\d*\.?\d*)?'         // 可选尾部数字
  );

  var inputs = [
    r'\frac{5}{8}',
    r'\frac{5} {8}',
    r'\frac{1}{2\sqrt{x}}',
    r'\frac{1}{2\sqrt{x}} y = 2 + \sqrt{x}',
    r'2\pi',
    r'\alpha_1',
    r'\beta_{i_1}'
  ];

  for (var input in inputs) {
    print('Input: "$input"');
    final matches = regex.allMatches(input);
    for (var m in matches) {
      final full = m.group(0)!;
      if (full.contains(r'\')) {
        print('  Match: "$full"');
      }
    }
  }
}
