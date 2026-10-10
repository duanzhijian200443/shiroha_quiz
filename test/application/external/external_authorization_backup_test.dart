import 'package:uuid/uuid.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/core/database/external_authorization_schema.dart';
import 'package:shiroha_quiz/data/repositories/external_authorization_repository.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/domain/backup/backup_values.dart';
import 'package:shiroha_quiz/services/backup/backup_archive_io.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_filesystem.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import '../generated_question/generated_test_support.dart';
import '../generated_question/external_origin_test_support.dart'
    show installLegacyGeneratedHeaderFixture;
import 'external_authorization_data_test.dart' show authFailure;

final class _Disk implements BackupDiskSpaceProbe {
  const _Disk();
  @override
  Future<int?> availableBytes(String path) async => 1 << 40;
}

final class _FailSwap extends BackupFaultInjector {
  const _FailSwap();
  @override
  Future<void> beforePostSwapValidation() async =>
      throw const BackupException(BackupFailure.databaseInvalid);
}

void main() {
  initializeGeneratedTests();
  late GeneratedHarness h;
  late ExternalAuthorizationManagement management;
  late ExternalProfileReference ref;
  late BackupSnapshotRepository snapshots;
  late Directory managed, restore;
  setUp(() async {
    h = GeneratedHarness();
    await h.open();
    management = ExternalAuthorizationManagement(
        mintProfileId: const Uuid().v4,
        repository:
            SqliteExternalAuthorizationRepository(databaseHelper: h.helper),
        compositionIsCurrent: () => true,
        clock: () => DateTime.utc(2026));
    ref = await management.createProfile(
        displayName: 'Synthetic Client', adapter: 'bridge', protocol: 'tcp-v1');
    await management.replaceGrant(
        ref,
        0,
        ExternalGrantPolicy(permissions: [
          CapabilityPermission.read,
          CapabilityPermission.stage
        ], scopes: [
          ExternalGrantScope(kind: ExternalTargetKind.bank, targetId: 'bank')
        ], categories: ExternalContentCategory.values));
    snapshots = BackupSnapshotRepository(databaseHelper: h.helper);
    managed = Directory(p.join(h.temp.path, 'managed'))..createSync();
    restore = Directory(p.join(h.temp.path, 'restore'))..createSync();
  });
  tearDown(() async => h.close());
  BackupRestoreRuntime runtime(
          {BackupFaultInjector faults = const BackupFaultInjector()}) =>
      BackupRestoreRuntime(
          databaseAuthority: SqliteBackupDatabaseAuthority(
              databaseHelper: h.helper, snapshotRepository: snapshots),
          snapshotRepository: snapshots,
          managedFileStorage: ManagedFileStorageAdapter(managedRoot: managed),
          restoreRoot: restore,
          managedFilesRoot: managed,
          diskSpaceProbe: const _Disk(),
          faultInjector: faults);
  Future<Map<String, List<Map<String, Object?>>>> authRows() async => {
        for (final table in externalAuthorizationTables)
          table: await h.db.query(table)
      };
  Future<String> package(String path, {int version = 34}) async {
    final manifest = BackupManifest(
        packageVersion: 2,
        schemaVersion: version,
        createdAtUtc: DateTime.utc(2026),
        database: BackupDatabaseEntry(
            archivePath: BackupValues.databaseArchivePath,
            sizeBytes: File(path).lengthSync(),
            sha256: BackupFilesystem.sha256File(path)),
        managedFiles: const []);
    final metadata = p.join(h.temp.path, 'package.json');
    await File(metadata).writeAsString(manifest.encode());
    final destination = p.join(h.temp.path, 'candidate.shiroha');
    await BackupArchiveIo.writeStoredPackage(
        packagePath: destination,
        manifestPath: metadata,
        databasePath: path,
        files: const []);
    return destination;
  }

  test(
      'portable copy strips all authorization; live data and soft Proposal origin survive',
      () async {
    final revoked = await management.createProfile(
        displayName: 'Revoked', adapter: 'bridge', protocol: 'tcp-v1');
    await management.revokeProfile(revoked, 0);
    final proposal =
        (await h.service.stage(submission(), h.origin(profile: ref.profileId)))
            .proposal;
    final before = await authRows();
    final copyPath = p.join(h.temp.path, 'scrub.db');
    final snapshot = await snapshots.createSanitizedSnapshot(copyPath);
    expect(snapshot.schemaVersion, 34);
    final copy = await databaseFactory.openDatabase(copyPath);
    try {
      for (final table in externalAuthorizationTables) {
        expect(await copy.query(table), isEmpty);
      }
      expect(
          (await copy.query('generated_question_proposals'))
              .single['client_profile_id'],
          ref.profileId);
      await snapshots.validateScrubInvariantsOn(copy);
    } finally {
      await copy.close();
    }
    expect(await authRows(), before);
    final path = p.join(h.temp.path, 'roundtrip.shiroha');
    await runtime().exportTo(path);
    expect((await BackupArchiveIo.readManifestOnly(path)).packageVersion, 2);
    final restoring = runtime();
    await restoring.prepareRestore(path);
    await restoring.commitPreparedRestore();
    h.db = await h.helper.database;
    for (final table in externalAuthorizationTables) {
      expect(await h.db.query(table), isEmpty);
    }
    expect(
        (await h.repository.read(proposal.proposalId, h.local)).clientProfileId,
        ref.profileId);
    await expectLater(
        management.read(ref), authFailure(ExternalAuthFailure.unauthorized));
    // Synthetic origin tests the existing soft-reference property only;
    // no external Origin codec, authentication or runtime enablement is added.
    final selected = await management.createProfile(
        displayName: 'Recreate', adapter: 'bridge', protocol: 'tcp-v1');
    expect(selected.profileId, isNot(ref.profileId));
    expect((await management.read(selected)).grant, isNull);
  });
  for (final revoked in [false, true]) {
    test(
        'checksummed package containing valid ${revoked ? 'revoked' : 'active'} auth rejected before swap',
        () async {
      if (revoked) {
        await management.revokeProfile(ref, 1);
      }
      final before = await authRows();
      final copyPath = p.join(h.temp.path, 'active.db');
      await snapshots.createRawConsistentSnapshot(copyPath);
      final path = await package(copyPath);
      await expectLater(
          runtime().prepareRestore(path),
          throwsA(isA<BackupException>().having((e) => e.failure,
              'fixed failure', BackupFailure.databaseInvalid)));
      expect(await authRows(), before);
    });
  }
  test(
      'failed swap rolls back original non-secret authorization, not portable scrub',
      () async {
    final before = await authRows();
    final proposal = await h.stage();
    final path = p.join(h.temp.path, 'rollback.shiroha');
    await runtime().exportTo(path);
    final restoring = runtime(faults: const _FailSwap());
    await restoring.prepareRestore(path);
    await expectLater(
        restoring.commitPreparedRestore(), throwsA(isA<BackupException>()));
    h.db = await h.helper.database;
    expect(await authRows(), before);
    expect((await h.repository.read(proposal.proposalId, h.local)).proposalId,
        proposal.proposalId);
    final grant = await management.inspectGrant(ref,
        expectedRevision: 1,
        permission: CapabilityPermission.read,
        scope:
            ExternalGrantScope(kind: ExternalTargetKind.bank, targetId: 'bank'),
        category: ExternalContentCategory.questionContent,
        recipientProfileId: ref.profileId);
    expect(grant.revision, 1);
  });
  test(
      'v32 portable package migrates staged only and restores empty auth tables',
      () async {
    final copyPath = p.join(h.temp.path, 'old.db');
    await snapshots.createSanitizedSnapshot(copyPath);
    final copy = await databaseFactory.openDatabase(copyPath);
    await copy.execute('PRAGMA foreign_keys=ON');
    await installLegacyGeneratedHeaderFixture(copy);
    for (final table in externalAuthorizationTables.reversed) {
      await copy.execute('DROP TABLE $table');
    }
    await copy.setVersion(32);
    await copy.close();
    final before = await authRows();
    final path = await package(copyPath, version: 32);
    final restoring = runtime();
    await restoring.prepareRestore(path);
    expect(await authRows(), before);
    await restoring.commitPreparedRestore();
    h.db = await h.helper.database;
    expect(await h.db.getVersion(), 34);
    for (final table in externalAuthorizationTables) {
      expect(await h.db.query(table), isEmpty);
    }
  });
  test('corrupt live authorization fails export before scrub can conceal it',
      () async {
    await h.db.execute('PRAGMA ignore_check_constraints=ON');
    await h.db.update('external_grants', {'allow_read': 9});
    await h.db.execute('PRAGMA ignore_check_constraints=OFF');
    final before = await authRows();
    final path = p.join(h.temp.path, 'unpublished.shiroha');
    await expectLater(
        runtime().exportTo(path),
        throwsA(isA<BackupException>().having(
            (e) => e.failure, 'fixed failure', BackupFailure.databaseInvalid)));
    expect(File(path).existsSync(), isFalse);
    expect(await authRows(), before);
  });
}
