void main() {
  String text = r"$$ \begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix} $$";
  final pattern = RegExp(r'(\\begin\{[a-zA-Z*]+\}.*?\\end\{[a-zA-Z*]+\})|(\$\$.*?\$\$)|(\\\(.*?\\\))|(\\\[.*?\\\])|(\$.*?\$)', dotAll: true);
  for (final match in pattern.allMatches(text)) {
    print("Matched: ${match.group(0)}");
  }
}
