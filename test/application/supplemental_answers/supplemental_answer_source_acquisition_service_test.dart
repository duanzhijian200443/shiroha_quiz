// P6-ACT-2 Application direct-source acquisition seam.
//
// Synthetic fixtures only: no live OCR/provider, no private PDFs, no network.
// Proves external file -> File Library ingestion -> deterministic F1 parsing ->
// explicit scanned-PDF OCR decision -> existing P6 activation, with exactly-once
// side effects, no silent OCR, and no LibraryFile rollback.
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/file_library/file_library_ports.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_activation_service.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_source_acquisition_service.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_review_session.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_target_port.dart';
import 'package:shiroha_quiz/application/supplemental_answers/target_question_snapshot_service.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/assets/parsed_artifact.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_scope.dart';

const _bankName = 'p6_direct_bank';
const _artifactId = 'p6_direct_artifact';
const _storageId = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';

void main() {
  group('addSourceAndStart', () {
    test('ingests once, parses deterministically once, and starts P6',
        () async {
      final ingestion = _FakeIngestionPort();
      final artifacts = _FakeArtifactLifecyclePort(
        snapshot: _snapshot(revision: 2, parts: [_answerParagraph('1. x = 1')]),
      );
      final phases = <SupplementalAnswerSourcePhase>[];
      final service = _service(
        ingestion: ingestion,
        artifacts: artifacts,
      );

      final outcome = await service.addSourceAndStart(
        targetScope: const QuestionBankScope(bankName: _bankName),
        externalPath: r'C:\picked\supplemental.pdf',
        displayName: 'supplemental.pdf',
        onPhase: phases.add,
      );

      final ready = outcome as SupplementalAnswerSourceReady;
      expect(ready.session.request.supplementalFileId, ingestion.issuedFileId);
      expect(
        ready.session.request.targetScope,
        const QuestionBankScope(bankName: _bankName),
      );
      expect(ready.session.records, hasLength(1));
      expect(ready.session.sessionRevision, 0);
      expect(
        ready.session.outcomes.values,
        isNot(contains(CandidateReviewOutcome.committed)),
      );

      expect(ingestion.ingestedPaths, [r'C:\picked\supplemental.pdf']);
      expect(ingestion.ingestedNames, ['supplemental.pdf']);
      expect(ingestion.ingestedMimeTypes, ['application/pdf']);
      expect(artifacts.ensureRoutes, [
        ParsedArtifactRouteSelection.auto,
      ]);
      expect(artifacts.getCurrentArtifactCalls, 1);
      expect(artifacts.reparseCalls, 0);
      expect(phases, [
        SupplementalAnswerSourcePhase.ingesting,
        SupplementalAnswerSourcePhase.preparing,
        SupplementalAnswerSourcePhase.matching,
      ]);
    });

    test('maps every supported extension to a safe media type', () async {
      expect(
        supplementalAnswerSourceFileExtensions.map(
          (extension) => supplementalAnswerSourceMimeType('source.$extension'),
        ),
        isNot(contains(null)),
      );
      expect(
        supplementalAnswerSourceMimeTypes.keys,
        containsAll(supplementalAnswerSourceFileExtensions),
      );
      expect(
        supplementalAnswerSourceMimeTypes,
        <String, String>{
          'pdf': 'application/pdf',
          'docx': 'application/vnd.openxmlformats-officedocument'
              '.wordprocessingml.document',
          'txt': 'text/plain',
          'md': 'text/markdown',
          'markdown': 'text/markdown',
        },
      );

      for (final entry in <String, String>{
        'paper.PDF': 'application/pdf',
        'notes.docx': 'application/vnd.openxmlformats-officedocument'
            '.wordprocessingml.document',
        'notes.txt': 'text/plain',
        'notes.md': 'text/markdown',
        'notes.markdown': 'text/markdown',
      }.entries) {
        final ingestion = _FakeIngestionPort();
        final artifacts = _FakeArtifactLifecyclePort(
          snapshot:
              _snapshot(revision: 1, parts: [_answerParagraph('1. x = 1')]),
        );
        final service = _service(ingestion: ingestion, artifacts: artifacts);

        await service.addSourceAndStart(
          targetScope: const QuestionBankScope(bankName: _bankName),
          externalPath: r'C:\picked\source',
          displayName: entry.key,
        );

        expect(ingestion.ingestedMimeTypes, [entry.value]);
      }
    });

    test('rejects unsupported file types before any side effect', () async {
      final ingestion = _FakeIngestionPort();
      final artifacts = _FakeArtifactLifecyclePort(
        snapshot: _snapshot(revision: 1, parts: [_answerParagraph('1. x = 1')]),
      );
      final service = _service(ingestion: ingestion, artifacts: artifacts);

      final outcome = await service.addSourceAndStart(
        targetScope: const QuestionBankScope(bankName: _bankName),
        externalPath: r'C:\picked\scan.png',
        displayName: 'scan.png',
      );

      expect(
        (outcome as SupplementalAnswerSourceFailed).failure,
        SupplementalAnswerSourceFailure.unsupportedFile,
      );
      expect(ingestion.ingestedPaths, isEmpty);
      expect(artifacts.ensureRoutes, isEmpty);
      expect(artifacts.getCurrentArtifactCalls, 0);
    });

    test('fails safely when the picked file cannot be ingested', () async {
      final ingestion = _FakeIngestionPort(ingestFailure: StateError('copy'));
      final artifacts = _FakeArtifactLifecyclePort();
      final service = _service(ingestion: ingestion, artifacts: artifacts);

      final outcome = await service.addSourceAndStart(
        targetScope: const QuestionBankScope(bankName: _bankName),
        externalPath: r'C:\picked\broken.pdf',
        displayName: 'broken.pdf',
      );

      expect(
        (outcome as SupplementalAnswerSourceFailed).failure,
        SupplementalAnswerSourceFailure.ingestionFailed,
      );
      expect(ingestion.ingestedPaths, hasLength(1));
      expect(artifacts.ensureRoutes, isEmpty);
      expect(artifacts.getCurrentArtifactCalls, 0);
    });

    test('keeps the ingested LibraryFile when deterministic parsing fails',
        () async {
      final ingestion = _FakeIngestionPort();
      final artifacts = _FakeArtifactLifecyclePort(
        ensureFailures: const {
          ParsedArtifactRouteSelection.auto:
              ParsedArtifactLifecycleFailure.parseFailed,
        },
      );
      final service = _service(ingestion: ingestion, artifacts: artifacts);

      final outcome = await service.addSourceAndStart(
        targetScope: const QuestionBankScope(bankName: _bankName),
        externalPath: r'C:\picked\broken.pdf',
        displayName: 'broken.pdf',
      );

      expect(
        (outcome as SupplementalAnswerSourceFailed).failure,
        SupplementalAnswerSourceFailure.parseFailed,
      );
      expect(ingestion.files, hasLength(1));
      expect(artifacts.ensureRoutes, [ParsedArtifactRouteSelection.auto]);
      expect(artifacts.getCurrentArtifactCalls, 0);
    });

    test('offers explicit OCR for a scanned PDF without calling OCR', () async {
      final ingestion = _FakeIngestionPort();
      final artifacts = _FakeArtifactLifecyclePort(
        ensureFailures: const {
          ParsedArtifactRouteSelection.auto:
              ParsedArtifactLifecycleFailure.sourceUnavailable,
        },
      );
      final service = _service(ingestion: ingestion, artifacts: artifacts);

      final outcome = await service.addSourceAndStart(
        targetScope: const QuestionBankScope(bankName: _bankName),
        externalPath: r'C:\picked\scanned.pdf',
        displayName: 'scanned.pdf',
      );

      expect(
        (outcome as SupplementalAnswerSourceOcrRequired).fileId,
        ingestion.issuedFileId,
      );
      expect(artifacts.ensureRoutes, [ParsedArtifactRouteSelection.auto]);
      expect(artifacts.getCurrentArtifactCalls, 0);
      expect(ingestion.files, hasLength(1));
    });

    test('does not offer OCR for a non-PDF without extractable text', () async {
      final ingestion = _FakeIngestionPort();
      final artifacts = _FakeArtifactLifecyclePort(
        ensureFailures: const {
          ParsedArtifactRouteSelection.auto:
              ParsedArtifactLifecycleFailure.sourceUnavailable,
        },
      );
      final service = _service(ingestion: ingestion, artifacts: artifacts);

      final outcome = await service.addSourceAndStart(
        targetScope: const QuestionBankScope(bankName: _bankName),
        externalPath: r'C:\picked\notes.txt',
        displayName: 'notes.txt',
      );

      expect(
        (outcome as SupplementalAnswerSourceFailed).failure,
        SupplementalAnswerSourceFailure.parseFailed,
      );
      expect(artifacts.ensureRoutes, [ParsedArtifactRouteSelection.auto]);
      expect(artifacts.getCurrentArtifactCalls, 0);
    });

    test('does not start a session when no usable answer is found', () async {
      final ingestion = _FakeIngestionPort();
      final artifacts = _FakeArtifactLifecyclePort(
        snapshot: _snapshot(revision: 1, parts: [_unsupportedPart()]),
      );
      final service = _service(ingestion: ingestion, artifacts: artifacts);

      final outcome = await service.addSourceAndStart(
        targetScope: const QuestionBankScope(bankName: _bankName),
        externalPath: r'C:\picked\worksheet.pdf',
        displayName: 'worksheet.pdf',
      );

      expect(
        (outcome as SupplementalAnswerSourceFailed).failure,
        SupplementalAnswerSourceFailure.noUsableAnswers,
      );
      expect(ingestion.files, hasLength(1));
    });

    test('reports the frozen targetUnavailable outcome unchanged', () async {
      final ingestion = _FakeIngestionPort();
      final artifacts = _FakeArtifactLifecyclePort(
        snapshot: _snapshot(revision: 1, parts: [_answerParagraph('1. x = 1')]),
      );
      final service = _service(
        ingestion: ingestion,
        artifacts: artifacts,
        targetReads: const [],
      );

      final outcome = await service.addSourceAndStart(
        targetScope: const QuestionBankScope(bankName: _bankName),
        externalPath: r'C:\picked\worksheet.pdf',
        displayName: 'worksheet.pdf',
      );

      expect(
        (outcome as SupplementalAnswerSourceFailed).failure,
        SupplementalAnswerSourceFailure.targetUnavailable,
      );
    });
  });

  group('continueWithOcr', () {
    test('runs ocr_pdf exactly once and then starts P6', () async {
      final ingestion = _FakeIngestionPort();
      final artifacts = _FakeArtifactLifecyclePort(
        snapshot: _snapshot(revision: 4, parts: [_answerParagraph('1. x = 1')]),
      );
      final service = _service(ingestion: ingestion, artifacts: artifacts);

      final outcome = await service.continueWithOcr(
        targetScope: const QuestionBankScope(bankName: _bankName),
        fileId: 'p6_direct_file',
      );

      final ready = outcome as SupplementalAnswerSourceReady;
      expect(ready.session.request.supplementalFileId, 'p6_direct_file');
      expect(artifacts.ensureRoutes, [ParsedArtifactRouteSelection.ocrPdf]);
      expect(artifacts.getCurrentArtifactCalls, 1);
      expect(ingestion.ingestedPaths, isEmpty);
    });

    test('maps an unavailable OCR service to its own bounded failure',
        () async {
      final artifacts = _FakeArtifactLifecyclePort(
        ensureFailures: const {
          ParsedArtifactRouteSelection.ocrPdf:
              ParsedArtifactLifecycleFailure.temporarilyUnavailable,
        },
      );
      final service = _service(
        ingestion: _FakeIngestionPort(),
        artifacts: artifacts,
      );

      final outcome = await service.continueWithOcr(
        targetScope: const QuestionBankScope(bankName: _bankName),
        fileId: 'p6_direct_file',
      );

      expect(
        (outcome as SupplementalAnswerSourceFailed).failure,
        SupplementalAnswerSourceFailure.ocrUnavailable,
      );
      expect(artifacts.ensureRoutes, [ParsedArtifactRouteSelection.ocrPdf]);
      expect(artifacts.getCurrentArtifactCalls, 0);
    });
  });
}

