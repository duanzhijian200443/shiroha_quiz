import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:shiroha_quiz/ui/assistant/assistant_content_renderer.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';

void main() {
  Widget host(String text) => MaterialApp(
        home: Scaffold(
          body: AssistantContentRenderer(text: text),
        ),
      );

  testWidgets('renders common Assistant Markdown without exposing markers',
      (tester) async {
    await tester.pumpWidget(host('''
### Heading

**bold** and *italic*

- first
- second

> quoted

| Column | Value |
| --- | --- |
| A | 1 |

```dart
final value = 1;
```
'''));

    expect(find.byType(GptMarkdown), findsOneWidget);
    expect(find.textContaining('###'), findsNothing);
    expect(find.textContaining('**bold**'), findsNothing);
    expect(find.textContaining('> quoted'), findsNothing);
    expect(find.textContaining('Heading'), findsWidgets);
    expect(find.textContaining('bold'), findsWidgets);
    expect(find.textContaining('first'), findsWidgets);
    expect(find.textContaining('quoted'), findsWidgets);
    expect(find.textContaining('Column'), findsWidgets);
    expect(find.textContaining('Value'), findsWidgets);
    expect(find.textContaining('final value = 1;'), findsWidgets);
  });

  testWidgets('delegates inline and display LaTeX to the structured renderer',
      (tester) async {
    await tester.pumpWidget(
      host(r'Inline \(x^2+1\) and display \[\frac{1}{2}\].'),
    );

    expect(find.byType(StructuredContentRenderer), findsNWidgets(2));
    expect(find.textContaining(r'\(x^2+1\)'), findsNothing);
    expect(find.textContaining(r'\[\frac{1}{2}\]'), findsNothing);
  });
}
