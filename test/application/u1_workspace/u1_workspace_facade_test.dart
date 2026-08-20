import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/file_library/file_library_ports.dart';
import 'package:shiroha_quiz/application/file_library/library_file_deletion.dart';
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

const _sha = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

LibraryFile _file(String id, int hour) => LibraryFile(
      fileId: id,
      displayName: '$id.pdf',
      mimeType: 'application/pdf',
      sizeBytes: hour,
      sha256: _sha,
      storageKey: 'library/$id',
      createdAt: DateTime.utc(2026, 8, 9, hour),
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

final class _Deletion implements LibraryFileDeletionPort {
  String? receivedFileId;
  LibraryFileDeletionResult? result;

  @override
  Future<LibraryFileDeletionResult> deleteLibraryFile(String fileId) async {
    receivedFileId = fileId;
    return result!;
  }
}

final class _Ingestion implements FileIngestionPort {
  _Ingestion(this.files);

  final _Files files;
  String? receivedMimeType;

  @override
  Future<LibraryFile> ingest({
    required String externalPath,
    required String displayName,
    String? mimeType,
  }) async {
    receivedMimeType = mimeType;
    final value = LibraryFile(
      fileId: 'ingested-file',
      displayName: displayName,
      mimeType: mimeType ?? 'application/octet-stream',
      sizeBytes: 1,
      sha256: _sha,
      storageKey: 'library/ingested-file',
      createdAt: DateTime.utc(2026, 8, 9),
    );
    await files.save(value);
    return value;
  }
}

final class _Folders extends Fake implements LibraryFolderRepositoryPort {
  _Folders(this.files);

  final _Files files;
  final Map<String, LibraryFolder> values = <String, LibraryFolder>{};
  final Map<String, String> memberships = <String, String>{};

  @override
  Future<void> createFolder(LibraryFolder folder) async {
    values[folder.folderId] = folder;
  }

  @override
  Future<List<LibraryFolder>> listFolders() async => values.values.toList();

  @override
  Future<LibraryFolder?> findFolder(String folderId) async => values[folderId];

  @override
  Future<LibraryFolder> renameFolder({
    required String folderId,
    required String displayName,
  }) async {
    final old = values[folderId]!;
    return values[folderId] = LibraryFolder(
      folderId: folderId,
      displayName: displayName,
      createdAt: old.createdAt,
    );
  }

  @override
  Future<void> deleteFolder(String folderId) async {
    values.remove(folderId);
    memberships.removeWhere((_, value) => value == folderId);
  }

  @override
  Future<LibraryFolder?> getFolderForFile(String fileId) async {
    final folderId = memberships[fileId];
    return folderId == null ? null : values[folderId];
  }

  @override
  Future<void> moveFileToFolder({
    required String fileId,
    required String folderId,
  }) async {
    memberships[fileId] = folderId;
  }

  @override
  Future<void> removeFileFromFolder(String fileId) async {
    memberships.remove(fileId);
  }

  @override
  Future<List<LibraryFile>> listFilesInFolder(String folderId) async =>
      files.values.values
          .where((file) => memberships[file.fileId] == folderId)
          .toList();

  @override
  Future<List<LibraryFile>> listUnclassifiedFiles() async => files.values.values
      .where((file) => !memberships.containsKey(file.fileId))
      .toList();
}

final class _Projects implements ProjectRepository {
  final Map<String, Project> projects = <String, Project>{};
  final Map<String, Set<String>> files = <String, Set<String>>{};
  final Map<String, Set<String>> banks = <String, Set<String>>{};

  @override
  Future<void> attachBank({
    required String projectId,
    required String bankName,
  }) async =>
      banks.putIfAbsent(projectId, () => <String>{}).add(bankName);

  @override
  Future<void> attachFile({
    required String projectId,
    required String fileId,
  }) async =>
      files.putIfAbsent(projectId, () => <String>{}).add(fileId);

  @override
  Future<void> createProject(Project project) async {
    projects[project.projectId] = project;
  }

  @override
  Future<void> deleteProject(String projectId) async {
    projects.remove(projectId);
    files.remove(projectId);
    banks.remove(projectId);
  }

  @override
  Future<void> detachBank({
    required String projectId,
    required String bankName,
  }) async =>
      banks[projectId]?.remove(bankName);

  @override
  Future<void> detachFile({
    required String projectId,
    required String fileId,
  }) async =>
      files[projectId]?.remove(fileId);

  @override
  Future<Project?> getProject(String projectId) async => projects[projectId];

  @override
  Future<List<Project>> listProjects() async => projects.values.toList();

  @override
  Future<List<String>> listProjectBankNames(String projectId) async =>
      (banks[projectId]?.toList() ?? <String>[])..sort();

  @override
  Future<List<String>> listProjectFileIds(String projectId) async =>
      (files[projectId]?.toList() ?? <String>[])..sort();

  @override
  Future<List<String>> listProjectIdsForBank(String bankName) async =>
      projects.keys
          .where((id) => banks[id]?.contains(bankName) ?? false)
          .toList();

  @override
  Future<List<String>> listProjectIdsForFile(String fileId) async =>
      projects.keys
          .where((id) => files[id]?.contains(fileId) ?? false)
          .toList();

  @override
  Future<Project> renameProject({
    required String projectId,
    required String displayName,
  }) async {
    final old = projects[projectId]!;
    final value = Project(
      projectId: projectId,
      displayName: displayName,
      createdAt: old.createdAt,
    );
    projects[projectId] = value;
    return value;
  }
}

final class _QuestionPort extends Fake implements StudyQuestionQueryPort {
  _QuestionPort(this.banks);

  final List<QuestionBankSummary> banks;

  @override
  Future<StudyPage<QuestionBankSummary>> listStudyQuestionBanks({
    required int nowUnixSeconds,
    required int limit,
    String? afterBankName,
  }) async {
    final start = afterBankName == null
        ? 0
        : banks.indexWhere((bank) => bank.bankName == afterBankName) + 1;
    final remaining = banks.skip(start).toList();
    return StudyPage<QuestionBankSummary>(
      items: remaining.take(limit).toList(),
      hasMore: remaining.length > limit,
    );
  }
}

final class _MetricsPort extends Fake implements StudyMetricsQueryPort {}

final class _FakeParsedArtifactLifecycle
    implements ParsedArtifactLifecyclePort {
  final Map<String, ParsedArtifactSnapshot> artifacts =
      <String, ParsedArtifactSnapshot>{};
  final List<(String, ParsedArtifactParseOptions)> ensureCalls =
      <(String, ParsedArtifactParseOptions)>[];
  Object? ensureError;
  Object? currentError;

  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async {
    if (currentError != null) {
      throw currentError!;
    }
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
    ensureCalls.add((fileId, options));
    if (ensureError != null) {
      throw ensureError!;
    }
    final existing = artifacts[fileId];
    if (existing != null) {
      return ParsedArtifactEnsureResult(
        outcome: ParsedArtifactLifecycleOutcome.cacheHit,
        snapshot: existing,
      );
    }
    final created = ParsedArtifactSnapshot(
      artifact: ParsedArtifact(
        fileId: fileId,
        artifactId: 'artifact-$fileId',
        revision: 1,
        payloadSchemaVersion: 1,
      ),
      sourceDocument: SourceDocument(sourceId: 'artifact-$fileId'),
      parserRoute: options.routeSelection == ParsedArtifactRouteSelection.ocrPdf
          ? 'ocr_pdf'
          : 'pdf_text',
    );
    artifacts[fileId] = created;
    return ParsedArtifactEnsureResult(
      outcome: ParsedArtifactLifecycleOutcome.published,
      snapshot: created,
    );
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
  late _Ingestion ingestion;
  late _Projects projects;
  late _Folders folders;
  late _FakeParsedArtifactLifecycle lifecycle;
  late _Deletion deletion;
  late U1WorkspaceFacade facade;

  setUp(() {
    files = _Files();
    ingestion = _Ingestion(files);
    projects = _Projects();
    folders = _Folders(files);
    lifecycle = _FakeParsedArtifactLifecycle();
    deletion = _Deletion();
    facade = U1WorkspaceFacade(
      projectService: ProjectService(
        repository: projects,
        projectIdFactory: () => 'project-new',
      ),
      fileRepository: files,
      fileIngestion: ingestion,
      folderService: LibraryFolderService(
        repository: folders,
        folderIdFactory: () => 'folder-new',
      ),
      studyQueryService: StudyQueryService(
        questionQuery: _QuestionPort(const <QuestionBankSummary>[
          QuestionBankSummary(
            bankName: 'existing-bank',
            folderName: '未分类',
            questionCount: 3,
            dueCount: 1,
            masteredCount: 1,
          ),
        ]),
        metricsQuery: _MetricsPort(),
      ),
      parsedArtifactLifecycle: lifecycle,
      libraryFileDeletion: deletion,
      mcpProjection: McpWorkspaceProjection(
        state: McpCapabilityState.configuredAvailable,
        transport: McpTransport.localStdio,
        permission: McpPermission.readOnly,
        toolNames: const <String>['list_question_banks'],
      ),
    );
  });

  test('lists newest files and caps the recent view at twenty', () async {
    for (var hour = 0; hour < 21; hour++) {
      final id = 'file-${hour.toString().padLeft(2, '0')}';
      files.values[id] = _file(id, hour);
    }

    final all = await facade.listLibraryFiles();
    final recent = await facade.listLibraryFiles(view: FileLibraryView.recent);

    expect(all.first.fileId, 'file-20');
    expect(recent, hasLength(20));
    expect(recent.last.fileId, 'file-01');
  });

  test('projects aggregate counts and preserve dangling bank references',
      () async {
    final project = Project(
      projectId: 'project-a',
      displayName: '深度学习',
      createdAt: DateTime.utc(2026, 8, 9),
    );
    projects.projects[project.projectId] = project;
    files.values['file-a'] = _file('file-a', 1);
    projects.files[project.projectId] = <String>{'file-a'};
    projects.banks[project.projectId] = <String>{
      'existing-bank',
      'missing-bank',
    };

    final detail = await facade.getLearningSpace(project.projectId);

    expect(detail!.summary.fileCount, 1);
    expect(detail.summary.bankCount, 2);
    expect(
      detail.banks
          .singleWhere((bank) => bank.bankName == 'missing-bank')
          .isMissing,
      isTrue,
    );
  });

  test('Folder and Learning Space unclassified projections stay independent',
      () async {
    files.values['free-file'] = _file('free-file', 1);
    files.values['folder-only-file'] = _file('folder-only-file', 2);
    folders.values['folder-a'] = LibraryFolder(
      folderId: 'folder-a',
      displayName: '论文',
      createdAt: DateTime.utc(2026, 8, 9),
    );
    folders.memberships['folder-only-file'] = 'folder-a';

    final folderUnclassified = await facade.listLibraryFiles(
      view: FileLibraryView.unclassified,
    );
    final projectUnclassified = await facade.getUnclassifiedAssets();

    expect(
        folderUnclassified.map((file) => file.fileId), <String>['free-file']);
    expect(
      projectUnclassified.files.map((file) => file.fileId),
      <String>['folder-only-file', 'free-file'],
    );
    expect(projectUnclassified.banks.single.bankName, 'existing-bank');
  });

  test('Folder CRUD, move, detail, and delete project-independence', () async {
    files.values['file-a'] = _file('file-a', 1);
    final project = Project(
      projectId: 'project-a',
      displayName: '深度学习',
      createdAt: DateTime.utc(2026, 8, 9),
    );
    projects.projects[project.projectId] = project;
    projects.files[project.projectId] = <String>{'file-a'};

    final folder = await facade.createLibraryFolder('  论文  ');
    await facade.moveLibraryFileToFolder(
      fileId: 'file-a',
      folderId: folder.folderId,
    );
    final detail = await facade.getLibraryFileDetail('file-a');
    expect(detail!.folder!.displayName, '论文');
    expect(detail.relatedSpaces.single.projectId, project.projectId);

    await facade.deleteLibraryFolder(folder.folderId);
    expect((await facade.getLibraryFileDetail('file-a'))!.folder, isNull);
    expect(projects.files[project.projectId], contains('file-a'));
  });

  test('ingestion infers known MIME types and safely falls back', () async {
    await facade.ingestSelectedFile(
      externalPath: 'ephemeral-input',
      displayName: 'notes.md',
    );
    expect(ingestion.receivedMimeType, 'text/markdown');
    expect(
      U1WorkspaceFacade.mimeTypeForDisplayName('unknown.data'),
      'application/octet-stream',
    );
  });

  test('MCP projection describes capability without a running state', () {
    expect(facade.mcpProjection.state, McpCapabilityState.configuredAvailable);
    expect(facade.mcpProjection.transport, McpTransport.localStdio);
    expect(facade.mcpProjection.permission, McpPermission.readOnly);
    expect(facade.mcpProjection.toolNames, <String>['list_question_banks']);
  });

  test('formal LibraryFile deletion entry delegates to the application port',
      () async {
    const result = LibraryFileDeletionResult(
      fileId: 'file-a',
      projectReferenceCount: 1,
      conversationReferenceCount: 2,
      managedBytesCleanup: LibraryFileManagedBytesCleanup.deleted,
      parsedArtifactCleanup: LibraryFileParsedArtifactCleanup.notPresent,
    );
    deletion.result = result;

    expect(await facade.deleteLibraryFile('file-a'), same(result));
    expect(deletion.receivedFileId, 'file-a');
  });

  test('formal LibraryFile deletion fails closed when authority is absent',
      () async {
    final facadeWithoutDeletion = U1WorkspaceFacade(
      projectService: ProjectService(
        repository: projects,
        projectIdFactory: () => 'project-new',
      ),
      fileRepository: files,
      fileIngestion: ingestion,
      folderService: LibraryFolderService(
        repository: folders,
        folderIdFactory: () => 'folder-new',
      ),
      studyQueryService: StudyQueryService(
        questionQuery: _QuestionPort(const <QuestionBankSummary>[]),
        metricsQuery: _MetricsPort(),
      ),
      mcpProjection: facade.mcpProjection,
    );

    expect(
      () => facadeWithoutDeletion.deleteLibraryFile('file-a'),
      throwsA(
        isA<LibraryFileDeletionException>().having(
          (error) => error.failure,
          'failure',
          LibraryFileDeletionFailure.unavailable,
        ),
      ),
    );
  });

  group('OCR-UX ParsedArtifact Application lifecycle seam', () {
    test('no current artifact -> state none', () async {
      lifecycle.artifacts.clear();
      final status = await facade.getLibraryFileArtifactStatus('file-a');
      expect(status.status, LibraryFileArtifactStatus.none);
      expect(status.parserRoute, isNull);
      expect(status.revision, isNull);
    });

    test('valid current artifact -> state available', () async {
      lifecycle.artifacts['file-a'] = ParsedArtifactSnapshot(
        artifact: ParsedArtifact(
          fileId: 'file-a',
          artifactId: 'art-1',
          revision: 2,
          payloadSchemaVersion: 1,
        ),
        sourceDocument: SourceDocument(sourceId: 'art-1'),
        parserRoute: 'pdf_text',
      );
      final status = await facade.getLibraryFileArtifactStatus('file-a');
      expect(status.status, LibraryFileArtifactStatus.available);
      expect(status.parserRoute, 'pdf_text');
      expect(status.revision, 2);
    });

    test('deterministic PDF parse success -> available, OCR never called',
        () async {
      files.values['file-a'] = _file('file-a', 1);
      final res = await facade.ensureLibraryFileParsed('file-a');
      expect(res.status, LibraryFileArtifactStatus.available);
      expect(res.parserRoute, 'pdf_text');
      expect(lifecycle.ensureCalls, hasLength(1));
      expect(
        lifecycle.ensureCalls.single.$2.routeSelection,
        ParsedArtifactRouteSelection.auto,
      );
    });

    test('PDF deterministic sourceUnavailable -> typed ocrRecommended',
        () async {
      files.values['pdf-file'] = _file('pdf-file', 1);
      lifecycle.ensureError = const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.sourceUnavailable,
      );
      final res = await facade.ensureLibraryFileParsed('pdf-file');
      expect(res.status, LibraryFileArtifactStatus.ocrRecommended);
    });

    test('non-PDF sourceUnavailable -> NOT ocrRecommended (state unavailable)',
        () async {
      files.values['txt-file'] = LibraryFile(
        fileId: 'txt-file',
        displayName: 'notes.txt',
        mimeType: 'text/plain',
        sizeBytes: 1,
        sha256: _sha,
        storageKey: 'library/txt-file',
        createdAt: DateTime.utc(2026, 8, 9),
      );
      lifecycle.ensureError = const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.sourceUnavailable,
      );
      final res = await facade.ensureLibraryFileParsed('txt-file');
      expect(res.status, LibraryFileArtifactStatus.unavailable);
      expect(res.status, isNot(LibraryFileArtifactStatus.ocrRecommended));
      expect(res.errorMessage, '文件内容当前不可读取。');
    });

    test('explicit OCR command uses ocrPdf route and publishes revision',
        () async {
      files.values['pdf-file'] = _file('pdf-file', 1);
      lifecycle.ensureError = null;
      final res = await facade.ensureLibraryFileOcrPdf('pdf-file');
      expect(res.status, LibraryFileArtifactStatus.available);
      expect(res.parserRoute, 'ocr_pdf');
      expect(res.revision, 1);
      expect(
        lifecycle.ensureCalls.last.$2.routeSelection,
        ParsedArtifactRouteSelection.ocrPdf,
      );
    });

    test('OCR temporarilyUnavailable -> bounded unavailable result', () async {
      files.values['pdf-file'] = _file('pdf-file', 1);
      lifecycle.ensureError = const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.temporarilyUnavailable,
      );
      final res = await facade.ensureLibraryFileOcrPdf('pdf-file');
      expect(res.status, LibraryFileArtifactStatus.unavailable);
      expect(
        res.errorMessage,
        '当前 OCR 服务不可用，请检查 OCR 引擎配置后重试。',
      );
    });

    test('artifactMissing does not break File Detail', () async {
      files.values['file-a'] = _file('file-a', 1);
      lifecycle.currentError = const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.artifactMissing,
      );
      final detail = await facade.getLibraryFileDetail('file-a');
      expect(detail, isNotNull);
      expect(detail!.file.fileId, 'file-a');
      final status = await facade.getLibraryFileArtifactStatus('file-a');
      expect(status.status, LibraryFileArtifactStatus.none);
    });

    test('artifactCorrupt maps safely without hiding file metadata', () async {
      files.values['file-a'] = _file('file-a', 1);
      lifecycle.currentError = const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.artifactCorrupt,
      );
      final detail = await facade.getLibraryFileDetail('file-a');
      expect(detail, isNotNull);
      expect(detail!.file.displayName, 'file-a.pdf');
      final status = await facade.getLibraryFileArtifactStatus('file-a');
      expect(status.status, LibraryFileArtifactStatus.failed);
      expect(status.errorMessage, '文件内容解析数据已损坏');
    });

    test('lifecycle null -> unavailable with fixed safe message', () async {
      final facadeWithoutLifecycle = U1WorkspaceFacade(
        projectService: ProjectService(
          repository: projects,
          projectIdFactory: () => 'project-new',
        ),
        fileRepository: files,
        fileIngestion: ingestion,
        folderService: LibraryFolderService(
          repository: folders,
          folderIdFactory: () => 'folder-new',
        ),
        studyQueryService: StudyQueryService(
          questionQuery: _QuestionPort(const <QuestionBankSummary>[]),
          metricsQuery: _MetricsPort(),
        ),
        parsedArtifactLifecycle: null,
        mcpProjection: McpWorkspaceProjection(
          state: McpCapabilityState.configuredAvailable,
          transport: McpTransport.localStdio,
          permission: McpPermission.readOnly,
          toolNames: const <String>['list_question_banks'],
        ),
      );
      final status =
          await facadeWithoutLifecycle.getLibraryFileArtifactStatus('file-a');
      expect(status.status, LibraryFileArtifactStatus.unavailable);
      expect(status.errorMessage, '解析服务未初始化');
    });

    test('temporarilyUnavailable -> unavailable with safe message', () async {
      files.values['file-a'] = _file('file-a', 1);
      lifecycle.currentError = const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.temporarilyUnavailable,
      );
      final status = await facade.getLibraryFileArtifactStatus('file-a');
      expect(status.status, LibraryFileArtifactStatus.unavailable);
      expect(status.errorMessage, '暂时无法读取解析状态，请稍后重试');
    });

    test(
        'fileNotFound and sourceUnavailable -> unavailable (not ocrRecommended)',
        () async {
      files.values['file-a'] = _file('file-a', 1);
      lifecycle.currentError = const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.sourceUnavailable,
      );
      final statusSource = await facade.getLibraryFileArtifactStatus('file-a');
      expect(statusSource.status, LibraryFileArtifactStatus.unavailable);
      expect(
          statusSource.status, isNot(LibraryFileArtifactStatus.ocrRecommended));
      expect(statusSource.errorMessage, '文件内容当前不可读取');

      lifecycle.currentError = const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.fileNotFound,
      );
      final statusNotFound =
          await facade.getLibraryFileArtifactStatus('file-a');
      expect(statusNotFound.status, LibraryFileArtifactStatus.unavailable);
      expect(statusNotFound.errorMessage, '文件内容当前不可读取');
    });

    test('payloadUnsupported -> failed with safe message', () async {
      files.values['file-a'] = _file('file-a', 1);
      lifecycle.currentError = const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.payloadUnsupported,
      );
      final status = await facade.getLibraryFileArtifactStatus('file-a');
      expect(status.status, LibraryFileArtifactStatus.failed);
      expect(status.errorMessage, '文件内容解析数据已损坏');
    });

    test('internalError and other typed failures -> failed with safe message',
        () async {
      files.values['file-a'] = _file('file-a', 1);
      for (final failure in <ParsedArtifactLifecycleFailure>[
        ParsedArtifactLifecycleFailure.internalError,
        ParsedArtifactLifecycleFailure.invalidRequest,
        ParsedArtifactLifecycleFailure.unsupportedRoute,
        ParsedArtifactLifecycleFailure.parseFailed,
        ParsedArtifactLifecycleFailure.publishConflict,
      ]) {
        lifecycle.currentError = ParsedArtifactLifecycleException(failure);
        final status = await facade.getLibraryFileArtifactStatus('file-a');
        expect(status.status, LibraryFileArtifactStatus.failed,
            reason: 'failure $failure should map to failed');
        expect(status.errorMessage, '暂时无法读取解析状态，请稍后重试');
      }
    });

    test(
        'unexpected exception -> failed with safe message, never leaks toString',
        () async {
      files.values['file-a'] = _file('file-a', 1);
      lifecycle.currentError = Exception('SECRET_DATABASE_LEAK');
      final status = await facade.getLibraryFileArtifactStatus('file-a');
      expect(status.status, LibraryFileArtifactStatus.failed);
      expect(status.errorMessage, '暂时无法读取解析状态，请稍后重试');
      expect(status.errorMessage, isNot(contains('SECRET_DATABASE_LEAK')));
    });

    test('status query failure never triggers ensureParsedArtifact or OCR',
        () async {
      files.values['file-a'] = _file('file-a', 1);
      lifecycle.currentError = const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.sourceUnavailable,
      );
      final status = await facade.getLibraryFileArtifactStatus('file-a');
      expect(status.status, LibraryFileArtifactStatus.unavailable);
      expect(lifecycle.ensureCalls, isEmpty);
    });

    test(
        'FileLibraryController.loadArtifactStatus unexpected throw maps to failed',
        () async {
      files.values['file-a'] = _file('file-a', 1);
      lifecycle.currentError = StateError('Unexpected crash in lifecycle');
      final controller = FileLibraryController(facade);
      await controller.loadArtifactStatus('file-a');
      expect(
          controller.artifactState?.status, LibraryFileArtifactStatus.failed);
      expect(controller.artifactState?.errorMessage, '暂时无法读取解析状态，请稍后重试');
    });

    test(
        'FileLibraryController.loadArtifactStatus artifactMissing maps to none',
        () async {
      files.values['file-a'] = _file('file-a', 1);
      lifecycle.currentError = const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.artifactMissing,
      );
      final controller = FileLibraryController(facade);
      await controller.loadArtifactStatus('file-a');
      expect(controller.artifactState?.status, LibraryFileArtifactStatus.none);
      expect(controller.artifactState?.errorMessage, isNull);
    });
  });
}
