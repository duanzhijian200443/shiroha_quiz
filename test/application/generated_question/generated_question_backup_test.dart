import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/application/modules/module_composition.dart';
import 'package:shiroha_quiz/application/modules/generated_question_module.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/generated_proposal_schema.dart';
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
import 'generated_test_support.dart';

final class _Disk implements BackupDiskSpaceProbe {
  const _Disk();
  @override
  Future<int?> availableBytes(String path) async => 1 << 40;
}

void main() {
  initializeGeneratedTests();
  late GeneratedHarness h;
  late Directory managed, restore;
  late BackupSnapshotRepository snapshots;
  setUp(() async {
    h = GeneratedHarness();
    await h.open();
    managed = Directory(p.join(h.temp.path, 'managed'))..createSync();
    restore = Directory(p.join(h.temp.path, 'restore'))..createSync();
    snapshots = BackupSnapshotRepository(databaseHelper: h.helper);
  });
  tearDown(() async => h.close());
  BackupRestoreRuntime runtime() => BackupRestoreRuntime(
      databaseAuthority: SqliteBackupDatabaseAuthority(
          databaseHelper: h.helper, snapshotRepository: snapshots),
      snapshotRepository: snapshots,
      managedFileStorage: ManagedFileStorageAdapter(managedRoot: managed),
      restoreRoot: restore,
      managedFilesRoot: managed,
      diskSpaceProbe: const _Disk());
  ModuleComposition compose(bool enabled) => const ModuleComposer()
      .compose([if (enabled) generatedQuestionModule(h.service)]);
  Future<String> package(String dbPath,
      {int version = 34, String name = 'candidate'}) async {
    final manifest = BackupManifest(
        packageVersion: 2,
        schemaVersion: version,
        createdAtUtc: DateTime.utc(2026),
        database: BackupDatabaseEntry(
            archivePath: BackupValues.databaseArchivePath,
            sizeBytes: File(dbPath).lengthSync(),
            sha256: BackupFilesystem.sha256File(dbPath)),
        managedFiles: const []);
    final manifestPath = p.join(h.temp.path, '$name.json');
    await File(manifestPath).writeAsString(manifest.encode());
    final result = p.join(h.temp.path, '$name.shiroha');
    await BackupArchiveIo.writeStoredPackage(
        packagePath: result,
        manifestPath: manifestPath,
        databasePath: dbPath,
        files: const []);
    return result;
  }

  test(
      'disabled module restart B0 roundtrip preserves pending edits, committed receipt and formal Questions',
      () async {
    var pending = await h.stage(items: [candidate(stem: 'Pending candidate')]);
    pending = await h.flush(pending, [
      {
        'type': 'edit',
        'edit': {
          'field': 'explanation',
          'itemId': pending.items.single.itemId,
          'value': [
            {'type': 'block_math', 'latex': 'x=1'}
          ]
        }
      },
      {
        'type': 'decide',
        'itemId': pending.items.single.itemId,
        'decision': 'deferred'
      }
    ]);
    final committed = await h.decide(await h.stage(
        key: 'committed', items: [candidate(stem: 'Committed candidate')]));
    final receipt = await h.service.approve(h.approval(committed), h.local);
    expect(compose(true).capabilities.definitions, hasLength(1));
    expect(compose(true).agentSurface.projections, isEmpty);
    expect(compose(true).mcpSurface, isEmpty);
    expect(
        compose(true).uiContributions.single.key, 'generated_proposal_review');
    expect(compose(false).uiContributions, isEmpty);
    expect(compose(false).capabilities.definitions, isEmpty);
    await h.reopen();
    await DatabaseHelper.validateStagedBackupSchema(h.db);
    final path = p.join(h.temp.path, 'roundtrip.shiroha');
    await runtime().exportTo(path);
    final manifest = await BackupArchiveIo.readManifestOnly(path);
    expect(manifest.schemaVersion, 34);
    expect(manifest.packageVersion, 2);
    await h.db.delete('questions');
    final restoring = runtime();
    await restoring.prepareRestore(path);
    await restoring.commitPreparedRestore();
    h.db = await h.helper.database;
    expect((await h.repository.read(pending.proposalId, h.local)).toJson(),
        pending.toJson());
    expect(
        (await h.repository.read(committed.proposalId, h.local))
            .commitReceipt!
            .toJson(),
        receipt.toJson());
    expect(await h.count('questions'), 1);
    expect(await h.count('question_v2_payloads'), 1);
    expect(await h.count('review_states'), 1);
    expect(compose(true).capabilities.definitions, hasLength(1));
    expect(
        await h.db.rawQuery(
            "SELECT name FROM sqlite_master WHERE name IN ('external_client_profiles','external_grants')"),
        hasLength(2));
    expect(await h.db.query('external_client_profiles'), isEmpty);
    expect(await h.db.query('external_grants'), isEmpty);
  });
  for (final corrupt in ['payload', 'receipt', 'relationship', 'schema']) {
    test('checksummed corrupt $corrupt package is rejected before live swap',
        () async {
      final proposal = await h.decide(await h.stage());
      await h.service.approve(h.approval(proposal), h.local);
      final rows = await h.db.query('questions');
      final staged = p.join(h.temp.path, 'corrupt.db');
      await snapshots.createSanitizedSnapshot(staged);
      final copy = await databaseFactory.openDatabase(staged);
      switch (corrupt) {
        case 'payload':
          await copy.execute('DROP TRIGGER gq_terminal_review_immutable');
          await copy.update('generated_question_review_state',
              {'working_json': '{"secret":"synthetic"}'});
          await copy.execute(
              generatedProposalSchemaObjects['gq_terminal_review_immutable']!);
        case 'receipt':
          await copy.execute('DROP TRIGGER gq_receipt_immutable');
          await copy.update('generated_question_commit_receipts',
              {'receipt_json': '{"schemaVersion":1}'});
          await copy
              .execute(generatedProposalSchemaObjects['gq_receipt_immutable']!);
        case 'relationship':
          await copy.delete('generated_question_commit_items');
        case 'schema':
          await copy.execute('DROP INDEX idx_generated_pending_owner');
      }
      await copy.close();
      final path = await package(staged);
      final restoring = runtime();
      await expectLater(
          restoring.prepareRestore(path),
          throwsA(isA<BackupException>().having((e) => e.failure,
              'fixed failure', BackupFailure.databaseInvalid)));
      expect(await h.db.query('questions'), rows);
      expect(
          (await h.repository.read(proposal.proposalId, h.local))
              .lifecycleStatus,
          GeneratedStatus.committed);
    });
  }
  test(
      'v31 package2 migrates staged only and keeps live state until explicit commit',
      () async {
    final staged = p.join(h.temp.path, 'old.db');
    await snapshots.createSanitizedSnapshot(staged);
    final copy = await databaseFactory.openDatabase(staged);
    for (final table in generatedProposalTables.reversed) {
      await copy.execute('DROP TABLE $table');
    }
    await copy.setVersion(31);
    await copy.close();
    final current = await h.stage();
    final path = await package(staged, version: 31, name: 'old');
    final restoring = runtime();
    await restoring.prepareRestore(path);
    expect((await h.repository.read(current.proposalId, h.local)).proposalId,
        current.proposalId);
    await restoring.commitPreparedRestore();
    h.db = await h.helper.database;
    expect(await h.db.getVersion(), 34);
    expect(await h.count('generated_question_proposals'), 0);
    await validateGeneratedProposalSchema(h.db);
  });
  test(
      'corrupt live proposal blocks export without mutating live rows when feature is disabled',
      () async {
    final proposal = await h.stage();
    expect(compose(false).capabilities.definitions, isEmpty);
    await h.db.update('generated_question_review_state', {'working_json': '{}'},
        where: 'proposal_id=?', whereArgs: [proposal.proposalId]);
    final before = await h.db.query('generated_question_review_state');
    final path = p.join(h.temp.path, 'not-published.shiroha');
    await expectLater(
        runtime().exportTo(path),
        throwsA(isA<BackupException>().having(
            (e) => e.failure, 'fixed failure', BackupFailure.databaseInvalid)));
    expect(File(path).existsSync(), isFalse);
    expect(await h.db.query('generated_question_review_state'), before);
  });
}
