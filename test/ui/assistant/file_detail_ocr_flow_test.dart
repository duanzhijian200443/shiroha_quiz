import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/file_library/file_library_ports.dart';
import 'package:shiroha_quiz/application/file_library/library_folder_repository.dart';
import 'package:shiroha_quiz/application/file_library/library_folder_service.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/application/projects/project_repository.dart';
import 'package:shiroha_quiz/application/projects/project_service.dart';
import 'package:shiroha_quiz/application/study_query/study_query_dtos.dart';
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/application/study_query/study_query_service.dart';
import 'package:shiroha_quiz/application/u1_workspace/u1_workspace_dtos.dart';
import 'package:shiroha_quiz/application/u1_workspace/u1_workspace_facade.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/assets/library_folder.dart';
import 'package:shiroha_quiz/domain/assets/parsed_artifact.dart';
import 'package:shiroha_quiz/domain/projects/project.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/ui/assistant/workspace_controller.dart';
import 'package:shiroha_quiz/ui/assistant/workspace_pages.dart';

const _sha = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

LibraryFile _pdfFile(String id) => LibraryFile(
      fileId: id,
      displayName: '$id.pdf',
      mimeType: 'application/pdf',
      sizeBytes: 1024,
      sha256: _sha,
      storageKey: 'library/$id',
      createdAt: DateTime.utc(2026, 8, 14),
    );

final class _Files implements LibraryFileRepositoryPort {
  final Map<String, LibraryFile> values = <String, LibraryFile>{};

  @override
  Future<List<LibraryFile>> findAll() async => values.values.toList();

  @override
  Future<LibraryFile?> findById(String fileId) async => values[fileId];

  @override
  Future<void> save(LibraryFile file) async => values[file.fileId] = file;
}

final class _Ingestion implements FileIngestionPort {
  @override
  Future<LibraryFile> ingest({
    required String externalPath,
    required String displayName,
    String? mimeType,
  }) async {
    throw UnimplementedError();
  }
}

final class _Folders extends Fake implements LibraryFolderRepositoryPort {
  @override
  Future<List<LibraryFolder>> listFolders() async => const <LibraryFolder>[];

  @override
  Future<LibraryFolder?> findFolder(String folderId) async => null;

  @override
  Future<LibraryFolder?> getFolderForFile(String fileId) async => null;
}

final class _Projects extends Fake implements ProjectRepository {
  @override
  Future<List<Project>> listProjects() async => const <Project>[];

  @override
  Future<List<String>> listProjectIdsForFile(String fileId) async =>
      const <String>[];
}

final class _Questions extends Fake implements StudyQuestionQueryPort {
  @override
  Future<StudyPage<QuestionBankSummary>> listStudyQuestionBanks({
    required int nowUnixSeconds,
    required int limit,
    String? afterBankName,
  }) async {
    return const StudyPage<QuestionBankSummary>(
      items: <QuestionBankSummary>[],
      hasMore: false,
    );
  }
}

final class _Metrics extends Fake implements StudyMetricsQueryPort {}

