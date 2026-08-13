import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_matcher.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_review_session.dart';
import 'package:shiroha_quiz/application/supplemental_answers/target_question_snapshot_service.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/answer_match_record.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_fragment.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_scope.dart';

const _artifact = SupplementalArtifactContext(
  supplementalFileId: 'file_001',
  artifactId: 'artifact_001',
  artifactRevision: 1,
);

void main() {
  group('SupplementalAnswerReviewSession lifecycle', () {
    test('fill candidate confirms with the next session revision', () {
      final session = _sessionFor([
        _target('q_1', number: 1, kind: QuestionKind.shortAnswer),
      ], [
        _fragment('frag_1', main: '1', answer: 'x = 1'),
      ]);

      expect(session.sessionRevision, 0);
      expect(
        session.outcomeOf('cand_frag_1_q_1'),
        CandidateReviewOutcome.pendingFill,
      );

      final result = session.confirmFill('cand_frag_1_q_1');

      expect(result.confirmation.sessionRevision, 1);
      expect(result.session.sessionRevision, 1);
      expect(
        result.session.outcomeOf('cand_frag_1_q_1'),
        CandidateReviewOutcome.confirmed,
      );
      expect(result.confirmation.candidate.targetStorageId, 'q_1');
    });

    test('conflict requires selectForReplace then confirmReplace', () {
      final session = _sessionFor([
        _target(
          'q_1',
          number: 1,
          kind: QuestionKind.shortAnswer,
          answer: ContentAnswer(content: _text('x = 9')),
        ),
      ], [
        _fragment('frag_1', main: '1', answer: 'x = 1'),
      ]);

      expect(
        session.outcomeOf('cand_frag_1_q_1'),
        CandidateReviewOutcome.pendingReplace,
      );
      expect(
        () => session.confirmFill('cand_frag_1_q_1'),
        throwsA(
          isA<SupplementalAnswerReviewException>().having(
            (error) => error.failure,
            'failure',
            SupplementalAnswerReviewFailure
                .conflictRequiresReplaceReconfirmation,
          ),
        ),
      );

      final selected = session.selectForReplace('cand_frag_1_q_1');
      expect(selected.sessionRevision, 1);
      final confirmed = selected.confirmReplace('cand_frag_1_q_1');
      expect(confirmed.confirmation.sessionRevision, 2);
      expect(
        confirmed.session.outcomeOf('cand_frag_1_q_1'),
        CandidateReviewOutcome.confirmed,
      );
    });

    test('noOp candidate is terminal and never committable', () {
      final session = _sessionFor([
        _target(
          'q_1',
          number: 1,
          kind: QuestionKind.shortAnswer,
          answer: ContentAnswer(content: _text('x = 1')),
        ),
      ], [
        _fragment('frag_1', main: '1', answer: 'x = 1'),
      ]);

      expect(
        session.outcomeOf('cand_frag_1_q_1'),
        CandidateReviewOutcome.noOp,
      );
      expect(
        () => session.confirmFill('cand_frag_1_q_1'),
        throwsA(
          isA<SupplementalAnswerReviewException>().having(
            (error) => error.failure,
            'failure',
            SupplementalAnswerReviewFailure.noOpTerminal,
          ),
        ),
      );
    });

    test('reject is terminal with zero mutation', () {
      final session = _sessionFor([
        _target('q_1', number: 1, kind: QuestionKind.shortAnswer),
      ], [
        _fragment('frag_1', main: '1', answer: 'x = 1'),
      ]);

      final rejected = session.reject('cand_frag_1_q_1');

      expect(
        rejected.outcomeOf('cand_frag_1_q_1'),
        CandidateReviewOutcome.rejected,
      );
      expect(
        () => rejected.confirmFill('cand_frag_1_q_1'),
        throwsA(
          isA<SupplementalAnswerReviewException>().having(
            (error) => error.failure,
            'failure',
            SupplementalAnswerReviewFailure.alreadyDecided,
          ),
        ),
      );
    });

    test('markCommitted is allowed only after confirmation', () {
      final session = _sessionFor([
        _target('q_1', number: 1, kind: QuestionKind.shortAnswer),
      ], [
        _fragment('frag_1', main: '1', answer: 'x = 1'),
      ]);

      final confirmed = session.confirmFill('cand_frag_1_q_1');
      final committed = confirmed.session.markCommitted('cand_frag_1_q_1');
      expect(
        committed.outcomeOf('cand_frag_1_q_1'),
        CandidateReviewOutcome.committed,
      );
      expect(
        () => session.markCommitted('cand_frag_1_q_1'),
        throwsA(
          isA<SupplementalAnswerReviewException>().having(
            (error) => error.failure,
            'failure',
            SupplementalAnswerReviewFailure.alreadyDecided,
          ),
        ),
      );
    });

    test('unknown candidate is rejected', () {
      final session = _sessionFor([
        _target('q_1', number: 1, kind: QuestionKind.shortAnswer),
      ], [
        _fragment('frag_1', main: '1', answer: 'x = 1'),
      ]);

      expect(
        () => session.confirmFill('cand_missing'),
        throwsA(
          isA<SupplementalAnswerReviewException>().having(
            (error) => error.failure,
            'failure',
            SupplementalAnswerReviewFailure.unknownCandidate,
          ),
        ),
      );
    });
  });
}

SupplementalAnswerReviewSession _sessionFor(
  List<AnswerTargetReference> targets,
  List<SupplementalAnswerFragment> fragments,
) {
  const matcher = SupplementalAnswerMatcher();
  final snapshot = TargetQuestionSnapshot(
    targets: targets,
    reports: const [],
  );
  final result = matcher.match(
    fragments: fragments,
    snapshot: snapshot,
    artifact: _artifact,
  );
  return SupplementalAnswerReviewSession(
    request: SupplementalAnswerMatchRequest(
      targetScope: const QuestionBankScope(bankName: 'bank_math'),
      supplementalFileId: 'file_001',
    ),
    snapshot: snapshot,
    matchResult: result,
  );
}

AnswerTargetReference _target(
  String storageId, {
  required int number,
  required QuestionKind kind,
  QuestionAnswer? answer,
}) {
  return AnswerTargetReference(
    storageId: storageId,
    bankName: 'bank_math',
    draft: QuestionDraftV2(
      questionId: storageId,
      kind: kind,
      questionNumber: number,
      stem: _text('synthetic stem'),
      answer: answer,
    ),
  );
}

SupplementalAnswerFragment _fragment(
  String fragmentId, {
  required String main,
  required String answer,
}) {
  return SupplementalAnswerFragment(
    fragmentId: fragmentId,
    normalizedMainNumber: main,
    answerContent: _text(answer),
    sourceRefs: [
      SourceRef.document(sourceId: 'artifact_001'),
    ],
    sequencePosition: const SupplementalSequencePosition(
      partIndex: 0,
      continuationOrdinal: 0,
    ),
  );
}

RichContent _text(String text) {
  return RichContent(nodes: [TextNode(text)]);
}
