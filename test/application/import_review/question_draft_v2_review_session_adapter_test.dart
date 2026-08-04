import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/question_draft_v2_review_session_adapter.dart';
import 'package:shiroha_quiz/application/import_review/review_session.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

const adapter = QuestionDraftV2ReviewSessionAdapter();

void main() {
  group('QuestionDraftV2 to ReviewSession adapter', () {
    test('forwards caller-supplied session, origin, and item identities', () {
      final session = adapter.openSession(
        sessionId: 'session_caller_001',
        taskId: 'task_caller_001',
        attemptToken: 'attempt_caller_001',
        attemptNumber: 7,
        items: [
          (itemId: 'item_caller_001', draft: _draft('question_caller_001')),
          (itemId: 'item_caller_002', draft: _draft('question_caller_002')),
        ],
      );

      expect(session.sessionId, 'session_caller_001');
      expect(
        session.origin,
        ReviewSessionOrigin(
          taskId: 'task_caller_001',
          attemptToken: 'attempt_caller_001',
          attemptNumber: 7,
        ),
      );
      expect(session.items.map((item) => item.itemId), [
        'item_caller_001',
        'item_caller_002',
      ]);
      expect(session.items.map((item) => item.original.questionId), [
        'question_caller_001',
        'question_caller_002',
      ]);
    });

    test('one call forms exactly one independent task-attempt session', () {
      final first = adapter.openSession(
        sessionId: 'session_one_001',
        taskId: 'task_one_001',
        attemptToken: 'attempt_one_001',
        attemptNumber: 1,
        items: [(itemId: 'item_one_001', draft: _draft('question_one_001'))],
      );
      final second = adapter.openSession(
        sessionId: 'session_one_002',
        taskId: 'task_one_002',
        attemptToken: 'attempt_one_002',
        attemptNumber: 2,
        items: [(itemId: 'item_one_002', draft: _draft('question_one_002'))],
      );

      expect(first.status, ReviewStatus.open);
      expect(first.revision, 0);
      expect(first.origin.taskId, 'task_one_001');
      expect(first.origin.attemptToken, 'attempt_one_001');
      expect(first.origin.attemptNumber, 1);
      expect(first, isNot(second));
      expect(first.items, isNot(same(second.items)));
      expect(first.items.single.itemId, isNot(second.items.single.itemId));
      expect(
        first.items.single.original,
        isNot(same(second.items.single.original)),
      );
    });

    test('keeps the caller input order stable and frozen', () {
      final drafts = [
        _draft('question_order_001'),
        _draft('question_order_002'),
        _draft('question_order_003'),
      ];
      final inputs = <QuestionDraftV2ReviewItemInput>[
        (itemId: 'item_order_002', draft: drafts[1]),
        (itemId: 'item_order_001', draft: drafts[0]),
        (itemId: 'item_order_003', draft: drafts[2]),
      ];

      final session = adapter.openSession(
        sessionId: 'session_order_001',
        taskId: 'task_order_001',
        attemptToken: 'attempt_order_001',
        attemptNumber: 1,
        items: inputs,
      );
      inputs.clear();

      expect(session.items.map((item) => item.itemId), [
        'item_order_002',
        'item_order_001',
        'item_order_003',
      ]);
      expect(
        session.items.map((item) => item.original.questionId),
        [
          'question_order_002',
          'question_order_001',
          'question_order_003',
        ],
      );
      expect(() => session.items.clear(), throwsUnsupportedError);
    });

    test('preserves drafts, source refs, asset refs, and issues losslessly',
        () {
      final sourceRefs = <SourceRef>[
        SourceRef.document(
          sourceId: 'source_preserve_001',
          displayLabel: 'synthetic.pdf',
        ),
        SourceRef.at(
          sourceId: 'source_preserve_001',
          point: SourcePoint.page(pageNumber: 2),
        ),
        SourceRef.range(
          sourceId: 'source_preserve_001',
          start: SourcePoint.block(
            pageNumber: 3,
            blockId: 'block_01',
            readingOrder: 0,
          ),
          end: SourcePoint.block(
            pageNumber: 3,
            blockId: 'block_02',
            readingOrder: 1,
          ),
        ),
      ];
      final assetRefs = <SourcedAssetRef>[
        SourcedAssetRef(
          sourceId: 'source_preserve_001',
          asset: AssetRef(assetId: 'asset_001', kind: AssetKind.image),
        ),
        SourcedAssetRef(
          sourceId: 'source_preserve_001',
          asset: AssetRef(
            assetId: 'asset_002',
            kind: AssetKind.image,
            mimeType: 'image/png',
            pixelWidth: 800,
            pixelHeight: 600,
          ),
        ),
      ];
      final issues = <ImportIssue>[
        ImportIssue(
          code: 'missing_answer',
          severity: ImportIssueSeverity.error,
          field: ImportIssueField.answer,
        ),
        ImportIssue(
          code: 'needs_review',
          severity: ImportIssueSeverity.warning,
          field: ImportIssueField.stem,
          sourceRef: sourceRefs[1],
        ),
        ImportIssue(
          code: 'source_note',
          severity: ImportIssueSeverity.info,
          field: ImportIssueField.source,
          sourceRef: sourceRefs[0],
        ),
      ];
      final draft = QuestionDraftV2(
        questionId: 'question_preserve_001',
        kind: QuestionKind.singleChoice,
        questionNumber: 3,
        stem: _text('synthetic stem'),
        options: [
          QuestionOption(
            optionId: 'option_a',
            label: 'A',
            content: _text('synthetic option'),
            sourceRef: sourceRefs[2],
          ),
          QuestionOption(
              optionId: 'option_b', label: 'B', content: _text('plain option')),
        ],
        answer: ChoiceAnswer(optionIds: const ['option_a']),
        explanation: _text('synthetic explanation'),
        sourceRefs: sourceRefs,
        assetRefs: assetRefs,
        issues: issues,
      );

      final item = adapter
          .openSession(
            sessionId: 'session_preserve_001',
            taskId: 'task_preserve_001',
            attemptToken: 'attempt_preserve_001',
            attemptNumber: 1,
            items: [
              (itemId: 'item_preserve_001', draft: draft),
            ],
          )
          .items
          .single;

      expect(item.original, same(draft));
      expect(item.working, draft);
      expect(item.working, isNot(same(draft)));
      expect(item.edit.isUnchanged, isTrue);
      expect(item.decision, ReviewDecision.unreviewed);
      expect(item.answerAssist, isNull);

      expect(item.original.sourceRefs, sourceRefs);
      expect(item.original.sourceRefs, isNot(same(sourceRefs)));
      for (var index = 0; index < sourceRefs.length; index++) {
        expect(item.original.sourceRefs[index], same(sourceRefs[index]));
      }
      expect(item.original.assetRefs, assetRefs);
      expect(item.original.assetRefs, isNot(same(assetRefs)));
      for (var index = 0; index < assetRefs.length; index++) {
        expect(item.original.assetRefs[index], same(assetRefs[index]));
      }
      expect(item.original.issues, issues);
      expect(item.original.issues, isNot(same(issues)));
      for (var index = 0; index < issues.length; index++) {
        expect(item.original.issues[index], same(issues[index]));
      }
      expect(item.original.options, draft.options);
      expect(item.original.options.first.sourceRef, sourceRefs[2]);
    });

    test('preserves raw fallback and unsupported content explicitly', () {
      final rawStem = RichContent(nodes: [
        const TextNode('legacy prefix'),
        RawFallbackNode(<Object?, Object?>{
          'type': 'raw_fallback',
          'payload': <Object?, Object?>{
            'unparsed': 'unsupported extension block',
            'meta': <Object?, Object?>{'format': 'legacy'},
          },
        }),
        const InlineMathNode(r'\int'),
      ]);
      final rawOptionContent = RichContent(nodes: [
        RawFallbackNode(<Object?, Object?>{
          'type': 'inline_math',
          'latex': r'\sum_{i=1}^{n}',
          'source': 'legacy-extension',
        }),
      ]);
      final rawAnswer = ContentAnswer(
        content: RichContent(nodes: [
          RawFallbackNode(<Object?, Object?>{
            'type': 'raw_fallback',
            'payload': <Object?, Object?>{'unparsed': 'answer extension'},
          }),
        ]),
      );
      final rawExplanation = RichContent(nodes: [
        RawFallbackNode(<Object?, Object?>{
          'type': 'raw_fallback',
          'payload': <Object?, Object?>{'unparsed': 'explanation extension'},
        }),
      ]);
      final draft = QuestionDraftV2(
        questionId: 'question_raw_001',
        kind: QuestionKind.fillBlank,
        stem: rawStem,
        options: [
          QuestionOption(
            optionId: 'option_a',
            label: 'A',
            content: rawOptionContent,
          ),
        ],
        answer: rawAnswer,
        explanation: rawExplanation,
      );

      final item = adapter
          .openSession(
            sessionId: 'session_raw_001',
            taskId: 'task_raw_001',
            attemptToken: 'attempt_raw_001',
            attemptNumber: 1,
            items: [(itemId: 'item_raw_001', draft: draft)],
          )
          .items
          .single;

      expect(item.original, same(draft));
      expect(item.working, draft);

      final originalStemNodes = item.original.stem.nodes;
      final workingStemNodes = item.working.stem.nodes;
      expect(originalStemNodes, hasLength(3));
      expect(workingStemNodes, hasLength(3));
      expect(workingStemNodes[1], isA<RawFallbackNode>());
      expect(workingStemNodes[1], isNot(isA<TextNode>()));
      final preservedStem = workingStemNodes[1] as RawFallbackNode;
      expect(preservedStem.rawJson, {
        'type': 'raw_fallback',
        'payload': <String, Object?>{
          'unparsed': 'unsupported extension block',
          'meta': <String, Object?>{'format': 'legacy'},
        },
      });
      expect(
        preservedStem.rawJson,
        same((originalStemNodes[1] as RawFallbackNode).rawJson),
      );

      final preservedOption =
          item.working.options.single.content.nodes.single as RawFallbackNode;
      expect(preservedOption.rawJson['type'], 'inline_math');
      expect(preservedOption.rawJson['source'], 'legacy-extension');
      expect(preservedOption.rawJson['latex'], r'\sum_{i=1}^{n}');

      final workingAnswer = item.working.answer! as ContentAnswer;
      expect(
        workingAnswer.content.nodes.single,
        isA<RawFallbackNode>(),
      );
      expect(
        (workingAnswer.content.nodes.single as RawFallbackNode)
            .rawJson['payload'],
        <String, Object?>{'unparsed': 'answer extension'},
      );

      final workingExplanation = item.working.explanation!;
      expect(workingExplanation.nodes.single, isA<RawFallbackNode>());
      expect(
        (workingExplanation.nodes.single as RawFallbackNode).rawJson['payload'],
        <String, Object?>{'unparsed': 'explanation extension'},
      );
    });

    test('adapts directly without AI, JSON round-trips, or persistence types',
        () {
      final source = SourceRef.document(sourceId: 'source_direct_001');
      final asset = SourcedAssetRef(
        sourceId: 'source_direct_001',
        asset: AssetRef(assetId: 'asset_direct_001', kind: AssetKind.image),
      );
      final issue = ImportIssue(
        code: 'direct_note',
        severity: ImportIssueSeverity.info,
        field: ImportIssueField.source,
        sourceRef: source,
      );
      final draft = _draft(
        'question_direct_001',
        source: source,
        assets: [asset],
        issues: [issue],
      );

      final item = adapter
          .openSession(
            sessionId: 'session_direct_001',
            taskId: 'task_direct_001',
            attemptToken: 'attempt_direct_001',
            attemptNumber: 1,
            items: [(itemId: 'item_direct_001', draft: draft)],
          )
          .items
          .single;

      // The session references the caller instance directly, so no map/JSON
      // codec or persistence round-trip rebuilt the draft or its parts.
      expect(item.original, same(draft));
      expect(item.original.stem, same(draft.stem));
      expect(item.original.options.single, same(draft.options.single));
      expect(item.original.answer, same(draft.answer));
      expect(item.original.sourceRefs.single, same(source));
      expect(item.original.assetRefs.single, same(draft.assetRefs.single));
      expect(item.original.issues.single, same(draft.issues.single));
      // The isolated working draft reuses the same immutable content
      // instances instead of copying content through a serialization layer.
      expect(item.working.stem, same(draft.stem));
      expect(item.working.options.single, same(draft.options.single));
      expect(item.working.answer, same(draft.answer));
      expect(item.working.explanation, same(draft.explanation));
    });

    test(
        'delegates identity, uniqueness, and construction invariants to the '
        'aggregate', () {
      expect(
        () => adapter.openSession(
          sessionId: 'bad session',
          taskId: 'task_invariant_001',
          attemptToken: 'attempt_invariant_001',
          attemptNumber: 1,
          items: [
            (
              itemId: 'item_invariant_001',
              draft: _draft('question_invariant_001')
            ),
          ],
        ),
        throwsFormatException,
      );
      expect(
        () => adapter.openSession(
          sessionId: 'session_invariant_001',
          taskId: 'task_invariant_001',
          attemptToken: 'attempt_invariant_001',
          attemptNumber: 0,
          items: [
            (
              itemId: 'item_invariant_001',
              draft: _draft('question_invariant_001')
            ),
          ],
        ),
        throwsFormatException,
      );
      expect(
        () => adapter.openSession(
          sessionId: 'session_invariant_001',
          taskId: 'task_invariant_001',
          attemptToken: 'attempt_invariant_001',
          attemptNumber: 1,
          items: [
            (itemId: 'bad item', draft: _draft('question_invariant_001')),
          ],
        ),
        throwsFormatException,
      );
      expect(
        () => adapter.openSession(
          sessionId: 'session_invariant_001',
          taskId: 'task_invariant_001',
          attemptToken: 'attempt_invariant_001',
          attemptNumber: 1,
          items: const <QuestionDraftV2ReviewItemInput>[],
        ),
        throwsFormatException,
      );

      final first = (
        itemId: 'duplicate_item',
        draft: _draft('question_invariant_001'),
      );
      expect(
        () => adapter.openSession(
          sessionId: 'session_invariant_001',
          taskId: 'task_invariant_001',
          attemptToken: 'attempt_invariant_001',
          attemptNumber: 1,
          items: [
            first,
            (itemId: 'duplicate_item', draft: _draft('question_invariant_002')),
          ],
        ),
        throwsFormatException,
      );
      expect(
        () => adapter.openSession(
          sessionId: 'session_invariant_001',
          taskId: 'task_invariant_001',
          attemptToken: 'attempt_invariant_001',
          attemptNumber: 1,
          items: [
            first,
            (itemId: 'other_item', draft: _draft('question_invariant_001')),
          ],
        ),
        throwsFormatException,
      );
    });
  });
}

QuestionDraftV2 _draft(
  String questionId, {
  SourceRef? source,
  Iterable<SourcedAssetRef> assets = const [],
  Iterable<ImportIssue> issues = const [],
}) {
  final effectiveSource = source ?? SourceRef.document(sourceId: 'source_001');
  return QuestionDraftV2(
    questionId: questionId,
    kind: QuestionKind.singleChoice,
    questionNumber: 1,
    stem: _text('synthetic stem'),
    options: [
      QuestionOption(
        optionId: 'option_a',
        label: 'A',
        content: _text('synthetic option'),
        sourceRef: effectiveSource,
      ),
    ],
    answer: ChoiceAnswer(optionIds: const ['option_a']),
    explanation: _text('synthetic explanation'),
    sourceRefs: [effectiveSource],
    assetRefs: assets,
    issues: issues,
  );
}

RichContent _text(String text) {
  return RichContent(nodes: [TextNode(text)]);
}
