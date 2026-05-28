import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;

class LatexInlineSyntax extends md.InlineSyntax {
  LatexInlineSyntax() : super(r'(?:\$(?!\$)([^$\n]+?)\$(?!\$))|(?:\\\((.+?)\\\))');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final tex = match.group(1) ?? match.group(2);
    if (tex == null) return false;
    final element = md.Element.text('latex', tex);
    element.attributes['MathStyle'] = 'text';
    parser.addNode(element);
    return true;
  }
}

void main() {
  test('latex', () {
    var text = r'\\(f(u)\\)';
    var doc = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored);
    var nodes = doc.parseInline(text);
    for (var node in nodes) {
      if (node is md.Element) {
        print('Element: ${node.tag}, ${node.textContent}');
      } else if (node is md.Text) {
        print('Text: ${node.text}');
      }
    }
  });
}
