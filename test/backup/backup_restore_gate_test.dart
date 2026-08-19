import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_contracts.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_coordinator.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/file_library/library_folder_repository.dart';
import 'package:shiroha_quiz/application/file_library/library_folder_service.dart';
import 'package:shiroha_quiz/application/projects/project_repository.dart';
import 'package:shiroha_quiz/application/projects/project_service.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/assets/library_folder.dart';
import 'package:shiroha_quiz/domain/projects/project.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/domain/backup/backup_values.dart';

final class _FakeOperations implements BackupRestoreOperations {
  bool maintenanceObservedDuringCommit = false;
  int commitCalls = 0;

  @override
  PreparedRestoreState? get preparedRestore => null;

  @override
  Future<BackupExportSummary> exportTo(String destinationPath) async {
    return const BackupExportSummary(
      fileName: 'backup.shiroha',
      schemaVersion: BackupValues.currentSchemaVersion,
      fileCount: 0,
      databaseSizeBytes: 0,
      managedBytes: 0,
    );
  }

  @override
  Future<BackupRestorePreview> inspectPackage(String packagePath) async {
    return BackupRestorePreview(
      packageVersion: 1,
      schemaVersion: BackupValues.currentSchemaVersion,
      createdAtUtc: DateTime.utc(2026),
      fileCount: 0,
      totalSizeBytes: 0,
    );
  }

  @override
  Future<BackupRestorePreview> prepareRestore(String packagePath) async {
    return inspectPackage(packagePath);
  }

  @override
  Future<void> cancelPreparedRestore() async {}

  @override
  Future<BackupRestoreSuccess> commitPreparedRestore({
    Future<void> Function()? beforeCommitted,
  }) async {
    commitCalls++;
    await beforeCommitted?.call();
    maintenanceObservedDuringCommit =
        BackupRestoreMutationGate.instance.isMaintenance;
    return const BackupRestoreSuccess(
      schemaVersion: BackupValues.currentSchemaVersion,
      fileCount: 0,
    );
  }

  @override
  Future<BackupStartupRecovery> recoverStartupIfNeeded() async {
    return const BackupStartupRecovery(
      blocked: false,
      diagnosticId: 'OBS-2222-2222',
    );
  }
}

final class _FakeProjectRepository implements ProjectRepository {
  int createCalls = 0;
  @override
  Future<void> createProject(Project project) async {
    createCalls++;
  }

  @override
  Future<List<Project>> listProjects() async => const [];
  @override
  Future<Project?> getProject(String projectId) async => null;
  @override
  Future<Project> renameProject(
          {required String projectId, required String displayName}) async =>
      throw UnimplementedError();
  @override
  Future<void> deleteProject(String projectId) async {}
  @override
  Future<void> attachFile(
      {required String projectId, required String fileId}) async {}
  @override
  Future<void> detachFile(
      {required String projectId, required String fileId}) async {}
  @override
  Future<void> attachBank(
      {required String projectId, required String bankName}) async {}
  @override
  Future<void> detachBank(
      {required String projectId, required String bankName}) async {}
  @override
  Future<List<String>> listProjectFileIds(String projectId) async => const [];
  @override
  Future<List<String>> listProjectBankNames(String projectId) async => const [];
  @override
  Future<List<String>> listProjectIdsForFile(String fileId) async => const [];
  @override
  Future<List<String>> listProjectIdsForBank(String bankName) async => const [];
}

final class _FakeFolderRepository implements LibraryFolderRepositoryPort {
  int createCalls = 0;
  @override
  Future<void> createFolder(LibraryFolder folder) async {
    createCalls++;
  }

  @override
  Future<List<LibraryFolder>> listFolders() async => const [];
  @override
  Future<LibraryFolder?> findFolder(String folderId) async => null;
  @override
  Future<LibraryFolder> renameFolder(
          {required String folderId, required String displayName}) async =>
      throw UnimplementedError();
  @override
  Future<void> deleteFolder(String folderId) async {}
  @override
  Future<LibraryFolder?> getFolderForFile(String fileId) async => null;
  @override
  Future<void> moveFileToFolder(
      {required String fileId, required String folderId}) async {}
  @override
  Future<void> removeFileFromFolder(String fileId) async {}
  @override
  Future<List<LibraryFile>> listFilesInFolder(String folderId) async =>
      const [];
  @override
  Future<List<LibraryFile>> listUnclassifiedFiles() async => const [];
}

void main() {
  setUp(BackupRestoreMutationGate.resetForTesting);
  tearDown(BackupRestoreMutationGate.resetForTesting);

  test('quiescence blocks all durable mutation authorities', () async {
    await BackupRestoreMutationGate.instance.enterQuiescence();
    expect(
      () => BackupRestoreMutationGate.instance.ensureMutationAllowed(),
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.restoreBlocked,
      )),
    );
    BackupRestoreMutationGate.instance.exitQuiescence();
    BackupRestoreMutationGate.instance.ensureMutationAllowed();
  });

  test('enterQuiescence drains an active mutation lease before completing',
      () async {
    final release = Completer<void>();
    final active = BackupRestoreMutationGate.instance.runMutation(
      () => release.future.then((_) => 'done'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(BackupRestoreMutationGate.instance.activeMutationCount, 1);

    final drained = BackupRestoreMutationGate.instance.enterQuiescence();
    var drainedCompleted = false;
    unawaited(drained.then((_) => drainedCompleted = true));
    await Future<void>.delayed(Duration.zero);
    expect(drainedCompleted, isFalse);
    expect(
      () => BackupRestoreMutationGate.instance.ensureMutationAllowed(),
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.restoreBlocked,
      )),
    );

    release.complete();
    expect(await active, 'done');
    await drained;
    expect(drainedCompleted, isTrue);
    expect(BackupRestoreMutationGate.instance.isMaintenance, isTrue);
    BackupRestoreMutationGate.instance.exitQuiescence();
  });

  test('exclusive B0 operations reject a concurrent backup/restore', () {
    BackupRestoreMutationGate.instance.acquireExclusive();
    expect(
      BackupRestoreMutationGate.instance.acquireExclusive,
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.restoreBusy,
      )),
    );
    BackupRestoreMutationGate.instance.releaseExclusive();
    BackupRestoreMutationGate.instance.acquireExclusive();
  });

  test(
      'Project and Folder durable authorities reject while maintenance is active',
      () async {
    final projectRepo = _FakeProjectRepository();
    final folderRepo = _FakeFolderRepository();
    final projects = ProjectService(
      repository: projectRepo,
      projectIdFactory: () => 'project-1',
    );
    final folders = LibraryFolderService(
      repository: folderRepo,
      folderIdFactory: () => 'folder-1',
    );

    await BackupRestoreMutationGate.instance.enterQuiescence();
    await expectLater(
      projects.createProject(displayName: 'p'),
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.restoreBlocked,
      )),
    );
    await expectLater(
      folders.createFolder('f'),
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.restoreBlocked,
      )),
    );
    expect(projectRepo.createCalls, 0);
    expect(folderRepo.createCalls, 0);
    BackupRestoreMutationGate.instance.exitQuiescence();
  });

  test('coordinator commit enters global quiescence before runtime commit',
      () async {
    final operations = _FakeOperations();
    final coordinator = BackupRestoreCoordinator(operations: operations);

    await coordinator.commitPreparedRestore();

    expect(operations.commitCalls, 1);
    expect(operations.maintenanceObservedDuringCommit, isTrue);
    expect(BackupRestoreMutationGate.instance.isMaintenance, isFalse);
    expect(BackupRestoreMutationGate.instance.isExclusive, isFalse);
  });
}
