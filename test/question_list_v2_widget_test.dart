// R7D QuestionListScreen widget acceptance (fake repository, synthetic
// fixtures; no real database, OCR, Provider, or network).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/ui/pages/question_edit_screen.dart';
import 'package:shiroha_quiz/ui/pages/question_list_screen.dart';
import 'package:shiroha_quiz/ui/widgets/persisted_question_card.dart';

const _bankName = 'synthetic_bank';

RichContent _text(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

class _FakeQuestionRepository extends Fake implements QuestionRepository {
  _FakeQuestionRepository({List<PersistedQuestion> persisted = const []})
      : persisted = List<PersistedQuestion>.from(persisted);

  List<PersistedQuestion> persisted;
  bool failLoad = false;
  bool failDelete = false;
  int persistedCalls = 0;
  final List<String> deletedIds = <String>[];

  @override
  Future<List<PersistedQuestion>> getPersistedQuestionsByBank(
    String bankName,
  ) async {
    persistedCalls++;
    if (failLoad) throw StateError('synthetic load failure');
    return List<PersistedQuestion>.from(persisted);
  }

  @override
  Future<void> deleteQuestion(String id) async {
    deletedIds.add(id);
    if (failDelete) throw StateError('synthetic delete failure');
    persisted =
        persisted.where((question) => question.storageId != id).toList();
  }
}

TypedPersistedQuestion _typedRow(
  String storageId, {
  String stem = 'Typed stem marker.',
  List<QuestionOption> options = const <QuestionOption>[],
  QuestionAnswer? answer,
  RichContent? explanation,
  int createdAt = 2,
}) {
  return TypedPersistedQuestion(
    storageId: storageId,
    bankName: _bankName,
    createdAt: createdAt,
    draft: QuestionDraftV2(
      questionId: 'typed_question_$storageId',
      kind: QuestionKind.singleChoice,
      stem: _text(stem),
      options: options,
      answer: answer,
      explanation: explanation,
    ),
  );
}

LegacyPersistedQuestion _legacyRow(
  String storageId, {
  String content = 'Legacy content marker.',
  String options = '["legacy option marker"]',
  String answer = 'Legacy-Answer-Marker',
  String? explanation = 'Legacy explanation marker.',
}) {
  return LegacyPersistedQuestion(
    question: Question(
      id: storageId,
      type: 3,
      content: content,
      options: options,
      answer: answer,
      createdAt: 1,
      bankName: _bankName,
      explanation: explanation,
    ),
  );
}

Future<void> _pumpScreen(
  WidgetTester tester,
  _FakeQuestionRepository repository, {
  ValueChanged<int?>? onLoadFinished,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: QuestionListScreen(
        bankName: _bankName,
        questionRepository: repository,
        onLoadFinished: onLoadFinished,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}

void main() {
  testWidgets('51/52/53: initial load reads only the V2-first union',
      (tester) async {
    final repository = _FakeQuestionRepository(
      persisted: <PersistedQuestion>[
        _typedRow('typed_1'),
        _legacyRow('legacy_1'),
      ],
    );
    await _pumpScreen(tester, repository);

    expect(repository.persistedCalls, 1);
  });

  testWidgets('54: mixed typed and legacy rows render together',
      (tester) async {
    final repository = _FakeQuestionRepository(
      persisted: <PersistedQuestion>[
        _typedRow('typed_1'),
        _legacyRow('legacy_1'),
      ],
    );
    await _pumpScreen(tester, repository);

    expect(find.byType(PersistedQuestionCard), findsNWidgets(2));
    expect(find.text('Typed stem marker.'), findsOneWidget);
    expect(find.text('Legacy content marker.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('55: onLoadFinished receives the full count', (tester) async {
    int? lastCount = -1;
    final repository = _FakeQuestionRepository(
      persisted: <PersistedQuestion>[
        _typedRow('typed_1'),
        _legacyRow('legacy_1'),
      ],
    );
    await _pumpScreen(
      tester,
      repository,
      onLoadFinished: (count) => lastCount = count,
    );

    expect(lastCount, 2);
  });

  testWidgets('56/57: search filters in memory and clearing restores all',
      (tester) async {
    final repository = _FakeQuestionRepository(
      persisted: <PersistedQuestion>[
        _typedRow('typed_1'),
        _legacyRow('legacy_1'),
      ],
    );
    await _pumpScreen(tester, repository);

    await _search(tester, 'Legacy content marker');
    expect(find.byType(PersistedQuestionCard), findsOneWidget);
    expect(repository.persistedCalls, 1);

    await _search(tester, '');
    expect(find.byType(PersistedQuestionCard), findsNWidgets(2));
  });

  testWidgets(
      '58/59/60/61/62: typed stem, option, answer, explanation, '
      'and math latex are searchable', (tester) async {
    final repository = _FakeQuestionRepository(
      persisted: <PersistedQuestion>[
        TypedPersistedQuestion(
          storageId: 'typed_stem',
          bankName: _bankName,
          createdAt: 2,
          draft: QuestionDraftV2(
            questionId: 'q_stem',
            kind: QuestionKind.singleChoice,
            stem: RichContent(nodes: const <ContentNode>[
              TextNode('Typed stem marker.'),
              InlineMathNode(r'x^2'),
            ]),
          ),
        ),
        _typedRow(
          'typed_option',
          stem: 'Option row.',
          options: <QuestionOption>[
            QuestionOption(
              optionId: 'z',
              label: 'Z',
              content: _text('typed option marker'),
            ),
          ],
        ),
        _typedRow(
          'typed_answer',
          stem: 'Answer row.',
          answer: ContentAnswer(content: _text('typed answer marker')),
        ),
        _typedRow(
          'typed_explanation',
          stem: 'Explanation row.',
          explanation: _text('typed explanation marker'),
        ),
      ],
    );
    await _pumpScreen(tester, repository);

    await _search(tester, 'Typed stem marker');
    expect(find.byType(PersistedQuestionCard), findsOneWidget);

    await _search(tester, 'typed option marker');
    expect(find.byType(PersistedQuestionCard), findsOneWidget);

    await _search(tester, 'typed answer marker');
    expect(find.byType(PersistedQuestionCard), findsOneWidget);

    await _search(tester, 'typed explanation marker');
    expect(find.byType(PersistedQuestionCard), findsOneWidget);

    await _search(tester, r'x^2');
    expect(find.byType(PersistedQuestionCard), findsOneWidget);
  });

  testWidgets('63: RawFallback payloads cannot be found by search',
      (tester) async {
    final repository = _FakeQuestionRepository(
      persisted: <PersistedQuestion>[
        TypedPersistedQuestion(
          storageId: 'typed_raw',
          bankName: _bankName,
          createdAt: 2,
          draft: QuestionDraftV2(
            questionId: 'q_raw',
            kind: QuestionKind.singleChoice,
            stem: RichContent(nodes: <ContentNode>[
              TextNode('raw fallback visible'),
              RawFallbackNode(<String, Object?>{
                'type': 'future_table',
                'payload': <String, Object?>{'secret': 'DO_NOT_RENDER'},
              }),
            ]),
          ),
        ),
      ],
    );
    await _pumpScreen(tester, repository);

    await _search(tester, 'DO_NOT_RENDER');
    expect(find.byType(PersistedQuestionCard), findsNothing);
    expect(find.text('没有找到匹配的题目'), findsOneWidget);

    await _search(tester, 'raw fallback visible');
    expect(find.byType(PersistedQuestionCard), findsOneWidget);
  });

  testWidgets(
      '64/65/66/67: legacy content, option, answer, and explanation '
      'are searchable', (tester) async {
    final repository = _FakeQuestionRepository(
      persisted: <PersistedQuestion>[
        _legacyRow('legacy_1'),
      ],
    );
    await _pumpScreen(tester, repository);

    await _search(tester, 'Legacy content marker');
    expect(find.byType(PersistedQuestionCard), findsOneWidget);

    await _search(tester, 'legacy option marker');
    expect(find.byType(PersistedQuestionCard), findsOneWidget);

    await _search(tester, 'Legacy-Answer-Marker');
    expect(find.byType(PersistedQuestionCard), findsOneWidget);

    await _search(tester, 'Legacy explanation marker');
    expect(find.byType(PersistedQuestionCard), findsOneWidget);
  });

  testWidgets('68: typed rows cannot open the legacy editor', (tester) async {
    final repository = _FakeQuestionRepository(
      persisted: <PersistedQuestion>[
        _typedRow('typed_1'),
      ],
    );
    await _pumpScreen(tester, repository);

    await tester.tap(find.text('编辑题目'));
    await tester.pumpAndSettle();

    expect(find.byType(QuestionEditScreen), findsNothing);
    expect(find.text('结构化题目暂不支持在旧编辑器中修改'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('69: legacy rows can open the legacy editor', (tester) async {
    final repository = _FakeQuestionRepository(
      persisted: <PersistedQuestion>[
        _legacyRow('legacy_1'),
      ],
    );
    await _pumpScreen(tester, repository);

    await tester.tap(find.text('编辑题目'));
    await tester.pumpAndSettle();

    expect(find.byType(QuestionEditScreen), findsOneWidget);
  });

  testWidgets('70: legacy editor success reloads the union', (tester) async {
    final repository = _FakeQuestionRepository(
      persisted: <PersistedQuestion>[
        _legacyRow('legacy_1'),
      ],
    );
    await _pumpScreen(tester, repository);
    expect(repository.persistedCalls, 1);

    await tester.tap(find.text('编辑题目'));
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.pop(true);
    await tester.pumpAndSettle();

    expect(repository.persistedCalls, 2);
    expect(find.byType(QuestionEditScreen), findsNothing);
  });

  testWidgets('71/72: typed and legacy deletes pass the storage id',
      (tester) async {
    final repository = _FakeQuestionRepository(
      persisted: <PersistedQuestion>[
        _typedRow('typed_storage_1'),
        _legacyRow('legacy_storage_1'),
      ],
    );
    await _pumpScreen(tester, repository);

    final typedCard = find.ancestor(
      of: find.text('结构化'),
      matching: find.byType(PersistedQuestionCard),
    );
    await tester.tap(
      find.descendant(
        of: typedCard,
        matching: find.byIcon(Icons.delete_outline),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, '删除'));
    await tester.pumpAndSettle();
    expect(repository.deletedIds, contains('typed_storage_1'));

    final legacyCard = find.ancestor(
      of: find.text('Legacy content marker.'),
      matching: find.byType(PersistedQuestionCard),
    );
    await tester.tap(
      find.descendant(
        of: legacyCard,
        matching: find.byIcon(Icons.delete_outline),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, '删除'));
    await tester.pumpAndSettle();
    expect(repository.deletedIds, contains('legacy_storage_1'));
  });

  testWidgets('73: delete reloads the union and re-applies the query',
      (tester) async {
    final repository = _FakeQuestionRepository(
      persisted: <PersistedQuestion>[
        _typedRow('typed_keep', stem: 'Keep me visible.'),
        _legacyRow('legacy_remove', content: 'Remove me marker.'),
      ],
    );
    await _pumpScreen(tester, repository);

    await _search(tester, 'Remove me marker');
    expect(find.byType(PersistedQuestionCard), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, '删除'));
    await tester.pumpAndSettle();

    expect(repository.persistedCalls, 2);
    expect(find.byType(PersistedQuestionCard), findsNothing);
    expect(find.text('没有找到匹配的题目'), findsOneWidget);
  });

  testWidgets(
      '74/75/76/77: load failure shows the fixed error page with no '
      'fallback', (tester) async {
    int? lastCount = -1;
    final repository = _FakeQuestionRepository(
      persisted: <PersistedQuestion>[
        _legacyRow('legacy_1'),
      ],
    )..failLoad = true;
    await _pumpScreen(
      tester,
      repository,
      onLoadFinished: (count) => lastCount = count,
    );

    expect(find.text('题库中存在无法安全读取的题目，请重试或修复数据'), findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);
    expect(find.textContaining('StateError'), findsNothing);
    expect(find.textContaining('synthetic load failure'), findsNothing);
    expect(find.byType(PersistedQuestionCard), findsNothing);
    expect(lastCount, isNull);
  });

  testWidgets('78: retry reloads the union', (tester) async {
    final repository = _FakeQuestionRepository(persisted: const [])
      ..failLoad = true;
    await _pumpScreen(tester, repository);
    expect(find.text('题库中存在无法安全读取的题目，请重试或修复数据'), findsOneWidget);

    repository
      ..failLoad = false
      ..persisted = <PersistedQuestion>[_typedRow('typed_1')];
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(repository.persistedCalls, 2);
    expect(find.byType(PersistedQuestionCard), findsOneWidget);
  });

  testWidgets('79/80: delete failure shows the fixed message only',
      (tester) async {
    final repository = _FakeQuestionRepository(
      persisted: <PersistedQuestion>[
        _typedRow('typed_1'),
      ],
    )..failDelete = true;
    await _pumpScreen(tester, repository);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('删除失败，请稍后重试'), findsOneWidget);
    expect(find.textContaining('StateError'), findsNothing);
    expect(repository.deletedIds, contains('typed_1'));
  });
}
