import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_command.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_failure.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_review_session.dart';
import 'package:shiroha_quiz/domain/assets/parsed_artifact.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/answer_candidate.dart';

void main() {
  final draft = _draft();
  final candidate = _candidate(draft);

  group('SupplementalAnswerConfirmCommand layer 1', () {
    test('confirms the artifact generation before forwarding to persistence',
        () async {
      final artifactPort = _ArtifactPort(
        artifact: ParsedArtifact(
          fileId: 'file_001',
          artifactId: 'artifact_001',
          revision: 2,
          payloadSchemaVersion: 1,
        ),
      );
      final persistencePort = _RecordingPersistencePort();
      final command = SupplementalAnswerConfirmCommand(
        artifactPort: artifactPort,
        persistencePort: persistencePort,
      );

      await command.confirm(
        SupplementalAnswerConfirmation(
          candidate: candidate,
          sessionRevision: 1,
        ),
      );

      expect(artifactPort.calls, ['file_001']);
      expect(persistencePort.candidates, hasLength(1));
      expect(
          persistencePort.candidates.single.candidateId, candidate.candidateId);
    });

    test('artifact generation drift maps to staleTarget with zero writes',
        () async {
      final artifactPort = _ArtifactPort(
        artifact: ParsedArtifact(
          fileId: 'file_001',
          artifactId: 'artifact_001',
          revision: 3,
          payloadSchemaVersion: 1,
        ),
      );
      final persistencePort = _RecordingPersistencePort();
      final command = SupplementalAnswerConfirmCommand(
        artifactPort: artifactPort,
        persistencePort: persistencePort,
      );

      await expectLater(
        command.confirm(
          SupplementalAnswerConfirmation(
            candidate: candidate,
            sessionRevision: 1,
          ),
        ),
        throwsA(
          isA<SupplementalAnswerException>().having(
            (error) => error.failure,
            'failure',
            SupplementalAnswerFailure.staleTarget,
          ),
        ),
      );
      expect(persistencePort.candidates, isEmpty);
    });

    test('maps F1 seam failures to the P6 taxonomy', () async {
      for (final entry in <(
        ParsedArtifactLifecycleFailure,
        SupplementalAnswerFailure,
      )>[
        (
          ParsedArtifactLifecycleFailure.artifactCorrupt,
          SupplementalAnswerFailure.artifactCorrupt,
        ),
        (
          ParsedArtifactLifecycleFailure.payloadUnsupported,
          SupplementalAnswerFailure.unsupportedArtifact,
        ),
        (
          ParsedArtifactLifecycleFailure.fileNotFound,
          SupplementalAnswerFailure.sourceUnavailable,
        ),
        (
          ParsedArtifactLifecycleFailure.temporarilyUnavailable,
          SupplementalAnswerFailure.temporarilyUnavailable,
        ),
        (
          ParsedArtifactLifecycleFailure.internalError,
          SupplementalAnswerFailure.internalError,
        ),
      ]) {
        final artifactPort = _ArtifactPort.failure(entry.$1);
        final persistencePort = _RecordingPersistencePort();
        final command = SupplementalAnswerConfirmCommand(
          artifactPort: artifactPort,
          persistencePort: persistencePort,
        );

        await expectLater(
          command.confirm(
            SupplementalAnswerConfirmation(
              candidate: candidate,
              sessionRevision: 1,
            ),
          ),
          throwsA(
            isA<SupplementalAnswerException>().having(
              (error) => error.failure,
              'failure',
              entry.$2,
            ),
          ),
        );
        expect(persistencePort.candidates, isEmpty);
      }
    });

    test('non-Supplemental origin fails safely with zero persistence',
        () async {
      final artifactPort = _ArtifactPort(
        artifact: ParsedArtifact(
          fileId: 'file_001',
          artifactId: 'artifact_001',
          revision: 2,
          payloadSchemaVersion: 1,
        ),
      );
      final persistencePort = _RecordingPersistencePort();
      final command = SupplementalAnswerConfirmCommand(
        artifactPort: artifactPort,
        persistencePort: persistencePort,
      );
      final aiCandidate = AnswerCandidate(
        candidateId: 'cand_ai_001',
        targetStorageId: 'q_1',
        targetBankName: 'bank_math',
        expectedDraft: draft,
        answer: ContentAnswer(content: _text('x = 1')),
        writeIntent: CandidateWriteIntent.fill,
        origin: AiAnswerOrigin(
          generationId: 'gen_001',
          providerProfileId: 'profile_alpha',
          generatedAtUtc: DateTime.utc(2026, 8, 13, 12),
        ),
      );

      await expectLater(
        command.confirm(
          SupplementalAnswerConfirmation(
            candidate: aiCandidate,
            sessionRevision: 1,
          ),
        ),
        throwsA(
          isA<SupplementalAnswerException>().having(
            (error) => error.failure,
            'failure',
            SupplementalAnswerFailure.invalidCandidate,
          ),
        ),
      );
      expect(persistencePort.candidates, isEmpty);
      expect(artifactPort.calls, isEmpty,
          reason: 'the guard must fail before any seam is touched');
    });
  });
}

class _ArtifactPort implements ParsedArtifactLifecyclePort {
  _ArtifactPort({required this.artifact}) : _failure = null;

  _ArtifactPort.failure(ParsedArtifactLifecycleFailure failure)
      : artifact = null,
        _failure = failure;

  final ParsedArtifact? artifact;
  final ParsedArtifactLifecycleFailure? _failure;
  final List<String> calls = <String>[];

  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async {
    calls.add(fileId);
    final failure = _failure;
    if (failure != null) {
      throw ParsedArtifactLifecycleException(failure);
    }
    return ParsedArtifactSnapshot(
      artifact: artifact!,
      sourceDocument: SourceDocument(
        sourceId: artifact!.artifactId,
        parts: const [],
      ),
    );
  }

  @override
  Future<ParsedArtifactEnsureResult> ensureParsedArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ParsedArtifactEnsureResult> reparseArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
    required int expectedRevision,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> removeCurrentArtifact({
    required String fileId,
    required int expectedRevision,
  }) {
    throw UnimplementedError();
  }
}

class _RecordingPersistencePort implements SupplementalAnswerPersistencePort {
  final List<AnswerCandidate> candidates = <AnswerCandidate>[];

  @override
  Future<void> confirmCandidate(AnswerCandidate candidate) async {
    candidates.add(candidate);
  }
}

AnswerCandidate _candidate(QuestionDraftV2 draft) {
  return AnswerCandidate(
    candidateId: 'cand_frag_1_q_1',
    targetStorageId: 'q_1',
    targetBankName: 'bank_math',
    expectedDraft: draft,
    answer: ContentAnswer(content: _text('x = 1')),
    writeIntent: CandidateWriteIntent.fill,
    origin: SupplementalAnswerOrigin(
      supplementalFileId: 'file_001',
      artifactId: 'artifact_001',
      artifactRevision: 2,
      supplementalSourceRefs: [
        SourceRef.document(sourceId: 'artifact_001'),
      ],
      matchEvidence: const [],
    ),
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