final class _RecordingLifecycle implements ParsedArtifactLifecyclePort {
  final Map<String, ParsedArtifactSnapshot> artifacts =
      <String, ParsedArtifactSnapshot>{};
  int autoCalls = 0;
  int ocrCalls = 0;
  Completer<void>? ensureGate;
  Object? deterministicError;
  Object? ocrError;

  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async {
    final artifact = artifacts[fileId];
    if (artifact == null) {
      throw const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.artifactMissing,
      );
    }
    return artifact;
  }

  @override
  Future<ParsedArtifactEnsureResult> ensureParsedArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
  }) async {
    if (ensureGate != null) {
      await ensureGate!.future;
    }
    if (options.routeSelection == ParsedArtifactRouteSelection.ocrPdf) {
      ocrCalls++;
      if (ocrError != null) {
        throw ocrError!;
      }
      final created = ParsedArtifactSnapshot(
        artifact: ParsedArtifact(
          fileId: fileId,
          artifactId: 'art-ocr-$fileId',
          revision: 1,
          payloadSchemaVersion: 1,
        ),
        sourceDocument: SourceDocument(sourceId: 'art-ocr-$fileId'),
        parserRoute: 'ocr_pdf',
      );
      artifacts[fileId] = created;
      return ParsedArtifactEnsureResult(
        outcome: ParsedArtifactLifecycleOutcome.published,
        snapshot: created,
      );
    } else {
      autoCalls++;
      if (deterministicError != null) {
        throw deterministicError!;
      }
      final created = ParsedArtifactSnapshot(
        artifact: ParsedArtifact(
          fileId: fileId,
          artifactId: 'art-det-$fileId',
          revision: 1,
          payloadSchemaVersion: 1,
        ),
        sourceDocument: SourceDocument(sourceId: 'art-det-$fileId'),
        parserRoute: 'pdf_text',
      );
      artifacts[fileId] = created;
      return ParsedArtifactEnsureResult(
        outcome: ParsedArtifactLifecycleOutcome.published,
        snapshot: created,
      );
    }
  }

  @override
  Future<ParsedArtifactEnsureResult> reparseArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
    required int expectedRevision,
  }) =>
      ensureParsedArtifact(fileId: fileId, options: options);

  @override
  Future<void> removeCurrentArtifact({
    required String fileId,
    required int expectedRevision,
  }) async {
    artifacts.remove(fileId);
  }
}

