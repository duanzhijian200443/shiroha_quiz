import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/review_session.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_pipeline/subjective_answer_distillation_snapshot_policy.dart';

void main() {
  group('CAS stale revisions', () {
    test('every transition rejects a stale revision with zero partial updates',
        () {
      final session = _open();
      final staleRevision = session.revision + 1;
      _expectStale(
        () => session.edit(
          itemId: 'item-1',
          edit: ReviewEdit(
            stem: ReviewFieldEdit.replace(_content('edited')),
          ),
          expectedRevision: staleRevision,
        ),
        session,
        expectedRevision: staleRevision,
      );
      _expectStale(
        () => session.restore(
          itemId: 'item-1',
          field: ReviewRestoreField.stem,
          expectedRevision: staleRevision,
        ),
        session,
        expectedRevision: staleRevision,
      );
      _expectStale(
        () => session.reset(itemId: 'item-1', expectedRevision: staleRevision),
        session,
        expectedRevision: staleRevision,
      );
      _expectStale(
        () => session.decide(
          itemId: 'item-1',
          decision: ReviewDecision.accepted,
          expectedRevision: staleRevision,
        ),
        session,
        expectedRevision: staleRevision,
      );
      _expectStale(
        () => session.acknowledge(
          itemId: 'item-1',
          acknowledgement: ReviewIssueAcknowledgement(issueIndex: 0),
          expectedRevision: staleRevision,
        ),
        session,
        expectedRevision: staleRevision,
      );
      _expectStale(
        () => session.applyAnswerAssist(
          itemId: 'item-1',
          assist: AnswerAssist(status: AnswerAssistStatus.localExtracted),
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

      expect(session, _open());
      expect(session.revision, 0);
      expect(session.status, ReviewStatus.open);
    });
  });

  group('session and item revisions', () {
    test(
        'session and affected item revisions advance exactly once per mutation',
        () {
      var session = _openWithIssues();
      expect(session.revision, 0);
      expect(session.items[0].revision, 0);
      expect(session.items[1].revision, 0);

      session = session.edit(
        itemId: 'item-1',
        edit: ReviewEdit(stem: ReviewFieldEdit.replace(_content('edited'))),
        expectedRevision: 0,
      );
      expect(session.revision, 1);
      expect(session.items[0].revision, 1);
      expect(session.items[1].revision, 0);

      session = session.restore(
        itemId: 'item-1',
        field: ReviewRestoreField.stem,
        expectedRevision: 1,
      );
      expect(session.revision, 2);
      expect(session.items[0].revision, 2);

      session = session.reset(itemId: 'item-1', expectedRevision: 2);
      expect(session.revision, 3);
      expect(session.items[0].revision, 3);

      session = session.decide(
        itemId: 'item-2',
        decision: ReviewDecision.accepted,
        expectedRevision: 3,
      );
      expect(session.revision, 4);
      expect(session.items[0].revision, 3);
      expect(session.items[1].revision, 1);

      session = session.acknowledge(
        itemId: 'item-1',
        acknowledgement: ReviewIssueAcknowledgement(issueIndex: 0),
        expectedRevision: 4,
      );
      expect(session.revision, 5);
      expect(session.items[0].revision, 4);

      session = session.applyAnswerAssist(
        itemId: 'item-1',
        assist: AnswerAssist(status: AnswerAssistStatus.localExtracted),
        expectedRevision: 5,
      );
      expect(session.revision, 6);
      expect(session.items[0].revision, 5);
      expect(session.items[1].revision, 1);
    });

    test('completion advances only the session revision', () {
      var session = _open();
      session = session.decide(
        itemId: 'item-1',
        decision: ReviewDecision.accepted,
        expectedRevision: 0,
      );
      session = session.decide(
        itemId: 'item-2',
        decision: ReviewDecision.rejected,
        expectedRevision: 1,
      );
      final completed = _complete(session);
      expect(completed.session.revision, 3);
      expect(completed.session.items[0].revision, 1);
      expect(completed.session.items[1].revision, 1);
      expect(completed.result.completedRevision, 3);
      expect(completed.session.items, session.items);
    });

    test('abandon advances only the session revision', () {
      final session = _open();
      final abandoned = session.abandon(expectedRevision: 0);
      expect(abandoned.status, ReviewStatus.abandoned);
      expect(abandoned.revision, 1);
      expect(abandoned.items, session.items);
      expect(abandoned.items[0].revision, 0);
    });
  });

  group('decision clearing', () {
    test('content edits, single-field restores, and resets clear the decision',
        () {
      var session = _open();
      session = session.decide(
        itemId: 'item-1',
        decision: ReviewDecision.accepted,
        expectedRevision: 0,
      );
      expect(session.items[0].decision, ReviewDecision.accepted);

      session = session.edit(
        itemId: 'item-1',
        edit: ReviewEdit(stem: ReviewFieldEdit.replace(_content('edited'))),
        expectedRevision: 1,
      );
      expect(session.items[0].decision, ReviewDecision.unreviewed);

      session = session.decide(
        itemId: 'item-1',
        decision: ReviewDecision.rejected,
        expectedRevision: 2,
      );
      session = session.restore(
        itemId: 'item-1',
        field: ReviewRestoreField.stem,
        expectedRevision: 3,
      );
      expect(session.items[0].decision, ReviewDecision.unreviewed);

      session = session.decide(
        itemId: 'item-1',
        decision: ReviewDecision.deferred,
        expectedRevision: 4,
      );
      session = session.reset(itemId: 'item-1', expectedRevision: 5);
      expect(session.items[0].decision, ReviewDecision.unreviewed);
      expect(session.items[0].edit.isUnchanged, isTrue);
    });
  });

  group('edit no-op and lifecycle', () {
    test('unchanged and repeated identical edits return the same aggregate',
        () {
      final open = _openWithIssues();
      final unchanged = open.edit(
        itemId: 'item-1',
        edit: ReviewEdit.unchanged(),
        expectedRevision: 0,
      );
      expect(unchanged, same(open));
      expect(unchanged.status, ReviewStatus.open);

      var session = open.edit(
        itemId: 'item-1',
        edit: ReviewEdit(stem: ReviewFieldEdit.replace(_content('edited'))),
        expectedRevision: 0,
      );
      session = session.decide(
        itemId: 'item-1',
        decision: ReviewDecision.accepted,
        expectedRevision: 1,
      );
      session = session.acknowledge(
        itemId: 'item-1',
        acknowledgement: ReviewIssueAcknowledgement(issueIndex: 0),
        expectedRevision: 2,
      );
      session = session.applyAnswerAssist(
        itemId: 'item-1',
        assist: AnswerAssist(status: AnswerAssistStatus.localExtracted),
        expectedRevision: 3,
      );

      final repeated = session.edit(
        itemId: 'item-1',
        edit: ReviewEdit(stem: ReviewFieldEdit.replace(_content('edited'))),
        expectedRevision: 4,
      );
      expect(repeated, same(session));
      expect(repeated.revision, 4);
      expect(repeated.status, ReviewStatus.inProgress);
      expect(repeated.items[0].revision, 4);
      expect(repeated.items[0].decision, ReviewDecision.accepted);
      expect(repeated.items[0].working, same(session.items[0].working));
      expect(repeated.items[0].answerAssist, session.items[0].answerAssist);
      expect(
        repeated.items[0].issueAcknowledgements,
        session.items[0].issueAcknowledgements,
      );
    });

    test('explicit original replacements and clear edits remain mutations', () {
      final open = _open();
      final replacedWithOriginal = open.edit(
        itemId: 'item-1',
        edit: ReviewEdit(
          stem: ReviewFieldEdit.replace(_content('synthetic stem')),
        ),
        expectedRevision: 0,
      );
      expect(replacedWithOriginal, isNot(same(open)));
      expect(replacedWithOriginal.items[0].edit.isUnchanged, isFalse);
      expect(replacedWithOriginal.items[0].working, open.items[0].working);
      expect(replacedWithOriginal.status, ReviewStatus.inProgress);

      final cleared = open.edit(
        itemId: 'item-1',
        edit: ReviewEdit(
          explanation: const ReviewFieldEdit<RichContent?>.clear(),
        ),
        expectedRevision: 0,
      );
      expect(cleared, isNot(same(open)));
      expect(cleared.items[0].edit.explanation.isClear, isTrue);
      expect(cleared.status, ReviewStatus.inProgress);
    });

    test('valid item mutations enter and retain in-progress state', () {
      final edited = _open().edit(
        itemId: 'item-1',
        edit: ReviewEdit(stem: ReviewFieldEdit.replace(_content('edited'))),
        expectedRevision: 0,
      );
      expect(edited.status, ReviewStatus.inProgress);
      expect(
        edited
            .restore(
              itemId: 'item-1',
              field: ReviewRestoreField.stem,
              expectedRevision: 1,
            )
            .status,
        ReviewStatus.inProgress,
      );
      expect(
        _open().reset(itemId: 'item-1', expectedRevision: 0).status,
        ReviewStatus.inProgress,
      );
      expect(
        _open()
            .decide(
              itemId: 'item-1',
              decision: ReviewDecision.accepted,
              expectedRevision: 0,
            )
            .status,
        ReviewStatus.inProgress,
      );
      expect(
        _openWithIssues()
            .acknowledge(
              itemId: 'item-1',
              acknowledgement: ReviewIssueAcknowledgement(issueIndex: 0),
              expectedRevision: 0,
            )
            .status,
        ReviewStatus.inProgress,
      );
      expect(
        _open()
            .applyAnswerAssist(
              itemId: 'item-1',
              assist: AnswerAssist(status: AnswerAssistStatus.localExtracted),
              expectedRevision: 0,
            )
            .status,
        ReviewStatus.inProgress,
      );

      expect(
        _open().abandon(expectedRevision: 0).status,
        ReviewStatus.abandoned,
      );
      expect(
        edited.abandon(expectedRevision: 1).status,
        ReviewStatus.abandoned,
      );
    });
  });

  group('typed edit and restore semantics', () {
    test('edits compose field-wise and restores revert exactly one field', () {
      var session = _open();
      session = session.edit(
        itemId: 'item-1',
        edit: ReviewEdit(stem: ReviewFieldEdit.replace(_content('edited'))),
        expectedRevision: 0,
      );
      session = session.edit(
        itemId: 'item-1',
        edit: ReviewEdit(questionNumber: ReviewFieldEdit.replace(9)),
        expectedRevision: 1,
      );
      expect(
        _contentEquals(session.items[0].working.stem, _content('edited')),
        isTrue,
      );
      expect(session.items[0].working.questionNumber, 9);

      session = session.restore(
        itemId: 'item-1',
        field: ReviewRestoreField.stem,
        expectedRevision: 2,
      );
      expect(
        _contentEquals(
          session.items[0].working.stem,
          _content('synthetic stem'),
        ),
        isTrue,
      );
      expect(session.items[0].working.questionNumber, 9);

      session = session.restore(
        itemId: 'item-1',
        field: ReviewRestoreField.questionNumber,
        expectedRevision: 3,
      );
      expect(session.items[0].working.questionNumber, 1);
      expect(
        _contentEquals(
          session.items[0].working.stem,
          _content('synthetic stem'),
        ),
        isTrue,
      );
      expect(session.items[0].edit.isUnchanged, isTrue);
    });

    test('restore maps every typed field to its original value', () {
      for (final field in ReviewRestoreField.values) {
        var session = _open();
        session = _applyFieldEdit(session, field);
        expect(session.items[0].edit.isUnchanged, isFalse, reason: '$field');
        expect(session.items[0].working, isNot(session.items[0].original),
            reason: '$field');

        session = session.restore(
          itemId: 'item-1',
          field: field,
          expectedRevision: session.revision,
        );
        expect(session.items[0].working, session.items[0].original,
            reason: '$field');
        expect(session.items[0].edit.isUnchanged, isTrue, reason: '$field');
        expect(session.items[0].revision, 2, reason: '$field');
        expect(session.revision, 2, reason: '$field');
      }
    });

    test('restoring an already-unchanged field is rejected with zero updates',
        () {
      final session = _open();
      for (final field in ReviewRestoreField.values) {
        expect(
          () => session.restore(
            itemId: 'item-1',
            field: field,
            expectedRevision: session.revision,
          ),
          throwsFormatException,
          reason: '$field',
        );
      }
      expect(session.revision, 0);
      expect(session.items[0].revision, 0);
      expect(session.items[0].decision, ReviewDecision.unreviewed);
      expect(session.items[0].edit.isUnchanged, isTrue);
      expect(session, _open());

      final edited = session.edit(
        itemId: 'item-1',
        edit: ReviewEdit(stem: ReviewFieldEdit.replace(_content('edited'))),
        expectedRevision: 0,
      );
      expect(
        () => edited.restore(
          itemId: 'item-1',
          field: ReviewRestoreField.kind,
          expectedRevision: 1,
        ),
        throwsFormatException,
      );
      expect(edited.revision, 1);
      expect(
        _contentEquals(edited.items[0].working.stem, _content('edited')),
        isTrue,
      );
      expect(edited.items[0].edit.isUnchanged, isFalse);
    });

    test('explanation edits change only the working draft', () {
      var session = _open();
      session = session.edit(
        itemId: 'item-1',
        edit: ReviewEdit(
          explanation: ReviewFieldEdit<RichContent?>.clear(),
        ),
        expectedRevision: 0,
      );
      expect(session.items[0].working.explanation, isNull);
      expect(
        _contentEquals(
          session.items[0].original.explanation,
          _content('original explanation'),
        ),
        isTrue,
      );

      session = session.edit(
        itemId: 'item-1',
        edit: ReviewEdit(
          explanation: ReviewFieldEdit.replace(_content('new explanation')),
        ),
        expectedRevision: 1,
      );
      expect(
        _contentEquals(
          session.items[0].working.explanation,
          _content('new explanation'),
        ),
        isTrue,
      );
      expect(
        _contentEquals(
          session.items[0].original.explanation,
          _content('original explanation'),
        ),
        isTrue,
      );
    });

    test('unknown item identities and unreviewed decisions are rejected', () {
      final session = _open();
      expect(
        () => session.edit(
          itemId: 'item-unknown',
          edit: ReviewEdit.unchanged(),
          expectedRevision: 0,
        ),
        throwsFormatException,
      );
      expect(
        () => session.restore(
          itemId: 'item-unknown',
          field: ReviewRestoreField.stem,
          expectedRevision: 0,
        ),
        throwsFormatException,
      );
      expect(
        () => session.reset(itemId: 'item-unknown', expectedRevision: 0),
        throwsFormatException,
      );
      expect(
        () => session.decide(
          itemId: 'item-unknown',
          decision: ReviewDecision.accepted,
          expectedRevision: 0,
        ),
        throwsFormatException,
      );
      expect(
        () => session.decide(
          itemId: 'item-1',
          decision: ReviewDecision.unreviewed,
          expectedRevision: 0,
        ),
        throwsFormatException,
      );
      expect(
        () => session.acknowledge(
          itemId: 'item-unknown',
          acknowledgement: ReviewIssueAcknowledgement(issueIndex: 0),
          expectedRevision: 0,
        ),
        throwsFormatException,
      );
      expect(
        () => session.applyAnswerAssist(
          itemId: 'item-unknown',
          assist: AnswerAssist(status: AnswerAssistStatus.localExtracted),
          expectedRevision: 0,
        ),
        throwsFormatException,
      );
      expect(session, _open());
    });
  });

  group('proof explanation invariant', () {
    test('clearing the explanation synchronously removes proof recognition',
        () {
      var session = _withProof(_open());
      expect(
        session.items[0].answerAssist?.status,
        AnswerAssistStatus.proofExplanationRecognized,
      );
      session = session.edit(
        itemId: 'item-1',
        edit: ReviewEdit(
          explanation: ReviewFieldEdit<RichContent?>.clear(),
        ),
        expectedRevision: 1,
      );
      expect(session.items[0].working.explanation, isNull);
      expect(session.items[0].answerAssist, isNull);
    });

    test(
        'replacing the explanation with an empty structure removes proof '
        'recognition', () {
      for (final emptyExplanation in <RichContent>[
        RichContent(nodes: const []),
        RichContent(nodes: const [TextNode(' \n ')]),
      ]) {
        var session = _withProof(_open());
        session = session.edit(
          itemId: 'item-1',
          edit: ReviewEdit(
            explanation: ReviewFieldEdit.replace(emptyExplanation),
          ),
          expectedRevision: 1,
        );
        expect(
            _isStructurallyEmpty(session.items[0].working.explanation), isTrue);
        expect(session.items[0].answerAssist, isNull);
      }
    });

    test(
        'resetting an item whose original explanation is empty removes proof '
        'recognition', () {
      var session = _sessionFromItems([
        ReviewItem.initial(
          itemId: 'item-1',
          original: _draft('question-1'),
        ),
      ]);
      session = session.edit(
        itemId: 'item-1',
        edit: ReviewEdit(
          explanation: ReviewFieldEdit.replace(_content('proof text')),
        ),
        expectedRevision: 0,
      );
      session = _withProof(session, expectedRevision: 1);
      expect(session.items[0].answerAssist, isNotNull);

      session = session.reset(itemId: 'item-1', expectedRevision: 2);
      expect(session.items[0].working.explanation, isNull);
      expect(session.items[0].answerAssist, isNull);
    });

    test('proof recognition cannot be applied to an empty working explanation',
        () {
      final session = _sessionFromItems([
        ReviewItem.initial(
          itemId: 'item-1',
          original: _draft('question-1'),
        ),
      ]);
      final assist = AnswerAssist(
        status: AnswerAssistStatus.proofExplanationRecognized,
        currentWorkingDraft: _draft(
          'question-other',
          explanation: _content('proof'),
        ),
      );
      expect(
        () => session.applyAnswerAssist(
          itemId: 'item-1',
          assist: assist,
          expectedRevision: 0,
        ),
        throwsFormatException,
      );
    });

    test(
        'non-empty explanation replacements and resets keep proof '
        'recognition', () {
      var session = _withProof(_open());
      session = session.edit(
        itemId: 'item-1',
        edit: ReviewEdit(
          explanation: ReviewFieldEdit.replace(_content('different proof')),
        ),
        expectedRevision: 1,
      );
      expect(
        session.items[0].answerAssist?.status,
        AnswerAssistStatus.proofExplanationRecognized,
      );
      session = session.reset(itemId: 'item-1', expectedRevision: 2);
      expect(
        session.items[0].answerAssist?.status,
        AnswerAssistStatus.proofExplanationRecognized,
      );
      expect(
        _contentEquals(
          session.items[0].working.explanation,
          _content('original explanation'),
        ),
        isTrue,
      );
    });

    test('explanation restores re-validate proof recognition', () {
      var session = _withProof(_open());
      session = session.edit(
        itemId: 'item-1',
        edit: ReviewEdit(
          explanation: ReviewFieldEdit.replace(_content('edited proof')),
        ),
        expectedRevision: 1,
      );
      expect(
        session.items[0].answerAssist?.status,
        AnswerAssistStatus.proofExplanationRecognized,
      );
      session = session.restore(
        itemId: 'item-1',
        field: ReviewRestoreField.explanation,
        expectedRevision: 2,
      );
      expect(
        session.items[0].answerAssist?.status,
        AnswerAssistStatus.proofExplanationRecognized,
      );
      expect(
        _contentEquals(
          session.items[0].working.explanation,
          _content('original explanation'),
        ),
        isTrue,
      );

      var emptySession = _sessionFromItems([
        ReviewItem.initial(
          itemId: 'item-1',
          original: _draft('question-1'),
        ),
      ]);
      emptySession = emptySession.edit(
        itemId: 'item-1',
        edit: ReviewEdit(
          explanation: ReviewFieldEdit.replace(_content('proof text')),
        ),
        expectedRevision: 0,
      );
      emptySession = _withProof(emptySession, expectedRevision: 1);
      emptySession = emptySession.restore(
        itemId: 'item-1',
        field: ReviewRestoreField.explanation,
        expectedRevision: 2,
      );
      expect(emptySession.items[0].working.explanation, isNull);
      expect(emptySession.items[0].answerAssist, isNull);
    });
  });

  group('issue acknowledgements', () {
    test('use stable issue indexes into the immutable original issue list', () {
      final issues = [
        ImportIssue(
          code: 'issue_one',
          severity: ImportIssueSeverity.warning,
        ),
        ImportIssue(code: 'issue_two', severity: ImportIssueSeverity.error),
      ];
      var session = _sessionFromItems([
        ReviewItem.initial(
          itemId: 'item-1',
          original: _draft('question-1', issues: issues),
        ),
        ReviewItem.initial(
          itemId: 'item-2',
          original: _draft('question-2'),
        ),
      ]);

      session = session.acknowledge(
        itemId: 'item-1',
        acknowledgement: ReviewIssueAcknowledgement(issueIndex: 1),
        expectedRevision: 0,
      );
      expect(session.items[0].issueAcknowledgements, [
        ReviewIssueAcknowledgement(issueIndex: 1),
      ]);
      expect(session.items[0].original.issues[1], same(issues[1]));
      expect(session.items[0].original.issues, issues);

      session = session.acknowledge(
        itemId: 'item-1',
        acknowledgement: ReviewIssueAcknowledgement(issueIndex: 1),
        expectedRevision: 1,
      );
      expect(session.items[0].issueAcknowledgements, hasLength(1));
      expect(session.revision, 2);

      session = session.acknowledge(
        itemId: 'item-1',
        acknowledgement: ReviewIssueAcknowledgement(issueIndex: 0),
        expectedRevision: 2,
      );
      expect(
        session.items[0].issueAcknowledgements
            .map((acknowledgement) => acknowledgement.issueIndex),
        [0, 1],
      );

      expect(
        () => session.acknowledge(
          itemId: 'item-1',
          acknowledgement: ReviewIssueAcknowledgement(issueIndex: 2),
          expectedRevision: 3,
        ),
        throwsFormatException,
      );
      expect(session.revision, 3);
      expect(session.items[0].issueAcknowledgements, hasLength(2));

      session = session.reset(itemId: 'item-1', expectedRevision: 3);
      expect(session.items[0].issueAcknowledgements, isEmpty);
      expect(session.items[0].original.issues[0], same(issues[0]));
      expect(session.items[0].original.issues[1], same(issues[1]));
    });

    test('survive content edits and restores but are cleared by reset', () {
      var session = _openWithIssues();
      session = session.acknowledge(
        itemId: 'item-1',
        acknowledgement: ReviewIssueAcknowledgement(issueIndex: 0),
        expectedRevision: 0,
      );
      session = session.edit(
        itemId: 'item-1',
        edit: ReviewEdit(stem: ReviewFieldEdit.replace(_content('edited'))),
        expectedRevision: 1,
      );
      expect(session.items[0].issueAcknowledgements, [
        ReviewIssueAcknowledgement(issueIndex: 0),
      ]);
      session = session.restore(
        itemId: 'item-1',
        field: ReviewRestoreField.stem,
        expectedRevision: 2,
      );
      expect(session.items[0].issueAcknowledgements, [
        ReviewIssueAcknowledgement(issueIndex: 0),
      ]);
      session = session.reset(itemId: 'item-1', expectedRevision: 3);
      expect(session.items[0].issueAcknowledgements, isEmpty);
    });
  });

  group('terminal states', () {
    test('completed sessions reject every further mutation', () {
      var session = _open();
      session = session.decide(
        itemId: 'item-1',
        decision: ReviewDecision.accepted,
        expectedRevision: 0,
      );
      session = session.decide(
        itemId: 'item-2',
        decision: ReviewDecision.accepted,
        expectedRevision: 1,
      );
      final completed = _complete(session).session;
      expect(completed.status, ReviewStatus.completed);
      final revision = completed.revision;

      expect(
        () => completed.edit(
          itemId: 'item-1',
          edit: ReviewEdit(stem: ReviewFieldEdit.replace(_content('x'))),
          expectedRevision: revision,
        ),
        throwsFormatException,
      );
      expect(
        () => completed.restore(
          itemId: 'item-1',
          field: ReviewRestoreField.stem,
          expectedRevision: revision,
        ),
        throwsFormatException,
      );
      expect(
        () => completed.reset(itemId: 'item-1', expectedRevision: revision),
        throwsFormatException,
      );
      expect(
        () => completed.decide(
          itemId: 'item-1',
          decision: ReviewDecision.rejected,
          expectedRevision: revision,
        ),
        throwsFormatException,
      );
      expect(
        () => completed.acknowledge(
          itemId: 'item-1',
          acknowledgement: ReviewIssueAcknowledgement(issueIndex: 0),
          expectedRevision: revision,
        ),
        throwsFormatException,
      );
      expect(
        () => completed.applyAnswerAssist(
          itemId: 'item-1',
          assist: AnswerAssist(status: AnswerAssistStatus.localExtracted),
          expectedRevision: revision,
        ),
        throwsFormatException,
      );
      expect(
        () => completed.complete(
          expectedRevision: revision,
          assessment: _completionAssessment(completed),
        ),
        throwsFormatException,
      );
      expect(
        () => completed.abandon(expectedRevision: revision),
        throwsFormatException,
      );
      expect(completed.status, ReviewStatus.completed);
      expect(completed.revision, revision);
    });

    test('abandoned sessions reject every further mutation', () {
      final abandoned = _open().abandon(expectedRevision: 0);
      final revision = abandoned.revision;
      expect(abandoned.status, ReviewStatus.abandoned);
      expect(
        () => abandoned.edit(
          itemId: 'item-1',
          edit: ReviewEdit.unchanged(),
          expectedRevision: revision,
        ),
        throwsFormatException,
      );
      expect(
        () => abandoned.restore(
          itemId: 'item-1',
          field: ReviewRestoreField.stem,
          expectedRevision: revision,
        ),
        throwsFormatException,
      );
      expect(
        () => abandoned.reset(itemId: 'item-1', expectedRevision: revision),
        throwsFormatException,
      );
      expect(
        () => abandoned.decide(
          itemId: 'item-1',
          decision: ReviewDecision.accepted,
          expectedRevision: revision,
        ),
        throwsFormatException,
      );
      expect(
        () => abandoned.acknowledge(
          itemId: 'item-1',
          acknowledgement: ReviewIssueAcknowledgement(issueIndex: 0),
          expectedRevision: revision,
        ),
        throwsFormatException,
      );
      expect(
        () => abandoned.applyAnswerAssist(
          itemId: 'item-1',
          assist: AnswerAssist(status: AnswerAssistStatus.localExtracted),
          expectedRevision: revision,
        ),
        throwsFormatException,
      );
      expect(
        () => abandoned.complete(
          expectedRevision: revision,
          assessment: _completionAssessment(abandoned),
        ),
        throwsFormatException,
      );
      expect(
        () => abandoned.abandon(expectedRevision: revision),
        throwsFormatException,
      );
      expect(abandoned.status, ReviewStatus.abandoned);
      expect(abandoned.revision, revision);
    });
  });

  group('completion validation', () {
    test('rejects assessments targeting another session or revision', () {
      final session = _open();
      final assessment = _completionAssessment(session);
      expect(
        () => session.complete(
          expectedRevision: 0,
          assessment: ReviewCompletionAssessment(
            sessionId: 'other-session',
            assessedRevision: 0,
            items: assessment.items,
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => session.complete(
          expectedRevision: 0,
          assessment: ReviewCompletionAssessment(
            sessionId: session.sessionId,
            assessedRevision: 1,
            items: assessment.items,
          ),
        ),
        throwsFormatException,
      );
      expect(session, _open());
    });

    test('rejects assessments that do not mirror session items', () {
      final session = _open();
      final assessment = _completionAssessment(session);
      expect(
        () => session.complete(
          expectedRevision: 0,
          assessment: ReviewCompletionAssessment(
            sessionId: session.sessionId,
            assessedRevision: 0,
            items: [assessment.items[0]],
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => session.complete(
          expectedRevision: 0,
          assessment: ReviewCompletionAssessment(
            sessionId: session.sessionId,
            assessedRevision: 0,
            items: [assessment.items[1], assessment.items[0]],
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => session.complete(
          expectedRevision: 0,
          assessment: ReviewCompletionAssessment(
            sessionId: session.sessionId,
            assessedRevision: 0,
            items: [
              ReviewItemCompletionAssessment(
                itemId: 'item-other',
                decision: ReviewDecision.accepted,
                issueCount: 0,
              ),
              assessment.items[1],
            ],
          ),
        ),
        throwsFormatException,
      );
      expect(session, _open());
    });

    test('rejects mismatched decisions, issue counts, and acknowledgements',
        () {
      var session = _openWithIssues();
      session = session.decide(
        itemId: 'item-1',
        decision: ReviewDecision.accepted,
        expectedRevision: 0,
      );
      session = session.acknowledge(
        itemId: 'item-1',
        acknowledgement: ReviewIssueAcknowledgement(issueIndex: 0),
        expectedRevision: 1,
      );
      session = session.decide(
        itemId: 'item-2',
        decision: ReviewDecision.accepted,
        expectedRevision: 2,
      );
      final revision = session.revision;
      final base = _completionAssessment(session);

      final wrongDecision = ReviewCompletionAssessment(
        sessionId: session.sessionId,
        assessedRevision: revision,
        items: [
          ReviewItemCompletionAssessment(
            itemId: 'item-1',
            decision: ReviewDecision.rejected,
            issueCount: 2,
            issueAcknowledgements: [
              ReviewIssueAcknowledgement(issueIndex: 0),
            ],
          ),
          base.items[1],
        ],
      );
      expect(
        () => session.complete(
          expectedRevision: revision,
          assessment: wrongDecision,
        ),
        throwsFormatException,
      );

      final wrongIssueCount = ReviewCompletionAssessment(
        sessionId: session.sessionId,
        assessedRevision: revision,
        items: [
          ReviewItemCompletionAssessment(
            itemId: 'item-1',
            decision: ReviewDecision.accepted,
            issueCount: 1,
            issueAcknowledgements: [
              ReviewIssueAcknowledgement(issueIndex: 0),
            ],
          ),
          base.items[1],
        ],
      );
      expect(
        () => session.complete(
          expectedRevision: revision,
          assessment: wrongIssueCount,
        ),
        throwsFormatException,
      );

      final missingAck = ReviewCompletionAssessment(
        sessionId: session.sessionId,
        assessedRevision: revision,
        items: [
          ReviewItemCompletionAssessment(
            itemId: 'item-1',
            decision: ReviewDecision.accepted,
            issueCount: 2,
            issueAcknowledgements: [
              ReviewIssueAcknowledgement(issueIndex: 0),
            ],
            requiredIssueAcknowledgements: [
              ReviewIssueAcknowledgement(issueIndex: 0),
              ReviewIssueAcknowledgement(issueIndex: 1),
            ],
          ),
          base.items[1],
        ],
      );
      expect(
        () => session.complete(
          expectedRevision: revision,
          assessment: missingAck,
        ),
        throwsFormatException,
      );

      final fabricatedAck = ReviewCompletionAssessment(
        sessionId: session.sessionId,
        assessedRevision: revision,
        items: [
          ReviewItemCompletionAssessment(
            itemId: 'item-1',
            decision: ReviewDecision.accepted,
            issueCount: 2,
            issueAcknowledgements: [
              ReviewIssueAcknowledgement(issueIndex: 0),
              ReviewIssueAcknowledgement(issueIndex: 1),
            ],
          ),
          base.items[1],
        ],
      );
      expect(
        () => session.complete(
          expectedRevision: revision,
          assessment: fabricatedAck,
        ),
        throwsFormatException,
      );

      expect(session.revision, revision);
      expect(session.status, ReviewStatus.inProgress);
    });

    test('policy blockers prevent completion', () {
      var session = _open();
      session = session.decide(
        itemId: 'item-1',
        decision: ReviewDecision.accepted,
        expectedRevision: 0,
      );
      session = session.decide(
        itemId: 'item-2',
        decision: ReviewDecision.accepted,
        expectedRevision: 1,
      );
      final blocked = ReviewCompletionAssessment(
        sessionId: session.sessionId,
        assessedRevision: session.revision,
        items: [
          ReviewItemCompletionAssessment(
            itemId: 'item-1',
            decision: ReviewDecision.accepted,
            issueCount: 0,
            policyBlockers: [
              ReviewPolicyBlocker(code: 'answer_missing'),
            ],
          ),
          ReviewItemCompletionAssessment(
            itemId: 'item-2',
            decision: ReviewDecision.accepted,
            issueCount: 0,
          ),
        ],
      );
      expect(
        () => session.complete(
          expectedRevision: 2,
          assessment: blocked,
        ),
        throwsFormatException,
      );
      expect(session.status, ReviewStatus.inProgress);
      expect(session.revision, 2);
    });

    test('completion enforces only the required acknowledgement subset', () {
      var noRequirements = _openWithIssues();
      noRequirements = noRequirements.decide(
        itemId: 'item-1',
        decision: ReviewDecision.accepted,
        expectedRevision: 0,
      );
      noRequirements = noRequirements.decide(
        itemId: 'item-2',
        decision: ReviewDecision.rejected,
        expectedRevision: 1,
      );
      final completedWithoutAcknowledgements = noRequirements.complete(
        expectedRevision: 2,
        assessment: _completionAssessment(noRequirements),
      );
      expect(
        completedWithoutAcknowledgements.session.status,
        ReviewStatus.completed,
      );

      var requiredSubset = _openWithIssues();
      requiredSubset = requiredSubset.decide(
        itemId: 'item-1',
        decision: ReviewDecision.accepted,
        expectedRevision: 0,
      );
      requiredSubset = requiredSubset.decide(
        itemId: 'item-2',
        decision: ReviewDecision.rejected,
        expectedRevision: 1,
      );
      final missingRequired = _completionAssessment(
        requiredSubset,
        requiredIssueIndexesByItem: const {
          'item-1': [1],
        },
      );
      expect(
        () => requiredSubset.complete(
          expectedRevision: 2,
          assessment: missingRequired,
        ),
        throwsFormatException,
      );
      expect(requiredSubset.revision, 2);
      expect(requiredSubset.status, ReviewStatus.inProgress);

      requiredSubset = requiredSubset.acknowledge(
        itemId: 'item-1',
        acknowledgement: ReviewIssueAcknowledgement(issueIndex: 1),
        expectedRevision: 2,
      );
      final completedSubset = requiredSubset.complete(
        expectedRevision: 3,
        assessment: _completionAssessment(
          requiredSubset,
          requiredIssueIndexesByItem: const {
            'item-1': [1],
          },
        ),
      );
      expect(completedSubset.session.status, ReviewStatus.completed);
      expect(
        requiredSubset.items[0].issueAcknowledgements
            .map((acknowledgement) => acknowledgement.issueIndex),
        [1],
      );
    });

    test('deferred and unreviewed items prevent completion', () {
      var session = _open();
      session = session.decide(
        itemId: 'item-1',
        decision: ReviewDecision.deferred,
        expectedRevision: 0,
      );
      session = session.decide(
        itemId: 'item-2',
        decision: ReviewDecision.accepted,
        expectedRevision: 1,
      );
      final deferredAssessment = _completionAssessment(session);
      expect(deferredAssessment.canComplete, isFalse);
      expect(
        () => session.complete(
          expectedRevision: 2,
          assessment: deferredAssessment,
        ),
        throwsFormatException,
      );
      expect(session.status, ReviewStatus.inProgress);

      final fresh = _open();
      expect(
        () => fresh.complete(
          expectedRevision: 0,
          assessment: _completionAssessment(fresh),
        ),
        throwsFormatException,
      );
      expect(fresh.status, ReviewStatus.open);
    });
  });

  group('completion results', () {
    test('completedRevision equals the post-transition session revision', () {
      var session = _open();
      session = session.decide(
        itemId: 'item-1',
        decision: ReviewDecision.rejected,
        expectedRevision: 0,
      );
      session = session.decide(
        itemId: 'item-2',
        decision: ReviewDecision.rejected,
        expectedRevision: 1,
      );
      final completed = _complete(session);
      expect(completed.session.status, ReviewStatus.completed);
      expect(completed.session.revision, 3);
      expect(completed.result.sessionId, session.sessionId);
      expect(completed.result.completedRevision, 3);
    });

    test('accepted items carry the final working draft and rejected items none',
        () {
      var session = _open();
      session = session.edit(
        itemId: 'item-1',
        edit: ReviewEdit(stem: ReviewFieldEdit.replace(_content('final stem'))),
        expectedRevision: 0,
      );
      session = session.decide(
        itemId: 'item-1',
        decision: ReviewDecision.accepted,
        expectedRevision: 1,
      );
      session = session.decide(
        itemId: 'item-2',
        decision: ReviewDecision.rejected,
        expectedRevision: 2,
      );
      final completed = _complete(session);
      expect(
        completed.result.items.map((item) => item.itemId),
        ['item-1', 'item-2'],
      );
      expect(completed.result.items[0].decision, ReviewDecision.accepted);
      expect(
        completed.result.items[0].finalDraft,
        same(completed.session.items[0].working),
      );
      expect(
        (completed.result.items[0].finalDraft!.stem.nodes.single as TextNode)
            .text,
        'final stem',
      );
      expect(completed.result.items[1].decision, ReviewDecision.rejected);
      expect(completed.result.items[1].finalDraft, isNull);
    });

    test('an all-rejected session completes without any final draft', () {
      var session = _open();
      session = session.decide(
        itemId: 'item-1',
        decision: ReviewDecision.rejected,
        expectedRevision: 0,
      );
      session = session.decide(
        itemId: 'item-2',
        decision: ReviewDecision.rejected,
        expectedRevision: 1,
      );
      final completed = _complete(session);
      expect(completed.session.status, ReviewStatus.completed);
      for (final item in completed.result.items) {
        expect(item.decision, ReviewDecision.rejected);
        expect(item.finalDraft, isNull);
      }
    });

    test(
        'a fully acknowledged session completes with required '
        'acknowledgements', () {
      var session = _openWithIssues();
      session = session.decide(
        itemId: 'item-1',
        decision: ReviewDecision.accepted,
        expectedRevision: 0,
      );
      session = session.acknowledge(
        itemId: 'item-1',
        acknowledgement: ReviewIssueAcknowledgement(issueIndex: 0),
        expectedRevision: 1,
      );
      session = session.acknowledge(
        itemId: 'item-1',
        acknowledgement: ReviewIssueAcknowledgement(issueIndex: 1),
        expectedRevision: 2,
      );
      session = session.decide(
        itemId: 'item-2',
        decision: ReviewDecision.rejected,
        expectedRevision: 3,
      );
      final completed = _complete(session);
      expect(completed.session.status, ReviewStatus.completed);
      expect(completed.result.items[0].decision, ReviewDecision.accepted);
      expect(completed.result.items[1].decision, ReviewDecision.rejected);
      expect(completed.result.items[1].finalDraft, isNull);
    });
  });

  group('result value contracts', () {
    test('validate final-draft presence by decision', () {
      expect(
        () => ReviewItemResult(
          itemId: 'item-1',
          decision: ReviewDecision.accepted,
        ),
        throwsFormatException,
      );
      expect(
        () => ReviewItemResult(
          itemId: 'item-1',
          decision: ReviewDecision.rejected,
          finalDraft: _draft('question-1'),
        ),
        throwsFormatException,
      );
      expect(
        () => ReviewItemResult(
          itemId: 'item-1',
          decision: ReviewDecision.unreviewed,
          finalDraft: _draft('question-1'),
        ),
        throwsFormatException,
      );
      expect(
        () => ReviewItemResult(
          itemId: 'item-1',
          decision: ReviewDecision.deferred,
          finalDraft: _draft('question-1'),
        ),
        throwsFormatException,
      );
    });

    test('results are defensive, ordered, and comparable', () {
      expect(
        () => ReviewResult(
          sessionId: 'session-1',
          completedRevision: 0,
          items: const [],
        ),
        throwsFormatException,
      );
      expect(
        () => ReviewResult(
          sessionId: 'session-1',
          completedRevision: 1,
          items: [
            ReviewItemResult(
              itemId: 'item-1',
              decision: ReviewDecision.accepted,
              finalDraft: _draft('question-1'),
            ),
            ReviewItemResult(
              itemId: 'item-1',
              decision: ReviewDecision.rejected,
            ),
          ],
        ),
        throwsFormatException,
      );

      final left = ReviewResult(
        sessionId: 'session-1',
        completedRevision: 1,
        items: [
          ReviewItemResult(
            itemId: 'item-1',
            decision: ReviewDecision.accepted,
            finalDraft: _draft('question-1'),
          ),
        ],
      );
      final right = ReviewResult(
        sessionId: 'session-1',
        completedRevision: 1,
        items: [
          ReviewItemResult(
            itemId: 'item-1',
            decision: ReviewDecision.accepted,
            finalDraft: _draft('question-1'),
          ),
        ],
      );
      expect(left, right);
      expect(left.hashCode, right.hashCode);
      expect(() => left.items.clear(), throwsUnsupportedError);
      expect(
        () => ReviewResult(
          sessionId: 'bad session',
          completedRevision: 1,
          items: left.items,
        ),
        throwsFormatException,
      );
      final otherSession = ReviewResult(
        sessionId: 'session-2',
        completedRevision: 1,
        items: left.items,
      );
      expect(left, isNot(otherSession));
      expect(left.hashCode, isNot(otherSession.hashCode));
    });
  });

  group('answer assist legacy mapping', () {
    test('rejected reason codes map losslessly to the legacy snapshot policy',
        () {
      const legacyRejectedCodes = <String>{
        'answer_distillation_rejected',
        'answer_distillation_rejected_not_candidate',
        'answer_distillation_rejected_question_number_changed',
        'answer_distillation_rejected_basis',
        'answer_distillation_rejected_empty',
        'answer_distillation_rejected_placeholder',
        'answer_distillation_rejected_too_verbose',
      };
      final typedRejectedCodes = <String>{
        for (final reason in AnswerAssistReason.values)
          if (reason != AnswerAssistReason.failed) reason.code,
      };
      expect(typedRejectedCodes, legacyRejectedCodes);
      expect(AnswerAssistReason.failed.code, 'answer_distillation_failed');

      for (final reason in AnswerAssistReason.values) {
        final status =
            reason == AnswerAssistReason.failed ? 'ai_failed' : 'ai_rejected';
        expect(
          SubjectiveAnswerDistillationSnapshotPolicy.sanitizeReason(
            status: status,
            value: reason.code,
          ),
          reason.code,
        );
      }
    });

    test(
        'the aggregate accepts every legacy rejected reason without '
        'redesigning combinations', () {
      for (final reason in AnswerAssistReason.values) {
        final session = _open();
        final assist = reason == AnswerAssistReason.failed
            ? AnswerAssist(status: AnswerAssistStatus.aiFailed, reason: reason)
            : AnswerAssist(
                status: AnswerAssistStatus.aiRejected,
                reason: reason,
              );
        final updated = session.applyAnswerAssist(
          itemId: 'item-1',
          assist: assist,
          expectedRevision: 0,
        );
        expect(updated.items[0].answerAssist, assist);
        expect(updated.revision, 1);
        expect(updated.items[0].revision, 1);
        expect(updated.items[1].revision, 0);
      }
    });
  });

  group('original immutability', () {
    test('originals stay immutable through the full mutation lifecycle', () {
      final issues = [
        ImportIssue(code: 'issue_one', severity: ImportIssueSeverity.warning),
      ];
      final originalOne = _draft(
        'question-1',
        explanation: _content('original explanation'),
        issues: issues,
      );
      final originalTwo = _draft('question-2');
      var session = _sessionFromItems([
        ReviewItem.initial(itemId: 'item-1', original: originalOne),
        ReviewItem.initial(itemId: 'item-2', original: originalTwo),
      ]);

      session = session.edit(
        itemId: 'item-1',
        edit: ReviewEdit(stem: ReviewFieldEdit.replace(_content('edited'))),
        expectedRevision: 0,
      );
      session = session.restore(
        itemId: 'item-1',
        field: ReviewRestoreField.stem,
        expectedRevision: 1,
      );
      session = session.reset(itemId: 'item-1', expectedRevision: 2);
      session = session.decide(
        itemId: 'item-1',
        decision: ReviewDecision.rejected,
        expectedRevision: 3,
      );
      session = session.acknowledge(
        itemId: 'item-1',
        acknowledgement: ReviewIssueAcknowledgement(issueIndex: 0),
        expectedRevision: 4,
      );
      session = session.decide(
        itemId: 'item-2',
        decision: ReviewDecision.rejected,
        expectedRevision: 5,
      );

      expect(session.items[0].original, same(originalOne));
      expect(session.items[0].original.stem, originalOne.stem);
      expect(session.items[0].original.explanation, originalOne.explanation);
      expect(session.items[0].original.issues.single, same(issues.single));
      expect(session.items[1].original, same(originalTwo));

      final completed = _complete(session);
      expect(completed.session.items[0].original, same(originalOne));
      expect(
        completed.session.items[0].original.issues.single,
        same(issues.single),
      );
    });
  });
}

ReviewSession _open() {
  return _sessionFromItems([
    ReviewItem.initial(
      itemId: 'item-1',
      original: _draft(
        'question-1',
        explanation: _content('original explanation'),
      ),
    ),
    ReviewItem.initial(
      itemId: 'item-2',
      original: _draft('question-2'),
    ),
  ]);
}

ReviewSession _openWithIssues() {
  return _sessionFromItems([
    ReviewItem.initial(
      itemId: 'item-1',
      original: _draft(
        'question-1',
        explanation: _content('original explanation'),
        issues: [
          ImportIssue(
            code: 'issue_one',
            severity: ImportIssueSeverity.warning,
          ),
          ImportIssue(code: 'issue_two', severity: ImportIssueSeverity.error),
        ],
      ),
    ),
    ReviewItem.initial(
      itemId: 'item-2',
      original: _draft('question-2'),
    ),
  ]);
}

ReviewSession _sessionFromItems(Iterable<ReviewItem> items) {
  return ReviewSession.open(
    sessionId: 'session-1',
    taskId: 'task-1',
    attemptToken: 'attempt-1',
    attemptNumber: 1,
    items: items,
  );
}

ReviewSession _withProof(ReviewSession session, {int? expectedRevision}) {
  return session.applyAnswerAssist(
    itemId: 'item-1',
    assist: AnswerAssist(
      status: AnswerAssistStatus.proofExplanationRecognized,
      currentWorkingDraft: session.items[0].working,
    ),
    expectedRevision: expectedRevision ?? session.revision,
  );
}

({ReviewSession session, ReviewResult result}) _complete(
  ReviewSession session,
) {
  return session.complete(
    expectedRevision: session.revision,
    assessment: _completionAssessment(session),
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

bool _isStructurallyEmpty(RichContent? explanation) {
  if (explanation == null) return true;
  for (final node in explanation.nodes) {
    if (node is TextNode) {
      if (node.text.trim().isNotEmpty) return false;
    } else {
      return false;
    }
  }
  return true;
}

QuestionDraftV2 _draft(
  String questionId, {
  int? questionNumber = 1,
  RichContent? explanation,
  Iterable<ImportIssue> issues = const [],
}) {
  final source = SourceRef.document(sourceId: 'source-1');
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
        sourceRef: source,
      ),
    ],
    answer: ChoiceAnswer(optionIds: const ['option-a']),
    explanation: explanation,
    sourceRefs: [source],
    assetRefs: const [],
    issues: issues,
  );
}

RichContent _content(String text) {
  return RichContent(nodes: [TextNode(text)]);
}

bool _contentEquals(RichContent? actual, RichContent? expected) {
  if (identical(actual, expected)) return true;
  if (actual == null || expected == null) return false;
  return ContentAnswer(content: actual) == ContentAnswer(content: expected);
}

ReviewSession _applyFieldEdit(
  ReviewSession session,
  ReviewRestoreField field,
) {
  final edit = switch (field) {
    ReviewRestoreField.kind => ReviewEdit(
        kind: ReviewFieldEdit.replace(QuestionKind.shortAnswer),
      ),
    ReviewRestoreField.questionNumber => ReviewEdit(
        questionNumber: ReviewFieldEdit.replace(9),
      ),
    ReviewRestoreField.stem => ReviewEdit(
        stem: ReviewFieldEdit.replace(_content('edited')),
      ),
    ReviewRestoreField.options => ReviewEdit(
        options: ReviewFieldEdit.replace(<QuestionOption>[
          QuestionOption(
            optionId: 'option-a',
            label: 'A',
            content: _content('edited option'),
            sourceRef: session.items[0].original.options.single.sourceRef,
          ),
          QuestionOption(
            optionId: 'option-b',
            label: 'B',
            content: _content('new option'),
          ),
        ]),
      ),
    ReviewRestoreField.answer => ReviewEdit(
        answer: ReviewFieldEdit<QuestionAnswer?>.replace(
          ContentAnswer(content: _content('edited answer')),
        ),
      ),
    ReviewRestoreField.explanation => ReviewEdit(
        explanation: ReviewFieldEdit<RichContent?>.replace(
          _content('edited explanation'),
        ),
      ),
  };
  return session.edit(
    itemId: 'item-1',
    edit: edit,
    expectedRevision: session.revision,
  );
}
