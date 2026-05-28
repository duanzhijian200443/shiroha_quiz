import 'package:markdown/markdown.dart';

void main() {
  String escapeRegex(String string) {
    return string.replaceAllMapped(RegExp(r'[-\/\\^$*+?.()|[\]{}]'), (match) {
      return '\\${match.group(0)}';
    });
  }

  final left = r'$';
  final right = r'$';
  String escapedLeft = escapeRegex(left);
  String escapedRight = escapeRegex(right);

  String inlinePattern = '$escapedLeft((?:\\\\.|[^\\\\\\n])*?(?:\\\\.|[^\\\\\\n]|(?!$escapedRight)))$escapedRight';
  String blockPattern = '$escapedLeft\\n((?:\\\\[^]|[^\\\\])+?)\\n$escapedRight';

  String finalPattern = '($inlinePattern)(?=[\\s?!.,:？！。，：]|\$)';
  RegExp regex = RegExp(finalPattern);

  String testString = r"(A)$f(1) = \frac{1}{2}, f'(1) = 0$.";
  print('Testing: \$testString');
  
  var match = regex.firstMatch(testString);
  if (match != null) {
    print('MATCHED: \${match.group(0)}');
  } else {
    print('NO MATCH');
  }

  String testString2 = r", $\frac{\partial z}{\partial y} = xf(\frac{y}{x}) + xyf'(\frac{y}{x}) \cdot (\frac{y}{x})'$";
  var match2 = regex.firstMatch(testString2);
  print('Testing 2: \$testString2');
  if (match2 != null) {
    print('MATCHED 2: \${match2.group(0)}');
  } else {
    print('NO MATCH 2');
  }
}
