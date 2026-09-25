// P6-ACT-2 direct supplemental-source acquisition widget acceptance.
//
// Synthetic fixtures only: no live OCR/provider, no private PDFs, no network.
// Proves the BankDetail entry can add a new file through the real ingestion and
// deterministic-parse seams, keeps scanned-PDF OCR behind the canonical
// confirmation dialog, and leaves the frozen existing-file path untouched.
import 'dart:async';

import 'package:file_picker/file_picker.dart';
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

const _bankName = 'p6_direct_ui_bank';
const _fileId = 'p6_direct_ui_file';
const _artifactId = 'p6_direct_ui_artifact';
const _storageId = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';

void main() {
  testWidgets('picker offers direct file adding next to the library list',
      (tester) async {
    await _pumpBankDetail(tester, existingFiles: [_libraryFile('old.pdf')]);

    await tester.tap(find.text('从文件补充答案'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('supplemental-add-file-button')),
      findsOneWidget,
    );
    expect(find.text('添加答案文件'), findsOneWidget);
    expect(find.text('或从资料库选择'), findsOneWidget);
    expect(find.text('old.pdf'), findsOneWidget);
  });

  testWidgets('adding a PDF ingests, parses deterministically, and reviews',
      (tester) async {
    final harness = await _pumpBankDetail(tester);
    harness.pickedFiles.add(
      _pickedFile(name: 'answers.pdf', path: r'C:\picked\answers.pdf'),
    );

    await tester.tap(find.text('从文件补充答案'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加答案文件'));
    await tester.pumpAndSettle();

    expect(find.byType(SupplementalAnswerReviewScreen), findsOneWidget);
    expect(find.text('补充答案确认'), findsOneWidget);
    expect(harness.ingestion.ingestedPaths, [r'C:\picked\answers.pdf']);
    expect(harness.ingestion.ingestedNames, ['answers.pdf']);
    expect(harness.artifacts.ensureRoutes, [
      ParsedArtifactRouteSelection.auto,
    ]);
    expect(
      harness.artifacts.ensureRoutes,
      isNot(contains(ParsedArtifactRouteSelection.ocrPdf)),
    );
    expect(harness.artifacts.getCurrentArtifactCalls, 1);
    expect(
      find.byKey(const ValueKey<String>('supplemental-ocr-dialog')),
      findsNothing,
    );
  });

  testWidgets('cancelling the system picker starts nothing', (tester) async {
    final harness = await _pumpBankDetail(tester);
    // No queued selection: the injected picker resolves to null (user cancel).

    await tester.tap(find.text('从文件补充答案'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加答案文件'));
    await tester.pumpAndSettle();

    expect(find.text('添加答案文件'), findsOneWidget);
    expect(harness.ingestion.ingestedPaths, isEmpty);
    expect(harness.artifacts.ensureRoutes, isEmpty);
    expect(harness.artifacts.getCurrentArtifactCalls, 0);
    expect(find.byType(SupplementalAnswerReviewScreen), findsNothing);
  });

  testWidgets('a scanned PDF asks for explicit OCR before any OCR call',
      (tester) async {
    final harness = await _pumpBankDetail(
      tester,
      deterministicFailure: ParsedArtifactLifecycleFailure.sourceUnavailable,
      displayName: 'scanned.pdf',
    );
    harness.pickedFiles.add(
      _pickedFile(name: 'scanned.pdf', path: r'C:\picked\scanned.pdf'),
    );

    await tester.tap(find.text('从文件补充答案'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加答案文件'));
    await tester.pumpAndSettle();

    expect(find.text('未检测到可提取文本'), findsOneWidget);
    expect(find.textContaining('这个 PDF 可能是扫描版。'), findsOneWidget);
    expect(find.textContaining('OCR 只用于生成可检索的文件内容'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('使用 OCR'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('supplemental-ocr-dialog')),
      findsOneWidget,
    );
    expect(harness.artifacts.ensureRoutes, [
      ParsedArtifactRouteSelection.auto,
    ]);
    expect(harness.artifacts.getCurrentArtifactCalls, 0);
    expect(find.byType(SupplementalAnswerReviewScreen), findsNothing);
  });

  testWidgets('cancelling the OCR dialog never runs OCR and keeps the file',
      (tester) async {
    final harness = await _pumpBankDetail(
      tester,
      deterministicFailure: ParsedArtifactLifecycleFailure.sourceUnavailable,
      displayName: 'scanned.pdf',
    );
    harness.pickedFiles.add(
      _pickedFile(name: 'scanned.pdf', path: r'C:\picked\scanned.pdf'),
    );

    await tester.tap(find.text('从文件补充答案'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加答案文件'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('supplemental-ocr-cancel')),
    );
    await tester.pumpAndSettle();

    expect(
      harness.artifacts.ensureRoutes,
      isNot(contains(ParsedArtifactRouteSelection.ocrPdf)),
    );
    expect(harness.artifacts.getCurrentArtifactCalls, 0);
    expect(find.byType(SupplementalAnswerReviewScreen), findsNothing);
    expect(find.textContaining('已取消 OCR 识别'), findsOneWidget);
    expect(harness.ingestion.ingestedPaths, hasLength(1));
  });

  testWidgets('confirming OCR runs ocr_pdf once and then reviews',
      (tester) async {
    final harness = await _pumpBankDetail(
      tester,
      deterministicFailure: ParsedArtifactLifecycleFailure.sourceUnavailable,
      displayName: 'scanned.pdf',
    );
    harness.pickedFiles.add(
      _pickedFile(name: 'scanned.pdf', path: r'C:\picked\scanned.pdf'),
    );

    await tester.tap(find.text('从文件补充答案'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加答案文件'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('supplemental-ocr-confirm')),
    );
    await tester.pumpAndSettle();

    expect(harness.artifacts.ensureRoutes, [
      ParsedArtifactRouteSelection.auto,
      ParsedArtifactRouteSelection.ocrPdf,
    ]);
    expect(find.byType(SupplementalAnswerReviewScreen), findsOneWidget);
    expect(harness.ingestion.ingestedPaths, hasLength(1));
  });

  testWidgets('an existing library file keeps the frozen existing-file path',
      (tester) async {
    final harness = await _pumpBankDetail(
      tester,
      existingFiles: [_libraryFile('old.pdf')],
    );

    await tester.tap(find.text('从文件补充答案'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('old.pdf'));
    await tester.pumpAndSettle();

    expect(find.byType(SupplementalAnswerReviewScreen), findsOneWidget);
    expect(harness.ingestion.ingestedPaths, isEmpty);
    expect(harness.artifacts.ensureRoutes, isEmpty);
    expect(harness.artifacts.getCurrentArtifactCalls, 1);
  });

  testWidgets('tapping add again while the picker is open adds nothing twice',
      (tester) async {
    final harness = await _pumpBankDetail(tester, holdPicker: true);
    harness.pickedFiles.add(
      _pickedFile(name: 'answers.pdf', path: r'C:\picked\answers.pdf'),
    );

    await tester.tap(find.text('从文件补充答案'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加答案文件'));
    await tester.pump();
    await tester.tap(find.text('添加答案文件'), warnIfMissed: false);
    await tester.pump();

    expect(harness.ingestion.ingestedPaths, isEmpty);

    harness.releasePicker();
    await tester.pumpAndSettle();

    expect(harness.ingestion.ingestedPaths, hasLength(1));
    expect(find.byType(SupplementalAnswerReviewScreen), findsOneWidget);
  });

  testWidgets('an ingestion failure shows one bounded safe message',
      (tester) async {
    final harness = await _pumpBankDetail(
      tester,
      ingestionFailure: StateError('copy failed'),
    );
    harness.pickedFiles.add(
      _pickedFile(name: 'answers.pdf', path: r'C:\picked\answers.pdf'),
    );

    await tester.tap(find.text('从文件补充答案'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加答案文件'));
    await tester.pumpAndSettle();

    expect(find.text('无法添加文件，请确认文件可读取后重试。'), findsOneWidget);
    expect(find.byType(SupplementalAnswerReviewScreen), findsNothing);
    expect(harness.artifacts.ensureRoutes, isEmpty);
  });
}

Future<_Harness> _pumpBankDetail(
  WidgetTester tester, {
  List<LibraryFile> existingFiles = const [],
  ParsedArtifactLifecycleFailure? deterministicFailure,
  Object? ingestionFailure,
  String displayName = 'answers.pdf',
  bool holdPicker = false,
}) async {
  final harness = _Harness(
    ingestion: _FakeIngestionPort(
      failure: ingestionFailure,
      displayName: displayName,
    ),
    artifacts: _FakeArtifactPort(
      snapshot: _snapshot(revision: 2, parts: [_answerParagraph('1. x = 1')]),
      deterministicFailure: deterministicFailure,
    ),
    holdPicker: holdPicker,
  );
  final activation = SupplementalAnswerActivationService(
    fileCatalog: _FakeFileCatalog(existingFiles),
    targetSnapshotService: TargetQuestionSnapshotService(
      port: _FakeTargetPort([_typedRead()]),
    ),
    artifactPort: harness.artifacts,
  );
  await tester.pumpWidget(
    SupplementalAnswerDependenciesScope(
      activationService: activation,
      sourceAcquisitionService: SupplementalAnswerSourceAcquisitionService(
        ingestion: harness.ingestion,
        artifactPort: harness.artifacts,
        activationService: activation,
      ),
      confirmCommand: SupplementalAnswerConfirmCommand(
        artifactPort: harness.artifacts,
        persistencePort: _FakePersistencePort(),
      ),
      pickFile: harness.pickFile,
      child: const MaterialApp(home: BankDetailScreen(bankName: _bankName)),
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

class _Harness {
  _Harness({
    required this.ingestion,
    required this.artifacts,
    required bool holdPicker,
  }) : _holdPicker = holdPicker;

  final _FakeIngestionPort ingestion;
  final _FakeArtifactPort artifacts;
  final List<FilePickerResult?> pickedFiles = <FilePickerResult?>[];
  final bool _holdPicker;
  Completer<void>? _pickerGate;

  Future<FilePickerResult?> pickFile() async {
    final gate = _holdPicker && _pickerGate == null
        ? (_pickerGate = Completer<void>())
        : _pickerGate;
    if (gate != null) {
      await gate.future;
      _pickerGate = null;
    }
    if (pickedFiles.isEmpty) return null;
    return pickedFiles.removeAt(0);
  }

  void releasePicker() {
    _pickerGate?.complete();
  }
}

FilePickerResult _pickedFile({required String name, required String path}) {
  return FilePickerResult(<PlatformFile>[
    PlatformFile(name: name, path: path, size: 32),
  ]);
}

LibraryFile _libraryFile(String displayName) {
  return LibraryFile(
    fileId: _fileId,
    displayName: displayName,
    mimeType: 'application/pdf',
    sizeBytes: 2048,
    sha256: 'a' * 64,
    storageKey: 'p6/direct-ui',
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

class _FakeIngestionPort implements FileIngestionPort {
  _FakeIngestionPort({this.failure, this.displayName = 'answers.pdf'});

  final Object? failure;
  final String displayName;
  final List<String> ingestedPaths = <String>[];
  final List<String> ingestedNames = <String>[];

  @override
  Future<LibraryFile> ingest({
    required String externalPath,
    required String displayName,
    String? mimeType,
  }) async {
    ingestedPaths.add(externalPath);
    ingestedNames.add(displayName);
    final failure = this.failure;
    if (failure != null) throw failure;
    return _libraryFile(displayName);
  }
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

class _FakeArtifactPort implements ParsedArtifactLifecyclePort {
  _FakeArtifactPort({required this.snapshot, this.deterministicFailure});

  final ParsedArtifactSnapshot snapshot;
  final ParsedArtifactLifecycleFailure? deterministicFailure;
  final List<ParsedArtifactRouteSelection> ensureRoutes =
      <ParsedArtifactRouteSelection>[];
  int getCurrentArtifactCalls = 0;

  @override
  Future<ParsedArtifactEnsureResult> ensureParsedArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
  }) async {
    ensureRoutes.add(options.routeSelection);
    if (options.routeSelection == ParsedArtifactRouteSelection.auto) {
      final failure = deterministicFailure;
      if (failure != null) throw ParsedArtifactLifecycleException(failure);
    }
    return ParsedArtifactEnsureResult(
      outcome: ParsedArtifactLifecycleOutcome.published,
      snapshot: snapshot,
    );
  }

  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async {
    getCurrentArtifactCalls++;
    return snapshot;
  }

  @override
  Future<ParsedArtifactEnsureResult> reparseArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
    required int expectedRevision,
  }) async {
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
  @override
  Future<void> confirmCandidate(AnswerCandidate candidate) async {}
}
