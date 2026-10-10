import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/external_authorization_schema.dart';
import 'package:shiroha_quiz/core/database/generated_proposal_schema.dart';
import 'package:shiroha_quiz/data/repositories/external_authorization_repository.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/domain/backup/backup_values.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'package:shiroha_quiz/services/backup/backup_archive_io.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_filesystem.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'external_origin_test_support.dart';

final class _Disk implements BackupDiskSpaceProbe {
  const _Disk();
  @override
  Future<int?> availableBytes(String path) async => 1 << 40;
}

final class _SwapFailure extends BackupFaultInjector {
  const _SwapFailure();
  @override
  Future<void> beforePostSwapValidation() async =>
      throw const BackupException(BackupFailure.databaseInvalid);
}

void main() {
  initializeGeneratedTests();
  late GeneratedHarness h;
  late BackupSnapshotRepository snapshots;
  late Directory managed, restore;
  setUp(() async {
    h = GeneratedHarness();
    await h.open();
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
  Future<String> package(String path, int version) async {
    final manifest = BackupManifest(
        packageVersion: 2,
        schemaVersion: version,
        createdAtUtc: DateTime.utc(2026),
        database: BackupDatabaseEntry(
            archivePath: BackupValues.databaseArchivePath,
            sizeBytes: File(path).lengthSync(),
            sha256: BackupFilesystem.sha256File(path)),
        managedFiles: const []);
    final metadata = p.join(h.temp.path, 'manifest.json');
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
      'real B0 retains external/local/synthetic history and Questions; scrubs active/revoked auth',
      () async {
    final repo =
        SqliteExternalAuthorizationRepository(databaseHelper: h.helper);
    await repo.create(
        ExternalClientProfile(
            clientProfileId: externalFixtureProfile,
            displayName: 'Synthetic',
            adapter: 'bridge',
            protocol: 'tcp-v1',
            createdAtUtcMs: 0,
            grantRevision: 0),
        () {});
    await repo.change(
        externalFixtureProfile,
        0,
        ExternalGrantPolicy(permissions: [
          CapabilityPermission.stage
        ], scopes: [
          ExternalGrantScope(kind: ExternalTargetKind.bank, targetId: 'bank')
        ], categories: [
          ExternalContentCategory.proposalMetadata
        ]),
        1,
        false,
        () {});
    final external = await insertExternalHistory(h);
    final synthetic = await h
        .stage(key: 'synthetic', items: [candidate(stem: 'Other synthetic')]);
    // A genuine local context keeps the old v1 encoding; no Origin fallback.
    final localContext = GeneratedOriginContext(
        localOwner: 'owner',
        originKind: 'local',
        clientProfileId: 'local',
        target: h.target,
        evidence: const [],
        isCurrent: () => true);
    var local = (await h.service.stage(
            submission(
                key: 'local-real', items: [candidate(stem: 'Local committed')]),
            localContext))
        .proposal;
    local = await h.decide(local);
    await h.service.approve(h.approval(local), h.local);
    local = await h.repository.read(local.proposalId, h.local);
    final before = [external, synthetic, local];
    final originalAuth = await h.db.query('external_grants');
    final path = p.join(h.temp.path, 'roundtrip.shiroha');
    await runtime().exportTo(path);
    expect((await BackupArchiveIo.readManifestOnly(path)).packageVersion, 2);
    expect((await BackupArchiveIo.readManifestOnly(path)).schemaVersion, 34);
    expect(await h.db.query('external_grants'), originalAuth);
    await repo.change(externalFixtureProfile, 1, null, 2, true, () {});
    final restoring = runtime();
    await restoring.prepareRestore(path);
    await restoring.commitPreparedRestore();
    h.db = await h.helper.database;
    for (final table in externalAuthorizationTables) {
      expect(await h.db.query(table), isEmpty);
    }
    for (final proposal in before) {
      expect((await h.repository.read(proposal.proposalId, h.local)).toJson(),
          proposal.toJson());
    }
    expect(await h.count('questions'), 1);
    expect(await h.count('question_v2_payloads'), 1);
    await expectLater(
        repo.currentGrant(
            externalFixtureProfile,
            1,
            CapabilityPermission.stage,
            ExternalGrantScope(kind: ExternalTargetKind.bank, targetId: 'bank'),
            ExternalContentCategory.proposalMetadata,
            externalFixtureProfile),
        throwsA(isA<ExternalAuthException>()));
    final editable =
        await h.decide(await h.repository.read(external.proposalId, h.local));
    final receipt = await h.service.approve(h.approval(editable), h.local);
    expect(receipt.itemMappings, hasLength(1));
    expect(await h.count('questions'), 2);
  });
  for (final version in [32, 33]) {
    test(
        'old package v$version migrates staged only with legacy histories preserved',
        () async {
      final legacy = await h.stage();
      final copyPath = p.join(h.temp.path, 'old.db');
      await snapshots.createSanitizedSnapshot(copyPath);
      final copy = await databaseFactory.openDatabase(copyPath);
      await copy.execute('PRAGMA foreign_keys=ON');
      await installLegacyGeneratedHeaderFixture(copy);
      if (version == 32) {
        for (final table in externalAuthorizationTables.reversed) {
          await copy.execute('DROP TABLE $table');
        }
      }
      await copy.setVersion(version);
      await copy.close();
      final current = await insertExternalHistory(h);
      final destination = await package(copyPath, version);
      final restoring = runtime();
      await restoring.prepareRestore(destination);
      expect((await h.repository.read(current.proposalId, h.local)).toJson(),
          current.toJson());
      await restoring.commitPreparedRestore();
      h.db = await h.helper.database;
      expect(await h.db.getVersion(), 34);
      expect((await h.repository.read(legacy.proposalId, h.local)).toJson(),
          legacy.toJson());
      await expectLater(h.repository.read(current.proposalId, h.local),
          failure(GeneratedFailure.proposalUnavailable));
    });
  }
  test('checksummed malformed external payload rejects before live swap',
      () async {
    final history = await insertExternalHistory(h);
    final copyPath = p.join(h.temp.path, 'bad.db');
    await snapshots.createSanitizedSnapshot(copyPath);
    final copy = await databaseFactory.openDatabase(copyPath);
    await copy.execute('DROP TRIGGER gq_original_header_immutable');
    await copy
        .update('generated_question_proposals', {'external_origin_json': '{}'});
    await copy.execute(
        generatedProposalSchemaObjects['gq_original_header_immutable']!);
    await copy.close();
    final path = await package(copyPath, 34);
    await expectLater(
        runtime().prepareRestore(path),
        throwsA(isA<BackupException>().having(
            (e) => e.failure, 'fixed failure', BackupFailure.databaseInvalid)));
    expect((await h.repository.read(history.proposalId, h.local)).toJson(),
        history.toJson());
  });
  test('corrupt live origin blocks export without live mutation', () async {
    final history = await insertExternalHistory(h);
    await h.db.execute('DROP TRIGGER gq_original_header_immutable');
    await h.db
        .update('generated_question_proposals', {'external_origin_json': '{}'});
    await h.db.execute(
        generatedProposalSchemaObjects['gq_original_header_immutable']!);
    final before = await h.db.query('generated_question_proposals');
    final path = p.join(h.temp.path, 'unpublished.shiroha');
    await expectLater(
        runtime().exportTo(path),
        throwsA(isA<BackupException>().having(
            (e) => e.failure, 'fixed failure', BackupFailure.databaseInvalid)));
    expect(File(path).existsSync(), isFalse);
    expect(await h.db.query('generated_question_proposals'), before);
    expect(before.single['proposal_id'], history.proposalId);
  });
  test(
      'post-swap failure rolls back complete external history and original live auth',
      () async {
    final history = await insertExternalHistory(h);
    final repo =
        SqliteExternalAuthorizationRepository(databaseHelper: h.helper);
    await repo.create(
        ExternalClientProfile(
            clientProfileId: externalFixtureProfile,
            displayName: 'Synthetic',
            adapter: 'bridge',
            protocol: 'tcp-v1',
            createdAtUtcMs: 0,
            grantRevision: 0),
        () {});
    final profiles = await h.db.query('external_client_profiles');
    final path = p.join(h.temp.path, 'rollback.shiroha');
    await runtime().exportTo(path);
    final restoring = runtime(faults: const _SwapFailure());
    await restoring.prepareRestore(path);
    await expectLater(
        restoring.commitPreparedRestore(), throwsA(isA<BackupException>()));
    h.db = await h.helper.database;
    expect((await h.repository.read(history.proposalId, h.local)).toJson(),
        history.toJson());
    expect(await h.db.query('external_client_profiles'), profiles);
    await DatabaseHelper.validateStagedBackupSchema(h.db);
  });
}
