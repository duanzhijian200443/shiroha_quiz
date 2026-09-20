import 'dart:convert';

import 'package:flutter/material.dart' hide TableRow, TableCell;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:shiroha_quiz/application/content/content_asset_authority.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/application/questions/folder_query_port.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/services/import_review/typed_review_result_builder.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';
import 'services/import_pipeline/ocr_math_production_test.dart' as production;
import 'package:shiroha_quiz/services/import_review/explanation_edit_provenance.dart';

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
    return base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
      '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
  }
}

RichContent _text(String value) => RichContent(nodes: [TextNode(value)]);

Map<String, dynamic> _question({
  String itemId = _itemId,
  String questionId = _questionId,
  String sourceId = _sourceId,
  String localAssetId = 'image_1',
  RichContent? explanationContent,
  String baselineExplanation = '**explanation**',
}) {
  final draft = QuestionDraftV2(
    questionId: questionId,
    kind: QuestionKind.fillBlank,
    questionNumber: 1,
    stem: RichContent(nodes: [
      const TextNode('Synthetic stem'),
      ImageNode(sourceId: sourceId, localAssetId: localAssetId),
      TableNode(
          structure: TableStructure(rows: [
        TableRow(cells: [
          TableCell(content: _text('cell left')),
          TableCell(content: _text('cell right')),
        ]),
      ])),
    ]),
    options: [
      QuestionOption(optionId: 'a', label: 'A', content: _text('**option A**')),
      QuestionOption(optionId: 'b', label: 'B', content: _text('**option B**')),
    ],
    answer: ContentAnswer(content: _text('**answer**')),
    explanation: explanationContent ?? _text('**explanation**'),
    sourceRefs: [SourceRef.document(sourceId: sourceId)],
    assetRefs: [
      SourcedAssetRef(
        sourceId: sourceId,
        asset: AssetRef(
            assetId: localAssetId,
            kind: AssetKind.image,
            mimeType: 'image/png'),
      ),
    ],
  );
  final baseline = LegacyReviewBaseline(
    type: 2,
    questionNumber: 1,
    content: 'Synthetic stem\n[图片]\n<table><tr><td>cell left</td>'
        '<td>cell right</td></tr></table>',
    options: ['A. **option A**', 'B. **option B**'],
    standardAnswer: '**answer**',
    explanation: baselineExplanation,
  );
  return {
    'type': baseline.type,
    'question_number': 1,
    'content': baseline.content,
    'options': baseline.options,
    'standard_answer': baseline.standardAnswer,
    'explanation': baseline.explanation,
    'raw_explanation': baseline.explanation,
    TaskManager.keyReviewItemId: itemId,
    TypedReviewSnapshotCodec.mapKey: const TypedReviewSnapshotCodec().encode(
      TypedReviewSnapshot(
          reviewItemId: itemId,
          questionId: questionId,
          draft: draft,
          baselineLegacy: baseline),
    ),
  };
}

/// Diagnostics a task persisted by the current import entry always carries.
///
/// Document import fixes explanation retention, so a task recording one is a
/// current task; a task recording none keeps the controls of the older builds
/// that let the user choose.
Map<String, dynamic> _newTaskDiagnostics() => <String, dynamic>{
      TaskManager.keyParseExplanationRetentionMode: 'allQuestionTypes',
      TaskManager.keyReviewExplanationRetentionMode: 'allQuestionTypes',
      TaskManager.keyExplanationRetentionMode: 'allQuestionTypes',
    };

