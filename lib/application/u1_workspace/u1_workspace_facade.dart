library;

import '../../domain/assets/library_file.dart';
import '../../domain/assets/library_folder.dart';
import '../../domain/projects/project.dart';
import '../file_library/file_library_ports.dart';
import '../file_library/library_file_deletion.dart';
import '../file_library/library_folder_service.dart';
import '../parsed_artifacts/parsed_artifact_lifecycle.dart';
import '../projects/project_service.dart';
import '../study_query/study_query_dtos.dart';
import '../study_query/study_query_service.dart';
import 'u1_workspace_dtos.dart';

/// U1-R1 application boundary shared by the Agent-first presentation shell.
final class U1WorkspaceFacade {
  U1WorkspaceFacade({
    required ProjectService projectService,
    required LibraryFileRepositoryPort fileRepository,
    required FileIngestionPort fileIngestion,
    required LibraryFolderService folderService,
    required StudyQueryService studyQueryService,
    ParsedArtifactLifecyclePort? parsedArtifactLifecycle,
    LibraryFileDeletionPort? libraryFileDeletion,
    required this.mcpProjection,
  })  : _projectService = projectService,
        _fileRepository = fileRepository,
        _fileIngestion = fileIngestion,
        _folderService = folderService,
        _studyQueryService = studyQueryService,
        _parsedArtifactLifecycle = parsedArtifactLifecycle,
        _libraryFileDeletion = libraryFileDeletion;

  static const int recentFileLimit = 20;

  final ProjectService _projectService;
  final LibraryFileRepositoryPort _fileRepository;
  final FileIngestionPort _fileIngestion;
  final LibraryFolderService _folderService;
  final StudyQueryService _studyQueryService;
  final ParsedArtifactLifecyclePort? _parsedArtifactLifecycle;
  final LibraryFileDeletionPort? _libraryFileDeletion;
  final McpWorkspaceProjection mcpProjection;

  Future<List<LearningSpaceSummary>> listLearningSpaces() async {
    final projects = await _projectService.listProjects();
    final summaries = await Future.wait(projects.map(_projectSummary));
    summaries.sort((a, b) {
      final created = a.createdAt.compareTo(b.createdAt);
      return created != 0 ? created : a.projectId.compareTo(b.projectId);
    });
    return List<LearningSpaceSummary>.unmodifiable(summaries);
  }

  Future<LearningSpaceDetail?> getLearningSpace(String projectId) async {
    final project = await _projectService.getProject(projectId);
    if (project == null) return null;

    final fileIds = await _projectService.listProjectFileIds(projectId);
    final bankNames = await _projectService.listProjectBankNames(projectId);
    final files = <LibraryFileSummary>[];
    for (final fileId in fileIds) {
      final file = await _fileRepository.findById(fileId);
      if (file != null) files.add(_fileSummary(file));
    }
    files.sort(_newestFileFirst);

    final catalog = <String, QuestionBankSummary>{
      for (final bank in await listQuestionBanks()) bank.bankName: bank,
    };
    final banks = <LearningSpaceBankReference>[
      for (final bankName in bankNames)
        LearningSpaceBankReference(
          bankName: bankName,
          summary: catalog[bankName],
        ),
    ];

    return LearningSpaceDetail(
      summary: LearningSpaceSummary(
        projectId: project.projectId,
        displayName: project.displayName,
        createdAt: project.createdAt,
        fileCount: fileIds.length,
        bankCount: bankNames.length,
      ),
      files: List<LibraryFileSummary>.unmodifiable(files),
      banks: List<LearningSpaceBankReference>.unmodifiable(banks),
    );
  }

  Future<LearningSpaceSummary> createLearningSpace(String displayName) async {
    final project = await _projectService.createProject(
      displayName: displayName,
    );
    return LearningSpaceSummary(
      projectId: project.projectId,
      displayName: project.displayName,
      createdAt: project.createdAt,
      fileCount: 0,
      bankCount: 0,
    );
  }

  Future<LearningSpaceSummary> renameLearningSpace({
    required String projectId,
    required String displayName,
  }) async {
    final project = await _projectService.renameProject(
      projectId: projectId,
      displayName: displayName,
    );
    return _projectSummary(project);
  }