void main() {
  late _Files files;
  late _RecordingLifecycle lifecycle;
  late U1WorkspaceFacade facade;
  late FileLibraryController controller;

  setUp(() {
    files = _Files();
    lifecycle = _RecordingLifecycle();
    facade = U1WorkspaceFacade(
      projectService: ProjectService(
        repository: _Projects(),
        projectIdFactory: () => 'proj',
      ),
      fileRepository: files,
      fileIngestion: _Ingestion(),
      folderService: LibraryFolderService(
        repository: _Folders(),
        folderIdFactory: () => 'fld',
      ),
      studyQueryService: StudyQueryService(
        questionQuery: _Questions(),
        metricsQuery: _Metrics(),
      ),
      parsedArtifactLifecycle: lifecycle,
      mcpProjection: McpWorkspaceProjection(
        state: McpCapabilityState.configuredAvailable,
        transport: McpTransport.localStdio,
        permission: McpPermission.readOnly,
        toolNames: const <String>[],
      ),
    );
    controller = FileLibraryController(facade);
  });

  Widget buildApp(String fileId) {
    return MaterialApp(
      home: FileLibraryWorkspace(controller: controller),
    );
  }

  testWidgets('File Detail shows “解析内容” button and starts command once',
      (tester) async {
    files.values['scan'] = _pdfFile('scan');
    await controller.load();
    await tester.pumpWidget(buildApp('scan'));
    await tester.pumpAndSettle();

    // Tap file to navigate to detail
    await tester.tap(find.byKey(const ValueKey<String>('u1-ux01-file-scan')));
    await tester.pumpAndSettle();

    expect(find.text('内容解析'), findsOneWidget);
    expect(find.text('尚未解析文件内容'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('file-detail-parse-button')),
      findsOneWidget,
    );

    // Tap "解析内容"
    await tester
        .tap(find.byKey(const ValueKey<String>('file-detail-parse-button')));
    await tester.pumpAndSettle();

    expect(lifecycle.autoCalls, 1);
    expect(lifecycle.ocrCalls, 0);
    expect(find.text('内容已解析'), findsOneWidget);
    expect(find.textContaining('PDF 文本'), findsOneWidget);
  });

  testWidgets('duplicate tap while busy triggers one command only',
      (tester) async {
    files.values['scan'] = _pdfFile('scan');
    lifecycle.ensureGate = Completer<void>();
    await controller.load();
    await tester.pumpWidget(buildApp('scan'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('u1-ux01-file-scan')));
    await tester.pumpAndSettle();

    // Tap "解析内容"
    await tester
        .tap(find.byKey(const ValueKey<String>('file-detail-parse-button')));
    await tester.pump();

    // Progress indicator visible
    expect(
      find.byKey(const ValueKey<String>('artifact-progress-indicator')),
      findsOneWidget,
    );

    // Button should be disabled or ignore clicks while busy
    controller.ensureFileParsed('scan'); // Duplicate programmatic / rapid tap
    expect(lifecycle.autoCalls, 0); // Still blocked on gate

    // Release gate
    lifecycle.ensureGate!.complete();
    await tester.pumpAndSettle();

    expect(lifecycle.autoCalls, 1);
    expect(find.text('内容已解析'), findsOneWidget);
  });

  testWidgets('deterministic success -> no OCR confirmation dialog',
      (tester) async {
    files.values['scan'] = _pdfFile('scan');
    await controller.load();
    await tester.pumpWidget(buildApp('scan'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('u1-ux01-file-scan')));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey<String>('file-detail-parse-button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('ocr-confirmation-dialog')),
      findsNothing,
    );
    expect(lifecycle.ocrCalls, 0);
  });

  testWidgets(
      'PDF sourceUnavailable shows confirmation dialog with required notice and cancel makes zero OCR call',
      (tester) async {
    files.values['scan'] = _pdfFile('scan');
    lifecycle.deterministicError = const ParsedArtifactLifecycleException(
      ParsedArtifactLifecycleFailure.sourceUnavailable,
    );
    await controller.load();
    await tester.pumpWidget(buildApp('scan'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('u1-ux01-file-scan')));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey<String>('file-detail-parse-button')));
    await tester.pumpAndSettle();

    // Dialog appears
    expect(
      find.byKey(const ValueKey<String>('ocr-confirmation-dialog')),
      findsOneWidget,
    );
    expect(find.text('未检测到可提取文本'), findsOneWidget);
    expect(
      find.textContaining('这个 PDF 可能是扫描版'),
      findsOneWidget,
    );
    expect(
      find.textContaining('发送到当前配置的 OCR 服务'),
      findsOneWidget,
    );
    expect(
      find.textContaining('不会自动生成或修改题目'),
      findsOneWidget,
    );

    // Cancel
    await tester.tap(find.byKey(const ValueKey<String>('ocr-dialog-cancel')));
    await tester.pumpAndSettle();

    expect(lifecycle.ocrCalls, 0);
    expect(
      find.text('未检测到可提取文本，可能是扫描版 PDF。'),
      findsOneWidget,
    );
  });

  testWidgets(
      'PDF sourceUnavailable confirm triggers explicit OCR and shows “内容已通过 OCR 解析”',
      (tester) async {
    files.values['scan'] = _pdfFile('scan');
    lifecycle.deterministicError = const ParsedArtifactLifecycleException(
      ParsedArtifactLifecycleFailure.sourceUnavailable,
    );
    await controller.load();
    await tester.pumpWidget(buildApp('scan'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('u1-ux01-file-scan')));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey<String>('file-detail-parse-button')));
    await tester.pumpAndSettle();

    // Confirm OCR
    await tester.tap(find.byKey(const ValueKey<String>('ocr-dialog-confirm')));
    await tester.pumpAndSettle();

    expect(lifecycle.ocrCalls, 1);
    expect(find.text('内容已通过 OCR 解析'), findsOneWidget);
    expect(find.textContaining('OCR (PDF)'), findsOneWidget);
    expect(find.textContaining('revision 1'), findsOneWidget);
  });

  testWidgets('OCR temporarilyUnavailable shows bounded safe error message',
      (tester) async {
    files.values['scan'] = _pdfFile('scan');
    lifecycle.deterministicError = const ParsedArtifactLifecycleException(
      ParsedArtifactLifecycleFailure.sourceUnavailable,
    );
    lifecycle.ocrError = const ParsedArtifactLifecycleException(
      ParsedArtifactLifecycleFailure.temporarilyUnavailable,
    );
    await controller.load();
    await tester.pumpWidget(buildApp('scan'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('u1-ux01-file-scan')));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey<String>('file-detail-parse-button')));
    await tester.pumpAndSettle();

    // Confirm OCR
    await tester.tap(find.byKey(const ValueKey<String>('ocr-dialog-confirm')));
    await tester.pumpAndSettle();

    expect(lifecycle.ocrCalls, 1);
    expect(
      find.text('当前 OCR 服务不可用，请检查 OCR 引擎配置后重试。'),
      findsOneWidget,
    );
  });
}
