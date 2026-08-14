import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/answers/answer_candidate_review_session.dart';
import 'package:shiroha_quiz/domain/answers/answer_candidate.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

void main() {
  group('shared fill flow', () {
    test('pending fill -> confirm -> confirmed -> committed', () {
      final session = AnswerCandidateReviewSession(
        candidates: [
          _candidate('cand_fill', writeIntent: CandidateWriteIntent.fill)
        ],
      );
      expect(
          session.outcomeOf('cand_fill'), CandidateReviewOutcome.pendingFill);
      expect(session.sessionRevision, 0);

      final confirmed = session.confirmFill('cand_fill');
      expect(confirmed.confirmation.sessionRevision, 1);
      expect(confirmed.session.sessionRevision, 1);
      expect(confirmed.session.outcomeOf('cand_fill'),
          CandidateReviewOutcome.confirmed);
      expect(confirmed.confirmation.candidate.candidateId, 'cand_fill');

      final committed = confirmed.session.markCommitted('cand_fill');
      expect(committed.sessionRevision, 2);
      expect(
          committed.outcomeOf('cand_fill'), CandidateReviewOutcome.committed);
    });

    test('AI origin uses the identical fill transition', () {
      final session = AnswerCandidateReviewSession(
        candidates: [
          _candidate('cand_ai_fill',
              writeIntent: CandidateWriteIntent.fill, origin: _aiOrigin()),
        ],
      );
      final confirmed = session.confirmFill('cand_ai_fill');
      expect(confirmed.confirmation.sessionRevision, 1);
      expect(confirmed.session.outcomeOf('cand_ai_fill'),
          CandidateReviewOutcome.confirmed);
      final committed = confirmed.session.markCommitted('cand_ai_fill');
      expect(committed.outcomeOf('cand_ai_fill'),
          CandidateReviewOutcome.committed);
    });

    test('Supplemental and AI candidates share one session and transitions',
        () {
      final session = AnswerCandidateReviewSession(
        candidates: [
          _candidate('cand_sup_fill',
              writeIntent: CandidateWriteIntent.fill,
              origin: _supplementalOrigin()),
          _candidate('cand_ai_fill',
              writeIntent: CandidateWriteIntent.fill, origin: _aiOrigin()),
        ],
      );

      final first = session.confirmFill('cand_sup_fill');
      expect(first.confirmation.sessionRevision, 1);
      final second = first.session.confirmFill('cand_ai_fill');
      expect(second.confirmation.sessionRevision, 2);
      expect(second.session.outcomeOf('cand_sup_fill'),
          CandidateReviewOutcome.confirmed);
      expect(second.session.outcomeOf('cand_ai_fill'),
          CandidateReviewOutcome.confirmed);
    });
  });

  group('noOp terminal', () {
    test('noOp candidate is terminal and never committable', () {
      final session = AnswerCandidateReviewSession(
        candidates: [
          _candidate('cand_noop', writeIntent: CandidateWriteIntent.noOp)
        ],
      );
      expect(session.outcomeOf('cand_noop'), CandidateReviewOutcome.noOp);
      expect(
        () => session.confirmFill('cand_noop'),
        throwsA(
          isA<AnswerCandidateReviewException>().having(
            (error) => error.failure,
            'failure',
            AnswerCandidateReviewFailure.noOpTerminal,
          ),
        ),
      );
      expect(
        () => session.confirmReplace('cand_noop'),
        throwsA(
          isA<AnswerCandidateReviewException>().having(
            (error) => error.failure,
            'failure',
            AnswerCandidateReviewFailure.replaceFlowRequired,
          ),
        ),
      );
      expect(session.sessionRevision, 0);
    });

    test('AI origin noOp is terminal identically', () {
      final session = AnswerCandidateReviewSession(
        candidates: [
          _candidate('cand_ai_noop',
              writeIntent: CandidateWriteIntent.noOp, origin: _aiOrigin()),
        ],
      );
      expect(session.outcomeOf('cand_ai_noop'), CandidateReviewOutcome.noOp);
      expect(
        () => session.confirmFill('cand_ai_noop'),
        throwsA(
          isA<AnswerCandidateReviewException>().having(
            (error) => error.failure,
            'failure',
            AnswerCandidateReviewFailure.noOpTerminal,
          ),
        ),
      );
    });
  });

  group('replace boundary', () {
    AnswerCandidateReviewSession replaceSession(
        {AnswerCandidateOrigin? origin}) {
      return AnswerCandidateReviewSession(
        candidates: [
          _candidate('cand_replace',
              writeIntent: CandidateWriteIntent.replace, origin: origin),
        ],
      );
    }

    test('direct confirmReplace from the initial session fails', () {
      final session = replaceSession();
      expect(session.outcomeOf('cand_replace'),
          CandidateReviewOutcome.pendingReplace);
      expect(
        () => session.confirmReplace('cand_replace'),
        throwsA(
          isA<AnswerCandidateReviewException>().having(
            (error) => error.failure,
            'failure',
            AnswerCandidateReviewFailure.replaceFlowRequired,
          ),
        ),
      );
      expect(session.sessionRevision, 0);
    });

    test('selectForReplace arms and advances revision, then confirm succeeds',
        () {
      final session = replaceSession();
      final selected = session.selectForReplace('cand_replace');
      expect(selected.sessionRevision, 1);
      expect(selected.outcomeOf('cand_replace'),
          CandidateReviewOutcome.pendingReplace);

      final confirmed = selected.confirmReplace('cand_replace');
      expect(confirmed.confirmation.sessionRevision, 2);
      expect(confirmed.session.sessionRevision, 2);
      expect(confirmed.session.outcomeOf('cand_replace'),
          CandidateReviewOutcome.confirmed);
    });

    test('repeated selectForReplace fails safely', () {
      final session = replaceSession();
      final selected = session.selectForReplace('cand_replace');
      expect(
        () => selected.selectForReplace('cand_replace'),
        throwsA(
          isA<AnswerCandidateReviewException>().having(
            (error) => error.failure,
            'failure',
            AnswerCandidateReviewFailure.alreadyDecided,
          ),
        ),
      );
      expect(selected.sessionRevision, 1);
    });

    test('repeated confirmReplace fails safely', () {
      final session = replaceSession();
      final selected = session.selectForReplace('cand_replace');
      final confirmed = selected.confirmReplace('cand_replace');
      expect(
        () => confirmed.session.confirmReplace('cand_replace'),
        throwsA(
          isA<AnswerCandidateReviewException>().having(
            (error) => error.failure,
            'failure',
            AnswerCandidateReviewFailure.alreadyDecided,
          ),
        ),
      );
    });

    test('reject around replacement selection is terminal and safe', () {
      final session = replaceSession();
      // Reject before selection.
      final rejected = session.reject('cand_replace');
      expect(
          rejected.outcomeOf('cand_replace'), CandidateReviewOutcome.rejected);
      expect(
        () => rejected.selectForReplace('cand_replace'),
        throwsA(
          isA<AnswerCandidateReviewException>().having(
            (error) => error.failure,
            'failure',
            AnswerCandidateReviewFailure.alreadyDecided,
          ),
        ),
      );

      // Reject after selection.
      final selected = session.selectForReplace('cand_replace');
      final rejectedAfterArm = selected.reject('cand_replace');
      expect(
        rejectedAfterArm.outcomeOf('cand_replace'),
        CandidateReviewOutcome.rejected,
      );
      expect(rejectedAfterArm.sessionRevision, 2);
      expect(
        () => rejectedAfterArm.confirmReplace('cand_replace'),
        throwsA(
          isA<AnswerCandidateReviewException>().having(
            (error) => error.failure,
            'failure',
            AnswerCandidateReviewFailure.replaceFlowRequired,
          ),
        ),
      );
    });

    test('AI origin replace requires the same arm then reconfirm sequence', () {
      final session = replaceSession(origin: _aiOrigin());
      expect(
        () => session.confirmReplace('cand_replace'),
        throwsA(
          isA<AnswerCandidateReviewException>().having(
            (error) => error.failure,
            'failure',
            AnswerCandidateReviewFailure.replaceFlowRequired,
          ),
        ),
      );
      final selected = session.selectForReplace('cand_replace');
      final confirmed = selected.confirmReplace('cand_replace');
      expect(confirmed.confirmation.sessionRevision, 2);
      expect(confirmed.session.outcomeOf('cand_replace'),
          CandidateReviewOutcome.confirmed);
    });
  });

  group('reject and commit boundaries', () {
    test('reject is terminal with zero mutation', () {
      final session = AnswerCandidateReviewSession(
        candidates: [
          _candidate('cand_fill', writeIntent: CandidateWriteIntent.fill)
        ],
      );
      final rejected = session.reject('cand_fill');
      expect(rejected.outcomeOf('cand_fill'), CandidateReviewOutcome.rejected);
      expect(
        () => rejected.confirmFill('cand_fill'),
        throwsA(
          isA<AnswerCandidateReviewException>().having(
            (error) => error.failure,
            'failure',
            AnswerCandidateReviewFailure.alreadyDecided,
          ),
        ),
      );
      expect(session.sessionRevision, 0);
    });

    test('AI origin reject is terminal identically', () {
      final session = AnswerCandidateReviewSession(
        candidates: [
          _candidate('cand_ai_fill',
              writeIntent: CandidateWriteIntent.fill, origin: _aiOrigin()),
        ],
      );
      final rejected = session.reject('cand_ai_fill');
      expect(
          rejected.outcomeOf('cand_ai_fill'), CandidateReviewOutcome.rejected);
      expect(
        () => rejected.markCommitted('cand_ai_fill'),
        throwsA(
          isA<AnswerCandidateReviewException>().having(
            (error) => error.failure,
            'failure',
            AnswerCandidateReviewFailure.alreadyDecided,
          ),
        ),
      );
    });

    test('markCommitted is allowed only after confirmation', () {
      final session = AnswerCandidateReviewSession(
        candidates: [
          _candidate('cand_fill', writeIntent: CandidateWriteIntent.fill)
        ],
      );
      expect(
        () => session.markCommitted('cand_fill'),
        throwsA(
          isA<AnswerCandidateReviewException>().having(
            (error) => error.failure,
            'failure',
            AnswerCandidateReviewFailure.alreadyDecided,
          ),
        ),
      );
      final confirmed = session.confirmFill('cand_fill');
      final committed = confirmed.session.markCommitted('cand_fill');
      expect(
          committed.outcomeOf('cand_fill'), CandidateReviewOutcome.committed);
      expect(
        () => committed.markCommitted('cand_fill'),
        throwsA(
          isA<AnswerCandidateReviewException>().having(
            (error) => error.failure,
            'failure',
            AnswerCandidateReviewFailure.alreadyDecided,
          ),
        ),
      );
    });

    test('AI origin markCommitted works after AI confirmation', () {
      final session = AnswerCandidateReviewSession(
        candidates: [
          _candidate('cand_ai_fill',
              writeIntent: CandidateWriteIntent.fill, origin: _aiOrigin()),
        ],
      );
      final confirmed = session.confirmFill('cand_ai_fill');
      final committed = confirmed.session.markCommitted('cand_ai_fill');
      expect(committed.outcomeOf('cand_ai_fill'),
          CandidateReviewOutcome.committed);
    });
  });

  group('typed failures and immutability', () {
    test('unknown candidate fails typed for every transition', () {
      final session = AnswerCandidateReviewSession(
        candidates: [
          _candidate('cand_fill', writeIntent: CandidateWriteIntent.fill)
        ],
      );
      for (final action in <void Function()>[
        () => session.confirmFill('cand_missing'),
        () => session.selectForReplace('cand_missing'),
        () => session.confirmReplace('cand_missing'),
        () => session.reject('cand_missing'),
        () => session.markCommitted('cand_missing'),
      ]) {
        expect(
          action,
          throwsA(
            isA<AnswerCandidateReviewException>().having(
              (error) => error.failure,
              'failure',
              AnswerCandidateReviewFailure.unknownCandidate,
            ),
          ),
        );
      }
    });

    test('already-decided candidates fail typed', () {
      final session = AnswerCandidateReviewSession(
        candidates: [
          _candidate('cand_fill', writeIntent: CandidateWriteIntent.fill)
        ],
      );
      final confirmed = session.confirmFill('cand_fill');
      expect(
        () => confirmed.session.confirmFill('cand_fill'),
        throwsA(
          isA<AnswerCandidateReviewException>().having(
            (error) => error.failure,
            'failure',
            AnswerCandidateReviewFailure.alreadyDecided,
          ),
        ),
      );
      expect(
        () => confirmed.session.reject('cand_fill'),
        throwsA(
          isA<AnswerCandidateReviewException>().having(
            (error) => error.failure,
            'failure',
            AnswerCandidateReviewFailure.alreadyDecided,
          ),
        ),
      );
    });

    test('state collections cannot be externally mutated', () {
      final session = AnswerCandidateReviewSession(
        candidates: [
          _candidate('cand_fill', writeIntent: CandidateWriteIntent.fill)
        ],
      );
      expect(
        () => session.outcomes['cand_fill'] = CandidateReviewOutcome.confirmed,
        throwsUnsupportedError,
      );
      expect(
        () => session.candidates.clear(),
        throwsUnsupportedError,
      );
      expect(session.sessionRevision, 0);
    });
  });
}

