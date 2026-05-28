void main() {
  var s = r'已知 a_n < b_n $$$n=1,2,\cdots$$$ , 若';
  s = s.replaceAllMapped(RegExp(r'\$\$+([^\$]+?)\$\$+'), (m) => '\n\n\$\$${m.group(1)}\$\$\n\n');
  print(s);
}
