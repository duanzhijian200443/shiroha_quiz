import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';

void main() {
  Widget host(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: child,
      ),
    );
  }

  group('RichContentRenderer', () {
    testWidgets('A: empty RichContent renders an empty widget', (tester) async {
      await tester.pumpWidget(
        host(RichContentRenderer(content: RichContent(nodes: []))),
      );

      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(RichContentRenderer)), Size.zero);
      expect(find.byType(Text), findsNothing);
      expect(find.byType(Math), findsNothing);
      expect(find.byType(RichText), findsNothing);
      expect(find.byType(Column), findsNothing);
    });

    testWidgets('B: typed text is not re-parsed as math or Markdown image',
        (tester) async {
      final content = RichContent(nodes: const [
        TextNode(r'Literal \(x\), \[y\], ![a](sandbox://asset).'),
      ]);

      await tester.pumpWidget(host(RichContentRenderer(content: content)));

      expect(find.byType(Math), findsNothing);
      expect(find.byType(BlankTokenWidget), findsNothing);
      expect(
        find.textContaining(
          r'Literal \(x\), \[y\], ![a](sandbox://asset).',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('B: image and table nodes use bounded text placeholders',
        (tester) async {
      final table = TableNode(
        structure: TableStructure(rows: <TableRow>[
          TableRow(cells: <TableCell>[
            TableCell(
              content: RichContent(nodes: const <ContentNode>[
                TextNode('cell'),
              ]),
            ),
          ]),
        ]),
      );
      final content = RichContent(nodes: <ContentNode>[
        ImageNode(
          sourceId: 'source_001',
          localAssetId: 'asset_001',
          alternativeText: RichContent(nodes: const <ContentNode>[
            TextNode('alt text'),
          ]),
        ),
        ImageNode(sourceId: 'source_001', localAssetId: 'asset_002'),
        table,
      ]);

      await tester.pumpWidget(host(RichContentRenderer(content: content)));

      expect(find.text('alt text'), findsOneWidget);
      expect(find.text('[图片]'), findsOneWidget);
      expect(find.textContaining('cell', findRichText: true), findsOneWidget);
      expect(find.textContaining('source_001'), findsNothing);
      expect(find.textContaining('asset_001'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('C: typed text blanks render BlankTokenWidget', (tester) async {
      final content = RichContent(nodes: const [
        TextNode('Fill ___ and _____.'),
      ]);

      await tester.pumpWidget(host(RichContentRenderer(content: content)));

      expect(find.byType(BlankTokenWidget), findsNWidgets(2));
      expect(find.textContaining('Fill', findRichText: true), findsOneWidget);
      expect(find.textContaining('.', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('D: node order and inline grouping are preserved',
        (tester) async {
      final content = RichContent(nodes: const [
        TextNode('Before '),
        InlineMathNode(r'x^2'),
        TextNode(' middle'),
        BlockMathNode(r'\int_0^1 x\,dx'),
        TextNode('After'),
      ]);

      await tester.pumpWidget(host(RichContentRenderer(content: content)));

      expect(tester.takeException(), isNull);
      expect(find.byType(Math), findsNWidgets(2));

      final paragraph = find.ancestor(
        of: find.byType(Math).first,
        matching: find.byType(RichText),
      );
      expect(paragraph, findsOneWidget);
      final plainText = tester.widget<RichText>(paragraph).text.toPlainText();
      expect(plainText, contains('Before'));
      expect(plainText, contains(' middle'));
      expect(
          plainText.indexOf('Before'), lessThan(plainText.indexOf('middle')));

      final block = find.ancestor(
        of: find.byType(Math),
        matching: find.byType(SingleChildScrollView),
      );
      expect(block, findsOneWidget);

      expect(
        tester.getTopLeft(paragraph).dy,
        lessThan(tester.getTopLeft(block).dy),
      );
      expect(
        tester.getTopLeft(block).dy,
        lessThan(tester.getTopLeft(find.text('After')).dy),
      );
    });

    testWidgets('E: typed inline math renders inline Math', (tester) async {
      final content = RichContent(nodes: const [
        TextNode('Before '),
        InlineMathNode(r'x^2'),
        TextNode(' after'),
      ]);

      await tester.pumpWidget(host(RichContentRenderer(content: content)));

      expect(find.byType(Math), findsOneWidget);
      expect(
        find.ancestor(of: find.byType(Math), matching: find.byType(FittedBox)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('E: typed block math renders block Math with scrolling',
        (tester) async {
      final content = RichContent(nodes: const [
        TextNode('Before '),
        BlockMathNode(r'\begin{pmatrix}1&2\\3&4\end{pmatrix}'),
        TextNode(' After'),
      ]);

      await tester.pumpWidget(host(RichContentRenderer(content: content)));

      expect(find.byType(Math), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(Math),
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
      );
      expect(
        find.ancestor(of: find.byType(Math), matching: find.byType(FittedBox)),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('E: typed inline math is not promoted to block by complexity',
        (tester) async {
      final content = RichContent(nodes: const [
        TextNode('Before '),
        InlineMathNode(r'\begin{pmatrix}1&2\\3&4\end{pmatrix}'),
        TextNode(' after'),
      ]);

      await tester.pumpWidget(host(RichContentRenderer(content: content)));

      expect(find.byType(Math), findsOneWidget);
      expect(
        find.ancestor(of: find.byType(Math), matching: find.byType(FittedBox)),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.byType(Math),
          matching: find.byType(SingleChildScrollView),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('E: malformed typed inline math falls back locally',
        (tester) async {
      final content = RichContent(nodes: const [
        TextNode('Valid '),
        InlineMathNode(r'\begin{array}{c}1\\2'),
        TextNode(' after.'),
      ]);

      await tester.pumpWidget(host(RichContentRenderer(content: content)));

      expect(find.byType(Math), findsNothing);
      expect(
        find.textContaining(r'\begin{array}{c}1\\2', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('Valid', findRichText: true), findsOneWidget);
      expect(find.textContaining('after.', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('E: malformed typed block math falls back locally',
        (tester) async {
      final content = RichContent(nodes: const [
        TextNode('Before '),
        BlockMathNode(r'\begin{array}{c}1\\2'),
        TextNode(' After.'),
      ]);

      await tester.pumpWidget(host(RichContentRenderer(content: content)));

      expect(find.byType(Math), findsNothing);
      expect(
        find.textContaining(r'\begin{array}{c}1\\2', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('Before', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('After.', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('E: malformed typed math does not hide valid neighbors',
        (tester) async {
      final content = RichContent(nodes: const [
        InlineMathNode(r'x=1'),
        InlineMathNode(r'\begin{array}{c}1\\2'),
        InlineMathNode(r'y=2'),
      ]);

      await tester.pumpWidget(host(RichContentRenderer(content: content)));

      expect(find.byType(Math), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('F: raw fallback hides payload and logs a fixed category only',
        (tester) async {
      final debugMessages = <String>[];
      final previousDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) debugMessages.add(message);
      };

      try {
        final content = RichContent(nodes: [
          TextNode('Before '),
          RawFallbackNode({
            'type': 'future_table',
            'payload': {'secret': 'DO_NOT_RENDER'},
          }),
          TextNode(' after.'),
        ]);

        await tester.pumpWidget(
          host(RichContentRenderer(content: content)),
        );

        expect(find.text('Unsupported content: future_table'), findsOneWidget);
        expect(find.textContaining('DO_NOT_RENDER'), findsNothing);
        expect(find.textContaining('secret', findRichText: true), findsNothing);
        expect(
          find.textContaining('Before', findRichText: true),
          findsOneWidget,
        );
        expect(
          find.textContaining('after.', findRichText: true),
          findsOneWidget,
        );
        expect(
          debugMessages,
          contains('RichContent render fallback: unsupported_node'),
        );
        final log = debugMessages.join('\n');
        expect(log, isNot(contains('future_table')));
        expect(log, isNot(contains('DO_NOT_RENDER')));
        expect(tester.takeException(), isNull);
      } finally {
        debugPrint = previousDebugPrint;
      }
    });

    testWidgets('F: unsafe raw fallback types show a generic placeholder',
        (tester) async {
      final unsafeTypes = <String>[
        'bad type\nwith newline',
        List.filled(65, 'a').join(),
      ];

      for (final type in unsafeTypes) {
        final content = RichContent(nodes: [
          RawFallbackNode({
            'type': type,
            'payload': {'secret': 'DO_NOT_RENDER'},
          }),
        ]);

        await tester.pumpWidget(host(RichContentRenderer(content: content)));

        expect(find.text('Unsupported content'), findsOneWidget);
        expect(find.textContaining('DO_NOT_RENDER'), findsNothing);
        expect(find.textContaining(type, findRichText: true), findsNothing);
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('RichContentFieldRenderer bridge', () {
    testWidgets('G: typed content always wins over legacy text',
        (tester) async {
      var imageBuilderCalls = 0;

      await tester.pumpWidget(
        host(
          RichContentFieldRenderer(
            legacyText: r'legacy-value ![img](https://example.com/a.png) \(x\)',
            content: RichContent(nodes: const [TextNode('typed-value')]),
            imageBuilder: (context, uri, alt) {
              imageBuilderCalls++;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(find.text('typed-value'), findsOneWidget);
      expect(find.textContaining('legacy-value'), findsNothing);
      expect(find.byType(Math), findsNothing);
      expect(find.byType(BlankTokenWidget), findsNothing);
      expect(imageBuilderCalls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('H: explicit empty typed content does not fall back to legacy',
        (tester) async {
      await tester.pumpWidget(
        host(
          RichContentFieldRenderer(
            legacyText: 'non-empty legacy',
            content: RichContent(nodes: []),
          ),
        ),
      );

      expect(find.textContaining('non-empty legacy'), findsNothing);
      expect(find.byType(Math), findsNothing);
      expect(tester.getSize(find.byType(RichContentFieldRenderer)), Size.zero);
      expect(tester.takeException(), isNull);
    });

    testWidgets('I: null typed content keeps the legacy renderer path',
        (tester) async {
      var imageBuilderCalls = 0;

      await tester.pumpWidget(
        host(
          RichContentFieldRenderer(
            legacyText:
                r'Legacy \(x^2\) fill ___ ![img](https://example.com/a.png)',
            content: null,
            imageBuilder: (context, uri, alt) {
              imageBuilderCalls++;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(find.byType(Math), findsOneWidget);
      expect(find.byType(BlankTokenWidget), findsOneWidget);
      expect(imageBuilderCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('J: typed renderer forwards text style', (tester) async {
      final content = RichContent(nodes: const [TextNode('Styled')]);

      await tester.pumpWidget(
        host(
          RichContentRenderer(
            content: content,
            textColor: Colors.red,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
      );

      final text = tester.widget<Text>(find.text('Styled'));
      expect(text.style?.fontSize, 22);
      expect(text.style?.color, Colors.red);
      expect(text.style?.fontWeight, FontWeight.bold);
    });

    testWidgets('J: legacy bridge path forwards text style', (tester) async {
      await tester.pumpWidget(
        host(
          const RichContentFieldRenderer(
            legacyText: 'Styled legacy',
            content: null,
            textColor: Colors.blue,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

      final text = tester.widget<Text>(find.text('Styled legacy'));
      expect(text.style?.fontSize, 18);
      expect(text.style?.color, Colors.blue);
      expect(text.style?.fontWeight, FontWeight.w600);
    });

    testWidgets(
        'K: synthetic QuestionDraftV2 field matrix renders typed fields',
        (tester) async {
      final draft = QuestionDraftV2(
        questionId: 'r5_matrix_001',
        kind: QuestionKind.singleChoice,
        questionNumber: 1,
        stem: RichContent(nodes: [
          TextNode('Stem: compute '),
          InlineMathNode(r'x^2'),
          TextNode(' then'),
          BlockMathNode(r'\int_0^1 x\,dx'),
        ]),
        options: [
          QuestionOption(
            optionId: 'opt_a',
            label: 'A',
            content: RichContent(nodes: const [TextNode('Option A text')]),
          ),
        ],
        answer: ContentAnswer(
          content: RichContent(nodes: const [InlineMathNode(r'1/3')]),
        ),
        explanation: RichContent(nodes: [
          TextNode('Explanation'),
          RawFallbackNode({
            'type': 'future_table',
            'payload': {'secret': 'DO_NOT_RENDER'},
          }),
        ]),
      );

      await tester.pumpWidget(
        host(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RichContentRenderer(content: draft.stem),
              RichContentRenderer(content: draft.options.single.content),
              RichContentRenderer(
                content: (draft.answer! as ContentAnswer).content,
              ),
              RichContentRenderer(content: draft.explanation!),
            ],
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(RichContentRenderer), findsNWidgets(4));
      expect(find.byType(Math), findsNWidgets(3));

      final stemParagraph = find
          .descendant(
            of: find.byType(RichContentRenderer).first,
            matching: find.byType(RichText),
          )
          .first;
      final stemPlain =
          tester.widget<RichText>(stemParagraph).text.toPlainText();
      expect(stemPlain, contains('Stem: compute'));
      expect(stemPlain, contains(' then'));
      expect(
        stemPlain.indexOf('Stem: compute'),
        lessThan(stemPlain.indexOf(' then')),
      );

      final stemBlock = find.descendant(
        of: find.byType(RichContentRenderer).first,
        matching: find.byType(SingleChildScrollView),
      );
      expect(stemBlock, findsOneWidget);
      expect(find.text('Option A text'), findsOneWidget);
      expect(find.text('Explanation'), findsOneWidget);
      expect(find.text('Unsupported content: future_table'), findsOneWidget);
      expect(find.textContaining('DO_NOT_RENDER'), findsNothing);

      final answerParagraph = find
          .descendant(
            of: find.byType(RichContentRenderer).at(2),
            matching: find.byType(RichText),
          )
          .first;
      final orderYs = <double>[
        tester.getTopLeft(stemParagraph).dy,
        tester.getTopLeft(stemBlock).dy,
        tester.getTopLeft(find.text('Option A text')).dy,
        tester.getTopLeft(answerParagraph).dy,
        tester.getTopLeft(find.text('Explanation')).dy,
        tester.getTopLeft(find.text('Unsupported content: future_table')).dy,
      ];
      expect(orderYs, orderedEquals(List<double>.from(orderYs)..sort()));
    });
  });
}
