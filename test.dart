void main() {
  String text = r"\boldsymbol{\alpha} \\boldsymbol{\\alpha}";
  String result = text.replaceAllMapped(RegExp(r'\\\\([a-zA-Z{(])'), (match) {
      return '\\';
  });
  print("Result: " + result);
}
