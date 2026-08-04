import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/review_session.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

void main() {
  group('ReviewSession initial model', () {
    test('opens with one immutable origin and frozen item order', () {
      final input = <ReviewItem>[
        ReviewItem.initial(itemId: 'item-1', original: _draft('question-1')),
        ReviewItem.initial(itemId: 'item-2', original: _draft('question-2')),
      ];

      final session = ReviewSession.open(
        sessionId: 'session-1',
        taskId: 'task-1',
        attemptToken: 'attempt-token-1',
        attemptNumber: 2,
        items: input,
      );
      input
        ..clear()
        ..add(
          ReviewItem.initial(itemId: 'item-3', original: _draft('question-3')),
        );

      expect(session.status, ReviewStatus.open);
      expect(session.revision, 0);
      expect(
        session.origin,
        ReviewSessionOrigin(
          taskId: 'task-1',
          attemptToken: 'attempt-token-1',
          attemptNumber: 2,
        ),
      );
      expect(session.items.map((item) => item.itemId), ['item-1', 'item-2']);
      expect(
        () => session.items.add(
          ReviewItem.initial(itemId: 'item-4', original: _draft('question-4')),
        ),
        throwsUnsupportedError,
      );
    });

    test('rejects invalid identities, attempts, empty and duplicate sessions',
        () {
      expect(
        () => ReviewSessionOrigin(
          taskId: 'task',
          attemptToken: 'attempt',
          attemptNumber: 0,
        ),
        throwsFormatException,
      );
      expect(
        () => ReviewItem.initial(itemId: 'bad item', original: _draft('q-1')),
        throwsFormatException,
      );
      expect(
        () => ReviewSession.open(
          sessionId: '',
          taskId: 'task',
          attemptToken: 'attempt',
          attemptNumber: 1,
          items: [ReviewItem.initial(itemId: 'item', original: _draft('q-1'))],
        ),
        throwsFormatException,
      );
      expect(
        () => ReviewSession.open(
          sessionId: 'session',
          taskId: 'task',
          attemptToken: 'attempt',
          attemptNumber: 1,
          items: const [],
        ),
        throwsFormatException,
      );

      final first = ReviewItem.initial(
        itemId: 'same-item',
        original: _draft('question-1'),
      );
      expect(
        () => _session([
          first,
          ReviewItem.initial(
            itemId: 'same-item',
            original: _draft('question-2'),
          ),
        ]),
        throwsFormatException,
      );
      expect(
        () => _session([
          first,
          ReviewItem.initial(
            itemId: 'other-item',
            original: _draft('question-1'),
          ),
        ]),
        throwsFormatException,
      );
    });

    test('initial items preserve an isolated, unchanged working draft', () {
      final original = _draft('question-1');
      final item = ReviewItem.initial(itemId: 'item-1', original: original);

      expect(item.original, same(original));
      expect(item.working, original);
      expect(item.working, isNot(same(original)));
      expect(item.edit.isUnchanged, isTrue);
      expect(item.decision, ReviewDecision.unreviewed);
      expect(item.answerAssist, isNull);
    });

    test('initial models have complete value equality and hashes', () {
      final left = _session([
        ReviewItem.initial(itemId: 'item-1', original: _draft('question-1')),
      ]);
      final right = _session([
        ReviewItem.initial(itemId: 'item-1', original: _draft('question-1')),
      ]);

      expect(left, right);
      expect(left.hashCode, right.hashCode);
      expect(left.items.single, right.items.single);
      expect(left.items.single.hashCode, right.items.single.hashCode);
    });
  });

  group('ReviewEdit', () {
    test('supports typed replacement and nullable clear semantics', () {
      final original = _draft(
        'question-1',
        explanation: _content('old explanation'),
      );
      final edit = ReviewEdit(
        kind: ReviewFieldEdit.replace(QuestionKind.shortAnswer),
        questionNumber: const ReviewFieldEdit<int?>.clear(),
        stem: ReviewFieldEdit.replace(_content('replacement stem')),
        answer: const ReviewFieldEdit<QuestionAnswer?>.clear(),
        explanation: const ReviewFieldEdit<RichContent?>.clear(),
      );

      final working = edit.deriveWorkingDraft(original);

      expect(working.kind, QuestionKind.shortAnswer);
      expect(working.questionNumber, isNull);
      expect((working.stem.nodes.single as TextNode).text, 'replacement stem');
      expect(working.answer, isNull);
      expect(working.explanation, isNull);
      expect(original.questionNumber, 1);
      expect(original.answer, isNotNull);
      expect(original.explanation, isNotNull);
    });

    test('rejects clear for required fields and null replacement', () {
      expect(
        () => ReviewEdit(
          kind: const ReviewFieldEdit<QuestionKind>.clear(),
        ),
        throwsFormatException,
      );
      expect(
        () => ReviewEdit(
          stem: const ReviewFieldEdit<RichContent>.clear(),
        ),
        throwsFormatException,
      );
      expect(
        () => ReviewEdit(
          options: const ReviewFieldEdit<List<QuestionOption>>.clear(),
        ),
        throwsFormatException,
      );
      expect(
        () => ReviewFieldEdit<RichContent?>.replace(null),
        throwsFormatException,
      );
      expect(
        () => const ReviewFieldEdit<int?>.unchanged().replacement,
        throwsStateError,
      );
    });

    test('preserves immutable identity, provenance, assets and issues', () {
      final source = SourceRef.document(sourceId: 'source-1');
      final issue = ImportIssue(
        code: 'review_required',
        severity: ImportIssueSeverity.warning,
        sourceRef: source,
      );
      final asset = SourcedAssetRef(
        sourceId: 'source-1',
        asset: AssetRef(assetId: 'asset-1', kind: AssetKind.image),
      );
      final original = _draft(
        'question-1',
        source: source,
        issues: [issue],
        assets: [asset],
      );

      final working = ReviewEdit(
        stem: ReviewFieldEdit.replace(_content('edited stem')),
      ).deriveWorkingDraft(original);

      expect(working.questionId, original.questionId);
      expect(working.sourceRefs, original.sourceRefs);
      expect(working.assetRefs, original.assetRefs);
      expect(working.issues, original.issues);
      expect(working.sourceRefs, isNot(same(original.sourceRefs)));
      expect(working.assetRefs, isNot(same(original.assetRefs)));
      expect(working.issues, isNot(same(original.issues)));
    });

    test('option replacement preserves existing provenance', () {
      final source = SourceRef.document(sourceId: 'source-1');
      final original = _draft('question-1', source: source);
      final replacement = <QuestionOption>[
        QuestionOption(
          optionId: 'option-a',
          label: 'A',
          content: _content('edited option'),
          sourceRef: source,
        ),
        QuestionOption(
          optionId: 'option-new',
          label: 'B',
          content: _content('new option'),
        ),
      ];
      final edit = ReviewEdit(
        options: ReviewFieldEdit.replace(replacement),
      );
      replacement.clear();

      final working = edit.deriveWorkingDraft(original);
      expect(working.options.map((option) => option.optionId), [
        'option-a',
        'option-new',
      ]);
      expect(() => edit.options.replacement.clear(), throwsUnsupportedError);

      expect(
        () => ReviewEdit(
          options: ReviewFieldEdit.replace([
            QuestionOption(
              optionId: 'option-a',
              label: 'A',
              content: _content('tampered'),
            ),
          ]),
        ).deriveWorkingDraft(original),
        throwsFormatException,
      );
      expect(
        () => ReviewEdit(
          options: ReviewFieldEdit.replace([
            QuestionOption(
              optionId: 'option-new',
              label: 'B',
              content: _content('fabricated'),
              sourceRef: source,
            ),
          ]),
        ).deriveWorkingDraft(original),
        throwsFormatException,
      );
    });

    test('field edits compare structurally', () {
      final left = ReviewEdit(
        stem: ReviewFieldEdit.replace(_content('same')),
        options: ReviewFieldEdit.replace([
          QuestionOption(
            optionId: 'option-a',
            label: 'A',
            content: _content('same option'),
          ),
        ]),
      );
      final right = ReviewEdit(
        stem: ReviewFieldEdit.replace(_content('same')),
        options: ReviewFieldEdit.replace([
          QuestionOption(
            optionId: 'option-a',
            label: 'A',
            content: _content('same option'),
          ),
        ]),
      );

      expect(left, right);
      expect(left.hashCode, right.hashCode);
    });
  });

  group('AnswerAssist', () {
    test('exposes stable reason-code mapping and legal combinations', () {
      expect(
        AnswerAssistReason.rejected.code,
        'answer_distillation_rejected',
      );
      expect(
        AnswerAssist(
          status: AnswerAssistStatus.aiRejected,
          reason: AnswerAssistReason.rejectedBasis,
        ),
        AnswerAssist(
          status: AnswerAssistStatus.aiRejected,
          reason: AnswerAssistReason.rejectedBasis,
        ),
      );
      expect(
        AnswerAssist(
          status: AnswerAssistStatus.aiFailed,
          reason: AnswerAssistReason.failed,
        ).status,
        AnswerAssistStatus.aiFailed,
      );
      expect(
        () => AnswerAssist(status: AnswerAssistStatus.aiRejected),
        throwsFormatException,
      );
      expect(
        () => AnswerAssist(
          status: AnswerAssistStatus.aiFailed,
          reason: AnswerAssistReason.rejected,
        ),
        throwsFormatException,
      );
      expect(
        () => AnswerAssist(
          status: AnswerAssistStatus.localExtracted,
          reason: AnswerAssistReason.rejected,
        ),
        throwsFormatException,
      );
    });

    test('proof recognition requires current structural explanation', () {
      for (final explanation in <RichContent?>[
        null,
        RichContent(nodes: const []),
        RichContent(nodes: const [TextNode('  \n')]),
      ]) {
        expect(
          () => AnswerAssist(
            status: AnswerAssistStatus.proofExplanationRecognized,
            currentWorkingDraft: _draft(
              'question-empty-proof',
              explanation: explanation,
            ),
          ),
          throwsFormatException,
        );
      }

      final textProof = AnswerAssist(
        status: AnswerAssistStatus.proofExplanationRecognized,
        currentWorkingDraft: _draft(
          'question-text-proof',
          explanation: _content('proof'),
        ),
      );
      final nonTextProof = AnswerAssist(
        status: AnswerAssistStatus.proofExplanationRecognized,
        currentWorkingDraft: _draft(
          'question-math-proof',
          explanation: RichContent(nodes: const [InlineMathNode('')]),
        ),
      );

      expect(textProof.status, AnswerAssistStatus.proofExplanationRecognized);
      expect(
          nonTextProof.status, AnswerAssistStatus.proofExplanationRecognized);
    });
  });

  group('completion assessment values', () {
    test('are defensive, ordered, comparable pure decision data', () {
      final acknowledgements = <ReviewIssueAcknowledgement>[
        ReviewIssueAcknowledgement(issueIndex: 0),
      ];
      final item = ReviewItemCompletionAssessment(
        itemId: 'item-1',
        decision: ReviewDecision.accepted,
        issueCount: 1,
        issueAcknowledgements: acknowledgements,
      );
      acknowledgements.clear();
      final assessment = ReviewCompletionAssessment(
        sessionId: 'session-1',
        assessedRevision: 3,
        items: [item],
      );
      final equalAssessment = ReviewCompletionAssessment(
        sessionId: 'session-1',
        assessedRevision: 3,
        items: [
          ReviewItemCompletionAssessment(
            itemId: 'item-1',
            decision: ReviewDecision.accepted,
            issueCount: 1,
            issueAcknowledgements: [
              ReviewIssueAcknowledgement(issueIndex: 0),
            ],
          ),
        ],
      );

      expect(item.issueAcknowledgements, hasLength(1));
      expect(item.canComplete, isTrue);
      expect(assessment.canComplete, isTrue);
      expect(assessment, equalAssessment);
      expect(assessment.hashCode, equalAssessment.hashCode);
      expect(() => assessment.items.clear(), throwsUnsupportedError);
      expect(
        () => item.issueAcknowledgements.clear(),
        throwsUnsupportedError,
      );
    });

    test('blockers and incomplete decisions prevent completion', () {
      final blocker = ReviewPolicyBlocker(code: 'answer_missing');
      final blocked = ReviewItemCompletionAssessment(
        itemId: 'item-1',
        decision: ReviewDecision.accepted,
        issueCount: 0,
        policyBlockers: [blocker],
      );
      final unreviewed = ReviewItemCompletionAssessment(
        itemId: 'item-2',
        decision: ReviewDecision.unreviewed,
        issueCount: 0,
      );

      expect(blocked.canComplete, isFalse);
      expect(unreviewed.canComplete, isFalse);
      expect(
        ReviewCompletionAssessment(
          sessionId: 'session-1',
          assessedRevision: 0,
          items: [blocked, unreviewed],
        ).canComplete,
        isFalse,
      );
    });

    test('rejects malformed or contradictory assessment values', () {
      expect(
        () => ReviewIssueAcknowledgement(issueIndex: -1),
        throwsFormatException,
      );
      expect(
        () => ReviewPolicyBlocker(code: 'Not Safe'),
        throwsFormatException,
      );
      expect(
        () => ReviewItemCompletionAssessment(
          itemId: 'item-1',
          decision: ReviewDecision.accepted,
          issueCount: 0,
          issueAcknowledgements: [
            ReviewIssueAcknowledgement(issueIndex: 0),
          ],
        ),
        throwsFormatException,
      );
      expect(
        () => ReviewCompletionAssessment(
          sessionId: 'session-1',
          assessedRevision: -1,
          items: [
            ReviewItemCompletionAssessment(
              itemId: 'item-1',
              decision: ReviewDecision.accepted,
              issueCount: 0,
            ),
          ],
        ),
        throwsFormatException,
      );
      expect(
        () => ReviewCompletionAssessment(
          sessionId: 'session-1',
          assessedRevision: 0,
          items: const [],
        ),
        throwsFormatException,
      );
    });
  });

  test('status and decision enums retain the frozen cases', () {
    expect(ReviewStatus.values, [
      ReviewStatus.open,
      ReviewStatus.inProgress,
      ReviewStatus.completed,
      ReviewStatus.abandoned,
    ]);
    expect(ReviewDecision.values, [
      ReviewDecision.unreviewed,
      ReviewDecision.accepted,
      ReviewDecision.rejected,
      ReviewDecision.deferred,
    ]);
  });
}

ReviewSession _session(Iterable<ReviewItem> items) {
  return ReviewSession.open(
    sessionId: 'session-1',
    taskId: 'task-1',
    attemptToken: 'attempt-1',
    attemptNumber: 1,
    items: items,
  );
}

QuestionDraftV2 _draft(
  String questionId, {
  int? questionNumber = 1,
  RichContent? explanation,
  SourceRef? source,
  Iterable<ImportIssue> issues = const [],
  Iterable<SourcedAssetRef> assets = const [],
}) {
  final effectiveSource = source ?? SourceRef.document(sourceId: 'source-1');
  return QuestionDraftV2(
    questionId: questionId,
    kind: QuestionKind.singleChoice,
    questionNumber: questionNumber,
    stem: _content('synthetic stem'),
    options: [
      QuestionOption(
        optionId: 'option-a',
        label: 'A',
        content: _content('synthetic option'),
        sourceRef: effectiveSource,
      ),
    ],
    answer: ChoiceAnswer(optionIds: const ['option-a']),
    explanation: explanation,
    sourceRefs: [effectiveSource],
    assetRefs: assets,
    issues: issues,
  );
}

RichContent _content(String text) {
  return RichContent(nodes: [TextNode(text)]);
}
