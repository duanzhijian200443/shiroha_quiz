import 'package:flutter/foundation.dart';

import '../../application/study_query/study_query_dtos.dart';
import '../../application/file_library/library_folder_repository.dart';
import '../../application/u1_workspace/u1_workspace_dtos.dart';
import '../../application/u1_workspace/u1_workspace_facade.dart';

const String workspaceSafeError = '暂时无法读取学习空间数据，请稍后重试';

class LearningSpacesController extends ChangeNotifier {
  LearningSpacesController(this.facade);

  final U1WorkspaceFacade facade;

  List<LearningSpaceSummary> spaces = const <LearningSpaceSummary>[];
  List<QuestionBankSummary> availableBanks = const <QuestionBankSummary>[];
  LearningSpaceDetail? selectedDetail;
  UnclassifiedAssets? unclassifiedAssets;
  bool isLoading = false;
  String? errorMessage;

  McpWorkspaceProjection get mcpProjection => facade.mcpProjection;

  Future<void> load() async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      spaces = await facade.listLearningSpaces();
      availableBanks = await facade.listQuestionBanks();
    } catch (_) {
      errorMessage = workspaceSafeError;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadUnclassified() async {
    try {
      unclassifiedAssets = await facade.getUnclassifiedAssets();
      errorMessage = null;
    } catch (_) {
      errorMessage = workspaceSafeError;
    }
    notifyListeners();
  }

  Future<void> select(String projectId) async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      selectedDetail = await facade.getLearningSpace(projectId);
      if (selectedDetail == null) errorMessage = '学习空间已不存在';
    } catch (_) {
      errorMessage = workspaceSafeError;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<LearningSpaceSummary?> create(String displayName) async {
    try {
      final created = await facade.createLearningSpace(displayName);
      await load();
      return created;
    } catch (_) {
      errorMessage = '无法创建学习空间，请检查名称后重试';
      notifyListeners();
      return null;
    }
  }

  Future<bool> rename(String projectId, String displayName) async {
    try {
      await facade.renameLearningSpace(
        projectId: projectId,
        displayName: displayName,
      );
      await load();
      await select(projectId);
      return true;
    } catch (_) {
      errorMessage = '无法重命名学习空间，请检查名称后重试';
      notifyListeners();
      return false;
    }
  }

  Future<bool> delete(String projectId) async {
    try {
      await facade.deleteLearningSpace(projectId);
      selectedDetail = null;
      await load();
      return true;
    } catch (_) {
      errorMessage = '无法删除学习空间，请稍后重试';
      notifyListeners();
      return false;
    }
  }

  Future<void> attachFile(String projectId, String fileId) =>
      _mutateDetail(projectId, () {
        return facade.attachFile(projectId: projectId, fileId: fileId);
      });

  Future<void> detachFile(String projectId, String fileId) =>
      _mutateDetail(projectId, () {
        return facade.detachFile(projectId: projectId, fileId: fileId);
      });

  Future<void> attachBank(String projectId, String bankName) =>
      _mutateDetail(projectId, () {
        return facade.attachBank(projectId: projectId, bankName: bankName);
      });

  Future<void> detachBank(String projectId, String bankName) =>
      _mutateDetail(projectId, () {
        return facade.detachBank(projectId: projectId, bankName: bankName);
      });

  Future<void> _mutateDetail(
    String projectId,
    Future<void> Function() action,
  ) async {
    try {
      await action();
      await load();
      await select(projectId);
    } catch (_) {
      errorMessage = '无法更新关联，请稍后重试';
      notifyListeners();
    }
  }
}

class FileLibraryController extends ChangeNotifier {
  FileLibraryController(this.facade);

  final U1WorkspaceFacade facade;

  FileLibraryView view = FileLibraryView.all;
  List<LibraryFileSummary> files = const <LibraryFileSummary>[];
  List<LibraryFolderSummary> folders = const <LibraryFolderSummary>[];
  List<LearningSpaceSummary> spaces = const <LearningSpaceSummary>[];
  String? selectedFolderId;
  LibraryFileDetail? selectedDetail;
  LibraryFileArtifactState? artifactState;
  bool isArtifactBusy = false;
  bool isLoading = false;
  String query = '';
  String? errorMessage;

  List<LibraryFileSummary> get visibleFiles {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return files;
    return files
        .where((file) => file.displayName.toLowerCase().contains(normalized))
        .toList(growable: false);
  }

