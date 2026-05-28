void main() {
  var s = r'$$$n=1,2,\cdots$$$';
  print(s.replaceAllMapped(RegExp(r'\$\$+([^\$]+?)\$\$+'), (m) => '[\n\n\$\$${m.group(1)}\$\$\n\n]'));
}
