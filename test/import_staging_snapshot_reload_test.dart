import 'dart:convert';

import 'package:flutter/material.dart' hide TableRow, TableCell;
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/content/content_asset_authority.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/application/questions/folder_query_port.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/content/rich_content_text_projection.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';

/// Reload regression for persisted Review drafts.
///
/// A saved draft hands the typed envelope over as a decoded map (the shape
/// `jsonDecode` produces from `import_tasks.parsed_data`), not as the
/// character-keyed wrapper `TypedReviewSnapshotCodec.containsEnvelope`
/// inspects. Registration must therefore decide from the envelope payload
/// itself, otherwise the Review preview silently drops every typed snapshot and
/// renders its configured explanation through the plain Markdown path, where
/// `TableNode` has no representation at all.
///
/// The envelopes below are produced by the real codec and then round-tripped
/// through JSON, so the fixtures carry exactly the persisted shape.
const _sourceId = '11111111-1111-4111-8111-000000000001';
const _questionId = '22222222-2222-4222-8222-000000000001';
const _itemId = '44444444-4444-4444-8444-000000000001';

class _Folders implements FolderQueryPort {
  @override
  Future<List<String>> listAvailableFolders() async => [];
}

class _Resolver implements ContentAssetResolver {
  final calls = <(String, String)>[];

  @override
  List<int>? resolveAssetBytes({
    required String sourceId,
    required String localAssetId,
  }) =>
      throw StateError('Synchronous resolution is forbidden');

  @override
  Future<List<int>?> resolveAssetBytesAsync({
    required String sourceId,
    required String localAssetId,
  }) async {
    calls.add((sourceId, localAssetId));
    return const <int>[];
  }
}

RichContent _text(String value) => RichContent(nodes: [TextNode(value)]);

RichContent _tableExplanation() => RichContent(nodes: <ContentNode>[
      const TextNode('Synthetic lead '),
      TableNode(
        structure: TableStructure(rows: [
          TableRow(cells: [
            TableCell(content: _text('left cell')),
            TableCell(content: _text('right cell')),
          ]),
        ]),
      ),
      const TextNode(' trailing'),
    ]);

QuestionDraftV2 _draft({required QuestionKind kind}) => QuestionDraftV2(
      questionId: _questionId,
      kind: kind,
      questionNumber: 5,
      stem: _text('Synthetic stem'),
      options: [
        QuestionOption(optionId: 'a', label: 'A', content: _text('alpha')),
        QuestionOption(optionId: 'b', label: 'B', content: _text('beta')),
      ],
      answer: ChoiceAnswer(optionIds: const ['a']),
      explanation: _tableExplanation(),
      sourceRefs: [SourceRef.document(sourceId: _sourceId)],
      assetRefs: const [],
    );

LegacyReviewBaseline _baseline(
        {required int type, required String explanation}) =>
    LegacyReviewBaseline(
      type: type,
      questionNumber: 5,
      content: 'Synthetic stem',
      options: const ['A. alpha', 'B. beta'],
      standardAnswer: 'A',
      explanation: explanation,
    );

/// Builds the persisted question map for one review item and round-trips it
/// through JSON so the envelope arrives as a map, exactly as after a reload.
Map<String, dynamic> _persistedQuestion({
  required TypedReviewSnapshot snapshot,
  required String explanation,
  required String rawExplanation,
  bool bareEnvelope = false,
}) {
  final envelope = const TypedReviewSnapshotCodec().encode(snapshot);
  return jsonDecode(jsonEncode(<String, dynamic>{
    'type': snapshot.baselineLegacy.type,
    'question_number': 5,
    'content': snapshot.baselineLegacy.content,
    'options': snapshot.baselineLegacy.options,
    'standard_answer': snapshot.baselineLegacy.standardAnswer,
    'explanation': explanation,
    'raw_explanation': rawExplanation,
    TaskManager.keyReviewItemId: snapshot.reviewItemId,
    TypedReviewSnapshotCodec.mapKey: bareEnvelope
        ? envelope
        : <String, dynamic>{TypedReviewSnapshotCodec.mapKey: envelope},
  })) as Map<String, dynamic>;
}