  Future<void> deleteLearningSpace(String projectId) =>
      _projectService.deleteProject(projectId);

  Future<List<LibraryFileSummary>> listLibraryFiles({
    FileLibraryView view = FileLibraryView.all,
  }) async {
    if (view == FileLibraryView.unclassified) {
      final unclassified = <LibraryFileSummary>[
        for (final file in await _folderService.listUnclassifiedFiles())
          _fileSummary(file),
      ]..sort(_newestFileFirst);
      return List<LibraryFileSummary>.unmodifiable(unclassified);
    }

    final files = <LibraryFileSummary>[
      for (final file in await _fileRepository.findAll()) _fileSummary(file),
    ]..sort(_newestFileFirst);

    switch (view) {
      case FileLibraryView.all:
        return List<LibraryFileSummary>.unmodifiable(files);
      case FileLibraryView.recent:
        return List<LibraryFileSummary>.unmodifiable(
          files.take(recentFileLimit),
        );
      case FileLibraryView.unclassified:
        throw StateError('Unreachable File Library view.');
    }
  }

  Future<List<LibraryFolderSummary>> listLibraryFolders() async {
    return List<LibraryFolderSummary>.unmodifiable(
      (await _folderService.listFolders()).map(_folderSummary),
    );
  }

  Future<LibraryFolderSummary> createLibraryFolder(String displayName) async {
    return _folderSummary(await _folderService.createFolder(displayName));
  }

  Future<LibraryFolderSummary> renameLibraryFolder({
    required String folderId,
    required String displayName,
  }) async {
    return _folderSummary(
      await _folderService.renameFolder(
        folderId: folderId,
        displayName: displayName,
      ),
    );
  }

  Future<void> deleteLibraryFolder(String folderId) =>
      _folderService.deleteFolder(folderId);

  Future<List<LibraryFileSummary>> listFilesInLibraryFolder(
    String folderId,
  ) async {
    final files = <LibraryFileSummary>[
      for (final file in await _folderService.listFilesInFolder(folderId))
        _fileSummary(file),
    ]..sort(_newestFileFirst);
    return List<LibraryFileSummary>.unmodifiable(files);
  }

  Future<void> moveLibraryFileToFolder({
    required String fileId,
    required String folderId,
  }) =>
      _folderService.moveFileToFolder(fileId: fileId, folderId: folderId);

  Future<void> removeLibraryFileFromFolder(String fileId) =>
      _folderService.removeFileFromFolder(fileId);

  Future<LibraryFileDetail?> getLibraryFileDetail(String fileId) async {
    final file = await _fileRepository.findById(fileId);
    if (file == null) return null;
    final folder = await _folderService.getFolderForFile(fileId);
    final relatedIds =
        (await _projectService.listProjectIdsForFile(fileId)).toSet();
    final relatedSpaces = (await listLearningSpaces())
        .where((space) => relatedIds.contains(space.projectId))
        .toList(growable: false);
    return LibraryFileDetail(
      file: _fileSummary(file),
      folder: folder == null ? null : _folderSummary(folder),
      relatedSpaces: List<LearningSpaceSummary>.unmodifiable(relatedSpaces),
    );
  }

  Future<LibraryFileSummary> ingestSelectedFile({
    required String externalPath,
    required String displayName,
    String? mimeType,
  }) async {
    final file = await _fileIngestion.ingest(
      externalPath: externalPath,
      displayName: displayName,
      mimeType: mimeType ?? mimeTypeForDisplayName(displayName),
    );
    return _fileSummary(file);
  }

  /// Formal Application deletion entry. Presentation owns confirmation; this
  /// boundary owns the DB-first mutation and managed-byte cleanup contract.
  Future<LibraryFileDeletionResult> deleteLibraryFile(String fileId) {
    final deletion = _libraryFileDeletion;
    if (deletion == null) {
      throw const LibraryFileDeletionException(
        LibraryFileDeletionFailure.unavailable,
      );
    }
    return deletion.deleteLibraryFile(fileId);
  }