SupplementalAnswerSourceAcquisitionService _service({
  required _FakeIngestionPort ingestion,
  required _FakeArtifactLifecyclePort artifacts,
  List<SupplementalTargetRead>? targetReads,
}) {
  final activation = SupplementalAnswerActivationService(
    fileCatalog: _FakeFileCatalog(),
    targetSnapshotService: TargetQuestionSnapshotService(
      port: _FakeTargetPort(targetReads ?? [_typedRead()]),
    ),
    artifactPort: artifacts,
  );
  return SupplementalAnswerSourceAcquisitionService(
    ingestion: ingestion,
    artifactPort: artifacts,
    activationService: activation,
  );
}

ParsedArtifactSnapshot _snapshot({
  required int revision,
  required List<SourcePart> parts,
}) {
  return ParsedArtifactSnapshot(
    artifact: ParsedArtifact(
      fileId: 'p6_direct_file',
      artifactId: _artifactId,
      revision: revision,
      payloadSchemaVersion: 1,
    ),
    sourceDocument: SourceDocument(sourceId: _artifactId, parts: parts),
  );
}

SourcePart _answerParagraph(String text) {
  return SourceContentPart(
    sourceRef: SourceRef.document(sourceId: _artifactId),
    content: RichContent(nodes: [TextNode(text)]),
    role: SourceContentRole.answerLike,
  );
}

