// P7-C0 Application confirmation/commit boundary acceptance.
//
// The persistence port is a deterministic fake; no database is touched here.
// Sentinel strings are fictional.
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_commit_command.dart';
import 'package:shiroha_quiz/application/answers/answer_candidate_review_session.dart';
import 'package:shiroha_quiz/domain/answers/answer_candidate.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

void main() {
  final draft = _draft();

  AnswerCandidateReviewSession sessionFor(
    CandidateWriteIntent writeIntent, {
    AnswerCandidateOrigin? origin,
    String candidateId = 'cand_001',
  }) {
    return AnswerCandidateReviewSession(
      candidates: [
        AnswerCandidate(
          candidateId: candidateId,
          targetStorageId: 'q_1',
          targetBankName: 'bank_math',
          expectedDraft: draft,
          answer: ContentAnswer(content: _text('x = 1')),
          writeIntent: writeIntent,
          origin: origin ?? _aiOrigin(),
        ),
      ],
    );
  }

  AnswerCandidateConfirmation handConfirmation(
    AnswerCandidateReviewSession session, {
    AnswerCandidate? candidate,
    int? sessionRevision,
  }) {
    return AnswerCandidateConfirmation(
      candidate: candidate ?? session.candidates.single,
      sessionRevision: sessionRevision ?? session.sessionRevision,
    );
  }

  Matcher commitFailure(AiAnswerCommitFailure failure) {
    return throwsA(
      isA<AiAnswerCommitException>().having(
        (error) => error.failure,
        'failure',
        failure,
      ),
    );
  }

  group('A/C. happy paths', () {
    test('confirmed fill commits and returns the committed session', () async {
      final port = _FakeCommitPort();
      final command = AiAnswerCommitCommand(persistencePort: port);
      final session = sessionFor(CandidateWriteIntent.fill);
      final decided = session.confirmFill('cand_001');

      final committed = await command.commit(
        session: decided.session,
        confirmation: decided.confirmation,
      );

      expect(
        committed.outcomeOf('cand_001'),
        CandidateReviewOutcome.committed,
      );
      expect(committed.sessionRevision, decided.session.sessionRevision + 1);
      expect(port.calls, 1);
      expect(port.committed.single.candidateId, 'cand_001');
      expect(
        port.committed.single.origin,
        isA<AiAnswerOrigin>(),
      );
    });

    test('armed replace commits after select -> reconfirm', () async {
      final port = _FakeCommitPort();
      final command = AiAnswerCommitCommand(persistencePort: port);
      final session = sessionFor(CandidateWriteIntent.replace);
      final selected = session.selectForReplace('cand_001');
      final confirmed = selected.confirmReplace('cand_001');

      final committed = await command.commit(
        session: confirmed.session,
        confirmation: confirmed.confirmation,
      );

      expect(
        committed.outcomeOf('cand_001'),
        CandidateReviewOutcome.committed,
      );
      expect(port.calls, 1);
    });
  });

  group('B/D/E/F/G/H. rejected before transaction', () {
    test('noOp candidate is never committable', () async {
      final port = _FakeCommitPort();
      final command = AiAnswerCommitCommand(persistencePort: port);
      final session = sessionFor(CandidateWriteIntent.noOp);

      await expectLater(
        command.commit(
          session: session,
          confirmation: handConfirmation(session),
        ),
        commitFailure(AiAnswerCommitFailure.candidateNotCommittable),
      );
      expect(port.calls, 0);
    });

    test('direct replace bypass without selectForReplace is rejected',
        () async {
      final port = _FakeCommitPort();
      final command = AiAnswerCommitCommand(persistencePort: port);
      final session = sessionFor(CandidateWriteIntent.replace);

      await expectLater(
        command.commit(
          session: session,
          confirmation: handConfirmation(session),
        ),
        commitFailure(AiAnswerCommitFailure.candidateNotCommittable),
      );
      expect(port.calls, 0);
    });

    test('pending fill without confirmFill is rejected', () async {
      final port = _FakeCommitPort();
      final command = AiAnswerCommitCommand(persistencePort: port);
      final session = sessionFor(CandidateWriteIntent.fill);

      await expectLater(
        command.commit(
          session: session,
          confirmation: handConfirmation(session),
        ),
        commitFailure(AiAnswerCommitFailure.candidateNotCommittable),
      );
      expect(port.calls, 0);
    });

    test('stale session revision is rejected with zero port calls', () async {
      final port = _FakeCommitPort();
      final command = AiAnswerCommitCommand(persistencePort: port);
      final session = sessionFor(CandidateWriteIntent.fill);
      final decided = session.confirmFill('cand_001');

      await expectLater(
        command.commit(
          session: decided.session,
          confirmation: handConfirmation(
            decided.session,
            sessionRevision: decided.confirmation.sessionRevision - 1,
          ),
        ),
        commitFailure(AiAnswerCommitFailure.candidateNotCommittable),
      );
      expect(port.calls, 0);
    });

    test('forged confirmation with matching id is rejected', () async {
      final port = _FakeCommitPort();
      final command = AiAnswerCommitCommand(persistencePort: port);
      final session = sessionFor(CandidateWriteIntent.fill);
      final decided = session.confirmFill('cand_001');
      final forged = AnswerCandidate(
        candidateId: 'cand_001',
        targetStorageId: 'q_1',
        targetBankName: 'bank_math',
        expectedDraft: draft,
        answer: ContentAnswer(content: _text('x = 9')),
        writeIntent: CandidateWriteIntent.fill,
        origin: AiAnswerOrigin(
          generationId: 'SENTINEL_FORGED_GEN',
          providerProfileId: 'engine_001',
          generatedAtUtc: DateTime.utc(2026, 8, 20, 12),
        ),
      );

      await expectLater(
        command.commit(
          session: decided.session,
          confirmation: handConfirmation(decided.session, candidate: forged),
        ),
        commitFailure(AiAnswerCommitFailure.candidateNotCommittable),
      );
      expect(port.calls, 0);
    });

    test('non-AI origin is rejected before the transaction', () async {
      final port = _FakeCommitPort();
      final command = AiAnswerCommitCommand(persistencePort: port);
      final session = sessionFor(
        CandidateWriteIntent.fill,
        origin: _supplementalOrigin(),
      );
      final decided = session.confirmFill('cand_001');

      await expectLater(
        command.commit(
          session: decided.session,
          confirmation: decided.confirmation,
        ),
        commitFailure(AiAnswerCommitFailure.candidateNotCommittable),
      );
      expect(port.calls, 0);
    });

    test('rejected candidate is alreadyDecided', () async {
      final port = _FakeCommitPort();
      final command = AiAnswerCommitCommand(persistencePort: port);
      final session = sessionFor(CandidateWriteIntent.fill);
      final rejected = session.reject('cand_001');

      await expectLater(
        command.commit(
          session: rejected,
          confirmation: handConfirmation(rejected),
        ),
        commitFailure(AiAnswerCommitFailure.candidateAlreadyDecided),
      );
      expect(port.calls, 0);
    });
  });

  group('L. retry and failure windows', () {
    test(
        'persistence failure returns no committed session; confirmed '
        'session retries safely', () async {
      final port = _FakeCommitPort()
        ..error = const AiAnswerCommitException(
          AiAnswerCommitFailure.persistenceFailed,
        );
      final command = AiAnswerCommitCommand(persistencePort: port);
      final session = sessionFor(CandidateWriteIntent.fill);
      final decided = session.confirmFill('cand_001');

      await expectLater(
        command.commit(
          session: decided.session,
          confirmation: decided.confirmation,
        ),
        commitFailure(AiAnswerCommitFailure.persistenceFailed),
      );
      expect(port.calls, 1);
      // The caller's confirmed session is untouched and may retry.
      expect(
        decided.session.outcomeOf('cand_001'),
        CandidateReviewOutcome.confirmed,
      );

      port.error = null;
      final committed = await command.commit(
        session: decided.session,
        confirmation: decided.confirmation,
      );
      expect(
        committed.outcomeOf('cand_001'),
        CandidateReviewOutcome.committed,
      );
      expect(port.calls, 2);
      expect(port.committed, hasLength(1),
          reason: 'exactly one formal mutation after retry');
    });

    test('durable staleTarget from the port propagates', () async {
      final port = _FakeCommitPort()
        ..error = const AiAnswerCommitException(
          AiAnswerCommitFailure.staleTarget,
        );
      final command = AiAnswerCommitCommand(persistencePort: port);
      final session = sessionFor(CandidateWriteIntent.fill);
      final decided = session.confirmFill('cand_001');

      await expectLater(
        command.commit(
          session: decided.session,
          confirmation: decided.confirmation,
        ),
        commitFailure(AiAnswerCommitFailure.staleTarget),
      );
    });

    test('unexpected port exception maps to internalError with no raw cause',
        () async {
      final port = _FakeCommitPort()
        ..rawError = StateError('SENTINEL_RAW_COMMIT');
      final command = AiAnswerCommitCommand(persistencePort: port);
      final session = sessionFor(CandidateWriteIntent.fill);
      final decided = session.confirmFill('cand_001');

      try {
        await command.commit(
          session: decided.session,
          confirmation: decided.confirmation,
        );
        fail('expected internalError');
      } on AiAnswerCommitException catch (error) {
        expect(error.failure, AiAnswerCommitFailure.internalError);
        expect(error.toString(), isNot(contains('SENTINEL_RAW_COMMIT')));
      }
    });

    test('every failure renders a fixed safe message', () {
      for (final failure in AiAnswerCommitFailure.values) {
        final message = AiAnswerCommitException(failure).toString();
        expect(message, contains('AiAnswerCommitException'));
        expect(message, isNot(contains('http')));
        expect(message, isNot(contains('api_key')));
        expect(message, isNot(contains('Bearer')));
      }
    });
  });
}

class _FakeCommitPort implements AiAnswerCommitPersistencePort {
  AiAnswerCommitException? error;
  Object? rawError;
  final List<AnswerCandidate> committed = <AnswerCandidate>[];
  int calls = 0;

  @override
  Future<void> commitAnswer(AnswerCandidate candidate) async {
    calls++;
    final typed = error;
    if (typed != null) throw typed;
    final raw = rawError;
    if (raw != null) throw raw;
    committed.add(candidate);
  }
}

AiAnswerOrigin _aiOrigin() {
  return AiAnswerOrigin(
    generationId: 'gen_001',
    providerProfileId: 'engine_001',
    generatedAtUtc: DateTime.utc(2026, 8, 20, 12),
  );
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

QuestionDraftV2 _draft() {
  return QuestionDraftV2(
    questionId: 'q_1',
    kind: QuestionKind.shortAnswer,
    questionNumber: 1,
    stem: _text('stem'),
  );
}

RichContent _text(String text) {
  return RichContent(nodes: [TextNode(text)]);
}
