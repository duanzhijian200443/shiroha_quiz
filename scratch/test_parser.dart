import 'package:markdown/markdown.dart';
import 'package:flutter_markdown_latex/flutter_markdown_latex.dart';

void main() {
  String testString = r"(A)$f(1) = \frac{1}{2}, f'(1) = 0$.";
  
  var document1 = Document(
    extensionSet: ExtensionSet(
      [LatexBlockSyntax()],
      [...ExtensionSet.gitHubFlavored.inlineSyntaxes, LatexInlineSyntax()],
    ),
  );
  
  var document2 = Document(
    extensionSet: ExtensionSet(
      [LatexBlockSyntax()],
      [LatexInlineSyntax(), ...ExtensionSet.gitHubFlavored.inlineSyntaxes],
    ),
  );

  var nodes1 = document1.parseLines([testString]);
  print('Nodes with Latex AFTER GFM:');
  for (var node in nodes1) {
    if (node is Element) {
      print(node.children?.map((e) => e is Element ? e.tag : (e as Text).text).toList());
    }
  }

  var nodes2 = document2.parseLines([testString]);
  print('Nodes with Latex BEFORE GFM:');
  for (var node in nodes2) {
    if (node is Element) {
      print(node.children?.map((e) => e is Element ? e.tag : (e as Text).text).toList());
    }
  }
}
