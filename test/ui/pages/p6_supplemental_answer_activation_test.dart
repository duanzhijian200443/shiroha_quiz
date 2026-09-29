// P6-ACT-1 ordinary-user activation surface.
//
// Synthetic fixtures only: no live OCR/provider, no private PDFs, no network.
// Proves the selected ImportedQuestionSet entry reaches the existing P6 review screen
// through the Application activation seam, and that cancel/empty/failure
// paths stay bounded with zero mutation.
import 'package:shiroha_quiz/ui/pages/answer_completion_screen.dart';
import 'package:shiroha_quiz/ui/dependencies/answer_completion_dependencies_scope.dart';
import 'package:shiroha_quiz/domain/answer_completion/imported_question_set.dart';
import 'package:shiroha_quiz/application/answer_completion/answer_completion_supplemental.dart';
import 'package:shiroha_quiz/application/answer_completion/answer_completion_query.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/file_library/file_library_ports.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_command.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_target_port.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_source_inspection.dart';
import 'package:shiroha_quiz/domain/answers/answer_candidate.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/assets/parsed_artifact.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
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

    expect(find.text('从答案文件补充'), findsNothing);
    expect(find.text('从文件补充答案'), findsNothing);
    expect(find.text('补充答案'), findsNothing);
    expect(find.text('浏览题库内容'), findsOneWidget);
  });

  testWidgets('selecting a library file opens the existing review screen',
      (tester) async {
    final targets = _TargetFixture([_typedRead()]);
    final artifacts = _FakeArtifactPort(
      snapshot: _snapshot(revision: 2, parts: [_answerParagraph('1. x = 1')]),
    );
    final persistence = _FakePersistencePort();
    final ingestion = _RecordingIngestionPort();

    await _pumpSetDetail(
      tester,
      files: [_libraryFile('supplemental.pdf')],
      targets: targets,
      artifacts: artifacts,
      persistence: persistence,
      ingestion: ingestion,
    );

    await tester.tap(find.text('从答案文件补充'));
    await tester.pumpAndSettle();

    expect(find.text('supplemental.pdf'), findsOneWidget);
    expect(find.text('从答案文件补充'), findsOneWidget);
    expect(find.text('从文件补充答案'), findsOneWidget);

    await tester.tap(find.text('supplemental.pdf'));
    await tester.pumpAndSettle();

    expect(find.text('补充答案确认'), findsOneWidget);
    expect(find.text('x = 1'), findsOneWidget);
    expect(find.byType(SupplementalAnswerReviewScreen), findsOneWidget);
    expect(targets.targetResolutionCalls, 1);
    expect(artifacts.getCurrentArtifactCalls, 1);
    expect(artifacts.ensureCalls, 0);
    expect(artifacts.reparseCalls, 0);
    expect(ingestion.ingestedPaths, isEmpty);
    expect(persistence.confirmed, isEmpty);
  });

  testWidgets(
      'the connected review starts unverified with the original-source entry',
      (tester) async {
    final targets = _TargetFixture([_typedRead()]);
    final artifacts = _FakeArtifactPort(
      snapshot: _snapshot(revision: 2, parts: [_answerParagraph('1. x = 1')]),
    );
    final persistence = _FakePersistencePort();

    await _pumpSetDetail(
      tester,
      files: [_libraryFile('supplemental.pdf')],
      targets: targets,
      artifacts: artifacts,
      persistence: persistence,
    );

    await tester.tap(find.text('从答案文件补充'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('supplemental.pdf'));
    await tester.pumpAndSettle();

    // SV-B: the review flow carries the inspection capability, exposes the
    // original-source entry, and every candidate starts at 待核对原文 with
    // zero writes.
    expect(find.byType(SupplementalAnswerReviewScreen), findsOneWidget);
    expect(find.text('查看原文件'), findsWidgets);
    expect(find.text('待核对原文'), findsWidgets);
    expect(find.text('已核对原文'), findsNothing);
    expect(find.text('我已对照原文件确认此候选答案'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, '我已对照原文件确认此候选答案'),
          )
          .onPressed,
      isNull,
      reason: 'verification stays closed until an inspection exists',
    );
    expect(find.byType(Checkbox), findsOneWidget,
        reason: 'the target has no typed answer, so this is a fill candidate');
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认填写'))
          .onPressed,
      isNull,
      reason: 'fill stays disabled before source verification',
    );
    expect(persistence.confirmed, isEmpty);
    expect(artifacts.ensureCalls, 0);
  });

  testWidgets('cancelling the picker starts no session', (tester) async {
    final targets = _TargetFixture([_typedRead()]);
    final artifacts = _FakeArtifactPort(
      snapshot: _snapshot(revision: 1, parts: [_answerParagraph('1. x = 1')]),
    );

    await _pumpSetDetail(
      tester,
      files: [_libraryFile('supplemental.pdf')],
      targets: targets,
      artifacts: artifacts,
    );

    await tester.tap(find.text('从答案文件补充'));
    await tester.pumpAndSettle();
    expect(find.text('supplemental.pdf'), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('supplemental.pdf'), findsNothing);
    expect(find.byType(SupplementalAnswerReviewScreen), findsNothing);
    expect(targets.targetResolutionCalls, 0);
    expect(artifacts.getCurrentArtifactCalls, 0);
  });

  testWidgets('an empty file library shows an explicit empty state',
      (tester) async {
    final targets = _TargetFixture([_typedRead()]);
    final artifacts = _FakeArtifactPort(
      snapshot: _snapshot(revision: 1, parts: [_answerParagraph('1. x = 1')]),
    );

    await _pumpSetDetail(
      tester,
      files: const [],
      targets: targets,
      artifacts: artifacts,
    );

    await tester.tap(find.text('从答案文件补充'));
    await tester.pumpAndSettle();

    expect(find.text('文件库中还没有文件，可先添加一份答案文件。'), findsOneWidget);
    expect(targets.targetResolutionCalls, 0);
  });

  testWidgets('an activation failure shows a bounded message and no review',
      (tester) async {
    final targets = _TargetFixture([_typedRead()]);
    final artifacts = _FakeArtifactPort(
      failure: ParsedArtifactLifecycleFailure.artifactMissing,
    );

    await _pumpSetDetail(
      tester,
      files: [_libraryFile('unparsed.pdf')],
      targets: targets,
      artifacts: artifacts,
    );

    await tester.tap(find.text('从答案文件补充'));
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
    final targets = _TargetFixture([_typedRead()]);
    final artifacts = _FakeArtifactPort(
      snapshot: _snapshot(revision: 1, parts: [_answerParagraph('1. x = 1')]),
    )..hold();

    await _pumpSetDetail(
      tester,
      files: [_libraryFile('supplemental.pdf')],
      targets: targets,
      artifacts: artifacts,
    );

    await tester.tap(find.text('从答案文件补充'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('supplemental.pdf'));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('supplemental.pdf'), warnIfMissed: false);
    await tester.pump();

    artifacts.release();
    await tester.pumpAndSettle();

    expect(find.byType(SupplementalAnswerReviewScreen), findsOneWidget);
    expect(targets.targetResolutionCalls, 1);
    expect(artifacts.getCurrentArtifactCalls, 1);
  });
}

