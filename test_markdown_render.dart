import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:shiroha_quiz/ui/widgets/markdown_extensions.dart';

void main() {
  testWidgets('Markdown rendering test', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownBody(
            data: r'已知 a_n < b_n  $n=1,2,\cdots$  , 若 $ \sum a_n $',
            extensionSet: md.ExtensionSet(
                [LatexBlockSyntax()],
                [LatexInlineSyntax(), ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes],
            ),
            builders: {
                'latex': RobustLatexElementBuilder(
                    textStyle: TextStyle(fontSize: 14, color: Colors.black),
                ),
            },
          ),
        ),
      ),
    );
    // Let's dump the render tree to see what is actually rendered
    debugDumpApp();
  });
}