Future<void> _open(
  WidgetTester tester,
  Map<String, dynamic> question, {
  required _Resolver resolver,
  ExplanationRetentionMode mode = ExplanationRetentionMode.allQuestionTypes,
}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 2200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: ContentAssetResolverScope(
      resolver: resolver,
      child: ImportStagingScreen(
        parsedQuestions: [question],
        folderQuery: _Folders(),
        taskManager: TaskManager.forTesting(),
        initialExplanationRetentionMode: mode,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Finder _tableAnchor(int row, int column) =>
    find.byKey(ValueKey('rich-table-anchor-$row-$column'));

Finder _typedContent(RichContent content) => find.byWidgetPredicate(
    (widget) => widget is RichContentRenderer && widget.content == content);

void main() {
  testWidgets(
      'persisted map envelope registers and renders the typed explanation table',
      (tester) async {
    final explanation = _tableExplanation();
    final projected = const RichContentTextProjection().project(explanation);
    final snapshot = TypedReviewSnapshot(
      reviewItemId: _itemId,
      questionId: _questionId,
      draft: _draft(kind: QuestionKind.singleChoice),
      baselineLegacy: _baseline(type: 0, explanation: projected),
    );
    // The configured text is the exact projection, so the retained typed
    // content stays authoritative for the preview.
    final question = _persistedQuestion(
      snapshot: snapshot,
      explanation: projected,
      rawExplanation: projected,
    );

    await _open(tester, question, resolver: _Resolver());

    expect(_typedContent(explanation), findsOneWidget,
        reason: 'the retained typed explanation must render structurally');
    expect(_tableAnchor(0, 0), findsOneWidget);
    expect(_tableAnchor(0, 1), findsOneWidget);
    // The pipe-separated text projection must never be the rendered table.
    expect(find.textContaining('left cell | right cell', findRichText: true),
        findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'map envelope with a baseline type mismatch keeps legacy and reads no asset',
      (tester) async {
    final explanation = _tableExplanation();
    final projected = const RichContentTextProjection().project(explanation);
    final snapshot = TypedReviewSnapshot(
      reviewItemId: _itemId,
      questionId: _questionId,
      // Declared kind maps to type 0 while the frozen baseline stays type 3.
      draft: _draft(kind: QuestionKind.singleChoice),
      baselineLegacy: _baseline(type: 3, explanation: projected),
    );
    final question = _persistedQuestion(
      snapshot: snapshot,
      explanation: projected,
      rawExplanation: projected,
    );
    final resolver = _Resolver();

    await _open(tester, question, resolver: resolver);

    expect(_typedContent(explanation), findsNothing,
        reason: 'a rejected snapshot must not reach the typed preview');
    expect(_tableAnchor(0, 0), findsNothing);
    expect(resolver.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'map envelope with a corrupt payload falls back without mutating it',
      (tester) async {
    final explanation = _tableExplanation();
    final projected = const RichContentTextProjection().project(explanation);
    final snapshot = TypedReviewSnapshot(
      reviewItemId: _itemId,
      questionId: _questionId,
      draft: _draft(kind: QuestionKind.singleChoice),
      baselineLegacy: _baseline(type: 0, explanation: projected),
    );
    final question = _persistedQuestion(
      snapshot: snapshot,
      explanation: projected,
      rawExplanation: projected,
      bareEnvelope: true,
    );
    (question[TypedReviewSnapshotCodec.mapKey] as Map)['schemaVersion'] = 999;
    final before = jsonEncode(question);
    final resolver = _Resolver();

    await _open(tester, question, resolver: resolver);

    expect(_typedContent(explanation), findsNothing);
    expect(_tableAnchor(0, 0), findsNothing);
    expect(resolver.calls, isEmpty);
    expect(jsonEncode(question), before,
        reason: 'presentation decoding must not repair the envelope');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'decoded envelope without the wrapper key still registers and renders',
      (tester) async {
    final explanation = _tableExplanation();
    final projected = const RichContentTextProjection().project(explanation);
    final snapshot = TypedReviewSnapshot(
      reviewItemId: _itemId,
      questionId: _questionId,
      draft: _draft(kind: QuestionKind.singleChoice),
      baselineLegacy: _baseline(type: 0, explanation: projected),
    );
    // Storage shape for this item is the envelope itself, so a key-presence
    // test on it is always false and would silently drop the typed preview.
    final question = _persistedQuestion(
      snapshot: snapshot,
      explanation: projected,
      rawExplanation: projected,
      bareEnvelope: true,
    );

    await _open(tester, question, resolver: _Resolver());

    expect(_typedContent(explanation), findsOneWidget);
    expect(_tableAnchor(0, 0), findsOneWidget);
    expect(find.textContaining('left cell | right cell', findRichText: true),
        findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'decoded envelope never re-applies the old structure over a manual edit',
      (tester) async {
    final explanation = _tableExplanation();
    final projected = const RichContentTextProjection().project(explanation);
    final snapshot = TypedReviewSnapshot(
      reviewItemId: _itemId,
      questionId: _questionId,
      draft: _draft(kind: QuestionKind.singleChoice),
      baselineLegacy: _baseline(type: 0, explanation: projected),
    );
    final question = _persistedQuestion(
      snapshot: snapshot,
      explanation: 'Synthetic manual edit',
      rawExplanation: projected,
      bareEnvelope: true,
    );

    await _open(tester, question, resolver: _Resolver());

    expect(_typedContent(explanation), findsNothing);
    expect(_tableAnchor(0, 0), findsNothing);
    expect(find.textContaining('Synthetic manual edit', findRichText: true),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
