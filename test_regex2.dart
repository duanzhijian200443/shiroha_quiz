void main() {
  var s = r'已知 $a_n < b_n$ $$n=1,2,\cdots$$';
  print(s.replaceAllMapped(RegExp(r'\$\$+([^\$]+?)\$\$+'), (m) => 'BLOCK'));
}
