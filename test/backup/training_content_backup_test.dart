import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/training_content_v29_schema.dart';
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

final class _InfiniteDisk implements BackupDiskSpaceProbe {
  const _InfiniteDisk();
  @override
  Future<int?> availableBytes(String path) async => 1 << 40;
}

const _category = '["uncategorized"]';
const _tables = [
  trainingContentsTable,
  trainingContentMembersTable,
  trainingCategoryPreferencesTable,
  'app_settings'
];
final _databaseInvalid = throwsA(isA<BackupException>().having(
    (error) => error.failure, 'failure', BackupFailure.databaseInvalid));

Future<void> _question(Database db, String id, String bank) async {
  await db.insert('questions', {
    'id': id,
    'type': 0,
    'content': 'synthetic',
    'standard_answer': 'A',
    'bank_name': bank,
    'created_at': 1
  });
}

Future<void> _configuration(Database db) async {
  await _question(db, 'q', 'Bank');
  await db.insert(trainingContentsTable, {
    'content_id': 'content',
    'category_key': _category,
    'name': 'Synthetic',
    'question_limit': 40,
    'sort_order': 0,
    'revision': 2
  });
  await db.insert(trainingContentMembersTable, {
    'content_id': 'content',
    'bank_name': 'Bank',
    'weight_percent': 100,
    'position': 0,
    'binding_status': 'valid',
    'invalidation_reason': null
  });
  await db.insert(trainingCategoryPreferencesTable, {
    'category_key': _category,
    'visual_key': 'computerScience',
    'current_content_id': 'content',
    'revision': 3
  });
  await db.insert('app_settings',
      {'key': currentTrainingCategorySetting, 'value': _category});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late Directory managed;
  late Directory restoreRoot;
  final helper = DatabaseHelper.instance;
  late BackupSnapshotRepository snapshots;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    temp = await Directory.systemTemp.createTemp('training_b0_');
    final dbRoot = Directory(p.join(temp.path, 'live'))..createSync();
    managed = Directory(p.join(temp.path, 'managed'))..createSync();
    restoreRoot = Directory(p.join(temp.path, 'restore'))..createSync();
    DatabaseHelper.configureRuntimeProfile(DatabaseRuntimeProfile.explicitFile,
        databasePath: dbRoot.path);
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
      restoreRoot: restoreRoot,
      managedFilesRoot: managed,
      diskSpaceProbe: const _InfiniteDisk());

  Future<String> packageDatabase(String path, String name,
      {int version = 29}) async {
    final manifest = BackupManifest(
        schemaVersion: version,
        createdAtUtc: DateTime.utc(2026),
        database: BackupDatabaseEntry(
            archivePath: BackupValues.databaseArchivePath,
            sizeBytes: File(path).lengthSync(),
            sha256: BackupFilesystem.sha256File(path)),
        managedFiles: const []);
    final manifestPath = p.join(temp.path, '$name.json');
    await File(manifestPath).writeAsString(manifest.encode(), flush: true);
    final packagePath = p.join(temp.path, '$name.shiroha');
    await BackupArchiveIo.writeStoredPackage(
        packagePath: packagePath,
        manifestPath: manifestPath,
        databasePath: path,
        files: const []);
    return packagePath;
  }

  test(
      'v29 real export/restore preserves unavailable selection, zero weight and scrub rules',
      () async {
    final db = await helper.database;
    await _configuration(db);
    await db.update(trainingContentMembersTable, {'weight_percent': 50});
    await db.insert(trainingContentMembersTable, {
      'content_id': 'content',
      'bank_name': 'Deleted',
      'weight_percent': 50,
      'position': 1,
      'binding_status': 'invalidated',
      'invalidation_reason': 'bankMissing'
    });
    await _question(db, 'moved', 'Moved');
    await db
        .insert('bank_folders', {'bank_name': 'Moved', 'folder_name': 'Other'});
    await db.insert(trainingContentMembersTable, {
      'content_id': 'content',
      'bank_name': 'Moved',
      'weight_percent': 0,
      'position': 2,
      'binding_status': 'invalidated',
      'invalidation_reason': 'categoryChanged'
    });
    await db.insert(trainingContentsTable, {
      'content_id': 'unavailable',
      'category_key': '["folder","配置"]',
      'name': 'Unavailable',
      'question_limit': 1,
      'sort_order': 1,
      'revision': 1
    });
    await _question(db, 'hidden', '📦 模考专属题库');
    await db.insert(trainingContentMembersTable, {
      'content_id': 'unavailable',
      'bank_name': '📦 模考专属题库',
      'weight_percent': 100,
      'position': 0,
      'binding_status': 'invalidated',
      'invalidation_reason': 'bankIneligible'
    });
    await db.insert(trainingCategoryPreferencesTable, {
      'category_key': '["folder","配置"]',
      'visual_key': 'math',
      'current_content_id': 'unavailable',
      'revision': 1
    });
    // A structurally valid Category that is no longer displayable is legal.
    await db.update('app_settings', {'value': '["folder","已删除分类"]'},
        where: 'key = ?', whereArgs: [currentTrainingCategorySetting]);
    await db.insert('import_tasks', {
      'id': 'transient',
      'title': 'Synthetic',
      'status': 1,
      'progress_text': 'review',
      'percent': 1.0,
      'created_at': 1
    });
    final before = {
      for (final table in _tables)
        table: await db.query(table,
            orderBy: table == trainingContentMembersTable
                ? 'content_id, position'
                : null)
    };
    final package = p.join(temp.path, 'round-trip.shiroha');
    final exported = runtime();
    await exported.exportTo(package);
    expect(BackupValues.currentSchemaVersion, 29);
    expect(await db.query('import_tasks'), hasLength(1));
    expect(
        await db.query(trainingContentMembersTable,
            orderBy: 'content_id, position'),
        before[trainingContentMembersTable]);
    await db.delete(trainingCategoryPreferencesTable);
    await db.delete(trainingContentsTable);
    await db.delete('app_settings');
    final restoring = runtime();
    await restoring.prepareRestore(package);
    await restoring.commitPreparedRestore();
    final restored = await helper.database;
    for (final table in _tables) {
      expect(
          await restored.query(table,
              orderBy: table == trainingContentMembersTable
                  ? 'content_id, position'
                  : null),
          before[table],
          reason: table);
    }
    expect(await restored.query('import_tasks'), isEmpty);
    await validateTrainingContentV29Data(restored);
  });

  test('malformed live configuration fails export without repairing live rows',
      () async {
    final db = await helper.database;
    await _configuration(db);
    await db.update(trainingContentMembersTable, {'weight_percent': 99});
    final before = {for (final table in _tables) table: await db.query(table)};
    final snapshotPath = p.join(temp.path, 'rejected-export.db');
    await expectLater(
        snapshots.createSanitizedSnapshot(snapshotPath), _databaseInvalid);
    expect(await File(snapshotPath).exists(), isFalse);
    for (final table in _tables) {
      expect(await db.query(table), before[table], reason: table);
    }
  });

  final corruptions = <String, Future<void> Function(Database)>{
    'dangling-current': (db) async {
      await db.update(
          trainingCategoryPreferencesTable, {'current_content_id': 'missing'});
    },
    'cross-category-current': (db) async {
      await db.update(trainingCategoryPreferencesTable,
          {'category_key': '["folder","Other"]'});
    },
    'malformed-content-category': (db) async {
      await db.update(trainingContentsTable, {'category_key': 'not-json'});
    },
    'malformed-preference-category': (db) async {
      await db.update(
          trainingCategoryPreferencesTable, {'category_key': 'not-json'});
    },
    'noncanonical-category': (db) async {
      await db.update(
          trainingContentsTable, {'category_key': '[ "uncategorized" ]'});
    },
    'malformed-global-category': (db) async {
      await db.update('app_settings', {'value': 'not-json'},
          where: 'key = ?', whereArgs: [currentTrainingCategorySetting]);
    },
    'invalid-weight-sum': (db) async {
      await db.update(trainingContentMembersTable, {'weight_percent': 99});
    },
    'all-zero': (db) async {
      await db.update(trainingContentMembersTable, {'weight_percent': 0});
    },
    'empty-members': (db) async {
      await db.delete(trainingContentMembersTable);
    },
    'valid-missing-bank': (db) async {
      await db.delete('questions');
    },
    'valid-moved-bank': (db) async {
      await db.insert(
          'bank_folders', {'bank_name': 'Bank', 'folder_name': 'Moved'});
    },
    'valid-ineligible-bank': (db) async {
      await _question(db, 'hidden', '📦 模考专属题库');
      await db.update(trainingContentMembersTable, {'bank_name': '📦 模考专属题库'});
    },
    'missing-index': (db) => db.execute('DROP INDEX $trainingCategoryIndex'),
    'weakened-member-schema': (db) async {
      await db.execute('DROP TABLE $trainingContentMembersTable');
      await db.execute(trainingContentMembersDdl.replaceFirst(
          'UNIQUE(content_id, position),', ''));
      await db.insert(trainingContentMembersTable, {
        'content_id': 'content',
        'bank_name': 'Bank',
        'weight_percent': 100,
        'position': 0,
        'binding_status': 'valid'
      });
    },
  };
  for (final entry in corruptions.entries) {
    test(
        '${entry.key} fails shared export validation and staged restore without changing live DB',
        () async {
      final live = await helper.database;
      await _question(live, 'live-keep', 'Live');
      final candidatePath = p.join(temp.path, 'candidate.db');
      final candidate = await helper.openPathForTesting(candidatePath);
      await _configuration(candidate);
      await entry.value(candidate);
      await expectLater(
          snapshots.validateScrubInvariantsOn(candidate), _databaseInvalid);
      final rejectedRows = {
        for (final table in _tables) table: await candidate.query(table)
      };
      await candidate.close();
      final package = await packageDatabase(candidatePath, entry.key);
      await expectLater(runtime().prepareRestore(package), _databaseInvalid);
      final original = await helper.database;
      expect((await original.query('questions')).single['id'], 'live-keep');
      expect(await original.query(trainingContentsTable), isEmpty);
      // The source candidate is not "repaired" by staging or rejection.
      final probe = await databaseFactory.openDatabase(candidatePath);
      for (final table in _tables) {
        expect(await probe.query(table), rejectedRows[table], reason: table);
      }
      await probe.close();
    });
  }

  test('staged v28 upgrades/seeds while live DB remains unchanged until commit',
      () async {
    final live = await helper.database;
    await _question(live, 'live', 'Live');
    final candidatePath = p.join(temp.path, 'v28.db');
    final candidate = await helper.openPathForTesting(candidatePath);
    await _question(candidate, 'legacy', 'Legacy');
    await candidate
        .insert('app_settings', {'key': 'current_bank', 'value': 'Legacy'});
    await candidate.execute('DROP TABLE $trainingCategoryPreferencesTable');
    await candidate.execute('DROP TABLE $trainingContentMembersTable');
    await candidate.execute('DROP TABLE $trainingContentsTable');
    await candidate.setVersion(28);
    await candidate.close();
    final package = await packageDatabase(candidatePath, 'legacy', version: 28);
    final restoring = runtime();
    await restoring.prepareRestore(package);
    expect((await live.query('questions')).single['id'], 'live');
    expect(await live.query(trainingContentsTable), isEmpty);
    await restoring.commitPreparedRestore();
    final restored = await helper.database;
    expect(await restored.getVersion(), 29);
    expect(
        (await restored.query(trainingContentsTable)).single['name'], 'Legacy');
    expect((await restored.query('questions')).single['id'], 'legacy');
    await validateTrainingContentV29Data(restored);
  });

  test('newer schema rejected before swap with original live data retained',
      () async {
    final live = await helper.database;
    await _question(live, 'live', 'Live');
    final path = p.join(temp.path, 'newer.db');
    final db = await helper.openPathForTesting(path);
    await db.setVersion(30);
    await db.close();
    final package = await packageDatabase(path, 'newer', version: 30);
    await expectLater(
        runtime().prepareRestore(package),
        throwsA(isA<BackupException>().having((error) => error.failure,
            'failure', BackupFailure.unsupportedSchemaVersion)));
    expect((await live.query('questions')).single['id'], 'live');
    expect(await live.getVersion(), 29);
  });
}
