import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/services/backup/backup_archive_io.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';

final class _InfiniteDisk implements BackupDiskSpaceProbe {
  const _InfiniteDisk();
  @override
  Future<int?> availableBytes(String path) async => 1 << 40;
}

final class _PublishFailureFaults extends BackupFaultInjector {
  _PublishFailureFaults(this.expectedTempPath);

  final String expectedTempPath;
  bool observedVerifiedSibling = false;

  @override
  Future<void> beforeExportPublish() async {
    observedVerifiedSibling = File(expectedTempPath).existsSync();
    throw StateError('synthetic publish failure');
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory temp;
  late Directory dbDir;
  late Directory managedRoot;
  late Directory restoreRoot;
  late ManagedFileStorageAdapter storage;
  late BackupRestoreRuntime runtime;

  BackupRestoreRuntime buildRuntime({
    BackupFaultInjector faultInjector = const BackupFaultInjector(),
    String Function()? operationIdFactory,
  }) {
    final helper = DatabaseHelper.instance;
    final snapshots = BackupSnapshotRepository(databaseHelper: helper);
    return BackupRestoreRuntime(
      databaseAuthority: SqliteBackupDatabaseAuthority(
        databaseHelper: helper,
        snapshotRepository: snapshots,
      ),
      snapshotRepository: snapshots,
      managedFileStorage: storage,
      restoreRoot: restoreRoot,
      managedFilesRoot: managedRoot,
      diskSpaceProbe: const _InfiniteDisk(),
      faultInjector: faultInjector,
      operationIdFactory: operationIdFactory,
    );
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('b0_export_');
    dbDir = Directory(p.join(temp.path, 'db'))..createSync(recursive: true);
    managedRoot = Directory(p.join(temp.path, 'managed'))
      ..createSync(recursive: true);
    restoreRoot = Directory(p.join(temp.path, 'restore'))
      ..createSync(recursive: true);
    await databaseFactory.setDatabasesPath(dbDir.path);
    storage = ManagedFileStorageAdapter(managedRoot: managedRoot);
    runtime = buildRuntime();
  });

