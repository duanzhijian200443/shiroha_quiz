import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/file_library/file_library_ports.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_matcher.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_review_session.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_source_inspection.dart';
import 'package:shiroha_quiz/application/supplemental_answers/target_question_snapshot_service.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/assets/parsed_artifact.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/answer_match_record.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_fragment.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_scope.dart';

const _artifact = SupplementalArtifactContext(
  supplementalFileId: 'file_001',
  artifactId: 'artifact_001',
  artifactRevision: 1,
);

const _id = 'cand_frag_1_q_1';
Matcher _failure(SupplementalAnswerReviewFailure failure) =>
    throwsA(isA<SupplementalAnswerReviewException>()
        .having((e) => e.failure, 'failure', failure));
SupplementalAnswerReviewSession _one({String? answer}) => _sessionFor([
      _target('q_1',
          number: 1,
          kind: QuestionKind.shortAnswer,
          answer:
              answer == null ? null : ContentAnswer(content: _text(answer))),
    ], [
      _fragment('frag_1', main: '1', answer: 'x = 1')
    ]);

void main() {
  test('fill requires explicit verification; inspection alone is insufficient',
      () async {
    final session = _one();
    final inspection = await _inspection();
    expect(session.sessionRevision, 0);
    expect(session.verificationStateOf(_id),
        SupplementalSourceVerificationState.required);
    expect(() => session.confirmFill(_id),
        _failure(SupplementalAnswerReviewFailure.sourceVerificationRequired));
    expect(session.sessionRevision, 0);
    final verified = session.verifySource(_id, inspection);
    expect(verified.sessionRevision, 1);
    expect(verified.verificationStateOf(_id),
        SupplementalSourceVerificationState.verified);
    final confirmed = verified.confirmFill(_id);
    expect(confirmed.session.sessionRevision, 2);
    expect(confirmed.confirmation.sessionRevision, 2);
    expect(confirmed.confirmation.candidate.targetStorageId, 'q_1');
    expect(confirmed.session.outcomeOf(_id), CandidateReviewOutcome.confirmed);
  });

  test('wrong file, artifact or revision inspection has zero state change',
      () async {
    final session = _one();
    for (final inspection in [
      await _inspection(fileId: 'other_file'),
      await _inspection(artifactId: 'other_artifact'),
      await _inspection(revision: 2),
    ]) {
      expect(() => session.verifySource(_id, inspection),
          _failure(SupplementalAnswerReviewFailure.sourceInspectionRequired));
      expect(session.sessionRevision, 0);
      expect(session.verificationStateOf(_id),
          SupplementalSourceVerificationState.required);
      expect(session.outcomeOf(_id), CandidateReviewOutcome.pendingFill);
    }
    expect(session.verifySource(_id, await _inspection()).sessionRevision, 1);
  });

  for (final verifyFirst in [true, false]) {
    test('replace requires verification and arming; verifyFirst=$verifyFirst',
        () async {
      var session = _one(answer: 'old');
      expect(
          () => session.confirmFill(_id),
          _failure(SupplementalAnswerReviewFailure
              .conflictRequiresReplaceReconfirmation));
      expect(() => session.confirmReplace(_id),
          _failure(SupplementalAnswerReviewFailure.sourceVerificationRequired));
      final inspection = await _inspection();
      if (verifyFirst) {
        session = session.verifySource(_id, inspection);
        expect(
            () => session.confirmReplace(_id),
            _failure(SupplementalAnswerReviewFailure
                .conflictRequiresReplaceReconfirmation));
        session = session.selectForReplace(_id);
      } else {
        session = session.selectForReplace(_id);
        expect(
            () => session.confirmReplace(_id),
            _failure(
                SupplementalAnswerReviewFailure.sourceVerificationRequired));
        session = session.verifySource(_id, inspection);
      }
      expect(session.verificationStateOf(_id),
          SupplementalSourceVerificationState.verified);
      expect(session.sessionRevision, 2);
      expect(() => session.selectForReplace(_id),
          _failure(SupplementalAnswerReviewFailure.alreadyDecided));
      final confirmed = session.confirmReplace(_id);
      expect(confirmed.session.sessionRevision, 3);
      expect(
          confirmed.session.outcomeOf(_id), CandidateReviewOutcome.confirmed);
    });
  }

  for (final verifyFirst in [false, true]) {
    test('reject before/after verification stays terminal: $verifyFirst',
        () async {
      var session = _one();
      final inspection = await _inspection();
      if (verifyFirst) session = session.verifySource(_id, inspection);
      final rejected = session.reject(_id);
      expect(rejected.outcomeOf(_id), CandidateReviewOutcome.rejected);
      expect(() => rejected.verifySource(_id, inspection),
          _failure(SupplementalAnswerReviewFailure.alreadyDecided));
      expect(() => rejected.confirmFill(_id),
          _failure(SupplementalAnswerReviewFailure.alreadyDecided));
      expect(() => rejected.reject(_id),
          _failure(SupplementalAnswerReviewFailure.alreadyDecided));
    });
  }

  test('noOp is exempt, terminal and noncommittable', () async {
    final session = _one(answer: 'x = 1');
    expect(session.verificationStateOf(_id),
        SupplementalSourceVerificationState.notRequired);
    expect(session.outcomeOf(_id), CandidateReviewOutcome.noOp);
    expect(() => session.confirmFill(_id),
        _failure(SupplementalAnswerReviewFailure.noOpTerminal));
    final inspection = await _inspection();
    expect(() => session.verifySource(_id, inspection),
        _failure(SupplementalAnswerReviewFailure.noOpTerminal));
    expect(() => session.confirmReplace(_id),
        throwsA(isA<SupplementalAnswerReviewException>()));
    expect(() => session.markCommitted(_id),
        _failure(SupplementalAnswerReviewFailure.alreadyDecided));
    expect(session.sessionRevision, 0);
  });

  test('every transition revokes all transition entrypoints on old snapshots',
      () async {
    final inspection = await _inspection();
    final initial = _one(answer: 'old');
    final verified = initial.verifySource(_id, inspection);
    final armed = verified.selectForReplace(_id);
    final confirmed = armed.confirmReplace(_id);
    final committed = confirmed.session.markCommitted(_id);
    final pending = _one();
    final rejected = pending.reject(_id);
    expect(committed.sessionRevision, 4);
    expect(rejected.sessionRevision, 1);
    for (final old in [initial, verified, armed, confirmed.session, pending]) {
      for (final transition in <void Function()>[
        () {
          old.verifySource(_id, inspection);
        },
        () {
          old.selectForReplace(_id);
        },
        () {
          old.confirmFill(_id);
        },
        () {
          old.confirmReplace(_id);
        },
        () {
          old.reject(_id);
        },
        () {
          old.markCommitted(_id);
        },
      ]) {
        expect(transition,
            _failure(SupplementalAnswerReviewFailure.staleSessionRevision));
      }
    }
  });

  test('verification is session-specific even for identical candidates',
      () async {
    final first = _one().verifySource(_id, await _inspection());
    final other = _one();
    expect(first.verificationStateOf(_id),
        SupplementalSourceVerificationState.verified);
    expect(() => other.confirmFill(_id),
        _failure(SupplementalAnswerReviewFailure.sourceVerificationRequired));
  });

  test('unknown candidates and premature commit fail', () async {
    final session = _one();
    expect(() => session.confirmFill('missing'),
        _failure(SupplementalAnswerReviewFailure.unknownCandidate));
    expect(() => session.verificationStateOf('missing'),
        _failure(SupplementalAnswerReviewFailure.unknownCandidate));
    expect(() => session.markCommitted(_id),
        _failure(SupplementalAnswerReviewFailure.alreadyDecided));
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

// Synthetic ports exercise the real inspection authority; no inspection bypass.
Future<SupplementalSourceInspection> _inspection({
  String fileId = 'file_001',
  String artifactId = 'artifact_001',
  int revision = 1,
  ParsedArtifactLifecyclePort? artifactPort,
}) =>
    SupplementalSourceInspectionService(
      fileCatalog: _InspectionCatalog(),
      artifactPort: artifactPort ?? _InspectionArtifacts(artifactId, revision),
      sourceReader: _InspectionReader(),
      maxBytes: 3,
    ).inspect(fileId);

const _sourceHash =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

class _InspectionCatalog extends Fake implements LibraryFileRepositoryPort {
  @override
  Future<LibraryFile?> findById(String fileId) async => LibraryFile(
        fileId: fileId,
        displayName: 'synthetic.txt',
        mimeType: 'text/plain',
        sizeBytes: 3,
        sha256: _sourceHash,
        storageKey: 'synthetic/source',
        createdAt: DateTime.utc(2026),
      );
}

class _InspectionArtifacts extends Fake implements ParsedArtifactLifecyclePort {
  _InspectionArtifacts(this.artifactId, this.revision);
  final String artifactId;
  final int revision;
  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async =>
      ParsedArtifactSnapshot(
        artifact: ParsedArtifact(
            fileId: fileId,
            artifactId: artifactId,
            revision: revision,
            payloadSchemaVersion: 1),
        sourceDocument: SourceDocument(sourceId: artifactId),
      );
}

class _InspectionReader extends Fake implements SupplementalSourceReaderPort {
  @override
  Future<SupplementalSourceReadResult> readOriginalBytes({
    required LibraryFile file,
    required int maxBytes,
  }) async =>
      SupplementalSourceReadResult(
        bytes: [97, 98, 99],
        actualSizeBytes: 3,
        actualSha256: _sourceHash,
      );
}
