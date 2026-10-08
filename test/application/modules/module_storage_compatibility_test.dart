import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/application/modules/module_composition.dart';
import 'package:shiroha_quiz/application/modules/production_modules.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_draft_service.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/data/repositories/study_plan_persistence_repository.dart';
import 'package:shiroha_quiz/data/repositories/study_plan_read_repository.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/domain/backup/backup_values.dart';
import 'package:shiroha_quiz/services/backup/backup_archive_io.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_filesystem.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';

final class _Disk implements BackupDiskSpaceProbe {
  const _Disk();
  @override
  Future<int?> availableBytes(String path) async => 1 << 40;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  late Directory temp;
  late Directory managed;
  late Directory restore;
  final helper = DatabaseHelper.instance;
  late BackupSnapshotRepository snapshots;
  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    temp = await Directory.systemTemp.createTemp('r4_storage_');
    final live = Directory(p.join(temp.path, 'live'))..createSync();
    managed = Directory(p.join(temp.path, 'managed'))..createSync();
    restore = Directory(p.join(temp.path, 'restore'))..createSync();
    DatabaseHelper.configureRuntimeProfile(DatabaseRuntimeProfile.explicitFile,
        databasePath: live.path);
    snapshots = BackupSnapshotRepository(databaseHelper: helper);
    final db = await helper.database;
    await db.insert('study_plans', {
      'plan_id': 'plan-r4',
      'singleton_key': 1,
      'bank_name': '默认题库',
      'goal': 'Synthetic goal',
      'daily_target': 10,
      'priority': 'balanced',
      'horizon_days': 7,
      'source_conversation_id': null,
      'source_user_message_id': null,
      'adopted_at': 1000,
    });
  });
  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    await temp.delete(recursive: true);
  });
  ModuleComposition compose(bool enabled) => const ModuleComposer().compose([
        if (enabled)
          studyPlanModule(StudyPlanDraftService(
              planningPort: StudyPlanReadRepository(databaseHelper: helper),
              draftIdFactory: () => 'draft-r4',
              clock: () => DateTime.utc(2026, 10, 8)))
      ]);
  BackupRestoreRuntime runtime() => BackupRestoreRuntime(
      databaseAuthority: SqliteBackupDatabaseAuthority(
          databaseHelper: helper, snapshotRepository: snapshots),
      snapshotRepository: snapshots,
      managedFileStorage: ManagedFileStorageAdapter(managedRoot: managed),
      restoreRoot: restore,
      managedFilesRoot: managed,
      diskSpaceProbe: const _Disk());
  Future<List<Map<String, Object?>>> schema(Database db) => db.rawQuery(
      "SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name");
  test(
      'published StudyPlan survives disable, storage restart, B0 roundtrip and re-enable with identical schema',
      () async {
    final db = await helper.database;
    final schemaBefore = await schema(db);
    final rows = await db.query('study_plans');
    final dataVersion = (await db.rawQuery('PRAGMA user_version')).single;
    expect(dataVersion['user_version'], DatabaseHelper.databaseVersion);
    expect(compose(true).agentSurface.projections.single.definition.name,
        'propose_study_plan');
    expect(compose(false).capabilities.definitions, isEmpty);
    await helper.close();
    final reopened = await helper.database;
    expect(await schema(reopened), schemaBefore);
    expect(await reopened.query('study_plans'), rows);
    final reader = StudyPlanPersistenceRepository(databaseHelper: helper);
    expect((await reader.loadActivePlan())!.planId, 'plan-r4');
    await DatabaseHelper.validateStagedBackupSchema(reopened);
    final package = p.join(temp.path, 'roundtrip.shiroha');
    final backup = runtime();
    await backup.exportTo(package);
    final manifest = await BackupArchiveIo.readManifestOnly(package);
    expect(manifest.schemaVersion, DatabaseHelper.databaseVersion);
    expect(manifest.packageVersion, BackupValues.currentPackageVersion);
    await reopened.delete('study_plans');
    await backup.prepareRestore(package);
    await backup.commitPreparedRestore();
    final restored = await helper.database;
    expect(await restored.query('study_plans'), rows);
    expect(await schema(restored), schemaBefore);
    expect(
        (await restored.rawQuery('PRAGMA user_version')).single, dataVersion);
    await DatabaseHelper.validateStagedBackupSchema(restored);
    expect(compose(true).capabilities.definitions.single.id.value,
        'propose_study_plan');
    final plan = (await reader.loadActivePlan())!;
    expect(plan.planId, 'plan-r4');
    expect(plan.dailyTarget, 10);
    expect(plan.goal, 'Synthetic goal');
    expect(plan.sourceConversationId, isNull);
  });
  test(
      'disabled runtime cannot bypass published-data corruption in B0 admission',
      () async {
    expect(compose(false).agentSurface.projections, isEmpty);
    final snapshotPath = p.join(temp.path, 'corrupt.db');
    final snapshot = await snapshots.createSanitizedSnapshot(snapshotPath);
    final corrupted = await databaseFactory.openDatabase(snapshotPath);
    await corrupted.execute('PRAGMA ignore_check_constraints = ON');
    await corrupted.update('study_plans', {'daily_target': 0});
    await corrupted.close();
    final manifest = BackupManifest(
        packageVersion: BackupValues.currentPackageVersion,
        schemaVersion: snapshot.schemaVersion,
        createdAtUtc: DateTime.utc(2026, 10, 8),
        database: BackupDatabaseEntry(
            archivePath: BackupValues.databaseArchivePath,
            sizeBytes: File(snapshotPath).lengthSync(),
            sha256: BackupFilesystem.sha256File(snapshotPath)),
        managedFiles: const []);
    final manifestPath = p.join(temp.path, 'manifest.json');
    await File(manifestPath).writeAsString(manifest.encode());
    final package = p.join(temp.path, 'corrupt.shiroha');
    await BackupArchiveIo.writeStoredPackage(
        packagePath: package,
        manifestPath: manifestPath,
        databasePath: snapshotPath,
        files: const []);
    final live = await helper.database;
    final before = await live.query('study_plans');
    await expectLater(
        runtime().prepareRestore(package),
        throwsA(isA<BackupException>().having((e) => e.failure,
            'fixed corruption code', BackupFailure.databaseInvalid)));
    expect(await live.query('study_plans'), before);
    expect(
        (await StudyPlanPersistenceRepository(databaseHelper: helper)
                .loadActivePlan())!
            .dailyTarget,
        10);
  });
}
