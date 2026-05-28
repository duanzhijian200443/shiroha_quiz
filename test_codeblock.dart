void main() {
  String text = "`latex\n\\begin{pmatrix}1&2\\\\3&4\\end{pmatrix}\n`";
  String result = text.replaceAllMapped(RegExp(r'`(?:math|latex|tex)?\s*([\s\S]+?)\s*`'), (match) {
      String inner = match.group(1)!;
      if (inner.startsWith('\$') && inner.endsWith('\$')) return '\n\\n';
      return '\n\$\$' + inner + '\$\$\n';
  });
  print(result);
}