  Future<void> load({FileLibraryView? nextView}) async {
    if (nextView != null) {
      view = nextView;
      selectedFolderId = null;
    }
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      folders = await facade.listLibraryFolders();
      final folderId = selectedFolderId;
      files = folderId == null
          ? await facade.listLibraryFiles(view: view)
          : await facade.listFilesInLibraryFolder(folderId);
      spaces = await facade.listLearningSpaces();
    } catch (_) {
      errorMessage = '暂时无法读取文件库，请稍后重试';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> selectFolder(String folderId) async {
    selectedFolderId = folderId;
    await load();
  }

  Future<LibraryFolderSummary?> createFolder(String displayName) async {
    try {
      final created = await facade.createLibraryFolder(displayName);
      await load();
      return created;
    } catch (error) {
      errorMessage = _folderError(error, action: '创建');
      notifyListeners();
      return null;
    }
  }

  Future<bool> renameFolder(String folderId, String displayName) async {
    try {
      await facade.renameLibraryFolder(
        folderId: folderId,
        displayName: displayName,
      );
      await load();
      return true;
    } catch (error) {
      errorMessage = _folderError(error, action: '重命名');
      notifyListeners();
      return false;
    }
  }

  Future<bool> deleteFolder(String folderId) async {
    try {
      await facade.deleteLibraryFolder(folderId);
      if (selectedFolderId == folderId) {
        selectedFolderId = null;
        view = FileLibraryView.unclassified;
      }
      await load();
      return true;
    } catch (error) {
      errorMessage = _folderError(error, action: '删除');
      notifyListeners();
      return false;
    }
  }

  Future<bool> moveFile({
    required String fileId,
    String? folderId,
  }) async {
    try {
      if (folderId == null) {
        await facade.removeLibraryFileFromFolder(fileId);
      } else {
        await facade.moveLibraryFileToFolder(
          fileId: fileId,
          folderId: folderId,
        );
      }
      await load();
      if (selectedDetail?.file.fileId == fileId) await select(fileId);
      return true;
    } catch (error) {
      errorMessage = _folderError(error, action: '移动');
      notifyListeners();
      return false;
    }
  }

  void setQuery(String value) {
    query = value;
    notifyListeners();
  }

  Future<void> select(String fileId) async {
    try {
      selectedDetail = await facade.getLibraryFileDetail(fileId);
      errorMessage = selectedDetail == null ? '文件已不存在' : null;
      if (selectedDetail != null) {
        await loadArtifactStatus(fileId);
      } else {
        artifactState = null;
      }
    } catch (_) {
      errorMessage = '暂时无法读取文件详情，请稍后重试';
      artifactState = null;
    }
    notifyListeners();
  }

  Future<void> loadArtifactStatus(String fileId) async {
    try {
      artifactState = await facade.getLibraryFileArtifactStatus(fileId);
    } catch (_) {
      artifactState = const LibraryFileArtifactState(
        status: LibraryFileArtifactStatus.none,
      );
    }
    notifyListeners();
  }

  Future<LibraryFileArtifactState> ensureFileParsed(String fileId) async {
    if (isArtifactBusy) {
      return artifactState ??
          const LibraryFileArtifactState(
            status: LibraryFileArtifactStatus.none,
          );
    }
    isArtifactBusy = true;
    notifyListeners();
    try {
      final state = await facade.ensureLibraryFileParsed(fileId);
      artifactState = state;
      return state;
    } catch (_) {
      const fallbackState = LibraryFileArtifactState(
        status: LibraryFileArtifactStatus.failed,
        errorMessage: '文件解析遇到错误，请稍后重试',
      );
      artifactState = fallbackState;
      return fallbackState;
    } finally {
      isArtifactBusy = false;
      notifyListeners();
    }
  }

  Future<LibraryFileArtifactState> ensureFileOcrPdf(String fileId) async {
    if (isArtifactBusy) {
      return artifactState ??
          const LibraryFileArtifactState(
            status: LibraryFileArtifactStatus.none,
          );
    }
    isArtifactBusy = true;
    notifyListeners();
    try {
      final state = await facade.ensureLibraryFileOcrPdf(fileId);
      artifactState = state;
      return state;
    } catch (_) {
      const fallbackState = LibraryFileArtifactState(
        status: LibraryFileArtifactStatus.failed,
        errorMessage: '文件 OCR 解析失败，请稍后重试',
      );
      artifactState = fallbackState;
      return fallbackState;
    } finally {
      isArtifactBusy = false;
      notifyListeners();
    }
  }

  Future<bool> ingest({
    required String externalPath,
    required String displayName,
  }) async {
    try {
      await facade.ingestSelectedFile(
        externalPath: externalPath,
        displayName: displayName,
      );
      await load();
      return true;
    } catch (_) {
      errorMessage = '无法添加文件，请确认文件可读取后重试';
      notifyListeners();
      return false;
    }
  }

  Future<void> setProjectRelation({
    required String fileId,
    required String projectId,
    required bool attached,
  }) async {
    try {
      if (attached) {
        await facade.attachFile(projectId: projectId, fileId: fileId);
      } else {
        await facade.detachFile(projectId: projectId, fileId: fileId);
      }
      await load();
      await select(fileId);
    } catch (_) {
      errorMessage = '无法更新文件关联，请稍后重试';
      notifyListeners();
    }
  }

  String _folderError(Object error, {required String action}) {
    if (error is LibraryFolderException) {
      return switch (error.failure) {
        LibraryFolderFailure.invalidName => '文件夹名称无效',
        LibraryFolderFailure.duplicateName => '已存在同名文件夹',
        LibraryFolderFailure.folderNotFound => '文件夹已不存在',
        LibraryFolderFailure.fileNotFound => '文件已不存在',
        LibraryFolderFailure.folderIdConflict ||
        LibraryFolderFailure.dataCorrupt ||
        LibraryFolderFailure.temporarilyUnavailable =>
          '暂时无法$action文件夹，请稍后重试',
      };
    }
    return '暂时无法$action文件夹，请稍后重试';
  }
}
