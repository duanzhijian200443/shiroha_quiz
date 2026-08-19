import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
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

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory temp;
  late Directory dbDir;
  late Directory managedRoot;
  late Directory restoreRoot;
  late ManagedFileStorageAdapter storage;
  late DatabaseHelper helper;
  late BackupSnapshotRepository snapshots;
  late BackupRestoreRuntime runtime;
  late List<int> fileBytes;
  late String fileHash;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('b0_accept_');
    dbDir = Directory(p.join(temp.path, 'db'))..createSync(recursive: true);
    managedRoot = Directory(p.join(temp.path, 'managed'))
      ..createSync(recursive: true);
    restoreRoot = Directory(p.join(temp.path, 'restore'))
      ..createSync(recursive: true);
    await databaseFactory.setDatabasesPath(dbDir.path);
    DatabaseHelper.configureRuntimeProfile(
      DatabaseRuntimeProfile.explicitFile,
      databasePath: dbDir.path,
    );
    helper = DatabaseHelper.instance;
    snapshots = BackupSnapshotRepository(databaseHelper: helper);
    storage = ManagedFileStorageAdapter(managedRoot: managedRoot);
    runtime = BackupRestoreRuntime(
      databaseAuthority: SqliteBackupDatabaseAuthority(
        databaseHelper: helper,
        snapshotRepository: snapshots,
      ),
      snapshotRepository: snapshots,
      managedFileStorage: storage,
      restoreRoot: restoreRoot,
      managedFilesRoot: managedRoot,
      diskSpaceProbe: const _InfiniteDisk(),
    );

    fileBytes = 'library-bytes-sentinel'.codeUnits;
    final source = File(p.join(temp.path, 'source.txt'));
    await source.writeAsBytes(fileBytes, flush: true);
    await storage.copyIntoManagedStorage(
      externalPath: source.path,
      storageKey: 'library/file-1',
    );
    fileHash = BackupFilesystem.sha256File(
      storage.resolveManagedFile('library/file-1').path,
    );

    final db = await helper.database;
    await db.insert('questions', <String, Object?>{
      'id': 'q-1',
      'type': 0,
      'content': 'QUESTION_CONTENT_SENTINEL',
      'options': '[]',
      'standard_answer': 'answer',
      'explanation': 'explain',
      'raw_explanation': null,
      'created_at': 1,
      'bank_name': '默认题库',
    });
    await db.insert('question_v2_payloads', <String, Object?>{
      'question_id': 'q-1',
      'payload_schema_version': 1,
      'payload_json': '{"content":"QUESTION_CONTENT_SENTINEL"}',
    });
    await db.insert('review_states', <String, Object?>{
      'question_id': 'q-1',
      'state': 2,
      'next_review_time': 99,
      'lapses': 1,
      'difficulty': 5.0,
      'stability': 1.0,
      'reps': 3,
      'last_lapse_time': 1,
      'last_review_time': 1,
    });
    await db.insert('review_logs', <String, Object?>{
      'id': 'log-1',
      'question_id': 'q-1',
      'grade': 3,
      'llm_score': 0.8,
      'review_time': 1,
      'duration_ms': 1000,
      'user_answer': 'user answer sentinel',
      'ai_evaluation': 'ai evaluation sentinel',
    });
    await db.insert('pomodoro_sessions', <String, Object?>{
      'id': 'pom-1',
      'bank_name': '默认题库',
      'start_time': 1,
      'end_time': 2,
      'target_duration': 25,
      'actual_duration': 20,
      'status': 1,
      'questions_solved': 3,
    });
    await db.insert('library_files', <String, Object?>{
      'file_id': 'file-1',
      'display_name': 'DISPLAY_FILENAME_SENTINEL.txt',
      'mime_type': 'text/plain',
      'size_bytes': fileBytes.length,
      'sha256': fileHash,
      'storage_key': 'library/file-1',
      'created_at': 1,
    });
    await db.insert('library_folders', <String, Object?>{
      'folder_id': 'folder-1',
      'display_name': 'folder',
      'created_at': 1,
    });
    await db.insert('library_file_folders', <String, Object?>{
      'file_id': 'file-1',
      'folder_id': 'folder-1',
    });
    await db.insert('projects', <String, Object?>{
      'project_id': 'project-1',
      'display_name': 'project',
      'created_at': 1,
    });
    await db.insert('project_files', <String, Object?>{
      'project_id': 'project-1',
      'file_id': 'file-1',
    });
    await db.insert('conversations', <String, Object?>{
      'conversation_id': 'conv-1',
      'scope_kind': 'global',
      'project_id': null,
      'title': 'title',
      'created_at': 1,
      'updated_at': 1,
    });
    await db.insert('conversation_messages', <String, Object?>{
      'message_id': 'msg-1',
      'conversation_id': 'conv-1',
      'sequence': 1,
      'role': 'user',
      'content': 'CONVERSATION_CONTENT_SENTINEL',
      'created_at': 1,
    });
    await db.insert('conversation_files', <String, Object?>{
      'conversation_id': 'conv-1',
      'file_id': 'file-1',
      'attached_at': 1,
    });
    await db.insert('study_plans', <String, Object?>{
      'plan_id': 'plan-1',
      'singleton_key': 1,
      'bank_name': '默认题库',
      'goal': 'goal',
      'daily_target': 10,
      'priority': 'balanced',
      'horizon_days': 7,
      'source_conversation_id': null,
      'source_user_message_id': null,
      'adopted_at': 1,
    });
    await db.insert('answer_attempts', <String, Object?>{
      'attempt_id': 'att-1',
      'question_id': 'q-1',
      'session_kind': 'normal',
      'modality': 'choice',
      'answer_payload_json':
          '{"version":1,"kind":"choice","option_ids":["opt_a"]}',
      'correctness': 1,
      'answered_at': 1,
      'duration_ms': 5000,
    });
    await db.insert('ai_engines', <String, Object?>{
      'id': 'engine-1',
      'engine_type': 'text',
      'name': 'engine metadata',
      'api_key': 'SECRET_API_KEY_SENTINEL',
      'base_url': 'ABSOLUTE_PATH_SENTINEL',
      'model_name': 'm',
      'temperature': 0.7,
      'reasoning_effort': '',
      'is_active': 0,
    });
    await db.insert('parsed_artifact_heads', <String, Object?>{
      'file_id': 'file-1',
      'last_revision': 1,
    });
    await db.insert('parsed_artifacts', <String, Object?>{
      'file_id': 'file-1',
      'artifact_id': 'artifact-1',
      'revision': 1,
      'source_sha256': fileHash,
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
      'title': 'import sentinel',
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
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  Future<String> exportPackage() async {
    final package = p.join(temp.path, 'package.shiroha');
    await runtime.exportTo(package);
    return package;
  }

  test(
      'populated current-schema round trip preserves durable state and excludes derived state',
      () async {
    final package = await exportPackage();
    final manifest = await BackupArchiveIo.readManifestOnly(package);
    final manifestJson = manifest.encode();
    for (final sentinel in <String>[
      'SECRET_API_KEY_SENTINEL',
      'ABSOLUTE_PATH_SENTINEL',
      'QUESTION_CONTENT_SENTINEL',
      'CONVERSATION_CONTENT_SENTINEL',
      'DISPLAY_FILENAME_SENTINEL',
    ]) {
      expect(manifestJson, isNot(contains(sentinel)), reason: sentinel);
    }

    // Mutate live durable state before restore.
    final db = await helper.database;
    await db.delete('questions');
    await storage
        .resolveManagedFile('library/file-1')
        .writeAsBytes('destroyed'.codeUnits, flush: true);

    final restoring = BackupRestoreRuntime(
      databaseAuthority: SqliteBackupDatabaseAuthority(
        databaseHelper: helper,
        snapshotRepository: snapshots,
      ),
      snapshotRepository: snapshots,
      managedFileStorage: storage,
      restoreRoot: restoreRoot,
      managedFilesRoot: managedRoot,
      diskSpaceProbe: const _InfiniteDisk(),
    );
    await restoring.prepareRestore(package);
    await restoring.commitPreparedRestore();

    final restored = await helper.database;
    expect((await restored.query('questions')).single['content'],
        'QUESTION_CONTENT_SENTINEL');
    expect((await restored.query('question_v2_payloads')).single['question_id'],
        'q-1');
    expect((await restored.query('review_logs')).single['id'], 'log-1');
    expect((await restored.query('pomodoro_sessions')).single['id'], 'pom-1');
    expect((await restored.query('conversations')).single['conversation_id'],
        'conv-1');
    expect((await restored.query('study_plans')).single['plan_id'], 'plan-1');
    expect((await restored.query('answer_attempts')).single['attempt_id'],
        'att-1');
    expect(
      storage.resolveManagedFile('library/file-1').readAsBytesSync(),
      fileBytes,
    );
    expect((await restored.query('ai_engines')).single['api_key'], '');

    final excluded = <String>[
      'parsed_artifacts',
      'parsed_artifact_heads',
      'retrieval_index_builds',
      'retrieval_index_heads',
      'retrieval_chunks',
      'retrieval_chunks_fts',
      'import_tasks',
    ];
    for (final table in excluded) {
      expect(await restored.query(table), isEmpty, reason: table);
    }

    // Restore the same package again; durable state must be identical.
    await restored.delete('questions');
    await storage
        .resolveManagedFile('library/file-1')
        .writeAsBytes('destroyed'.codeUnits, flush: true);
    final second = BackupRestoreRuntime(
      databaseAuthority: SqliteBackupDatabaseAuthority(
        databaseHelper: helper,
        snapshotRepository: snapshots,
      ),
      snapshotRepository: snapshots,
      managedFileStorage: storage,
      restoreRoot: restoreRoot,
      managedFilesRoot: managedRoot,
      diskSpaceProbe: const _InfiniteDisk(),
    );
    await second.prepareRestore(package);
    await second.commitPreparedRestore();
    final afterSecond = await helper.database;
    expect((await afterSecond.query('questions')).single['content'],
        'QUESTION_CONTENT_SENTINEL');
    expect(
      storage.resolveManagedFile('library/file-1').readAsBytesSync(),
      fileBytes,
    );
  });

  test(
      'restore rejects an unsanitized DB carrying credentials and derived rows',
      () async {
    final rawDb = p.join(temp.path, 'raw.shiroha.db');
    await snapshots.createRawConsistentSnapshot(rawDb);
    final rawManifest = BackupManifest(
      schemaVersion: BackupValues.currentSchemaVersion,
      createdAtUtc: DateTime.utc(2026),
      database: BackupDatabaseEntry(
        archivePath: BackupValues.databaseArchivePath,
        sizeBytes: File(rawDb).lengthSync(),
        sha256: BackupFilesystem.sha256File(rawDb),
      ),
      managedFiles: <BackupManagedFileEntry>[
        BackupManagedFileEntry(
          fileId: 'file-1',
          storageKey: 'library/file-1',
          archivePath: BackupValues.managedArchivePath('file-1'),
          sizeBytes: fileBytes.length,
          sha256: fileHash,
        ),
      ],
    );
    final manifestPath = p.join(temp.path, 'raw_manifest.json');
    await File(manifestPath).writeAsString(rawManifest.encode(), flush: true);
    final rawPackage = p.join(temp.path, 'raw_package.shiroha');
    await BackupArchiveIo.writeStoredPackage(
      packagePath: rawPackage,
      manifestPath: manifestPath,
      databasePath: rawDb,
      files: <ArchiveSourceFile>[
        ArchiveSourceFile(
          fileId: 'file-1',
          path: storage.resolveManagedFile('library/file-1').path,
        ),
      ],
    );

    final restoring = BackupRestoreRuntime(
      databaseAuthority: SqliteBackupDatabaseAuthority(
        databaseHelper: helper,
        snapshotRepository: snapshots,
      ),
      snapshotRepository: snapshots,
      managedFileStorage: storage,
      restoreRoot: restoreRoot,
      managedFilesRoot: managedRoot,
      diskSpaceProbe: const _InfiniteDisk(),
    );
    await expectLater(
      restoring.prepareRestore(rawPackage),
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.databaseInvalid,
      )),
    );
  });

  test('corrupt manifest and missing/extra entries fail before commit',
      () async {
    final package = await exportPackage();
    final manifest = await BackupArchiveIo.readManifestOnly(package);

    // Bad JSON manifest + valid DB/file entries.
    final badManifest = p.join(temp.path, 'bad_manifest.shiroha');
    final fileSource =
        p.join(temp.path, 'extracted', 'files', 'library', 'file-1');
    final extracted = await BackupArchiveIo.extractAndValidate(
      packagePath: package,
      stagingRoot: p.join(temp.path, 'extracted'),
    );
    final badManifestPath = p.join(temp.path, 'bad_manifest.json');
    await File(badManifestPath).writeAsString('{', flush: true);
    await BackupArchiveIo.writeStoredPackage(
      packagePath: badManifest,
      manifestPath: badManifestPath,
      databasePath: extracted.databasePath,
      files: <ArchiveSourceFile>[
        ArchiveSourceFile(
            fileId: 'file-1', path: '${extracted.managedFilesRoot}/file-1'),
      ],
    );
    await expectLater(
      BackupArchiveIo.readManifestOnly(badManifest),
      throwsA(isA<BackupException>()),
    );

    // Missing database entry.
    final missingDb = p.join(temp.path, 'missing_db.shiroha');
    final missingDbManifestPath = p.join(temp.path, 'missing_db_manifest.json');
    final manifestWithFile = BackupManifest(
      schemaVersion: manifest.schemaVersion,
      createdAtUtc: manifest.createdAtUtc,
      database: manifest.database,
      managedFiles: manifest.managedFiles,
    );
    await File(missingDbManifestPath).writeAsString(
      manifestWithFile.encode(),
      flush: true,
    );
    final missingArchive = Archive();
    missingArchive.addFile(
      ArchiveFile.string('manifest.json', manifestWithFile.encode()),
    );
    final missingOutput = OutputFileStream(missingDb);
    ZipEncoder().encode(missingArchive, output: missingOutput);
    missingOutput.closeSync();
    await expectLater(
      BackupArchiveIo.extractAndValidate(
        packagePath: missingDb,
        stagingRoot: p.join(temp.path, 'staging_missing_db'),
      ),
      throwsA(isA<BackupException>()),
    );

    // Extra unknown entry.
    final extraPackage = p.join(temp.path, 'extra.shiroha');
    final dbBytes = File(extracted.databasePath).readAsBytesSync();
    final file1Bytes = File(fileSource).readAsBytesSync();
    final extraArchive = Archive()
      ..addFile(ArchiveFile.string('manifest.json', manifest.encode()))
      ..addFile(ArchiveFile('database/shiroha.db', dbBytes.length, dbBytes))
      ..addFile(
          ArchiveFile('files/library/file-1', file1Bytes.length, file1Bytes))
      ..addFile(ArchiveFile.string('unexpected.txt', 'x'));
    final extraOutput = OutputFileStream(extraPackage);
    ZipEncoder().encode(extraArchive, output: extraOutput);
    extraOutput.closeSync();
    await expectLater(
      BackupArchiveIo.extractAndValidate(
        packagePath: extraPackage,
        stagingRoot: p.join(temp.path, 'staging_extra'),
      ),
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.invalidPackage,
      )),
    );
  });
}
