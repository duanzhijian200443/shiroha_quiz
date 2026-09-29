import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/file_library/file_library_ports.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/application/safe_write/typed_answer_command.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_command.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_failure.dart';
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
import 'package:shiroha_quiz/domain/supplemental_answers/answer_candidate.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/answer_match_record.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_scope.dart';

Matcher _reviewFailure(SupplementalAnswerReviewFailure failure) =>
    throwsA(isA<SupplementalAnswerReviewException>()
        .having((e) => e.failure, 'failure', failure));
Matcher _commandFailure(SupplementalAnswerFailure failure) =>
    throwsA(isA<SupplementalAnswerException>()
        .having((e) => e.failure, 'failure', failure));

void main() {
  test(
      'Confirmation has only a private constructor and cannot be implemented externally',
      () {
    final source = File(
            'lib/application/supplemental_answers/supplemental_answer_review_session.dart')
        .readAsStringSync();
    expect(source, contains('final class SupplementalAnswerConfirmation'));
    final declarations = RegExp(
            r'^  (?:const |factory )?SupplementalAnswerConfirmation(?:\.([\w]+))?\(',
            multiLine: true)
        .allMatches(source)
        .map((m) => m.group(1))
        .toList();
    expect(declarations, ['_']);
  });

  test('legal confirmation commits once and supports markCommitted', () async {
    final issued = await _issued();
    final artifacts = _currentArtifacts();
    final persistence = _RecordingPersistencePort();
    final command = SupplementalAnswerConfirmCommand(
        artifactPort: artifacts, persistencePort: persistence);
    await command.confirm(issued.confirmation);
    expect(artifacts.calls, ['file_001']);
    expect(persistence.candidates, [issued.confirmation.candidate]);
    final committed =
        issued.session.markCommitted(issued.confirmation.candidate.candidateId);
    expect(committed.outcomeOf(issued.confirmation.candidate.candidateId),
        CandidateReviewOutcome.committed);
    await expectLater(command.confirm(issued.confirmation),
        _reviewFailure(SupplementalAnswerReviewFailure.alreadyDecided));
    expect(artifacts.calls, hasLength(1));
    expect(persistence.candidates, hasLength(1));
  });

  test('sequential replay across command instances fails before both seams',
      () async {
    final issued = await _issued();
    final artifacts = _currentArtifacts();
    final persistence = _RecordingPersistencePort();
    await SupplementalAnswerConfirmCommand(
            artifactPort: artifacts, persistencePort: persistence)
        .confirm(issued.confirmation);
    await expectLater(
        SupplementalAnswerConfirmCommand(
                artifactPort: artifacts, persistencePort: persistence)
            .confirm(issued.confirmation),
        _reviewFailure(SupplementalAnswerReviewFailure.alreadyDecided));
    expect(artifacts.calls, hasLength(1));
    expect(persistence.candidates, hasLength(1));
  });

  for (final holdArtifact in [true, false]) {
    test(
        'concurrent replay is claimed before await; holdArtifact=$holdArtifact',
        () async {
      final issued = await _issued();
      final gate = Completer<void>();
      final entered = Completer<void>();
      final artifacts = _currentArtifacts();
      final persistence = _RecordingPersistencePort();
      if (holdArtifact) {
        artifacts.gate = gate;
        artifacts.entered = entered;
      } else {
        persistence.gate = gate;
        persistence.entered = entered;
      }
      final command = SupplementalAnswerConfirmCommand(
          artifactPort: artifacts, persistencePort: persistence);
      final first = command.confirm(issued.confirmation);
      try {
        await entered.future;
        await expectLater(command.confirm(issued.confirmation),
            _reviewFailure(SupplementalAnswerReviewFailure.alreadyDecided));
        expect(artifacts.calls, hasLength(1));
        expect(persistence.candidates, hasLength(holdArtifact ? 0 : 1));
      } finally {
        gate.complete();
      }
      await first;
      expect(persistence.candidates, hasLength(1));
    });
  }

  test('artifact identity drift remains staleTarget and consumes authorization',
      () async {
    for (final artifact in [
      ParsedArtifact(
          fileId: 'file_001',
          artifactId: 'artifact_001',
          revision: 3,
          payloadSchemaVersion: 1),
      ParsedArtifact(
          fileId: 'file_001',
          artifactId: 'other',
          revision: 2,
          payloadSchemaVersion: 1),
      ParsedArtifact(
          fileId: 'other',
          artifactId: 'artifact_001',
          revision: 2,
          payloadSchemaVersion: 1),
    ]) {
      final issued = await _issued();
      final artifacts = _ArtifactPort(artifact: artifact);
      final persistence = _RecordingPersistencePort();
      final command = SupplementalAnswerConfirmCommand(
          artifactPort: artifacts, persistencePort: persistence);
      await expectLater(command.confirm(issued.confirmation),
          _commandFailure(SupplementalAnswerFailure.staleTarget));
      await expectLater(command.confirm(issued.confirmation),
          _reviewFailure(SupplementalAnswerReviewFailure.alreadyDecided));
      expect(artifacts.calls, hasLength(1));
      expect(persistence.candidates, isEmpty);
    }
  });

  test('artifact errors map safely and consume authorization', () async {
    for (final entry in [
      (
        ParsedArtifactLifecycleFailure.artifactCorrupt,
        SupplementalAnswerFailure.artifactCorrupt
      ),
      (
        ParsedArtifactLifecycleFailure.payloadUnsupported,
        SupplementalAnswerFailure.unsupportedArtifact
      ),
      (
        ParsedArtifactLifecycleFailure.fileNotFound,
        SupplementalAnswerFailure.sourceUnavailable
      ),
      (
        ParsedArtifactLifecycleFailure.temporarilyUnavailable,
        SupplementalAnswerFailure.temporarilyUnavailable
      ),
      (
        ParsedArtifactLifecycleFailure.internalError,
        SupplementalAnswerFailure.internalError
      ),
    ]) {
      final issued = await _issued();
      final artifacts = _ArtifactPort.failure(entry.$1);
      final persistence = _RecordingPersistencePort();
      final command = SupplementalAnswerConfirmCommand(
          artifactPort: artifacts, persistencePort: persistence);
      await expectLater(
          command.confirm(issued.confirmation), _commandFailure(entry.$2));
      await expectLater(command.confirm(issued.confirmation),
          _reviewFailure(SupplementalAnswerReviewFailure.alreadyDecided));
      expect(artifacts.calls, hasLength(1));
      expect(persistence.candidates, isEmpty);
    }
  });

  test('persistence failure consumes authorization even after recovery',
      () async {
    final issued = await _issued();
    final artifacts = _currentArtifacts();
    final persistence = _RecordingPersistencePort()
      ..failure = TypedAnswerMutationFailure.transactionFailed;
    final command = SupplementalAnswerConfirmCommand(
        artifactPort: artifacts, persistencePort: persistence);
    await expectLater(command.confirm(issued.confirmation),
        _commandFailure(SupplementalAnswerFailure.temporarilyUnavailable));
    persistence.failure = null;
    await expectLater(command.confirm(issued.confirmation),
        _reviewFailure(SupplementalAnswerReviewFailure.alreadyDecided));
    expect(artifacts.calls, hasLength(1));
    expect(persistence.candidates, hasLength(1));
    // Recovery requires a new review and explicit verification.
    final fresh = await _issued();
    await command.confirm(fresh.confirmation);
    expect(persistence.candidates, hasLength(2));
  });

  test('later session transition invalidates unclaimed authorization',
      () async {
    final issued = await _issued();
    issued.session.markCommitted(issued.confirmation.candidate.candidateId);
    final artifacts = _currentArtifacts();
    final persistence = _RecordingPersistencePort();
    await expectLater(
        SupplementalAnswerConfirmCommand(
                artifactPort: artifacts, persistencePort: persistence)
            .confirm(issued.confirmation),
        _reviewFailure(SupplementalAnswerReviewFailure.staleSessionRevision));
    expect(artifacts.calls, isEmpty);
    expect(persistence.candidates, isEmpty);
  });

  test('foreign origin cannot be verified or issued a P6 confirmation',
      () async {
    final ai = AnswerCandidate(
        candidateId: 'ai',
        targetStorageId: 'q_1',
        targetBankName: 'bank_math',
        expectedDraft: _draft(),
        answer: ContentAnswer(content: _text('x = 1')),
        writeIntent: CandidateWriteIntent.fill,
        origin: AiAnswerOrigin(
            generationId: 'gen',
            providerProfileId: 'profile',
            generatedAtUtc: DateTime.utc(2026)));
    final session = _review(ai);
    final inspection = await _inspection(revision: 2);
    expect(
        () => session.verifySource('ai', inspection),
        _reviewFailure(
            SupplementalAnswerReviewFailure.sourceInspectionRequired));
    expect(
        () => session.confirmFill('ai'),
        _reviewFailure(
            SupplementalAnswerReviewFailure.sourceVerificationRequired));
  });
}

