import 'package:markdown/markdown.dart' as md;
import 'package:shiroha_quiz/ui/widgets/markdown_extensions.dart';
import 'package:shiroha_quiz/utils/ai_data_sanitizer.dart';

void main() {
  String text = r'已知 a_n < b_n $$n=1,2,\cdots$$ , 若 \sum a_n 与 \sum b_n 均收敛，则 \sum a_n 绝对收敛是 \sum b_n 绝对收敛的';
  String cleanText = AiDataSanitizer.formatLatex(text);
  
  var document = md.Document(
    extensionSet: md.ExtensionSet(
      [LatexBlockSyntax()],
      [LatexInlineSyntax(), ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes],
    ),
  );
  
  var nodes = document.parseLines(cleanText.split('\n'));
  
  void printNode(md.Node node, int depth) {
    String indent = '  ' * depth;
    if (node is md.Text) {
      print('$indent Text: "${node.text}"');
    } else if (node is md.Element) {
      print('$indent Element: ${node.tag} (attributes: ${node.attributes})');
      if (node.children != null) {
        for (var child in node.children!) {
          printNode(child, depth + 1);
        }
      }
    }
  }
  
  for (var node in nodes) {
    printNode(node, 0);
  }
}
