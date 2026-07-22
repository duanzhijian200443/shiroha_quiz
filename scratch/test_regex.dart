void main() {
  final regex = RegExp(
    r'(^|\n|\s)(?:(?:第\s*)|[(（]\s*)?(\d{1,3})\s*(?:(?:小)?\s*题|[\.、．)）])?\s*(?=[^\d]|$)',
    multiLine: true,
  );

  final text = '''
1. 题干
A. 1
B. 2
C. 3

(2) 第二题
A. 12
B. 23
''';

  final matches = regex.allMatches(text).toList();
  for (final match in matches) {
    final numStr = match.group(2)!;
    final lineStart = text.lastIndexOf('\n', match.start);
    final start = lineStart == -1 ? 0 : lineStart + 1;
    final prefix = text.substring(start, match.start);

    // Check if prefix looks like an option
    final isOption = RegExp(r'^\s*[A-DＡ-Ｄ][\.、．\)]').hasMatch(prefix);

    print('Num: $numStr, Prefix: "$prefix", isOption: $isOption');
  }
}