Future<void> _pumpSetDetail(
  WidgetTester tester, {
  required List<LibraryFile> files,
  required _TargetFixture targets,
  required _FakeArtifactPort artifacts,
  _FakePersistencePort? persistence,
  _RecordingIngestionPort? ingestion,
}) async {
  final command = SupplementalAnswerConfirmCommand(
    artifactPort: artifacts,
    persistencePort: persistence ?? _FakePersistencePort(),
  );
  final sourceInspection = SupplementalSourceInspectionService(
    fileCatalog: _FakeFileCatalog(files),
    artifactPort: artifacts,
    sourceReader: _FakeSourceReader(const <int>[]),
    maxBytes: 1 << 30,
  );
  await tester.pumpWidget(
    AnswerCompletionDependenciesScope(
      query: _CompletionQuery(targets.reads),
      supplemental: AnswerCompletionSupplementalService(
          query: _CompletionQuery(targets.reads,
              onRead: () => targets.targetResolutionCalls++),
          fileCatalog: _FakeFileCatalog(files),
          artifactPort: artifacts,
          ingestion: ingestion ?? _RecordingIngestionPort()),
      confirmCommand: command,
      pickFile: () async => null,
      sourceInspectionService: sourceInspection,
      child: const MaterialApp(
          home: AnswerCompletionScreen(bankName: _bankName, setId: _setId)),
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

class _FakeSourceReader implements SupplementalSourceReaderPort {
  _FakeSourceReader(this.bytes);

  final List<int> bytes;

  @override
  Future<SupplementalSourceReadResult> readOriginalBytes({
    required LibraryFile file,
    required int maxBytes,
  }) async {
    return SupplementalSourceReadResult(
      bytes: bytes,
      actualSizeBytes: bytes.length,
      actualSha256: file.sha256,
    );
  }
}

class _TargetFixture {
  _TargetFixture(this.reads);
  final List<SupplementalTargetRead> reads;
  int targetResolutionCalls = 0;
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

const _setId = '11111111-1111-4111-8111-111111111111';

class _CompletionQuery implements AnswerCompletionQuery {
  _CompletionQuery(this.reads, {this.onRead});
  final List<SupplementalTargetRead> reads;
  final void Function()? onRead;
  @override
  Future<AnswerCompletionRead> readBank(String bankName) async {
    onRead?.call();
    return AnswerCompletionSnapshot(sets: [
      AnswerCompletionSet(
          set: ImportedQuestionSet(
              setId: _setId,
              bankName: _bankName,
              displayName: 'synthetic set',
              createdAt: 1),
          provenance: AnswerCompletionProvenance.none,
          members: [
            for (final read in reads)
              AnswerCompletionMember.typed(
                  storageId: read.storageId, typedDraft: read.typedDraft!)
          ])
    ], ungrouped: []);
  }
}
