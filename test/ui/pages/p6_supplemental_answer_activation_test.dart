// P6-ACT-1 ordinary-user activation surface.
//
// Synthetic fixtures only: no live OCR/provider, no private PDFs, no network.
// Proves the real BankDetail entry reaches the existing P6 review screen
// through the Application activation seam, and that cancel/empty/failure
// paths stay bounded with zero mutation.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/file_library/file_library_ports.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_activation_service.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_command.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_source_acquisition_service.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_target_port.dart';
import 'package:shiroha_quiz/application/supplemental_answers/target_question_snapshot_service.dart';
import 'package:shiroha_quiz/domain/answers/answer_candidate.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/assets/parsed_artifact.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/ui/dependencies/supplemental_answer_dependencies_scope.dart';
import 'package:shiroha_quiz/ui/pages/bank_detail_screen.dart';
import 'package:shiroha_quiz/ui/pages/supplemental_answer_review_screen.dart';

const _bankName = 'p6_ui_bank';
const _fileId = 'p6_ui_file';
const _artifactId = 'p6_ui_artifact';
const _storageId = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';

void main() {
  testWidgets('BankDetail hides the P6 entry without the dependency scope',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: BankDetailScreen(bankName: _bankName)),
    );
    await tester.pumpAndSettle();

    expect(find.text('从文件补充答案'), findsNothing);
    expect(find.text('浏览题库内容'), findsOneWidget);
  });

  testWidgets('selecting a library file opens the existing review screen',
      (tester) async {
    final targets = _FakeTargetPort([_typedRead()]);
    final artifacts = _FakeArtifactPort(
      snapshot: _snapshot(revision: 2, parts: [_answerParagraph('1. x = 1')]),
    );
    final persistence = _FakePersistencePort();
    final ingestion = _RecordingIngestionPort();

    await _pumpBankDetail(
      tester,
      files: [_libraryFile('supplemental.pdf')],
      targets: targets,
      artifacts: artifacts,
      persistence: persistence,
      ingestion: ingestion,
    );

    await tester.tap(find.text('从文件补充答案'));
    await tester.pumpAndSettle();

    expect(find.text('supplemental.pdf'), findsOneWidget);
    expect(find.text('从文件补充答案'), findsNWidgets(2));

    await tester.tap(find.text('supplemental.pdf'));
    await tester.pumpAndSettle();

    expect(find.text('补充答案确认'), findsOneWidget);
    expect(find.text('x = 1'), findsOneWidget);
    expect(find.byType(SupplementalAnswerReviewScreen), findsOneWidget);
    expect(targets.listByBankCalls, 1);
    expect(artifacts.getCurrentArtifactCalls, 1);
    expect(artifacts.ensureCalls, 0);
    expect(artifacts.reparseCalls, 0);
    expect(ingestion.ingestedPaths, isEmpty);
    expect(persistence.confirmed, isEmpty);
  });

  testWidgets('cancelling the picker starts no session', (tester) async {
    final targets = _FakeTargetPort([_typedRead()]);
    final artifacts = _FakeArtifactPort(
      snapshot: _snapshot(revision: 1, parts: [_answerParagraph('1. x = 1')]),
    );

    await _pumpBankDetail(
      tester,
      files: [_libraryFile('supplemental.pdf')],
      targets: targets,
      artifacts: artifacts,
    );

    await tester.tap(find.text('从文件补充答案'));
    await tester.pumpAndSettle();
    expect(find.text('supplemental.pdf'), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('supplemental.pdf'), findsNothing);
    expect(find.byType(SupplementalAnswerReviewScreen), findsNothing);
    expect(targets.listByBankCalls, 0);
    expect(artifacts.getCurrentArtifactCalls, 0);
  });

  testWidgets('an empty file library shows an explicit empty state',
      (tester) async {
    final targets = _FakeTargetPort([_typedRead()]);
    final artifacts = _FakeArtifactPort(
      snapshot: _snapshot(revision: 1, parts: [_answerParagraph('1. x = 1')]),
    );

    await _pumpBankDetail(
      tester,
      files: const [],
      targets: targets,
      artifacts: artifacts,
    );

    await tester.tap(find.text('从文件补充答案'));
    await tester.pumpAndSettle();

    expect(find.text('文件库中还没有文件，可先添加一份答案文件。'), findsOneWidget);
    expect(targets.listByBankCalls, 0);
  });

  testWidgets('an activation failure shows a bounded message and no review',
      (tester) async {
    final targets = _FakeTargetPort([_typedRead()]);
    final artifacts = _FakeArtifactPort(
      failure: ParsedArtifactLifecycleFailure.artifactMissing,
    );

    await _pumpBankDetail(
      tester,
      files: [_libraryFile('unparsed.pdf')],
      targets: targets,
      artifacts: artifacts,
    );

    await tester.tap(find.text('从文件补充答案'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('unparsed.pdf'));
    await tester.pumpAndSettle();

    expect(find.text('该文件尚未完成内容解析，请先在文件库中解析后再试。'), findsOneWidget);
    expect(find.byType(SupplementalAnswerReviewScreen), findsNothing);
    expect(artifacts.getCurrentArtifactCalls, 1);
    expect(artifacts.ensureCalls, 0);
    expect(artifacts.reparseCalls, 0);
  });

  testWidgets('tapping again while starting starts no second session',
      (tester) async {
    final targets = _FakeTargetPort([_typedRead()]);
    final artifacts = _FakeArtifactPort(
      snapshot: _snapshot(revision: 1, parts: [_answerParagraph('1. x = 1')]),
    )..hold();

    await _pumpBankDetail(
      tester,
      files: [_libraryFile('supplemental.pdf')],
      targets: targets,
      artifacts: artifacts,
    );

    await tester.tap(find.text('从文件补充答案'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('supplemental.pdf'));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('supplemental.pdf'), warnIfMissed: false);
    await tester.pump();

    artifacts.release();
    await tester.pumpAndSettle();

    expect(find.byType(SupplementalAnswerReviewScreen), findsOneWidget);
    expect(targets.listByBankCalls, 1);
    expect(artifacts.getCurrentArtifactCalls, 1);
  });
}