SupplementalAnswerOrigin _supplementalOrigin() {
  return SupplementalAnswerOrigin(
    supplementalFileId: 'file_001',
    artifactId: 'artifact_001',
    artifactRevision: 1,
    supplementalSourceRefs: [
      SourceRef.document(sourceId: 'artifact_001'),
    ],
    matchEvidence: const [MatchEvidenceCode.uniqueMainNumber],
  );
}

AiAnswerOrigin _aiOrigin() {
  return AiAnswerOrigin(
    generationId: 'gen_001',
    providerProfileId: 'profile_alpha',
    generatedAtUtc: DateTime.utc(2026, 8, 13, 12),
  );
}

AnswerCandidate _candidate(
  String candidateId, {
  required CandidateWriteIntent writeIntent,
  AnswerCandidateOrigin? origin,
}) {
  return AnswerCandidate(
    candidateId: candidateId,
    targetStorageId: 'q_$candidateId',
    targetBankName: 'bank_math',
    expectedDraft: QuestionDraftV2(
      questionId: 'q_$candidateId',
      kind: QuestionKind.shortAnswer,
      questionNumber: 1,
      stem: _text('stem'),
    ),
    answer: ContentAnswer(content: _text('x = 1')),
    writeIntent: writeIntent,
    origin: origin ?? _supplementalOrigin(),
  );
}

RichContent _text(String text) {
  return RichContent(nodes: [TextNode(text)]);
}