  tearDown(() async {
    await DatabaseHelper.instance.close();
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  Future<void> populate({required String apiKeySentinel}) async {
    final db = await DatabaseHelper.instance.database;
    await db.insert('ai_engines', <String, Object?>{
      'id': 'engine-1',
      'engine_type': 'text',
      'name': 'engine',
      'api_key': apiKeySentinel,
      'base_url': 'https://example.invalid',
      'model_name': 'm',
      'temperature': 0.7,
      'reasoning_effort': '',
      'is_active': 0,
    });
    await db.insert('library_files', <String, Object?>{
      'file_id': 'file-1',
      'display_name': 'notes.txt',
      'mime_type': 'text/plain',
      'size_bytes': 6,
      'sha256':
          '6ca13d52ca70c883e0f0bb101e425a89e8624de51db2d2392593af6a84118090',
      'storage_key': 'library/file-1',
      'created_at': 1,
    });
    await db.insert('parsed_artifact_heads', <String, Object?>{
      'file_id': 'file-1',
      'last_revision': 1,
    });
    await db.insert('parsed_artifacts', <String, Object?>{
      'file_id': 'file-1',
      'artifact_id': 'artifact-1',
      'revision': 1,
      'source_sha256':
          '6ca13d52ca70c883e0f0bb101e425a89e8624de51db2d2392593af6a84118090',
      'cache_key_version': 1,
      'cache_fingerprint': 'fp',
      'parser_route': 'txt',
      'parser_version': '1',
      'options_schema_version': 1,
      'payload_schema_version': 1,
      'storage_key': 'artifacts/artifact-1',
      'payload_sha256': 'a' * 64,
      'size_bytes': 2,
      'published_at': 1,
    });
    await db.insert('retrieval_index_builds', <String, Object?>{
      'build_id': 'build-1',
      'file_id': 'file-1',
      'artifact_id': 'artifact-1',
      'revision': 1,
      'payload_digest': 'b' * 64,
      'chunker_version': '1',
      'lexical_projection_version': '1',
      'chunk_count': 1,
      'chunk_digest': 'c' * 64,
    });
    await db.insert('retrieval_index_heads', <String, Object?>{
      'file_id': 'file-1',
      'build_id': 'build-1',
    });
    await db.insert('retrieval_chunks', <String, Object?>{
      'chunk_id': 'chunk-1',
      'build_id': 'build-1',
      'ordinal': 0,
      'kind': 'paragraph',
      'locator': '0',
      'safe_heading': 'h',
      'heading': 'h',
      'body': 'body',
      'safe_content': 'safe',
      'content_hash': 'd' * 64,
      'part_ordinal': 0,
      'window_ordinal': 0,
    });
    await db.insert('import_tasks', <String, Object?>{
      'id': 'import-1',
      'title': 'task',
      'status': 1,
      'progress_text': 'progress',
      'percent': 0.5,
      'error_msg': 'err',
      'parsed_data': 'parsedData sentinel',
      'bank_name': '默认题库',
      'folder_name': null,
      'created_at': 1,
      'completed_at': null,
      'source_type': 'txt',
      'pending_chunks': 'pending sentinel',
      'failed_chunks': 'failed sentinel',
      'warnings': 'warn',
      'diagnostics': 'diagnostic sentinel',
    });
  }

  test('export produces sanitized package and leaves live DB unchanged',
      () async {
    const apiKeySentinel = 'SECRET_API_KEY_SENTINEL';
    await populate(apiKeySentinel: apiKeySentinel);

    final sourceBytes = 'abc123'.codeUnits;
    final source = File(p.join(temp.path, 'source.txt'));
    await source.writeAsBytes(sourceBytes, flush: true);
    await storage.copyIntoManagedStorage(
      externalPath: source.path,
      storageKey: 'library/file-1',
    );

    final packagePath = p.join(temp.path, 'out', 'backup.shiroha');
    final summary = await runtime.exportTo(packagePath);

    expect(summary.fileName, 'backup.shiroha');
    expect(summary.fileCount, 1);

    final manifest = await BackupArchiveIo.readManifestOnly(packagePath);
    expect(manifest.managedFiles.single.fileId, 'file-1');
    expect(manifest.managedFiles.single.sizeBytes, 6);

    final extracted = await BackupArchiveIo.extractAndValidate(
      packagePath: packagePath,
      stagingRoot: p.join(temp.path, 'verify'),
    );
    expect(
      File(p.join(extracted.managedFilesRoot, 'file-1')).readAsBytesSync(),
      sourceBytes,
    );

    final probe = await databaseFactory.openDatabase(extracted.databasePath);
    try {
      final engine = (await probe.query('ai_engines')).single;
      expect(engine['api_key'], '');

      final scrubbedTables = <String>[
        'parsed_artifacts',
        'parsed_artifact_heads',
        'retrieval_index_builds',
        'retrieval_index_heads',
        'retrieval_chunks',
        'retrieval_chunks_fts',
        'import_tasks',
      ];
      for (final table in scrubbedTables) {
        final rows = await probe.query(table);
        expect(rows, isEmpty, reason: table);
      }
      final library = (await probe.query('library_files')).single;
      expect(library['storage_key'], 'library/file-1');
    } finally {
      await probe.close();
    }

    final live = await DatabaseHelper.instance.database;
    final liveEngine = (await live.query('ai_engines')).single;
    expect(liveEngine['api_key'], apiKeySentinel);
  });

  test('existing destination survives a verified sibling publish failure',
      () async {
    await populate(apiKeySentinel: 'SECRET_API_KEY_SENTINEL');
    final source = File(p.join(temp.path, 'source.txt'));
    await source.writeAsBytes('abc123'.codeUnits, flush: true);
    await storage.copyIntoManagedStorage(
      externalPath: source.path,
      storageKey: 'library/file-1',
    );

    final destination = p.join(temp.path, 'out', 'backup.shiroha');
    await File(destination).parent.create(recursive: true);
    await File(destination).writeAsString('OLD_SENTINEL', flush: true);
    final expectedTemp = p.join(
      p.dirname(destination),
      'backup.shiroha.publish-test.tmp',
    );
    final faults = _PublishFailureFaults(expectedTemp);
    final publishing = buildRuntime(
      faultInjector: faults,
      operationIdFactory: () => 'publish-test',
    );

    await expectLater(
      publishing.exportTo(destination),
      throwsA(isA<StateError>()),
    );
    expect(await File(destination).readAsString(), 'OLD_SENTINEL');
    expect(faults.observedVerifiedSibling, isTrue);
    expect(p.dirname(expectedTemp), p.dirname(destination));
    expect(File(expectedTemp).existsSync(), isFalse);
    expect(
      File('$destination.publish-test.bak').existsSync(),
      isFalse,
    );
  });

  test('missing managed original fails export with no final package', () async {
    await populate(apiKeySentinel: 'SECRET_API_KEY_SENTINEL');
    final packagePath = p.join(temp.path, 'out', 'backup.shiroha');
    await expectLater(
      runtime.exportTo(packagePath),
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.integrityMismatch,
      )),
    );
    expect(File(packagePath).existsSync(), isFalse);
  });

  test('mutated managed original fails export', () async {
    await populate(apiKeySentinel: 'SECRET_API_KEY_SENTINEL');
    final source = File(p.join(temp.path, 'source.txt'));
    await source.writeAsBytes('abc123'.codeUnits, flush: true);
    await storage.copyIntoManagedStorage(
      externalPath: source.path,
      storageKey: 'library/file-1',
    );
    await storage.resolveManagedFile('library/file-1').writeAsBytes(
          'mutated'.codeUnits,
          flush: true,
        );

    await expectLater(
      runtime.exportTo(p.join(temp.path, 'backup.shiroha')),
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.integrityMismatch,
      )),
    );
  });
}