  Future<List<QuestionBankSummary>> listQuestionBanks() async {
    final banks = <QuestionBankSummary>[];
    OpaqueCursor? cursor;
    final seenCursors = <String>{};
    do {
      final page = await _studyQueryService.listQuestionBanks(
        cursor: cursor,
        limit: 100,
      );
      banks.addAll(page.items);
      cursor = page.nextCursor;
      if (cursor != null && !seenCursors.add(cursor.value)) {
        throw StateError('Question-bank pagination did not advance.');
      }
    } while (cursor != null);
    return List<QuestionBankSummary>.unmodifiable(banks);
  }

  Future<UnclassifiedAssets> getUnclassifiedAssets() async {
    final files = <LibraryFileSummary>[];
    for (final file in await _fileRepository.findAll()) {
      if ((await _projectService.listProjectIdsForFile(file.fileId)).isEmpty) {
        files.add(_fileSummary(file));
      }
    }
    files.sort(_newestFileFirst);
    final banks = <QuestionBankSummary>[];
    for (final bank in await listQuestionBanks()) {
      if ((await _projectService.listProjectIdsForBank(bank.bankName))
          .isEmpty) {
        banks.add(bank);
      }
    }
    return UnclassifiedAssets(
      files: List<LibraryFileSummary>.unmodifiable(files),
      banks: List<QuestionBankSummary>.unmodifiable(banks),
    );
  }

  Future<void> attachFile({
    required String projectId,
    required String fileId,
  }) =>
      _projectService.attachFile(projectId: projectId, fileId: fileId);

  Future<void> detachFile({
    required String projectId,
    required String fileId,
  }) =>
      _projectService.detachFile(projectId: projectId, fileId: fileId);

  Future<void> attachBank({
    required String projectId,
    required String bankName,
  }) =>
      _projectService.attachBank(projectId: projectId, bankName: bankName);

  Future<void> detachBank({
    required String projectId,
    required String bankName,
  }) =>
      _projectService.detachBank(projectId: projectId, bankName: bankName);