Future<void> _open(
  WidgetTester tester,
  Map<String, dynamic> question,
  _Resolver resolver, {
  ExplanationRetentionMode explanationRetentionMode =
      ExplanationRetentionMode.allQuestionTypes,
  Map<String, dynamic>? diagnostics,
}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 2200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: ContentAssetResolverScope(
      resolver: resolver,
      child: ImportStagingScreen(
        parsedQuestions: [question],
        diagnostics: diagnostics,
        folderQuery: _Folders(),
        taskManager: TaskManager.forTesting(),
        initialExplanationRetentionMode: explanationRetentionMode,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Finder _typedText(String text) => find.byWidgetPredicate(
    (widget) => widget is RichContentRenderer && widget.content == _text(text));

void main() {
  testWidgets('OCR production snapshot renders math in staging',
      (tester) async {
    final question = production.buildMathFixture().questions.single;
    final before = jsonEncode(question);
    await _open(tester, question, _Resolver());
    expect(find.byType(RichContentRenderer), findsWidgets);
    expect(find.byType(Math), findsWidgets);
    expect(find.textContaining(r'$x_n$'), findsNothing);
    expect(tester.takeException(), isNull);
    expect(jsonEncode(question), before);
  });
  for (final defect in ['identity', 'questionNumber', 'type']) {
    testWidgets(
        'static snapshot $defect mismatch keeps legacy without asset reads',
        (tester) async {
      final question = _question();
      if (defect == 'identity') {
        // Both valid envelopes have identical lossy legacy image projections.
        final other = _question(
          itemId: '44444444-4444-4444-8444-000000000002',
          questionId: '22222222-2222-4222-8222-000000000002',
          sourceId: '11111111-1111-4111-8111-000000000002',
          localAssetId: 'image_2',
        );
        const codec = TypedReviewSnapshotCodec();
        final original =
            codec.decodeRequired(question[TypedReviewSnapshotCodec.mapKey]);
        final swapped =
            codec.decodeRequired(other[TypedReviewSnapshotCodec.mapKey]);
        expect(original.baselineLegacy, swapped.baselineLegacy);
        expect(original.draft.assetRefs, isNot(swapped.draft.assetRefs));
        question[TypedReviewSnapshotCodec.mapKey] =
            other[TypedReviewSnapshotCodec.mapKey];
      } else {
        final envelope = question[TypedReviewSnapshotCodec.mapKey] as Map;
        final baseline = envelope['baselineLegacy'] as Map;
        baseline[defect] = defect == 'questionNumber' ? 2 : 3;
      }
      final envelope = question[TypedReviewSnapshotCodec.mapKey];
      // A strict decode succeeds; failure belongs to static binding checks.
      const TypedReviewSnapshotCodec().decodeRequired(envelope);
      final before = jsonEncode(question);
      expect(
        () => TypedReviewResultBuilder().build(
          inputs: [
            TypedReviewCommitInput(
              reviewItemId: question[TaskManager.keyReviewItemId] as String,
              envelope: envelope,
              currentDraft: QuestionDraft.fromMap(question),
              explanationRetained: true,
              explanationEditProvenance:
                  ExplanationEditProvenance.legacyUnknown,
            )
          ],
          taskId: 'synthetic-task',
          attemptToken: 'synthetic-attempt',
          attemptNumber: 1,
        ),
        throwsA(isA<TypedReviewCommitException>().having(
          (error) => error.failure,
          'failure',
          defect == 'identity'
              ? TypedReviewCommitFailure.identityMismatch
              : TypedReviewCommitFailure.baselineMismatch,
        )),
      );
      final resolver = _Resolver();
      await _open(tester, question, resolver);
      expect(find.byType(RichContentRenderer), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(resolver.calls, isEmpty);
      expect(find.textContaining('Synthetic stem', findRichText: true),
          findsOneWidget);
      expect(find.textContaining('[图片]', findRichText: true), findsOneWidget);
      expect(jsonEncode(question), before);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('typed staging resolves image and renders table and all fields',
      (tester) async {
    final resolver = _Resolver();
    await _open(tester, _question(), resolver);
    expect(find.byType(Image), findsOneWidget);
    expect(resolver.calls, [(_sourceId, 'image_1')]);
    expect(find.text('[图片]'), findsNothing);
    expect(find.byKey(const ValueKey('rich-table-anchor-0-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('rich-table-anchor-0-1')), findsOneWidget);
    expect(find.textContaining('<table>', findRichText: true), findsNothing);
    for (final text in [
      '**option A**',
      '**option B**',
      '**answer**',
      '**explanation**'
    ]) {
      expect(_typedText(text), findsOneWidget);
      expect(find.textContaining(text, findRichText: true), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  for (final field in [
    'content',
    'options',
    'standard_answer',
    'explanation'
  ]) {
    testWidgets(
        'saved $field edit displays current value and preserves other fields',
        (tester) async {
      final question = _question();
      question[field] = field == 'options'
          ? ['A. current edit', 'B. **option B**']
          : 'current edit';
      await _open(tester, question, _Resolver());
      expect(find.textContaining('current edit', findRichText: true),
          findsOneWidget);
      expect(find.byType(Image),
          field == 'content' ? findsNothing : findsOneWidget);
      expect(_typedText('**option A**'),
          field == 'options' ? findsNothing : findsOneWidget);
      expect(_typedText('**option B**'), findsOneWidget);
      expect(_typedText('**answer**'),
          field == 'standard_answer' ? findsNothing : findsOneWidget);
      expect(_typedText('**explanation**'),
          field == 'explanation' ? findsNothing : findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('new import keeps the typed explanation without any chip',
      (tester) async {
    await _open(
      tester,
      _question(),
      _Resolver(),
      diagnostics: _newTaskDiagnostics(),
    );

    // Retention is no longer a per-question choice, so the explanation stays
    // rendered and there is nothing to discard it with.
    expect(find.byKey(const ValueKey('question-explanation-discard-0')),
        findsNothing);
    expect(find.byKey(const ValueKey('question-explanation-keep-0')),
        findsNothing);
    expect(_typedText('**explanation**'), findsOneWidget);
    expect(find.textContaining('**explanation**', findRichText: true),
        findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(_typedText('**answer**'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('per-question retention chips are gone for a new import',
      (tester) async {
    await _open(
      tester,
      _question(),
      _Resolver(),
      diagnostics: _newTaskDiagnostics(),
    );

    expect(
      find.byKey(const ValueKey('objective-explanation-document-switch')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('question-explanation-keep-0')),
        findsNothing);
    expect(find.byKey(const ValueKey('question-explanation-discard-0')),
        findsNothing);
    expect(find.text('保留解析'), findsNothing);
    expect(find.text('忽略解析'), findsNothing);
    expect(find.text('同时导入选择题、填空题解析'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'new typed task renders its table explanation, commits it, and keeps it',
      (tester) async {
    final tableExplanation = RichContent(nodes: <ContentNode>[
      const TextNode('Explanation '),
      TableNode(
        structure: TableStructure(rows: [
          TableRow(cells: [
            TableCell(content: _text('kept left')),
            TableCell(content: _text('kept right')),
          ]),
        ]),
      ),
    ]);
    final question = _question(
      explanationContent: tableExplanation,
      baselineExplanation: 'Explanation kept left | kept right',
    );
    await _open(
      tester,
      question,
      _Resolver(),
      diagnostics: _newTaskDiagnostics(),
    );

    // No retention control may stand between the user and the explanation.
    expect(
      find.byKey(const ValueKey('objective-explanation-document-switch')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('question-explanation-discard-0')),
        findsNothing);

    // The typed explanation and its structure are visible.
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichContentRenderer && widget.content == tableExplanation,
      ),
      findsOneWidget,
    );
    expect(
        find.textContaining('kept left', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The commit path must keep that structure rather than flattening it.
    final envelope = question[TypedReviewSnapshotCodec.mapKey];
    final built = TypedReviewResultBuilder().build(
      inputs: [
        TypedReviewCommitInput(
          reviewItemId: question[TaskManager.keyReviewItemId] as String,
          envelope: envelope,
          currentDraft: QuestionDraft.fromMap(question),
          explanationRetained: true,
          explanationEditProvenance: ExplanationEditProvenance.legacyUnknown,
        )
      ],
      taskId: 'synthetic-task',
      attemptToken: 'synthetic-attempt',
      attemptNumber: 1,
    );

    expect(built.acceptedDrafts, hasLength(1));
    final committed = built.acceptedDrafts.single;
    expect(
      committed.explanation,
      isNotNull,
      reason: 'a new import must not drop the recognized explanation',
    );
    expect(
      committed.explanation!.nodes.whereType<TableNode>(),
      hasLength(1),
    );
  });

  testWidgets('legacy retention switch restores hidden typed table explanation',
      (tester) async {
    final question = _question();
    const codec = TypedReviewSnapshotCodec();
    final original = codec.decodeRequired(
      question[TypedReviewSnapshotCodec.mapKey],
    );
    final hiddenExplanation = RichContent(nodes: <ContentNode>[
      const TextNode('Restored '),
      TableNode(
        structure: TableStructure(rows: [
          TableRow(cells: [
            TableCell(content: _text('toggle left')),
            TableCell(content: _text('toggle right')),
          ]),
        ]),
      ),
    ]);
    final hiddenDraft = QuestionDraftV2(
      questionId: original.draft.questionId,
      kind: original.draft.kind,
      questionNumber: original.draft.questionNumber,
      stem: original.draft.stem,
      options: original.draft.options,
      answer: original.draft.answer,
      explanation: hiddenExplanation,
      sourceRefs: original.draft.sourceRefs,
      assetRefs: original.draft.assetRefs,
      issues: original.draft.issues,
    );
    question
      ..['explanation'] = ''
      ..['raw_explanation'] = 'Restored toggle left | toggle right'
      ..[TypedReviewSnapshotCodec.mapKey] = codec.encode(
        TypedReviewSnapshot(
          reviewItemId: original.reviewItemId,
          questionId: original.questionId,
          draft: hiddenDraft,
          baselineLegacy: LegacyReviewBaseline(
            type: original.baselineLegacy.type,
            questionNumber: original.baselineLegacy.questionNumber,
            content: original.baselineLegacy.content,
            options: original.baselineLegacy.options,
            standardAnswer: original.baselineLegacy.standardAnswer,
            explanation: '',
          ),
        ),
      );

    // A task that recorded no policy is a legacy task, so it keeps the switch
    // that describes what its parse stage actually did.
    await _open(
      tester,
      question,
      _Resolver(),
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichContentRenderer &&
            widget.content == hiddenExplanation,
      ),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey('objective-explanation-document-switch')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichContentRenderer &&
            widget.content == hiddenExplanation,
      ),
      findsOneWidget,
    );
    expect(
        find.textContaining('toggle left', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy-only task retains markdown display', (tester) async {
    final question = _question()..remove(TypedReviewSnapshotCodec.mapKey);
    question['content'] = '**legacy stem**';
    final resolver = _Resolver();
    await _open(tester, question, resolver);
    expect(find.byType(RichContentRenderer), findsNothing);
    expect(
        find.textContaining('legacy stem', findRichText: true), findsOneWidget);
    expect(find.textContaining('**legacy stem**', findRichText: true),
        findsNothing);
    expect(resolver.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid snapshot falls back without mutating its envelope',
      (tester) async {
    final question = _question();
    final envelope = question[TypedReviewSnapshotCodec.mapKey] as Map;
    envelope['schemaVersion'] = 999;
    question['content'] = 'safe current stem';
    final before = jsonEncode(question);
    final resolver = _Resolver();
    await _open(tester, question, resolver);
    expect(find.byType(RichContentRenderer), findsNothing);
    expect(find.textContaining('safe current stem', findRichText: true),
        findsOneWidget);
    expect(jsonEncode(question), before);
    expect(resolver.calls, isEmpty);
    expect(() => const TypedReviewSnapshotCodec().decodeRequired(envelope),
        throwsA(isA<TypedReviewSnapshotException>()));
    expect(tester.takeException(), isNull);
  });
}
