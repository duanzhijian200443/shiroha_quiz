// P6-ACT-1 Application activation seam.
//
// Synthetic fixtures only: no live OCR/provider, no private PDFs, no network.
// Proves the ordinary-user entry resolves a bank scope plus one explicitly
// selected File Library file into the existing P6 session, and that every
// activation failure fails safely with zero ensure/reparse/OCR/mutation.
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/file_library/file_library_ports.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_activation_service.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_failure.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_target_port.dart';
import 'package:shiroha_quiz/application/supplemental_answers/target_question_snapshot_service.dart';
import 'package:shiroha_quiz/application/u1_workspace/u1_workspace_dtos.dart';
import 'package:shiroha_quiz/domain/answers/answer_candidate.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/assets/parsed_artifact.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/answer_match_record.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_scope.dart';

const _bankName = 'p6_activation_bank';
const _fileId = 'p6_activation_file';
const _artifactId = 'p6_activation_artifact';
const _storageId = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';

void main() {
  group('listSupplementalFiles', () {
    test('exposes only safe file summaries, newest first', () async {
      final older = _libraryFile(
        fileId: 'file_older',
        displayName: 'older.pdf',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final newer = _libraryFile(
        fileId: 'file_newer',
        displayName: 'newer.pdf',
        createdAt: DateTime.utc(2026, 6, 1),
      );
      final service = _service(
        files: [older, newer],
        targetReads: const [],
      );

      final summaries = await service.listSupplementalFiles();

      expect(
        summaries.map((summary) => summary.fileId),
        ['file_newer', 'file_older'],
      );
      final summary = summaries.first;
      expect(summary.displayName, 'newer.pdf');
      expect(summary.mimeType, 'application/pdf');
      expect(summary.sizeBytes, 128);
      expect(summary.createdAt, DateTime.utc(2026, 6, 1));
      expect(summary, isA<LibraryFileSummary>());
    });
  });

  group('startSession', () {
    test('binds the bank scope, the selected file, and artifact provenance',
        () async {
      final artifacts = _RecordingArtifactPort(
        snapshot: _snapshot(
          revision: 3,
          parts: [_answerParagraph(_artifactId, '1. x = 1')],
        ),
      );
      final service = _service(
        files: [_libraryFile()],
        targetReads: [_typedRead(number: 1)],
        artifacts: artifacts,
      );

      final session = await service.startSession(
        targetScope: const QuestionBankScope(bankName: _bankName),
        supplementalFileId: _fileId,
      );

      expect(session.request.supplementalFileId, _fileId);
      expect(
        session.request.targetScope,
        const QuestionBankScope(bankName: _bankName),
      );
      expect(session.snapshot.targets.single.storageId, _storageId);
      expect(session.records, hasLength(1));
      expect(
        session.records.single.disposition,
        AnswerMatchDisposition.matched,
      );

      final candidate = session.records.single.candidate!;
      expect(candidate.targetStorageId, _storageId);
      expect(candidate.targetBankName, _bankName);
      expect(candidate.writeIntent, CandidateWriteIntent.fill);
      final origin = candidate.origin as SupplementalAnswerOrigin;
      expect(origin.supplementalFileId, _fileId);
      expect(origin.artifactId, _artifactId);
      expect(origin.artifactRevision, 3);
      expect(origin.supplementalSourceRefs, isNotEmpty);

      expect(artifacts.getCurrentArtifactCalls, 1);
      expect(artifacts.ensureCalls, 0);
      expect(artifacts.reparseCalls, 0);
      expect(artifacts.removeCalls, 0);
    });

    test('a file without a current artifact fails safely, never reparses',
        () async {
      final artifacts = _RecordingArtifactPort(
        failure: ParsedArtifactLifecycleFailure.artifactMissing,
      );
      final service = _service(
        files: [_libraryFile()],
        targetReads: [_typedRead(number: 1)],
        artifacts: artifacts,
      );

      await expectLater(
        service.startSession(
          targetScope: const QuestionBankScope(bankName: _bankName),
          supplementalFileId: _fileId,
        ),
        throwsA(
          isA<SupplementalAnswerException>().having(
            (error) => error.failure,
            'failure',
            SupplementalAnswerFailure.sourceUnavailable,
          ),
        ),
      );
      expect(artifacts.ensureCalls, 0);
      expect(artifacts.reparseCalls, 0);
      expect(artifacts.removeCalls, 0);
    });

    test('a corrupt artifact fails closed as artifactCorrupt', () async {
      final artifacts = _RecordingArtifactPort(
        failure: ParsedArtifactLifecycleFailure.artifactCorrupt,
      );
      final service = _service(
        files: [_libraryFile()],
        targetReads: [_typedRead(number: 1)],
        artifacts: artifacts,
      );

      await expectLater(
        service.startSession(
          targetScope: const QuestionBankScope(bankName: _bankName),
          supplementalFileId: _fileId,
        ),
        throwsA(
          isA<SupplementalAnswerException>().having(
            (error) => error.failure,
            'failure',
            SupplementalAnswerFailure.artifactCorrupt,
          ),
        ),
      );
      expect(artifacts.getCurrentArtifactCalls, 1);
      expect(artifacts.ensureCalls, 0);
      expect(artifacts.reparseCalls, 0);
    });

    test('a bank without eligible typed targets fails as targetUnavailable',
        () async {
      final artifacts = _RecordingArtifactPort(
        snapshot: _snapshot(
          revision: 1,
          parts: [_answerParagraph(_artifactId, '1. x = 1')],
        ),
      );
      final targets = _FakeTargetPort(const []);
      final service = SupplementalAnswerActivationService(
        fileCatalog: _FakeFileCatalog([_libraryFile()]),
        targetSnapshotService: TargetQuestionSnapshotService(port: targets),
        artifactPort: artifacts,
      );

      await expectLater(
        service.startSession(
          targetScope: const QuestionBankScope(bankName: _bankName),
          supplementalFileId: _fileId,
        ),
        throwsA(
          isA<SupplementalAnswerException>().having(
            (error) => error.failure,
            'failure',
            SupplementalAnswerFailure.targetUnavailable,
          ),
        ),
      );
      expect(targets.listByBankCalls, 1);
      expect(artifacts.getCurrentArtifactCalls, 0);
    });

    test('an artifact without a usable answer fails as noUsableAnswers',
        () async {
      final artifacts = _RecordingArtifactPort(
        snapshot:
            _snapshot(revision: 1, parts: [_unsupportedPart(_artifactId)]),
      );
      final service = _service(
        files: [_libraryFile()],
        targetReads: [_typedRead(number: 1)],
        artifacts: artifacts,
      );

      await expectLater(
        service.startSession(
          targetScope: const QuestionBankScope(bankName: _bankName),
          supplementalFileId: _fileId,
        ),
        throwsA(
          isA<SupplementalAnswerException>().having(
            (error) => error.failure,
            'failure',
            SupplementalAnswerFailure.noUsableAnswers,
          ),
        ),
      );
      expect(artifacts.ensureCalls, 0);
      expect(artifacts.reparseCalls, 0);
    });
  });
}

SupplementalAnswerActivationService _service({
  required List<LibraryFile> files,
  required List<SupplementalTargetRead> targetReads,
  _RecordingArtifactPort? artifacts,
}) {
  return SupplementalAnswerActivationService(
    fileCatalog: _FakeFileCatalog(files),
    targetSnapshotService: TargetQuestionSnapshotService(
      port: _FakeTargetPort(targetReads),
    ),
    artifactPort: artifacts ?? _RecordingArtifactPort(),
  );
}

LibraryFile _libraryFile({
  String fileId = _fileId,
  String displayName = 'supplemental.pdf',
  DateTime? createdAt,
}) {
  return LibraryFile(
    fileId: fileId,
    displayName: displayName,
    mimeType: 'application/pdf',
    sizeBytes: 128,
    sha256: 'a' * 64,
    storageKey: 'p6/activation',
    createdAt: createdAt ?? DateTime.utc(2026, 1, 1),
  );
}

SupplementalTargetRead _typedRead({
  required int number,
  String storageId = _storageId,
  String bankName = _bankName,
}) {
  return SupplementalTargetRead(
    storageId: storageId,
    bankName: bankName,
    typedDraft: QuestionDraftV2(
      questionId: storageId,
      kind: QuestionKind.shortAnswer,
      questionNumber: number,
      stem: _text('stem $number'),
    ),
  );
}

ParsedArtifactSnapshot _snapshot({
  required int revision,
  required List<SourcePart> parts,
}) {
  return ParsedArtifactSnapshot(
    artifact: ParsedArtifact(
      fileId: _fileId,
      artifactId: _artifactId,
      revision: revision,
      payloadSchemaVersion: 1,
    ),
    sourceDocument: SourceDocument(sourceId: _artifactId, parts: parts),
  );
}

SourcePart _answerParagraph(String artifactId, String text) {
  return SourceContentPart(
    sourceRef: SourceRef.document(sourceId: artifactId),
    content: _text(text),
    role: SourceContentRole.answerLike,
  );
}

SourcePart _unsupportedPart(String artifactId) {
  return UnsupportedSourcePart(
    sourceRef: SourceRef.document(sourceId: artifactId),
    kindCode: 'embedded_object',
    fallbackContent: _text('unsupported payload'),
  );
}

RichContent _text(String text) {
  return RichContent(nodes: [TextNode(text)]);
}

class _FakeFileCatalog implements LibraryFileRepositoryPort {
  _FakeFileCatalog(this.files);

  final List<LibraryFile> files;

  @override
  Future<void> save(LibraryFile file) async {
    throw UnimplementedError();
  }

  @override
  Future<LibraryFile?> findById(String fileId) async {
    for (final file in files) {
      if (file.fileId == fileId) return file;
    }
    return null;
  }

  @override
  Future<List<LibraryFile>> findAll() async => files;
}

class _FakeTargetPort implements SupplementalAnswerTargetPort {
  _FakeTargetPort(this.reads);

  final List<SupplementalTargetRead> reads;
  int listByBankCalls = 0;

  @override
  Future<List<SupplementalTargetRead>> listTypedQuestionsByBank(
    String bankName,
  ) async {
    listByBankCalls++;
    return reads;
  }

  @override
  Future<List<SupplementalTargetRead>> listTypedQuestionsByIds(
    Iterable<String> storageIds,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<List<String>> listProjectBankNames(String projectId) async {
    throw UnimplementedError();
  }
}

/// Records artifact-seam usage so every test can prove what was never called.
class _RecordingArtifactPort implements ParsedArtifactLifecyclePort {
  _RecordingArtifactPort({this.snapshot, this.failure});

  final ParsedArtifactSnapshot? snapshot;
  final ParsedArtifactLifecycleFailure? failure;
  int getCurrentArtifactCalls = 0;
  int ensureCalls = 0;
  int reparseCalls = 0;
  int removeCalls = 0;

  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async {
    getCurrentArtifactCalls++;
    final failure = this.failure;
    if (failure != null) throw ParsedArtifactLifecycleException(failure);
    return snapshot!;
  }

  @override
  Future<ParsedArtifactEnsureResult> ensureParsedArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
  }) async {
    ensureCalls++;
    throw UnimplementedError();
  }

  @override
  Future<ParsedArtifactEnsureResult> reparseArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
    required int expectedRevision,
  }) async {
    reparseCalls++;
    throw UnimplementedError();
  }

  @override
  Future<void> removeCurrentArtifact({
    required String fileId,
    required int expectedRevision,
  }) async {
    removeCalls++;
    throw UnimplementedError();
  }
}
