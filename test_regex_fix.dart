import 'dart:convert';

void main() {
  String jsonStr = '{"text": "\\begin and \\beta and \\frac and \\right and \\tan and \\notin and \\nabla and \\n and \\t"}';
  
  // Known cmds that start with b, f, n, r, t which overlap with JSON escapes
  const dangerousCmds = r'begin|beta|boldsymbol|bmatrix|bar|bf|mathbb|mathbf|mathcal|mathrm|mathit|'
                        r'frac|forall|'
                        r'nabla|notin|nu|neq|'
                        r'right|rho|rangle|rightarrow|Rightarrow|'
                        r'tan|theta|times|to|tilde|tau|text|triangle|textbf|textit';

  // Replace single backslash + dangerousCmd with double backslash
  // Note: Since jsonStr is a raw string from network, it literally contains \ and b.
  // In Dart string literal, that is '\\begin'.
  
  String cleanText = jsonStr;
  
  cleanText = cleanText.replaceAllMapped(RegExp(r'(?<!\\)\\(' + dangerousCmds + r')\b'), (match) {
    return '\\\\${match.group(1)}';
  });

  print("Clean text: " + cleanText);
  try {
    var decoded = jsonDecode(cleanText);
    print("Decoded: " + decoded['text']);
  } catch(e) {
    print("Error: $e");
  }
}
