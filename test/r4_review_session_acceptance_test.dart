// R4D1 pure synthetic acceptance for the frozen R4 review-session contract:
//
//   QuestionDraftV2
//     -> QuestionDraftV2ReviewSessionAdapter
//     -> ReviewSession
//     -> edit / acknowledge / accept / reject / defer
//     -> stale CAS rejection
//     -> completion assessment
//     -> ReviewResult
//
// Evidence class: synthetic fixtures only. This harness has no Provider,
// Replay, network, database, UI, filesystem, or environment-secret call site,
// so Provider calls are 0 by construction. Every transition exercises the
// frozen public API only; no production reducer is copied and no map/JSON
// round-trip rebuilds state. Assertions read exposed aggregate state.
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

const _adapter = QuestionDraftV2ReviewSessionAdapter();

/// Provider calls in this pure harness: there is no callable Provider site,
/// so the count is constant zero.
const _providerCallCount = 0;

void main() {
  group('adapter chain identity and input order', () {
    test(
        'session, origin, and item identities plus caller order stay stable '
        'through the adapter', () {
      final drafts = [
        _draft('question_r4d_001'),
        _draft('question_r4d_002'),
        _draft('question_r4d_003'),
      ];
      final inputs = <QuestionDraftV2ReviewItemInput>[
        (itemId: 'item_r4d_002', draft: drafts[1]),
        (itemId: 'item_r4d_003', draft: drafts[2]),
        (itemId: 'item_r4d_001', draft: drafts[0]),
      ];

      final session = _adapter.openSession(
        sessionId: 'session_r4d_001',
        taskId: 'task_r4d_001',
        attemptToken: 'attempt_r4d_001',
        attemptNumber: 3,
        items: inputs,
      );
      inputs.clear();

      expect(_providerCallCount, 0);
      expect(session.sessionId, 'session_r4d_001');
      expect(
        session.origin,
        ReviewSessionOrigin(
          taskId: 'task_r4d_001',
          attemptToken: 'attempt_r4d_001',
          attemptNumber: 3,
        ),
      );
      expect(session.status, ReviewStatus.open);
      expect(session.revision, 0);
      expect(session.items.map((item) => item.itemId), [
        'item_r4d_002',
        'item_r4d_003',
        'item_r4d_001',
      ]);
      expect(session.items.map((item) => item.original.questionId), [
        'question_r4d_002',
        'question_r4d_003',
        'question_r4d_001',
      ]);
      expect(session.items[0].original, same(drafts[1]));
      expect(session.items[1].original, same(drafts[2]));
      expect(session.items[2].original, same(drafts[0]));
      for (final item in session.items) {
        expect(item.working, item.original);
        expect(item.working, isNot(same(item.original)));
        expect(item.edit.isUnchanged, isTrue);
        expect(item.decision, ReviewDecision.unreviewed);
        expect(item.answerAssist, isNull);
      }
      expect(() => session.items.clear(), throwsUnsupportedError);
    });
  });

  group('original draft preservation', () {
    test(
        'source refs, asset refs, issues, and content stay lossless and '
        'inspectable after edits, restores, and reset', () {
      final sourceRefs = <SourceRef>[
        SourceRef.document(
          sourceId: 'source_r4d_preserve',
          displayLabel: 'synthetic.pdf',
        ),
        SourceRef.at(
          sourceId: 'source_r4d_preserve',
          point: SourcePoint.page(pageNumber: 2),
        ),
        SourceRef.range(
          sourceId: 'source_r4d_preserve',
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
          sourceId: 'source_r4d_preserve',
          asset: AssetRef(assetId: 'asset_r4d_001', kind: AssetKind.image),
        ),
        SourcedAssetRef(
          sourceId: 'source_r4d_preserve',
          asset: AssetRef(
            assetId: 'asset_r4d_002',
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
      ];
      final original = QuestionDraftV2(
        questionId: 'question_r4d_preserve',
        kind: QuestionKind.singleChoice,
        questionNumber: 2,
        stem: _content('synthetic stem'),
        options: [
          QuestionOption(
            optionId: 'option_a',
            label: 'A',
            content: _content('synthetic option'),
            sourceRef: sourceRefs[0],
          ),
        ],
        answer: ChoiceAnswer(optionIds: const ['option_a']),
        explanation: _content('synthetic explanation'),
        sourceRefs: sourceRefs,
        assetRefs: assetRefs,
        issues: issues,
      );

      var session = _adapter.openSession(
        sessionId: 'session_r4d_preserve',
        taskId: 'task_r4d_001',
        attemptToken: 'attempt_r4d_001',
        attemptNumber: 1,
        items: [(itemId: 'item_r4d_001', draft: original)],
      );
      expect(session.items.single.original, same(original));

      session = session.edit(
        itemId: 'item_r4d_001',
        edit: ReviewEdit(
          stem: ReviewFieldEdit.replace(_content('edited stem')),
          answer: ReviewFieldEdit<QuestionAnswer?>.replace(
            ContentAnswer(content: _content('edited answer')),
          ),
          explanation: const ReviewFieldEdit<RichContent?>.clear(),
        ),
        expectedRevision: 0,
      );

      final edited = session.items.single;
      expect(_text(edited.working.stem), 'edited stem');
      expect(
        edited.working.answer,
        ContentAnswer(content: _content('edited answer')),
      );
      expect(edited.working.explanation, isNull);

      expect(edited.original, same(original));
      expect(_text(edited.original.stem), 'synthetic stem');
      expect(
        edited.original.answer,
        ChoiceAnswer(optionIds: const ['option_a']),
      );
      expect(_text(edited.original.explanation!), 'synthetic explanation');
      expect(edited.original.sourceRefs, sourceRefs);
      expect(edited.original.sourceRefs, isNot(same(sourceRefs)));
      for (var index = 0; index < sourceRefs.length; index++) {
        expect(edited.original.sourceRefs[index], same(sourceRefs[index]));
      }
      expect(edited.original.assetRefs, assetRefs);
      expect(edited.original.assetRefs, isNot(same(assetRefs)));
      for (var index = 0; index < assetRefs.length; index++) {
        expect(edited.original.assetRefs[index], same(assetRefs[index]));
      }
      expect(edited.original.issues, issues);
      expect(edited.original.issues, isNot(same(issues)));
      for (var index = 0; index < issues.length; index++) {
        expect(edited.original.issues[index], same(issues[index]));
      }
      expect(edited.original.options.single.sourceRef, sourceRefs[0]);

      // The working draft carries the same provenance without mutating it.
      expect(edited.working.sourceRefs, sourceRefs);
      expect(edited.working.assetRefs, assetRefs);
      expect(edited.working.issues, issues);
      expect(edited.working.options.single.sourceRef, sourceRefs[0]);

      // Single-field restore returns only the stem to its original value.
      session = session.restore(
        itemId: 'item_r4d_001',
        field: ReviewRestoreField.stem,
        expectedRevision: 1,
      );
      final restored = session.items.single;
      expect(_text(restored.working.stem), 'synthetic stem');
      expect(
        restored.working.answer,
        ContentAnswer(content: _content('edited answer')),
      );
      expect(restored.working.explanation, isNull);
      expect(_text(restored.original.stem), 'synthetic stem');

      // Whole-question reset restores the full draft; the original never
      // changes.
      session = session.reset(itemId: 'item_r4d_001', expectedRevision: 2);
      final reset = session.items.single;
      expect(reset.working, original);
      expect(reset.working, isNot(same(original)));
      expect(reset.edit.isUnchanged, isTrue);
      expect(reset.decision, ReviewDecision.unreviewed);
      expect(reset.original, same(original));
      expect(reset.original.sourceRefs, sourceRefs);
      expect(reset.original.assetRefs, assetRefs);
      expect(reset.original.issues, issues);
    });
  });

  group('decision lifecycle', () {
    test(
        'accepted, rejected, and deferred decisions drive completion and '
        're-decision', () {
      var session = _openSession(3);
      session = session.decide(
        itemId: 'item_r4d_001',
        decision: ReviewDecision.accepted,
        expectedRevision: 0,
      );
      session = session.decide(
        itemId: 'item_r4d_002',
        decision: ReviewDecision.rejected,
        expectedRevision: 1,
      );
      session = session.decide(
        itemId: 'item_r4d_003',
        decision: ReviewDecision.deferred,
        expectedRevision: 2,
      );
      expect(session.items.map((item) => item.decision), [
        ReviewDecision.accepted,
        ReviewDecision.rejected,
        ReviewDecision.deferred,
      ]);

      // A deferred item blocks completion with zero state change.
      expect(
        () => session.complete(
          expectedRevision: 3,
          assessment: _completionAssessment(session),
        ),
        throwsFormatException,
      );
      expect(session.status, ReviewStatus.inProgress);
      expect(session.revision, 3);

      // The deferred item can be re-decided, then the session completes.
      session = session.decide(
        itemId: 'item_r4d_003',
        decision: ReviewDecision.accepted,
        expectedRevision: 3,
      );
      final completed = session.complete(
        expectedRevision: 4,
        assessment: _completionAssessment(session),
      );
      expect(completed.session.status, ReviewStatus.completed);
      expect(completed.result.items.map((item) => item.itemId), [
        'item_r4d_001',
        'item_r4d_002',
        'item_r4d_003',
      ]);
      expect(completed.result.items.map((item) => item.decision), [
        ReviewDecision.accepted,
        ReviewDecision.rejected,
        ReviewDecision.accepted,
      ]);
      expect(completed.result.completedRevision, 5);
    });
  });

  group('typed edit, restore, and reset', () {
    test('edits compose field-wise and restores revert exactly one field', () {
      var session = _openSession(1);
      session = session.edit(
        itemId: 'item_r4d_001',
        edit: ReviewEdit(
          stem: ReviewFieldEdit.replace(_content('edited stem')),
          questionNumber: ReviewFieldEdit.replace(9),
          answer: ReviewFieldEdit<QuestionAnswer?>.replace(
            ContentAnswer(content: _content('edited answer')),
          ),
        ),
        expectedRevision: 0,
      );
      var item = session.items.single;
      expect(_text(item.working.stem), 'edited stem');
      expect(item.working.questionNumber, 9);
      expect(
        item.working.answer,
        ContentAnswer(content: _content('edited answer')),
      );

      session = session.restore(
        itemId: 'item_r4d_001',
        field: ReviewRestoreField.stem,
        expectedRevision: 1,
      );
      item = session.items.single;
      expect(_text(item.working.stem), 'synthetic stem');
      expect(item.working.questionNumber, 9);
      expect(
        item.working.answer,
        ContentAnswer(content: _content('edited answer')),
      );

      session = session.restore(
        itemId: 'item_r4d_001',
        field: ReviewRestoreField.questionNumber,
        expectedRevision: 2,
      );
      item = session.items.single;
      expect(item.working.questionNumber, 1);
      expect(_text(item.working.stem), 'synthetic stem');

      session = session.restore(
        itemId: 'item_r4d_001',
        field: ReviewRestoreField.answer,
        expectedRevision: 3,
      );
      item = session.items.single;
      expect(item.edit.isUnchanged, isTrue);
      expect(item.working, item.original);
      expect(item.working, isNot(same(item.original)));
    });

    test('reset clears edits, decisions, and issue acknowledgements', () {
      var session = _sessionWithIssues();
      session = session.edit(
        itemId: 'item_r4d_001',
        edit: ReviewEdit(
          stem: ReviewFieldEdit.replace(_content('edited stem')),
        ),
        expectedRevision: 0,
      );
      session = session.decide(
        itemId: 'item_r4d_001',
        decision: ReviewDecision.accepted,
        expectedRevision: 1,
      );
      session = session.acknowledge(
        itemId: 'item_r4d_001',
        acknowledgement: ReviewIssueAcknowledgement(issueIndex: 0),
        expectedRevision: 2,
      );
      expect(session.items[0].issueAcknowledgements, hasLength(1));

      session = session.reset(itemId: 'item_r4d_001', expectedRevision: 3);
      final item = session.items[0];
      expect(item.edit.isUnchanged, isTrue);
      expect(item.decision, ReviewDecision.unreviewed);
      expect(item.issueAcknowledgements, isEmpty);
      expect(item.working, item.original);
      expect(item.working, isNot(same(item.original)));
    });
  });

  group('stale CAS rejection', () {
    test('stale transitions throw the typed error with zero partial updates',
        () {
      final session = _sessionWithIssues();
      final staleRevision = session.revision + 1;
      final untouched = _sessionWithIssues();

      _expectStale(
        () => session.edit(
          itemId: 'item_r4d_001',
          edit: ReviewEdit(
            stem: ReviewFieldEdit.replace(_content('edited')),
          ),
          expectedRevision: staleRevision,
        ),
        session,
        expectedRevision: staleRevision,
      );
      _expectStale(
        () => session.decide(
          itemId: 'item_r4d_001',
          decision: ReviewDecision.accepted,
          expectedRevision: staleRevision,
        ),
        session,
        expectedRevision: staleRevision,
      );
      _expectStale(
        () => session.acknowledge(
          itemId: 'item_r4d_001',
          acknowledgement: ReviewIssueAcknowledgement(issueIndex: 0),
          expectedRevision: staleRevision,
        ),
        session,
        expectedRevision: staleRevision,
      );
      _expectStale(
        () => session.complete(
          expectedRevision: staleRevision,
          assessment: _completionAssessment(session),
        ),
        session,
        expectedRevision: staleRevision,
      );
      _expectStale(
        () => session.abandon(expectedRevision: staleRevision),
        session,
        expectedRevision: staleRevision,
      );

      expect(session, untouched);
      expect(session.revision, 0);
      expect(session.status, ReviewStatus.open);
      expect(session.items[0].decision, ReviewDecision.unreviewed);
      expect(session.items[0].edit.isUnchanged, isTrue);
      expect(session.items[0].issueAcknowledgements, isEmpty);
      expect(session.items[0].original.issues, hasLength(2));
    });
  });

  group('acknowledgement gate and completion', () {
    test(
        'required acknowledgement subsets gate completion and accepted items carry '
        'the final working draft', () {
      var session = _sessionWithIssues();
      session = session.decide(
        itemId: 'item_r4d_001',
        decision: ReviewDecision.accepted,
        expectedRevision: 0,
      );
      session = session.decide(
        itemId: 'item_r4d_002',
        decision: ReviewDecision.rejected,
        expectedRevision: 1,
      );

      // Only issue 1 is policy-required, so no acknowledgements blocks.
      expect(
        () => session.complete(
          expectedRevision: 2,
          assessment: _completionAssessment(
            session,
            requiredIssueIndexesByItem: const {
              'item_r4d_001': [1],
            },
          ),
        ),
        throwsFormatException,
      );
      expect(session.status, ReviewStatus.inProgress);

      // Out-of-range acknowledgements are rejected with zero updates.
      expect(
        () => session.acknowledge(
          itemId: 'item_r4d_001',
          acknowledgement: ReviewIssueAcknowledgement(issueIndex: 2),
          expectedRevision: 2,
        ),
        throwsFormatException,
      );
      expect(session.revision, 2);

      session = session.acknowledge(
        itemId: 'item_r4d_001',
        acknowledgement: ReviewIssueAcknowledgement(issueIndex: 1),
        expectedRevision: 2,
      );
      final preRevision = session.revision;
      final completed = session.complete(
        expectedRevision: preRevision,
        assessment: _completionAssessment(
          session,
          requiredIssueIndexesByItem: const {
            'item_r4d_001': [1],
          },
        ),
      );

      expect(completed.session.status, ReviewStatus.completed);
      expect(completed.session.revision, preRevision + 1);
      expect(completed.result.sessionId, session.sessionId);
      expect(completed.result.completedRevision, preRevision + 1);
      expect(completed.result.items.map((item) => item.itemId), [
        'item_r4d_001',
        'item_r4d_002',
      ]);
      expect(completed.result.items[0].decision, ReviewDecision.accepted);
      expect(
        completed.result.items[0].finalDraft,
        same(completed.session.items[0].working),
      );
      expect(completed.result.items[1].decision, ReviewDecision.rejected);
      expect(completed.result.items[1].finalDraft, isNull);
    });

    test('an all-rejected session completes without any final draft', () {
      var session = _openSession(2);
      session = session.decide(
        itemId: 'item_r4d_001',
        decision: ReviewDecision.rejected,
        expectedRevision: 0,
      );
      session = session.decide(
        itemId: 'item_r4d_002',
        decision: ReviewDecision.rejected,
        expectedRevision: 1,
      );
      final preRevision = session.revision;
      final completed = session.complete(
        expectedRevision: preRevision,
        assessment: _completionAssessment(session),
      );

      expect(completed.session.status, ReviewStatus.completed);
      expect(completed.session.revision, preRevision + 1);
      expect(completed.result.completedRevision, preRevision + 1);
      for (final item in completed.result.items) {
        expect(item.decision, ReviewDecision.rejected);
        expect(item.finalDraft, isNull);
      }
    });
  });

  group('terminal state protection', () {
    test('completed and abandoned sessions reject every further transition',
        () {
      var session = _openSession(2);
      session = session.decide(
        itemId: 'item_r4d_001',
        decision: ReviewDecision.accepted,
        expectedRevision: 0,
      );
      session = session.decide(
        itemId: 'item_r4d_002',
        decision: ReviewDecision.rejected,
        expectedRevision: 1,
      );
      final completed = session
          .complete(
            expectedRevision: 2,
            assessment: _completionAssessment(session),
          )
          .session;
      expect(completed.status, ReviewStatus.completed);
      final completedRevision = completed.revision;

      final completedActions = <void Function()>[
        () => completed.edit(
              itemId: 'item_r4d_001',
              edit: ReviewEdit(
                stem: ReviewFieldEdit.replace(_content('x')),
              ),
              expectedRevision: completedRevision,
            ),
        () => completed.restore(
              itemId: 'item_r4d_001',
              field: ReviewRestoreField.stem,
              expectedRevision: completedRevision,
            ),
        () => completed.reset(
              itemId: 'item_r4d_001',
              expectedRevision: completedRevision,
            ),
        () => completed.decide(
              itemId: 'item_r4d_001',
              decision: ReviewDecision.rejected,
              expectedRevision: completedRevision,
            ),
        () => completed.acknowledge(
              itemId: 'item_r4d_001',
              acknowledgement: ReviewIssueAcknowledgement(issueIndex: 0),
              expectedRevision: completedRevision,
            ),
        () => completed.complete(
              expectedRevision: completedRevision,
              assessment: _completionAssessment(completed),
            ),
        () => completed.abandon(expectedRevision: completedRevision),
      ];
      for (final action in completedActions) {
        expect(action, throwsFormatException);
      }
      expect(completed.status, ReviewStatus.completed);
      expect(completed.revision, completedRevision);

      final abandoned = _openSession(1).abandon(expectedRevision: 0);
      expect(abandoned.status, ReviewStatus.abandoned);
      final abandonedRevision = abandoned.revision;
      expect(
        () => abandoned.edit(
          itemId: 'item_r4d_001',
          edit: ReviewEdit.unchanged(),
          expectedRevision: abandonedRevision,
        ),
        throwsFormatException,
      );
      expect(
        () => abandoned.complete(
          expectedRevision: abandonedRevision,
          assessment: _completionAssessment(abandoned),
        ),
        throwsFormatException,
      );
      expect(
        () => abandoned.abandon(expectedRevision: abandonedRevision),
        throwsFormatException,
      );
      expect(abandoned.status, ReviewStatus.abandoned);
      expect(abandoned.revision, abandonedRevision);
    });
  });

  group('raw fallback preservation', () {
    test(
        'unsupported raw fallback content is preserved explicitly in '
        'original, working, and result', () {
      final draft = QuestionDraftV2(
        questionId: 'question_r4d_raw_001',
        kind: QuestionKind.shortAnswer,
        stem: RichContent(nodes: [
          const TextNode('legacy prefix '),
          RawFallbackNode(<Object?, Object?>{
            'type': 'raw_fallback',
            'payload': <Object?, Object?>{
              'unparsed': 'unsupported extension block',
            },
          }),
          const InlineMathNode(r'\int'),
        ]),
        options: [
          QuestionOption(
            optionId: 'option_a',
            label: 'A',
            content: RichContent(nodes: [
              RawFallbackNode(<Object?, Object?>{
                'type': 'inline_math',
                'latex': r'\sum_{i=1}^{n}',
                'source': 'legacy-extension',
              }),
            ]),
          ),
        ],
        answer: ContentAnswer(
          content: RichContent(nodes: [
            RawFallbackNode(<Object?, Object?>{
              'type': 'raw_fallback',
              'payload': <Object?, Object?>{'unparsed': 'answer extension'},
            }),
          ]),
        ),
        explanation: RichContent(nodes: [
          RawFallbackNode(<Object?, Object?>{
            'type': 'raw_fallback',
            'payload': <Object?, Object?>{
              'unparsed': 'explanation extension',
            },
          }),
        ]),
      );

      var session = _adapter.openSession(
        sessionId: 'session_r4d_raw_001',
        taskId: 'task_r4d_001',
        attemptToken: 'attempt_r4d_001',
        attemptNumber: 1,
        items: [(itemId: 'item_r4d_001', draft: draft)],
      );
      final item = session.items.single;
      expect(item.original, same(draft));
      expect(item.working, draft);
      expect(item.working, isNot(same(draft)));

      expect(item.working.stem.nodes, hasLength(3));
      expect(item.working.stem.nodes[1], isA<RawFallbackNode>());
      expect(item.working.stem.nodes[1], isNot(isA<TextNode>()));
      expect(
        (item.working.stem.nodes[1] as RawFallbackNode).rawJson,
        same((item.original.stem.nodes[1] as RawFallbackNode).rawJson),
      );
      expect(
        (item.working.options.single.content.nodes.single as RawFallbackNode)
            .rawJson['latex'],
        r'\sum_{i=1}^{n}',
      );
      expect(
        (item.working.answer! as ContentAnswer).content.nodes.single,
        isA<RawFallbackNode>(),
      );
      expect(
        item.working.explanation!.nodes.single,
        isA<RawFallbackNode>(),
      );

      // An unrelated typed edit keeps the raw fallback in the working stem.
      session = session.edit(
        itemId: 'item_r4d_001',
        edit: ReviewEdit(questionNumber: ReviewFieldEdit.replace(7)),
        expectedRevision: 0,
      );
      expect(session.items[0].working.stem.nodes[1], isA<RawFallbackNode>());
      expect(
        (session.items[0].working.stem.nodes[1] as RawFallbackNode)
            .rawJson['payload'],
        <String, Object?>{'unparsed': 'unsupported extension block'},
      );

      // The accepted final result retains the raw fallback explicitly.
      session = session.decide(
        itemId: 'item_r4d_001',
        decision: ReviewDecision.accepted,
        expectedRevision: 1,
      );
      final completed = session.complete(
        expectedRevision: 2,
        assessment: _completionAssessment(session),
      );
      final finalDraft = completed.result.items.single.finalDraft!;
      expect(finalDraft.stem.nodes[1], isA<RawFallbackNode>());
      expect(
        (finalDraft.stem.nodes[1] as RawFallbackNode).rawJson['type'],
        'raw_fallback',
      );
      expect(
        (finalDraft.options.single.content.nodes.single as RawFallbackNode)
            .rawJson['source'],
        'legacy-extension',
      );
      expect(
        completed.session.items.single.original.stem.nodes[1],
        isA<RawFallbackNode>(),
      );
    });
  });
}

ReviewSession _openSession(int itemCount) {
  return _adapter.openSession(
    sessionId: 'session_r4d_001',
    taskId: 'task_r4d_001',
    attemptToken: 'attempt_r4d_001',
    attemptNumber: 1,
    items: [
      for (var index = 1; index <= itemCount; index++)
        (itemId: 'item_r4d_00$index', draft: _draft('question_r4d_00$index')),
    ],
  );
}

ReviewSession _sessionWithIssues() {
  return _adapter.openSession(
    sessionId: 'session_r4d_issues',
    taskId: 'task_r4d_001',
    attemptToken: 'attempt_r4d_001',
    attemptNumber: 1,
    items: [
      (
        itemId: 'item_r4d_001',
        draft: _draftWithIssues('question_r4d_001'),
      ),
      (itemId: 'item_r4d_002', draft: _draft('question_r4d_002')),
    ],
  );
}

QuestionDraftV2 _draft(String questionId) {
  final source = SourceRef.document(sourceId: 'source_r4d_default');
  return QuestionDraftV2(
    questionId: questionId,
    kind: QuestionKind.singleChoice,
    questionNumber: 1,
    stem: _content('synthetic stem'),
    options: [
      QuestionOption(
        optionId: 'option_a',
        label: 'A',
        content: _content('synthetic option'),
      ),
    ],
    answer: ChoiceAnswer(optionIds: const ['option_a']),
    explanation: _content('synthetic explanation'),
    sourceRefs: [source],
  );
}

QuestionDraftV2 _draftWithIssues(String questionId) {
  final source = SourceRef.document(sourceId: 'source_r4d_issues');
  return QuestionDraftV2(
    questionId: questionId,
    kind: QuestionKind.singleChoice,
    questionNumber: 1,
    stem: _content('synthetic stem'),
    options: [
      QuestionOption(
        optionId: 'option_a',
        label: 'A',
        content: _content('synthetic option'),
      ),
    ],
    answer: ChoiceAnswer(optionIds: const ['option_a']),
    explanation: _content('synthetic explanation'),
    sourceRefs: [source],
    issues: [
      ImportIssue(
        code: 'issue_one',
        severity: ImportIssueSeverity.warning,
        field: ImportIssueField.stem,
        sourceRef: source,
      ),
      ImportIssue(
        code: 'issue_two',
        severity: ImportIssueSeverity.error,
        field: ImportIssueField.answer,
      ),
    ],
  );
}

ReviewCompletionAssessment _completionAssessment(
  ReviewSession session, {
  Map<String, List<int>> requiredIssueIndexesByItem = const {},
}) {
  return ReviewCompletionAssessment(
    sessionId: session.sessionId,
    assessedRevision: session.revision,
    items: [
      for (final item in session.items)
        ReviewItemCompletionAssessment(
          itemId: item.itemId,
          decision: item.decision,
          issueCount: item.original.issues.length,
          issueAcknowledgements: item.issueAcknowledgements,
          requiredIssueAcknowledgements: [
            for (final issueIndex
                in requiredIssueIndexesByItem[item.itemId] ?? const <int>[])
              ReviewIssueAcknowledgement(issueIndex: issueIndex),
          ],
        ),
    ],
  );
}

void _expectStale(
  void Function() action,
  ReviewSession session, {
  required int expectedRevision,
}) {
  try {
    action();
    fail('Expected a stale revision error.');
  } on ReviewSessionStaleRevisionError catch (error) {
    expect(error.sessionId, session.sessionId);
    expect(error.expectedRevision, expectedRevision);
    expect(error.actualRevision, session.revision);
  }
}

RichContent _content(String text) {
  return RichContent(nodes: [TextNode(text)]);
}

String _text(RichContent content) {
  final buffer = StringBuffer();
  for (final node in content.nodes) {
    if (node is TextNode) buffer.write(node.text);
  }
  return buffer.toString();
}
