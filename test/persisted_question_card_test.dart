// R7D PersistedQuestionCard widget acceptance (synthetic fixtures only).
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/ui/models/persisted_question_view.dart';
import 'package:shiroha_quiz/ui/widgets/persisted_question_card.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';

const _storageId = '11111111-2222-4333-8444-555555555555';

RichContent _text(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

PersistedQuestionView _typedView(QuestionDraftV2 draft) {
  return PersistedQuestionViewAdapter.fromPersisted(
    TypedPersistedQuestion(
      storageId: _storageId,
      bankName: 'synthetic_bank',
      createdAt: 1,
      draft: draft,
    ),
  );
}

PersistedQuestionView _legacyView({
  int type = 0,
  String content = 'Legacy stem text.',
  String options = '["A. legacy option body"]',
  String answer = 'A',
  String explanation = 'Legacy explanation.',
}) {
  return PersistedQuestionViewAdapter.fromPersisted(
    LegacyPersistedQuestion(
      question: Question(
        id: 'legacy_1',
        type: type,
        content: content,
        options: options,
        answer: answer,
        createdAt: 1,
        bankName: 'synthetic_bank',
        explanation: explanation,
      ),
    ),
  );
}

QuestionDraftV2 _richTypedDraft() {
  return QuestionDraftV2(
    questionId: 'card_typed_001',
    kind: QuestionKind.singleChoice,
    stem: RichContent(nodes: <ContentNode>[
      TextNode('Typed stem.'),
      BlockMathNode(r'\int_0^1 x\,dx'),
      TextNode(' After '),
      InlineMathNode(r'x^2'),
      TextNode(' math.'),
      RawFallbackNode(<String, Object?>{
        'type': 'future_table',
        'payload': <String, Object?>{'secret': 'DO_NOT_RENDER'},
      }),
    ]),
    options: <QuestionOption>[
      QuestionOption(
        optionId: 'a',
        label: 'A',
        content: _text('Option one'),
      ),
      QuestionOption(
        optionId: 'b',
        label: 'B',
        content:
            RichContent(nodes: const <ContentNode>[InlineMathNode(r'y^2')]),
      ),
    ],
    answer: ChoiceAnswer(optionIds: <String>['a']),
    explanation: _text('Typed explanation.'),
  );
}

Widget _host(Widget child, {ThemeData? theme}) {
  return MaterialApp(
    theme: theme,
    home: Scaffold(
      body: SingleChildScrollView(child: child),
    ),
  );
}

Widget _card(
  PersistedQuestionView view, {
  VoidCallback? onDelete,
  VoidCallback? onEditLegacy,
}) {
  return PersistedQuestionCard(
    question: view,
    onDelete: onDelete ?? () {},
    onEditLegacy: onEditLegacy,
  );
}

void main() {
  group('typed rendering', () {
    testWidgets('29: typed TextNode is not re-parsed as math', (tester) async {
      final view = _typedView(
        QuestionDraftV2(
          questionId: 'card_typed_002',
          kind: QuestionKind.singleChoice,
          stem: RichContent(nodes: const <ContentNode>[
            TextNode(r'Literal \(x\), \[y\], ![a](sandbox://asset).'),
          ]),
        ),
      );
      await tester.pumpWidget(_host(_card(view)));

      expect(find.byType(Math), findsNothing);
      expect(find.byType(BlankTokenWidget), findsNothing);
      expect(
        find.textContaining(r'Literal \(x\)'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('30: typed InlineMathNode renders the Math widget',
        (tester) async {
      final view = _typedView(
        QuestionDraftV2(
          questionId: 'card_typed_003',
          kind: QuestionKind.singleChoice,
          stem: RichContent(nodes: const <ContentNode>[
            TextNode('Before '),
            InlineMathNode(r'x^2'),
            TextNode(' after'),
          ]),
        ),
      );
      await tester.pumpWidget(_host(_card(view)));

      expect(find.byType(Math), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(Math),
          matching: find.byType(FittedBox),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('31: typed BlockMathNode renders block math', (tester) async {
      final view = _typedView(
        QuestionDraftV2(
          questionId: 'card_typed_004',
          kind: QuestionKind.singleChoice,
          stem: RichContent(nodes: const <ContentNode>[
            TextNode('Before'),
            BlockMathNode(r'\begin{pmatrix}1&2\\3&4\end{pmatrix}'),
            TextNode('After'),
          ]),
        ),
      );
      await tester.pumpWidget(_host(_card(view)));

      expect(find.byType(Math), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(Math),
          matching: find.byType(SingleChildScrollView),
        ),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('32/33: RawFallback shows the generic placeholder only',
        (tester) async {
      final view = _typedView(_richTypedDraft());
      await tester.pumpWidget(_host(_card(view)));

      expect(find.text('Unsupported content: future_table'), findsOneWidget);
      expect(find.textContaining('DO_NOT_RENDER'), findsNothing);
      expect(find.textContaining('secret', findRichText: true), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '34: typed explicit empty content never falls back to '
        'compatibility text', (tester) async {
      final view = _typedView(
        QuestionDraftV2(
          questionId: 'card_typed_005',
          kind: QuestionKind.singleChoice,
          stem: RichContent(nodes: const <ContentNode>[]),
        ),
      );
      await tester.pumpWidget(_host(_card(view)));

      expect(find.text('无题干'), findsNothing);
      expect(find.textContaining('Typed stem.'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('36: typed options render per-item RichContent',
        (tester) async {
      final view = _typedView(_richTypedDraft());
      await tester.pumpWidget(_host(_card(view)));

      expect(find.text('Option one'), findsOneWidget);
      expect(find.text('A.'), findsOneWidget);
      expect(find.text('B.'), findsOneWidget);
      expect(find.byType(RichContentRenderer), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('38: typed ChoiceAnswer displays the option labels',
        (tester) async {
      final view = _typedView(_richTypedDraft());
      await tester.pumpWidget(_host(_card(view)));

      expect(find.text('A'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('39: typed null answer shows the fixed empty state',
        (tester) async {
      final view = _typedView(
        QuestionDraftV2(
          questionId: 'card_typed_006',
          kind: QuestionKind.singleChoice,
          stem: _text('Stem.'),
          answer: null,
          explanation: null,
        ),
      );
      await tester.pumpWidget(_host(_card(view)));

      expect(
        find.text('暂无答案；结构化题目暂不支持旧编辑器修改'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('40: typed null explanation shows 无解析', (tester) async {
      final view = _typedView(
        QuestionDraftV2(
          questionId: 'card_typed_007',
          kind: QuestionKind.singleChoice,
          stem: _text('Stem.'),
          answer: ContentAnswer(content: _text('answer')),
          explanation: null,
        ),
      );
      await tester.pumpWidget(_host(_card(view)));

      expect(find.text('无解析'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('47: fillBlank typed options stay visible when non-empty',
        (tester) async {
      final view = _typedView(
        QuestionDraftV2(
          questionId: 'card_typed_008',
          kind: QuestionKind.fillBlank,
          stem: _text('Fill stem.'),
          options: <QuestionOption>[
            QuestionOption(
              optionId: 'f1',
              label: 'A',
              content: _text('Fill option one'),
            ),
          ],
          answer: ContentAnswer(content: _text('computed')),
        ),
      );
      await tester.pumpWidget(_host(_card(view)));

      expect(find.text('Fill option one'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('48: typed cards show the 结构化 badge', (tester) async {
      final view = _typedView(_richTypedDraft());
      await tester.pumpWidget(_host(_card(view)));

      expect(find.text('结构化'), findsOneWidget);
      expect(find.text('单选'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('legacy rendering', () {
    testWidgets('35: legacy stem keeps the legacy renderer', (tester) async {
      final view = _legacyView();
      await tester.pumpWidget(_host(_card(view)));

      expect(find.byType(StructuredContentRenderer), findsWidgets);
      expect(find.text('Legacy stem text.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('37: legacy options render per-item with a separate label',
        (tester) async {
      final view = _legacyView();
      await tester.pumpWidget(_host(_card(view)));

      expect(find.text('A.'), findsOneWidget);
      expect(find.text('legacy option body'), findsOneWidget);
      expect(find.text('A. legacy option body'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('edit and delete wiring', () {
    testWidgets('41: typed edit button is disabled', (tester) async {
      final view = _typedView(_richTypedDraft());
      await tester.pumpWidget(_host(_card(view)));

      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '编辑题目'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('42: typed edit never invokes the legacy callback',
        (tester) async {
      var legacyEditCalls = 0;
      final view = _typedView(_richTypedDraft());
      await tester.pumpWidget(
        _host(
          _card(view, onEditLegacy: () => legacyEditCalls++),
        ),
      );

      await tester.tap(find.text('编辑题目'));
      await tester.pump();
      expect(legacyEditCalls, 0);
    });

    testWidgets('43/44: legacy edit is enabled and calls the callback',
        (tester) async {
      var legacyEditCalls = 0;
      final view = _legacyView();
      await tester.pumpWidget(
        _host(_card(view, onEditLegacy: () => legacyEditCalls++)),
      );

      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '编辑题目'),
      );
      expect(button.onPressed, isNotNull);

      await tester.tap(find.text('编辑题目'));
      await tester.pump();
      expect(legacyEditCalls, 1);
    });

    testWidgets('45: typed delete invokes the delete callback', (tester) async {
      var deleteCalls = 0;
      final view = _typedView(_richTypedDraft());
      await tester
          .pumpWidget(_host(_card(view, onDelete: () => deleteCalls++)));

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pump();
      expect(deleteCalls, 1);
    });

    testWidgets('46: legacy delete invokes the delete callback',
        (tester) async {
      var deleteCalls = 0;
      final view = _legacyView();
      await tester
          .pumpWidget(_host(_card(view, onDelete: () => deleteCalls++)));

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pump();
      expect(deleteCalls, 1);
    });
  });

  group('theme robustness', () {
    testWidgets('49: dark theme renders without exceptions', (tester) async {
      final view = _typedView(_richTypedDraft());
      await tester.pumpWidget(
        _host(_card(view), theme: ThemeData(brightness: Brightness.dark)),
      );

      expect(find.text('Typed stem.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('50: large text scaling renders without exceptions',
        (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final view = _typedView(_richTypedDraft());
      await tester.pumpWidget(_host(_card(view)));

      expect(tester.takeException(), isNull);
      expect(find.text('Typed stem.'), findsOneWidget);
    });
  });
}
