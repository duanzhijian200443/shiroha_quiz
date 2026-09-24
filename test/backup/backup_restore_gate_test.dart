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
  bool maintenanceObservedDuringExport = false;
  int commitCalls = 0;
  int exportCalls = 0;
  void Function()? duringExport;

  @override
  PreparedRestoreState? get preparedRestore => null;

  @override
  Future<BackupExportSummary> exportTo(String destinationPath) async {
    exportCalls++;
    maintenanceObservedDuringExport =
        BackupRestoreMutationGate.instance.isMaintenance;
    duringExport?.call();
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

  for (final innerThrows in [false, true]) {
    test('reentrant quiescence drains one root; inner throws: $innerThrows',
        () async {
      final gate = BackupRestoreMutationGate.instance;
      final entered = Completer<void>();
      final proceed = Completer<void>();
      final events = <String>[];
      final root = gate.runMutation(() async {
        entered.complete();
        await proceed.future;
        try {
          await gate.runMutation(() => gate.runMutation(() async {
                expect(gate.activeMutationCount, 1);
                events.add('nested');
                if (innerThrows) throw StateError('synthetic');
              }));
        } finally {
          events.add('root-finally');
        }
      });
      final checkedRoot =
          innerThrows ? expectLater(root, throwsStateError) : root;
      await entered.future;
      final drained = gate.enterQuiescence().then((_) => events.add('drained'));
      await expectLater(
          gate.runMutation(() async => fail('external admitted')),
          throwsA(isA<BackupException>().having(
              (e) => e.failure, 'failure', BackupFailure.restoreBlocked)));
      expect(events, isEmpty);
      expect(gate.activeMutationCount, 1);
      proceed.complete();
      await checkedRoot;
      await drained;
      expect(events, ['nested', 'root-finally', 'drained']);
      expect(gate.activeMutationCount, 0);
    });
  }

  test('nested mutation that outlives its root keeps the lease drained',
      () async {
    final gate = BackupRestoreMutationGate.instance;
    final started = Completer<void>();
    final finish = Completer<void>();
    final root = gate.runMutation(() async {
      unawaited(gate.runMutation(() async {
        started.complete();
        await finish.future;
      }));
      await started.future;
    });
    await root;
    expect(gate.activeMutationCount, 1);
    var drained = false;
    final quiescence = gate.enterQuiescence().then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, false);
    expect(gate.activeMutationCount, 1);
    finish.complete();
    await quiescence;
    expect(gate.activeMutationCount, 0);
  });

  test('live nested action may still start its own nested work after root',
      () async {
    final gate = BackupRestoreMutationGate.instance;
    final started = Completer<void>();
    final resume = Completer<void>();
    var grandchildRan = false;
    var drained = false;
    final root = gate.runMutation(() async {
      unawaited(gate.runMutation(() async {
        started.complete();
        await resume.future;
        // The root action returned already; this live action still owns its
        // scope and keeps working while quiescence waits.
        await gate.runMutation(() async {
          grandchildRan = true;
        });
      }));
      await started.future;
    });
    await root;
    expect(gate.activeMutationCount, 1);
    final quiescence = gate.enterQuiescence().then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, false);
    resume.complete();
    await quiescence;
    expect(grandchildRan, true);
    expect(drained, true);
    expect(gate.activeMutationCount, 0);
  });

  test('released zone ownership cannot admit late work during maintenance',
      () async {
    final gate = BackupRestoreMutationGate.instance;
    late Future<void> Function() lateWork;
    await gate.runMutation(() async {
      final ownerZone = Zone.current;
      lateWork = () => ownerZone.run(() => gate.runMutation(() async {}));
    });
    await gate.enterQuiescence();
    await expectLater(
        lateWork(),
        throwsA(isA<BackupException>().having(
            (e) => e.failure, 'failure', BackupFailure.restoreBlocked)));
    expect(gate.activeMutationCount, 0);
  });

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

  test('export fails immediately while mutation is active and releases gates',
      () async {
    final gate = BackupRestoreMutationGate.instance;
    final operations = _FakeOperations();
    final coordinator = BackupRestoreCoordinator(operations: operations);
    final lease = gate.acquireMutationLease();

    await expectLater(
      coordinator.exportTo('synthetic.shiroha'),
      throwsA(isA<BackupException>().having(
        (error) => error.failure,
        'failure',
        BackupFailure.restoreBusy,
      )),
    );
    expect(operations.exportCalls, 0);
    expect(coordinator.isBusy, isFalse);
    expect(gate.isExclusive, isFalse);
    expect(gate.isMaintenance, isFalse);

    lease.release();
    await coordinator.exportTo('synthetic.shiroha');
    expect(operations.exportCalls, 1);
    expect(operations.maintenanceObservedDuringExport, isTrue);
    expect(gate.isExclusive, isFalse);
    expect(gate.isMaintenance, isFalse);
  });

  test('export maintenance rejects a new mutation', () async {
    final gate = BackupRestoreMutationGate.instance;
    final operations = _FakeOperations();
    final coordinator = BackupRestoreCoordinator(operations: operations);
    operations.duringExport = () {
      expect(
        gate.acquireMutationLease,
        throwsA(isA<BackupException>().having(
          (error) => error.failure,
          'failure',
          BackupFailure.restoreBlocked,
        )),
      );
    };

    await coordinator.exportTo('synthetic.shiroha');
    expect(operations.maintenanceObservedDuringExport, isTrue);
    expect(gate.isMaintenance, isFalse);
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

  test('coordinator restore commit still waits for an active mutation',
      () async {
    final gate = BackupRestoreMutationGate.instance;
    final operations = _FakeOperations();
    final coordinator = BackupRestoreCoordinator(operations: operations);
    final lease = gate.acquireMutationLease();

    final commit = coordinator.commitPreparedRestore();
    await Future<void>.delayed(Duration.zero);
    expect(gate.isMaintenance, isTrue);
    expect(operations.commitCalls, 0);

    lease.release();
    await commit;
    expect(operations.commitCalls, 1);
    expect(gate.isMaintenance, isFalse);
    expect(gate.isExclusive, isFalse);
  });
}