  static String mimeTypeForDisplayName(String displayName) {
    final lower = displayName.toLowerCase();
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.txt')) return 'text/plain';
    if (lower.endsWith('.md')) return 'text/markdown';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.docx')) {
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    }
    if (lower.endsWith('.zip')) return 'application/zip';
    return 'application/octet-stream';
  }

  Future<LearningSpaceSummary> _projectSummary(Project project) async {
    final fileIds = await _projectService.listProjectFileIds(project.projectId);
    final bankNames =
        await _projectService.listProjectBankNames(project.projectId);
    return LearningSpaceSummary(
      projectId: project.projectId,
      displayName: project.displayName,
      createdAt: project.createdAt,
      fileCount: fileIds.length,
      bankCount: bankNames.length,
    );
  }

  Future<LibraryFileArtifactState> getLibraryFileArtifactStatus(
    String fileId,
  ) async {
    final lifecycle = _parsedArtifactLifecycle;
    if (lifecycle == null) {
      return const LibraryFileArtifactState(
        status: LibraryFileArtifactStatus.unavailable,
        errorMessage: '解析服务未初始化',
      );
    }
    try {
      final snapshot = await lifecycle.getCurrentArtifact(fileId);
      return LibraryFileArtifactState(
        status: LibraryFileArtifactStatus.available,
        parserRoute: snapshot.parserRoute,
        revision: snapshot.artifact.revision,
      );
    } on ParsedArtifactLifecycleException catch (e) {
      return switch (e.failure) {
        ParsedArtifactLifecycleFailure.artifactMissing =>
          const LibraryFileArtifactState(
            status: LibraryFileArtifactStatus.none,
          ),
        ParsedArtifactLifecycleFailure.temporarilyUnavailable =>
          const LibraryFileArtifactState(
            status: LibraryFileArtifactStatus.unavailable,
            errorMessage: '暂时无法读取解析状态，请稍后重试',
          ),
        ParsedArtifactLifecycleFailure.fileNotFound ||
        ParsedArtifactLifecycleFailure.sourceUnavailable =>
          const LibraryFileArtifactState(
            status: LibraryFileArtifactStatus.unavailable,
            errorMessage: '文件内容当前不可读取',
          ),
        ParsedArtifactLifecycleFailure.artifactCorrupt ||
        ParsedArtifactLifecycleFailure.payloadUnsupported =>
          const LibraryFileArtifactState(
            status: LibraryFileArtifactStatus.failed,
            errorMessage: '文件内容解析数据已损坏',
          ),
        ParsedArtifactLifecycleFailure.internalError ||
        ParsedArtifactLifecycleFailure.invalidRequest ||
        ParsedArtifactLifecycleFailure.unsupportedRoute ||
        ParsedArtifactLifecycleFailure.parseFailed ||
        ParsedArtifactLifecycleFailure.publishConflict =>
          const LibraryFileArtifactState(
            status: LibraryFileArtifactStatus.failed,
            errorMessage: '暂时无法读取解析状态，请稍后重试',
          ),
      };
    } catch (_) {
      return const LibraryFileArtifactState(
        status: LibraryFileArtifactStatus.failed,
        errorMessage: '暂时无法读取解析状态，请稍后重试',
      );
    }
  }

  Future<LibraryFileArtifactState> ensureLibraryFileParsed(
      String fileId) async {
    final lifecycle = _parsedArtifactLifecycle;
    if (lifecycle == null) {
      return const LibraryFileArtifactState(
        status: LibraryFileArtifactStatus.unavailable,
        errorMessage: '解析服务未初始化',
      );
    }
    try {
      final result = await lifecycle.ensureParsedArtifact(
        fileId: fileId,
        options: const ParsedArtifactParseOptions(
          routeSelection: ParsedArtifactRouteSelection.auto,
        ),
      );
      return LibraryFileArtifactState(
        status: LibraryFileArtifactStatus.available,
        parserRoute: result.snapshot.parserRoute,
        revision: result.snapshot.artifact.revision,
      );
    } on ParsedArtifactLifecycleException catch (e) {
      return _mapDeterministicParseFailure(fileId, e.failure);
    } catch (_) {
      return const LibraryFileArtifactState(
        status: LibraryFileArtifactStatus.failed,
        errorMessage: '文件解析遇到错误，请稍后重试',
      );
    }
  }

  Future<LibraryFileArtifactState> ensureLibraryFileOcrPdf(
      String fileId) async {
    final lifecycle = _parsedArtifactLifecycle;
    if (lifecycle == null) {
      return const LibraryFileArtifactState(
        status: LibraryFileArtifactStatus.unavailable,
        errorMessage: '解析服务未初始化',
      );
    }
    try {
      final result = await lifecycle.ensureParsedArtifact(
        fileId: fileId,
        options: const ParsedArtifactParseOptions(
          routeSelection: ParsedArtifactRouteSelection.ocrPdf,
        ),
      );
      return LibraryFileArtifactState(
        status: LibraryFileArtifactStatus.available,
        parserRoute: result.snapshot.parserRoute,
        revision: result.snapshot.artifact.revision,
      );
    } on ParsedArtifactLifecycleException catch (e) {
      return _mapOcrParseFailure(e.failure);
    } catch (_) {
      return const LibraryFileArtifactState(
        status: LibraryFileArtifactStatus.failed,
        errorMessage: '文件 OCR 解析失败，请稍后重试。',
      );
    }
  }

  Future<LibraryFileArtifactState> _mapDeterministicParseFailure(
    String fileId,
    ParsedArtifactLifecycleFailure failure,
  ) async {
    switch (failure) {
      case ParsedArtifactLifecycleFailure.sourceUnavailable:
        final file = await _fileRepository.findById(fileId);
        final isPdf = file != null &&
            (file.displayName.toLowerCase().endsWith('.pdf') ||
                file.mimeType == 'application/pdf');
        if (isPdf) {
          return const LibraryFileArtifactState(
            status: LibraryFileArtifactStatus.ocrRecommended,
          );
        }
        return const LibraryFileArtifactState(
          status: LibraryFileArtifactStatus.unavailable,
          errorMessage: '文件内容当前不可读取。',
        );
      case ParsedArtifactLifecycleFailure.temporarilyUnavailable:
        return const LibraryFileArtifactState(
          status: LibraryFileArtifactStatus.unavailable,
          errorMessage: '解析服务暂不可用，请稍后重试。',
        );
      case ParsedArtifactLifecycleFailure.parseFailed:
        return const LibraryFileArtifactState(
          status: LibraryFileArtifactStatus.failed,
          errorMessage: '文件解析失败，请稍后重试。',
        );
      case ParsedArtifactLifecycleFailure.fileNotFound:
        return const LibraryFileArtifactState(
          status: LibraryFileArtifactStatus.unavailable,
          errorMessage: '文件不存在。',
        );
      case ParsedArtifactLifecycleFailure.unsupportedRoute:
        return const LibraryFileArtifactState(
          status: LibraryFileArtifactStatus.failed,
          errorMessage: '不支持的文件解析类型。',
        );
      case ParsedArtifactLifecycleFailure.artifactCorrupt:
      case ParsedArtifactLifecycleFailure.payloadUnsupported:
        return const LibraryFileArtifactState(
          status: LibraryFileArtifactStatus.failed,
          errorMessage: '文件内容解析数据已损坏。',
        );
      case ParsedArtifactLifecycleFailure.invalidRequest:
      case ParsedArtifactLifecycleFailure.publishConflict:
      case ParsedArtifactLifecycleFailure.artifactMissing:
      case ParsedArtifactLifecycleFailure.internalError:
        return const LibraryFileArtifactState(
          status: LibraryFileArtifactStatus.failed,
          errorMessage: '文件解析遇到错误，请稍后重试。',
        );
    }
  }

  LibraryFileArtifactState _mapOcrParseFailure(
    ParsedArtifactLifecycleFailure failure,
  ) {
    return switch (failure) {
      ParsedArtifactLifecycleFailure.temporarilyUnavailable =>
        const LibraryFileArtifactState(
          status: LibraryFileArtifactStatus.unavailable,
          errorMessage: '当前 OCR 服务不可用，请检查 OCR 引擎配置后重试。',
        ),
      ParsedArtifactLifecycleFailure.sourceUnavailable =>
        const LibraryFileArtifactState(
          status: LibraryFileArtifactStatus.unavailable,
          errorMessage: '文件内容当前不可读取。',
        ),
      ParsedArtifactLifecycleFailure.parseFailed =>
        const LibraryFileArtifactState(
          status: LibraryFileArtifactStatus.failed,
          errorMessage: '文件 OCR 解析失败，请稍后重试。',
        ),
      ParsedArtifactLifecycleFailure.unsupportedRoute =>
        const LibraryFileArtifactState(
          status: LibraryFileArtifactStatus.failed,
          errorMessage: '该文件不支持 OCR 识别。',
        ),
      ParsedArtifactLifecycleFailure.fileNotFound =>
        const LibraryFileArtifactState(
          status: LibraryFileArtifactStatus.unavailable,
          errorMessage: '文件不存在。',
        ),
      _ => const LibraryFileArtifactState(
          status: LibraryFileArtifactStatus.failed,
          errorMessage: '文件 OCR 解析失败，请稍后重试。',
        ),
    };
  }

  static LibraryFileSummary _fileSummary(LibraryFile file) {
    return LibraryFileSummary(
      fileId: file.fileId,
      displayName: file.displayName,
      mimeType: file.mimeType,
      sizeBytes: file.sizeBytes,
      createdAt: file.createdAt,
    );
  }

  static LibraryFolderSummary _folderSummary(LibraryFolder folder) {
    return LibraryFolderSummary(
      folderId: folder.folderId,
      displayName: folder.displayName,
      createdAt: folder.createdAt,
    );
  }

  static int _newestFileFirst(
    LibraryFileSummary left,
    LibraryFileSummary right,
  ) {
    final created = right.createdAt.compareTo(left.createdAt);
    return created != 0 ? created : left.fileId.compareTo(right.fileId);
  }
}