_ArtifactPort _currentArtifacts() => _ArtifactPort(
    artifact: ParsedArtifact(
        fileId: 'file_001',
        artifactId: 'artifact_001',
        revision: 2,
        payloadSchemaVersion: 1));

SupplementalAnswerReviewSession _review(AnswerCandidate candidate) =>
    SupplementalAnswerReviewSession(
      request: SupplementalAnswerMatchRequest(
          targetScope: const QuestionBankScope(bankName: 'bank_math'),
          supplementalFileId: 'file_001'),
      snapshot: TargetQuestionSnapshot(targets: [], reports: []),
      matchResult: SupplementalMatchResult(records: [
        AnswerMatchRecord(
            fragmentId: 'frag',
            disposition: AnswerMatchDisposition.matched,
            certainty: MatchCertainty.deterministic,
            evidence: [],
            candidate: candidate)
      ], coverage: []),
    );

Future<
    ({
      SupplementalAnswerReviewSession session,
      SupplementalAnswerConfirmation confirmation
    })> _issued() async {
  final candidate = _candidate(_draft());
  final inspection = await _inspection(revision: 2);
  return _review(candidate)
      .verifySource(candidate.candidateId, inspection)
      .confirmFill(candidate.candidateId);
}

class _ArtifactPort implements ParsedArtifactLifecyclePort {
  _ArtifactPort({required this.artifact}) : _failure = null;

  _ArtifactPort.failure(ParsedArtifactLifecycleFailure failure)
      : artifact = null,
        _failure = failure;

  final ParsedArtifact? artifact;
  final ParsedArtifactLifecycleFailure? _failure;
  final List<String> calls = <String>[];
  Completer<void>? gate;
  Completer<void>? entered;

  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async {
    calls.add(fileId);
    entered?.complete();
    if (gate != null) await gate!.future;
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
  Completer<void>? gate;
  Completer<void>? entered;
  TypedAnswerMutationFailure? failure;

  @override
  Future<void> confirmCandidate(AnswerCandidate candidate) async {
    candidates.add(candidate);
    entered?.complete();
    if (gate != null) await gate!.future;
    if (failure != null) throw TypedAnswerMutationException(failure!);
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