SourcePart _unsupportedPart() {
  return UnsupportedSourcePart(
    sourceRef: SourceRef.document(sourceId: _artifactId),
    kindCode: 'embedded_object',
    fallbackContent: RichContent(nodes: [const TextNode('unsupported')]),
  );
}

SupplementalTargetRead _typedRead() {
  return SupplementalTargetRead(
    storageId: _storageId,
    bankName: _bankName,
    typedDraft: QuestionDraftV2(
      questionId: _storageId,
      kind: QuestionKind.shortAnswer,
      questionNumber: 1,
      stem: RichContent(nodes: [const TextNode('stem 1')]),
    ),
  );
}

class _FakeIngestionPort implements FileIngestionPort {
  _FakeIngestionPort({this.ingestFailure});

  final Object? ingestFailure;
  final List<String> ingestedPaths = <String>[];
  final List<String> ingestedNames = <String>[];
  final List<String?> ingestedMimeTypes = <String?>[];
  final List<LibraryFile> files = <LibraryFile>[];

  String get issuedFileId =>
      files.isEmpty ? 'p6_direct_file' : files.last.fileId;

  @override
  Future<LibraryFile> ingest({
    required String externalPath,
    required String displayName,
    String? mimeType,
  }) async {
    ingestedPaths.add(externalPath);
    ingestedNames.add(displayName);
    ingestedMimeTypes.add(mimeType);
    final failure = ingestFailure;
    if (failure != null) throw failure;
    final file = LibraryFile(
      fileId: 'p6_direct_file',
      displayName: displayName,
      mimeType: mimeType ?? 'application/octet-stream',
      sizeBytes: 64,
      sha256: 'a' * 64,
      storageKey: 'p6/direct',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    files.add(file);
    return file;
  }
}

class _FakeFileCatalog implements LibraryFileRepositoryPort {
  @override
  Future<void> save(LibraryFile file) async {
    throw UnimplementedError();
  }

