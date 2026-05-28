import 'dart:core';

void main() {
  String result = r"$$ \begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix} $$";
  final pattern = RegExp(r'(\\begin\{[a-zA-Z*]+\}.*?\\end\{[a-zA-Z*]+\})|(\$\$.*?\$\$)|(\\\(.*?\\\))|(\\\[.*?\\\])|(\$.*?\$)', dotAll: true);
  
  List<String> tokens = [];
  int lastEnd = 0;
  for (final match in pattern.allMatches(result)) {
    if (match.start > lastEnd) {
      tokens.add(result.substring(lastEnd, match.start));
    }
    tokens.add(match.group(0)!);
    lastEnd = match.end;
  }
  if (lastEnd < result.length) {
    tokens.add(result.substring(lastEnd));
  }
  print(tokens);
}
