import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/study_activity_v30_schema.dart';
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

final class _Disk implements BackupDiskSpaceProbe {
  const _Disk();
  @override
  Future<int?> availableBytes(String path) async => 1 << 40;
}

final _invalid = throwsA(isA<BackupException>()
    .having((e) => e.failure, 'safe code', BackupFailure.databaseInvalid));

Future<void> _facts(Database db, String id, {String status = 'active'}) async {
  await db.insert(studyActivitySessionsTable, {
    'session_id': id,
    'scene': 'mockExam',
    'lifecycle_status': status,
    'started_at_utc_ms': 1000,
    'last_checkpoint_at_utc_ms': 100,
    'checkpoint_sequence': 1,
    'revision': 2,
    'ended_at_utc_ms': status == 'ended' ? 100 : null,
    'end_reason': status == 'ended' ? 'submitted' : null,
    'category_key': '["folder","Exact 数学"]',
    'content_id': 'deleted',
    'bank_name': 'deleted',
    'plan_id': 'stopped',
    'paper_id': 'deleted',
  });
  await db.insert(studyActivitySegmentsTable, {
    'segment_id': '$id-segment',
    'session_id': id,
    'sequence': 3,
    'local_date': '2026-10-05',
    'utc_offset_minutes': 330,
    'start_utc_ms': 90,
    'end_utc_ms': 99,
    'duration_ms': 59999,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late Directory managed;
  late Directory restore;
  final helper = DatabaseHelper.instance;
  late BackupSnapshotRepository snapshots;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    temp = await Directory.systemTemp.createTemp('activity_b0_');
    final live = Directory(p.join(temp.path, 'live'))..createSync();
    managed = Directory(p.join(temp.path, 'managed'))..createSync();
    restore = Directory(p.join(temp.path, 'restore'))..createSync();
    DatabaseHelper.configureRuntimeProfile(DatabaseRuntimeProfile.explicitFile,
        databasePath: live.path);
    snapshots = BackupSnapshotRepository(databaseHelper: helper);
  });
  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    await temp.delete(recursive: true);
  });
  BackupRestoreRuntime runtime() => BackupRestoreRuntime(
      databaseAuthority: SqliteBackupDatabaseAuthority(
          databaseHelper: helper, snapshotRepository: snapshots),
      snapshotRepository: snapshots,
      managedFileStorage: ManagedFileStorageAdapter(managedRoot: managed),
      restoreRoot: restore,
      managedFilesRoot: managed,
      diskSpaceProbe: const _Disk());
  Future<String> package(String path, int version, String name) async {
    final manifest = BackupManifest(
        packageVersion: 2,
        schemaVersion: version,
        createdAtUtc: DateTime.utc(2026),
        database: BackupDatabaseEntry(
            archivePath: BackupValues.databaseArchivePath,
            sizeBytes: File(path).lengthSync(),
            sha256: BackupFilesystem.sha256File(path)),
        managedFiles: const []);
    final json = p.join(temp.path, '$name.json');
    await File(json).writeAsString(manifest.encode());
    final result = p.join(temp.path, '$name.shiroha');
    await BackupArchiveIo.writeStoredPackage(
        packagePath: result,
        manifestPath: json,
        databasePath: path,
        files: const []);
    return result;
  }

  test(
      'snapshot closes active/paused only in copy, keeping segments and live facts',
      () async {
    final live = await helper.database;
    await _facts(live, 'active');
    await _facts(live, 'paused', status: 'paused');
    await _facts(live, 'ended', status: 'ended');
    final before =
        await live.query(studyActivitySessionsTable, orderBy: 'session_id');
    final segments =
        await live.query(studyActivitySegmentsTable, orderBy: 'session_id');
    final path = p.join(temp.path, 'snapshot.db');
    final snap = await snapshots.createSanitizedSnapshot(path);
    expect(snap.schemaVersion, DatabaseHelper.databaseVersion);
    final copy = await databaseFactory.openDatabase(path);
    try {
      for (final row in await copy.query(studyActivitySessionsTable)) {
        expect(row['ended_at_utc_ms'], 100);
        expect(row['checkpoint_sequence'], 1);
        expect(row['revision'], row['session_id'] == 'ended' ? 2 : 3);
        expect(row['end_reason'],
            row['session_id'] == 'ended' ? 'submitted' : 'snapshotInterrupted');
      }
      expect(
          await copy.query(studyActivitySegmentsTable, orderBy: 'session_id'),
          segments);
      await snapshots.validateScrubInvariantsOn(copy);
    } finally {
      await copy.close();
    }
    expect(await live.query(studyActivitySessionsTable, orderBy: 'session_id'),
        before);
    expect(await live.query(studyActivitySegmentsTable, orderBy: 'session_id'),
        segments);
  });

  test(
      'v30 package2 roundtrip preserves soft context and duration/offset facts',
      () async {
    final live = await helper.database;
    await _facts(live, 's');
    final segment = (await live.query(studyActivitySegmentsTable)).single;
    final file = p.join(temp.path, 'roundtrip.shiroha');
    await runtime().exportTo(file);
    final manifest = await BackupArchiveIo.readManifestOnly(file);
    expect(manifest.packageVersion, 2);
    expect(manifest.schemaVersion, DatabaseHelper.databaseVersion);
    await live.delete(studyActivitySessionsTable);
    final restoring = runtime();
    await restoring.prepareRestore(file);
    await restoring.commitPreparedRestore();
    final restored = await helper.database;
    expect(
        (await restored.query(studyActivitySessionsTable)).single['end_reason'],
        'snapshotInterrupted');
    expect(
        (await restored.query(studyActivitySessionsTable)).single['content_id'],
        'deleted');
    expect((await restored.query(studyActivitySegmentsTable)).single, segment);
    expect(await restored.query('questions'), isEmpty);
    await validateStudyActivityV30Data(restored);
  });

  for (final corruption in [
    'active-owner',
    'matrix',
    'category',
    'date',
    'negative-duration',
    'orphan',
    'index',
    'fifth-scene'
  ]) {
    test('portable $corruption rejected before swap; source/live unchanged',
        () async {
      final live = await helper.database;
      await _facts(live, 'keep', status: 'ended');
      final path = p.join(temp.path, '$corruption.db');
      await snapshots.createSanitizedSnapshot(path);
      final candidate = await databaseFactory.openDatabase(path);
      await candidate.execute('PRAGMA foreign_keys=OFF');
      await candidate.execute('PRAGMA ignore_check_constraints=ON');
      switch (corruption) {
        case 'active-owner':
          await candidate.update(studyActivitySessionsTable, {
            'lifecycle_status': 'active',
            'end_reason': null,
            'ended_at_utc_ms': null
          });
        case 'matrix':
          await candidate.update(studyActivitySessionsTable,
              {'lifecycle_status': 'interrupted', 'end_reason': 'submitted'});
        case 'category':
          await candidate.update(studyActivitySessionsTable,
              {'category_key': '[ "uncategorized" ]'});
        case 'date':
          await candidate
              .update(studyActivitySegmentsTable, {'local_date': '2026-02-30'});
        case 'negative-duration':
          await candidate
              .update(studyActivitySegmentsTable, {'duration_ms': -1});
        case 'orphan':
          await candidate
              .update(studyActivitySegmentsTable, {'session_id': 'missing'});
        case 'index':
          await candidate.execute('DROP INDEX idx_study_activity_local_date');
        case 'fifth-scene':
          await candidate.update(
              studyActivitySessionsTable, {'scene': 'singleQuestionStudy'});
      }
      final sourceRows = [
        await candidate.query(studyActivitySessionsTable),
        await candidate.query(studyActivitySegmentsTable)
      ];
      await candidate.close();
      final file = await package(path, 30, corruption);
      await expectLater(runtime().prepareRestore(file), _invalid);
      final original = await helper.database;
      expect(
          (await original.query(studyActivitySessionsTable))
              .single['session_id'],
          'keep');
      final probe = await databaseFactory.openDatabase(path);
      expect([
        await probe.query(studyActivitySessionsTable),
        await probe.query(studyActivitySegmentsTable)
      ], sourceRows);
      await probe.close();
    });
  }

  test(
      'invalid live active matrix fails export rather than being sanitized into valid state',
      () async {
    final db = await helper.database;
    await _facts(db, 'bad');
    await db.execute('PRAGMA ignore_check_constraints=ON');
    await db.update(studyActivitySessionsTable, {'end_reason': 'exited'});
    final before = await db.query(studyActivitySessionsTable);
    final path = p.join(temp.path, 'rejected.db');
    await expectLater(snapshots.createSanitizedSnapshot(path), _invalid);
    expect(await File(path).exists(), isFalse);
    expect(await db.query(studyActivitySessionsTable), before);
  });

  test(
      'old v29 staged migration empty Activity, source stays v29 until copy swap',
      () async {
    final live = await helper.database;
    await _facts(live, 'keep', status: 'ended');
    final path = p.join(temp.path, 'v29.db');
    await snapshots.createSanitizedSnapshot(path);
    final old = await databaseFactory.openDatabase(path);
    await old.delete(studyActivitySessionsTable);
    await old.execute('DROP TABLE study_activity_segments');
    await old.execute('DROP TABLE study_activity_sessions');
    await old.setVersion(29);
    await old.close();
    final file = await package(path, 29, 'legacy');
    final restoring = runtime();
    await restoring.prepareRestore(file);
    expect((await live.query(studyActivitySessionsTable)).single['session_id'],
        'keep');
    final source = await databaseFactory.openDatabase(path);
    expect(await source.getVersion(), 29);
    await source.close();
    await restoring.commitPreparedRestore();
    final restored = await helper.database;
    expect(await restored.getVersion(), DatabaseHelper.databaseVersion);
    expect(await restored.query(studyActivitySessionsTable), isEmpty);
    expect(await restored.query(studyActivitySegmentsTable), isEmpty);
  });
}