  @override
  Future<LibraryFile?> findById(String fileId) async => null;

  @override
  Future<List<LibraryFile>> findAll() async => const <LibraryFile>[];
}

class _FakeTargetPort implements SupplementalAnswerTargetPort {
  _FakeTargetPort(this.reads);

  final List<SupplementalTargetRead> reads;

  @override
  Future<List<SupplementalTargetRead>> listTypedQuestionsByBank(
    String bankName,
  ) async {
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

class _FakeArtifactLifecyclePort implements ParsedArtifactLifecyclePort {
  _FakeArtifactLifecyclePort({
    this.snapshot,
    this.ensureFailures = const {},
  });

  final ParsedArtifactSnapshot? snapshot;
  final Map<ParsedArtifactRouteSelection, ParsedArtifactLifecycleFailure>
      ensureFailures;
  final List<ParsedArtifactRouteSelection> ensureRoutes =
      <ParsedArtifactRouteSelection>[];
  int getCurrentArtifactCalls = 0;
  int reparseCalls = 0;

  @override
  Future<ParsedArtifactEnsureResult> ensureParsedArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
  }) async {
    ensureRoutes.add(options.routeSelection);
    final failure = ensureFailures[options.routeSelection];
    if (failure != null) throw ParsedArtifactLifecycleException(failure);
    return ParsedArtifactEnsureResult(
      outcome: ParsedArtifactLifecycleOutcome.published,
      snapshot: snapshot!,
    );
  }

  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async {
    getCurrentArtifactCalls++;
    return snapshot!;
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
    throw UnimplementedError();
  }
}
