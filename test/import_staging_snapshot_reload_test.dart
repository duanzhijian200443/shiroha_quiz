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
import 'package:shiroha_quiz/services/import_review/explanation_edit_provenance.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';
import 'package:shiroha_quiz/services/import_review/typed_review_result_builder.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';

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
    TypedReviewSnapshotCodec.mapKey: envelope,
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
    );

    await _open(tester, question, resolver: _Resolver());

    expect(_typedContent(explanation), findsOneWidget);
    expect(_tableAnchor(0, 0), findsOneWidget);
    expect(find.textContaining('left cell | right cell', findRichText: true),
        findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'untouched provenance renders structure even when the legacy text differs',
      (tester) async {
    final explanation = _tableExplanation();
    final projected = const RichContentTextProjection().project(explanation);
    // The real observed shape: the stored legacy text is NOT the typed
    // projection of the same content.
    final legacyText = projected.replaceAll(' | ', '\n').replaceAll(' ', '');
    expect(legacyText == projected, isFalse,
        reason: 'the fixture must really differ from the typed projection');
    final snapshot = TypedReviewSnapshot(
      reviewItemId: _itemId,
      questionId: _questionId,
      draft: _draft(kind: QuestionKind.singleChoice),
      baselineLegacy: _baseline(type: 0, explanation: legacyText),
    );
    final question = _persistedQuestion(
      snapshot: snapshot,
      explanation: legacyText,
      rawExplanation: legacyText,
    );
    question[TaskManager.keyExplanationEditProvenance] =
        explanationEditProvenanceUntouched;

    await _open(tester, question, resolver: _Resolver());

    // The explicit provenance, not string similarity, keeps the structure.
    expect(_typedContent(explanation), findsOneWidget);
    expect(_tableAnchor(0, 0), findsOneWidget);
    expect(find.textContaining('left cell | right cell', findRichText: true),
        findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'manualEdited never inherits the structure even when the text matches',
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
    );
    question[TaskManager.keyExplanationEditProvenance] =
        explanationEditProvenanceManualEdited;

    await _open(tester, question, resolver: _Resolver());

    expect(_typedContent(explanation), findsNothing,
        reason: 'an edited explanation never re-inherits the original nodes');
    expect(_tableAnchor(0, 0), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'editing the explanation marks the item manually edited and commits the '
      'literal text', (tester) async {
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
    );
    question[TaskManager.keyExplanationEditProvenance] =
        explanationEditProvenanceUntouched;

    await _open(tester, question, resolver: _Resolver());

    // Untouched typed structure renders and offers the edit affordance.
    expect(_typedContent(explanation), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('explanation-edit-open')));
    await tester.pumpAndSettle();

    // The editor is seeded with what the reviewer is looking at.
    final field = find.byKey(const ValueKey('explanation-edit-field'));
    expect(field, findsOneWidget);
    await tester.enterText(field, 'Corrected by the reviewer');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('explanation-edit-save')));
    await tester.pumpAndSettle();

    // A real edit is terminal: the typed structure is no longer inherited.
    expect(_typedContent(explanation), findsNothing);
    expect(_tableAnchor(0, 0), findsNothing);
    expect(find.textContaining('Corrected by the reviewer', findRichText: true),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dismissing the explanation editor is not an edit',
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
    );
    question[TaskManager.keyExplanationEditProvenance] =
        explanationEditProvenanceUntouched;

    await _open(tester, question, resolver: _Resolver());
    await tester.tap(find.byKey(const ValueKey('explanation-edit-open')));
    await tester.pumpAndSettle();
    // Save without changing anything: no edit happened, so the typed
    // structure and its provenance must both survive.
    await tester.tap(find.byKey(const ValueKey('explanation-edit-save')));
    await tester.pumpAndSettle();

    expect(_typedContent(explanation), findsOneWidget,
        reason: 'an unchanged save must not discard the structure');
    expect(_tableAnchor(0, 0), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'saving the editor unchanged keeps the structure on a non-isomorphic '
      'payload', (tester) async {
    final explanation = _tableExplanation();
    final projected = const RichContentTextProjection().project(explanation);
    // The real premise: the stored legacy text is NOT the typed projection, so
    // the editor seed differs from the stored field.
    final legacyText = projected.replaceAll(' | ', '\n').replaceAll(' ', '');
    expect(legacyText == projected, isFalse);
    final snapshot = TypedReviewSnapshot(
      reviewItemId: _itemId,
      questionId: _questionId,
      draft: _draft(kind: QuestionKind.singleChoice),
      baselineLegacy: _baseline(type: 0, explanation: legacyText),
    );
    final question = _persistedQuestion(
      snapshot: snapshot,
      explanation: legacyText,
      rawExplanation: legacyText,
    );
    question[TaskManager.keyExplanationEditProvenance] =
        explanationEditProvenanceUntouched;

    await _open(tester, question, resolver: _Resolver());
    expect(_typedContent(explanation), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('explanation-edit-open')));
    await tester.pumpAndSettle();
    // The field is seeded with the rendered text, not with the stored legacy
    // string, so a no-op save must be judged against the seed.
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('explanation-edit-field')),
    );
    expect(field.controller!.text, isNot(legacyText),
        reason: 'the seed is the typed projection of the rendered content');
    await tester.tap(find.byKey(const ValueKey('explanation-edit-save')));
    await tester.pumpAndSettle();

    // A no-op save must not be recorded as an edit: the structure survives.
    expect(_typedContent(explanation), findsOneWidget,
        reason: 'a no-op save must never flatten the structure');
    expect(_tableAnchor(0, 0), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a nested non-canonical envelope is rejected by preview and commit alike',
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
    );
    question[TaskManager.keyExplanationEditProvenance] =
        explanationEditProvenanceUntouched;
    // Canonical persistence stores the envelope itself under the reserved key.
    // Wrap it once more: the preview must not be more permissive than the
    // commit, otherwise it would render typed content that can never commit.
    final envelope = question[TypedReviewSnapshotCodec.mapKey];
    question[TypedReviewSnapshotCodec.mapKey] = <String, dynamic>{
      TypedReviewSnapshotCodec.mapKey: envelope
    };

    await _open(tester, question, resolver: _Resolver());

    // Preview fails closed.
    expect(_typedContent(explanation), findsNothing);
    expect(_tableAnchor(0, 0), findsNothing);

    // Commit fails closed on the same payload.
    expect(
      () => TypedReviewResultBuilder().build(
        inputs: <TypedReviewCommitInput>[
          TypedReviewCommitInput(
            reviewItemId: _itemId,
            envelope: question[TypedReviewSnapshotCodec.mapKey],
            currentDraft: QuestionDraft.fromMap(question),
            explanationRetained: true,
            explanationEditProvenance: ExplanationEditProvenance.untouched,
          ),
        ],
        taskId: 'synthetic-task',
        attemptToken: 'synthetic-attempt',
        attemptNumber: 1,
      ),
      throwsA(isA<TypedReviewCommitException>()),
    );
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
    );

    await _open(tester, question, resolver: _Resolver());

    expect(_typedContent(explanation), findsNothing);
    expect(_tableAnchor(0, 0), findsNothing);
    expect(find.textContaining('Synthetic manual edit', findRichText: true),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
