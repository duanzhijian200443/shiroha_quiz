// R8B WrongBookPage V2-first acceptance (fake repository, synthetic
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
import 'package:shiroha_quiz/ui/pages/wrong_book_page.dart';
import 'package:shiroha_quiz/ui/widgets/persisted_question_card.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';

RichContent _text(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

PersistedQuestionReviewMetrics _metrics({
  int lapses = 1,
  double difficulty = 5.0,
  double stability = 1.0,
  int lastLapseTime = 100,
}) {
  return PersistedQuestionReviewMetrics(
    lapses: lapses,
    difficulty: difficulty,
    stability: stability,
    lastLapseTime: lastLapseTime,
  );
}

class _FakeQuestionRepository extends Fake implements QuestionRepository {
  _FakeQuestionRepository({required List<PersistedQuestion> allQuestions})
      : allQuestions = List<PersistedQuestion>.from(allQuestions);

  /// Full store, including non-lapsed controls. The fake mirrors the frozen
  /// SQL contract: `lapses > 0` filter + `last_lapse_time DESC` ordering.
  final List<PersistedQuestion> allQuestions;
  final List<String> deletedIds = <String>[];
  int wrongReadCalls = 0;
  bool failLoad = false;
  bool failDelete = false;

  @override
  Future<List<PersistedQuestion>> getPersistedWrongQuestions() async {
    wrongReadCalls++;
    if (failLoad) throw StateError('synthetic load failure');
    final lapsed = allQuestions
        .where((question) => (question.reviewMetrics?.lapses ?? 0) > 0)
        .toList()
      ..sort(
        (a, b) => (b.reviewMetrics?.lastLapseTime ?? 0)
            .compareTo(a.reviewMetrics?.lastLapseTime ?? 0),
      );
    return lapsed;
  }

  @override
  Future<void> deleteQuestion(String id) async {
    deletedIds.add(id);
    if (failDelete) throw StateError('synthetic delete failure');
    // FK-cascade analog: the sidecar-backed typed row disappears with its
    // parent row.
    allQuestions.removeWhere((question) => question.storageId == id);
  }
}

TypedPersistedQuestion _typedRow(
  String storageId, {
  RichContent? stem,
  PersistedQuestionReviewMetrics? reviewMetrics,
}) {
  return TypedPersistedQuestion(
    storageId: storageId,
    bankName: 'synthetic_bank',
    createdAt: 2,
    draft: QuestionDraftV2(
      questionId: 'typed_question_$storageId',
      kind: QuestionKind.singleChoice,
      stem: stem ?? _text('Typed wrong stem.'),
    ),
    // Wrong-book rows always carry review metrics (the read joins
    // review_states); null in the fixture means "not lapsed" to the fake.
    reviewMetrics: reviewMetrics ?? _metrics(),
  );
}

LegacyPersistedQuestion _legacyRow(
  String storageId, {
  String content = 'Legacy wrong content.',
  PersistedQuestionReviewMetrics? reviewMetrics,
}) {
  return LegacyPersistedQuestion(
    question: Question(
      id: storageId,
      type: 0,
      content: content,
      options: '["A. legacy option body"]',
      answer: 'A',
      createdAt: 1,
      bankName: 'synthetic_bank',
      explanation: 'Legacy explanation.',
    ),
    reviewMetrics: reviewMetrics ?? _metrics(),
  );
}

Future<void> _pumpPage(
  WidgetTester tester,
  _FakeQuestionRepository repository,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: WrongBookPage(questionRepository: repository),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    '81: mixed bank renders only wrong rows via the union read',
    (tester) async {
      final repository = _FakeQuestionRepository(
        allQuestions: <PersistedQuestion>[
          _typedRow(
            'typed_lapsed',
            stem: _text('Typed sidecar stem.'),
            reviewMetrics: _metrics(lapses: 2, difficulty: 6.5, stability: 3.2),
          ),
          _legacyRow(
            'legacy_lapsed',
            content: 'Legacy lapsed content.',
            reviewMetrics: _metrics(lapses: 1),
          ),
          _legacyRow(
            'control_not_lapsed',
            content: 'Non-lapsed control marker.',
            reviewMetrics: _metrics(lapses: 0, lastLapseTime: 500),
          ),
        ],
      );
      await _pumpPage(tester, repository);

      expect(repository.wrongReadCalls, 1);
      expect(find.byType(PersistedQuestionCard), findsNWidgets(2));
      expect(find.text('Typed sidecar stem.'), findsOneWidget);
      expect(find.text('Legacy lapsed content.'), findsOneWidget);
      expect(find.text('Non-lapsed control marker.'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '82: typed rows render sidecar authority with no V1 decoy',
    (tester) async {
      final repository = _FakeQuestionRepository(
        allQuestions: <PersistedQuestion>[
          _typedRow('typed_lapsed', stem: _text('Typed sidecar stem.')),
        ],
      );
      await _pumpPage(tester, repository);

      expect(find.text('Typed sidecar stem.'), findsOneWidget);
      // The V1 compatibility placeholder must never surface for typed rows,
      // and typed content never goes through the legacy renderer.
      expect(find.text('无题干'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(PersistedQuestionCard),
          matching: find.byType(StructuredContentRenderer),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '83: list order follows the repository last_lapse_time DESC order',
    (tester) async {
      final repository = _FakeQuestionRepository(
        allQuestions: <PersistedQuestion>[
          _legacyRow(
            'older',
            content: 'Older lapse.',
            reviewMetrics: _metrics(lastLapseTime: 100),
          ),
          _typedRow(
            'newer',
            stem: _text('Newer lapse.'),
            reviewMetrics: _metrics(lastLapseTime: 300),
          ),
        ],
      );
      await _pumpPage(tester, repository);

      final newerY = tester.getTopLeft(find.text('Newer lapse.')).dy;
      final olderY = tester.getTopLeft(find.text('Older lapse.')).dy;
      expect(newerY, lessThan(olderY));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '84: typed explicit empty stem never falls back to a decoy',
    (tester) async {
      final repository = _FakeQuestionRepository(
        allQuestions: <PersistedQuestion>[
          _typedRow(
            'typed_empty',
            stem: RichContent(nodes: const <ContentNode>[]),
            reviewMetrics: _metrics(),
          ),
        ],
      );
      await _pumpPage(tester, repository);

      expect(find.text('无题干'), findsNothing);
      expect(find.textContaining('Typed wrong stem.'), findsNothing);
      expect(
        find.text('暂无答案；结构化题目暂不支持旧编辑器修改'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '85: review metrics render from reviewMetrics for typed and legacy rows',
    (tester) async {
      final repository = _FakeQuestionRepository(
        allQuestions: <PersistedQuestion>[
          _typedRow(
            'typed_lapsed',
            stem: _text('Typed metrics stem.'),
            reviewMetrics: _metrics(lapses: 2, difficulty: 6.5, stability: 3.2),
          ),
          _legacyRow(
            'legacy_lapsed',
            content: 'Legacy metrics content.',
            reviewMetrics: _metrics(lapses: 4, difficulty: 7.0, stability: 5.5),
          ),
        ],
      );
      await _pumpPage(tester, repository);

      expect(find.text('错误次数：2'), findsOneWidget);
      expect(find.text('难度系数：6.50'), findsOneWidget);
      expect(find.text('稳定性：3.20'), findsOneWidget);
      expect(find.text('错误次数：4'), findsOneWidget);
      expect(find.text('难度系数：7.00'), findsOneWidget);
      expect(find.text('稳定性：5.50'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '86: typed rows cannot open the legacy editor',
    (tester) async {
      final repository = _FakeQuestionRepository(
        allQuestions: <PersistedQuestion>[
          _typedRow('typed_lapsed', stem: _text('Typed stem.')),
        ],
      );
      await _pumpPage(tester, repository);

      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '编辑题目'),
      );
      expect(button.onPressed, isNull);

      await tester.tap(find.text('编辑题目'));
      await tester.pumpAndSettle();
      expect(find.byType(QuestionEditScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '87: legacy rows keep the legacy editor and reload on success',
    (tester) async {
      final repository = _FakeQuestionRepository(
        allQuestions: <PersistedQuestion>[
          _legacyRow('legacy_lapsed', content: 'Legacy content.'),
        ],
      );
      await _pumpPage(tester, repository);
      expect(repository.wrongReadCalls, 1);

      await tester.tap(find.text('编辑题目'));
      await tester.pumpAndSettle();
      expect(find.byType(QuestionEditScreen), findsOneWidget);

      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      navigator.pop(true);
      await tester.pumpAndSettle();

      expect(find.byType(QuestionEditScreen), findsNothing);
      expect(repository.wrongReadCalls, 2);
    },
  );

  testWidgets(
    '88: typed delete passes the storage id and reloads (sidecar cascade)',
    (tester) async {
      final repository = _FakeQuestionRepository(
        allQuestions: <PersistedQuestion>[
          _typedRow('typed_delete', stem: _text('Delete me.')),
          _legacyRow('legacy_keep', content: 'Keep me.'),
        ],
      );
      await _pumpPage(tester, repository);

      final typedCard = find.ancestor(
        of: find.text('Delete me.'),
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

      expect(repository.deletedIds, <String>['typed_delete']);
      expect(repository.wrongReadCalls, 2);
      expect(find.text('Delete me.'), findsNothing);
      expect(find.text('Keep me.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '89: delete failure shows the fixed message only',
    (tester) async {
      final repository = _FakeQuestionRepository(
        allQuestions: <PersistedQuestion>[
          _typedRow('typed_fail', stem: _text('Stem.')),
        ],
      )..failDelete = true;
      await _pumpPage(tester, repository);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, '删除'));
      await tester.pumpAndSettle();

      expect(find.text('删除失败，请稍后重试'), findsOneWidget);
      expect(find.textContaining('StateError'), findsNothing);
      expect(repository.deletedIds, contains('typed_fail'));
    },
  );

  testWidgets(
    '90/91: load failure shows the fixed error page and retry reloads',
    (tester) async {
      final repository = _FakeQuestionRepository(
        allQuestions: <PersistedQuestion>[
          _legacyRow('legacy_lapsed'),
        ],
      )..failLoad = true;
      await _pumpPage(tester, repository);

      expect(
        find.text('错题本中存在无法安全读取的题目，请重试或修复数据'),
        findsOneWidget,
      );
      expect(find.textContaining('StateError'), findsNothing);
      expect(find.textContaining('synthetic load failure'), findsNothing);
      expect(find.byType(PersistedQuestionCard), findsNothing);

      repository.failLoad = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(repository.wrongReadCalls, 2);
      expect(find.byType(PersistedQuestionCard), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
