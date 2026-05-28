void main() {
  String text = r'`$$n=1,2,\cdots$$`';
  RegExp reg = RegExp(r'`(\$+[^`]+?\$+)`');
  print('Matches: ${reg.hasMatch(text)}');
  print('Result: ' + text.replaceAllMapped(reg, (m) => m.group(1)!));

  String text2 = r'`$\begin{cases}x=t^2+2t\y=\sin t\end{cases}$`';
  print('\nMatches2: ${reg.hasMatch(text2)}');
  print('Result2: ' + text2.replaceAllMapped(reg, (m) => m.group(1)!));
}