Future<void> _pumpBankDetail(
  WidgetTester tester, {
  required List<LibraryFile> files,
  required _FakeTargetPort targets,
  required _FakeArtifactPort artifacts,
  _FakePersistencePort? persistence,
  _RecordingIngestionPort? ingestion,
}) async {
  final service = SupplementalAnswerActivationService(
    fileCatalog: _FakeFileCatalog(files),
    targetSnapshotService: TargetQuestionSnapshotService(port: targets),
    artifactPort: artifacts,
  );
  final command = SupplementalAnswerConfirmCommand(
    artifactPort: artifacts,
    persistencePort: persistence ?? _FakePersistencePort(),
  );
  await tester.pumpWidget(
    SupplementalAnswerDependenciesScope(
      activationService: service,
      sourceAcquisitionService: SupplementalAnswerSourceAcquisitionService(
        ingestion: ingestion ?? _RecordingIngestionPort(),
        artifactPort: artifacts,
        activationService: service,
      ),
      confirmCommand: command,
      pickFile: () async => null,
      child: const MaterialApp(home: BankDetailScreen(bankName: _bankName)),
    ),
  );
  await tester.pumpAndSettle();
}

/// Records ingestion attempts so the existing-file path can prove it never
/// ingests, parses, or OCRs anything.
class _RecordingIngestionPort implements FileIngestionPort {
  final List<String> ingestedPaths = <String>[];

  @override
  Future<LibraryFile> ingest({
    required String externalPath,
    required String displayName,
    String? mimeType,
  }) async {
    ingestedPaths.add(externalPath);
    throw UnimplementedError();
  }
}

LibraryFile _libraryFile(String displayName) {
  return LibraryFile(
    fileId: _fileId,
    displayName: displayName,
    mimeType: 'application/pdf',
    sizeBytes: 2048,
    sha256: 'a' * 64,
    storageKey: 'p6/ui',
    createdAt: DateTime.utc(2026, 1, 1),
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
      stem: _text('stem 1'),
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

SourcePart _answerParagraph(String text) {
  return SourceContentPart(
    sourceRef: SourceRef.document(sourceId: _artifactId),
    content: _text(text),
    role: SourceContentRole.answerLike,
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

class _FakeArtifactPort implements ParsedArtifactLifecyclePort {
  _FakeArtifactPort({this.snapshot, this.failure});

  final ParsedArtifactSnapshot? snapshot;
  final ParsedArtifactLifecycleFailure? failure;
  int getCurrentArtifactCalls = 0;
  int ensureCalls = 0;
  int reparseCalls = 0;
  Completer<void>? _gate;

  void hold() {
    _gate = Completer<void>();
  }

  void release() {
    _gate?.complete();
  }

  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async {
    getCurrentArtifactCalls++;
    final gate = _gate;
    if (gate != null) {
      await gate.future;
      _gate = null;
    }
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
    throw UnimplementedError();
  }
}

class _FakePersistencePort implements SupplementalAnswerPersistencePort {
  final List<AnswerCandidate> confirmed = <AnswerCandidate>[];

  @override
  Future<void> confirmCandidate(AnswerCandidate candidate) async {
    confirmed.add(candidate);
  }
}
