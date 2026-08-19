import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/file_library/library_file_deletion.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/observability/log_record.dart';
import 'package:shiroha_quiz/core/observability/log_writer.dart';
import 'package:shiroha_quiz/data/repositories/library_file_repository.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/services/file_library/library_file_deletion_service.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _fileId = 'file-delete-0001';

final class _StorageSpy implements ManagedFileStorage {
  _StorageSpy(this.delegate);

  final ManagedFileStorage delegate;
  int deleteCalls = 0;
  Object? deleteError;
  Future<void> Function()? beforeDelete;

  @override
  String allocateStorageKey(String fileId) =>
      delegate.allocateStorageKey(fileId);

  @override
  Future<ManagedFileCopyResult> copyIntoManagedStorage({
    required String externalPath,
    required String storageKey,
  }) {
    return delegate.copyIntoManagedStorage(
      externalPath: externalPath,
      storageKey: storageKey,
    );
  }

  @override
  File resolveManagedFile(String storageKey) =>
      delegate.resolveManagedFile(storageKey);

  @override
  Future<bool> managedFileExists(String storageKey) =>
      delegate.managedFileExists(storageKey);

  @override
  Future<void> deleteManagedFile(String storageKey) async {
    deleteCalls++;
    await beforeDelete?.call();
    final error = deleteError;
    if (error != null) throw error;
    await delegate.deleteManagedFile(storageKey);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ManagedFileStorageAdapter delegateStorage;
  late _StorageSpy storage;
  late LibraryFileRepository repository;
  late LibraryFileDeletionService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    tempDir = await Directory.systemTemp.createTemp('d2b_library_delete_');
    delegateStorage = ManagedFileStorageAdapter(
      managedRoot: Directory(p.join(tempDir.path, 'managed')),
    );
    storage = _StorageSpy(delegateStorage);
    repository = LibraryFileRepository();
    service = LibraryFileDeletionService(
      metadataRepository: repository,
      deletionRepository: repository,
      managedFileStorage: storage,
    );
  });

  tearDown(() async {
    LogWriter.setRecordHandler(null);
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<LibraryFile> seedFile({
    String storageKey = 'library/$_fileId',
  }) async {
    final source = File(p.join(tempDir.path, 'source.txt'));
    await source.writeAsString('abc', flush: true);
    final copy = await storage.copyIntoManagedStorage(
      externalPath: source.path,
      storageKey: storageKey,
    );
    final file = LibraryFile(
      fileId: _fileId,
      displayName: 'source.txt',
      mimeType: 'text/plain',
      sizeBytes: copy.sizeBytes,
      sha256: copy.sha256,
      storageKey: storageKey,
      createdAt: DateTime.utc(2026, 8, 19),
    );
    await repository.save(file);
    return file;
  }

  test('DB commit detaches project/session refs before managed-byte delete',
      () async {
    final file = await seedFile();
    final db = await DatabaseHelper.instance.database;
    await seedReferences(db, file.fileId);
    storage.beforeDelete = () async {
      expect(await db.query('library_files'), isEmpty);
      expect(await db.query('project_files'), isEmpty);
      expect(await db.query('conversation_files'), isEmpty);
      expect(await db.query('library_file_folders'), isEmpty);
    };

    final result = await service.deleteLibraryFile(file.fileId);

    expect(result.fileId, file.fileId);
    expect(result.projectReferenceCount, 1);
    expect(result.conversationReferenceCount, 1);
    expect(
      result.managedBytesCleanup,
      LibraryFileManagedBytesCleanup.deleted,
    );
    expect(storage.deleteCalls, 1);
    expect(await db.query('library_files'), isEmpty);
    expect(await db.query('project_files'), isEmpty);
    expect(await db.query('conversation_files'), isEmpty);
    expect(await db.query('library_file_folders'), isEmpty);
    expect(await db.query('projects'), hasLength(1));
    expect(await db.query('conversations'), hasLength(1));
    expect(await db.query('library_folders'), hasLength(1));
    expect(await storage.managedFileExists(file.storageKey), isFalse);
  });

  test('database failure preserves row and never deletes managed bytes',
      () async {
    final file = await seedFile();
    final db = await DatabaseHelper.instance.database;
    await seedReferences(db, file.fileId);
    await db.execute('''
      CREATE TRIGGER d2b_block_library_delete
      BEFORE DELETE ON library_files
      BEGIN
        SELECT RAISE(ABORT, 'blocked');
      END;
    ''');

    await expectLater(
      service.deleteLibraryFile(file.fileId),
      throwsA(
        isA<LibraryFileDeletionException>().having(
          (error) => error.failure,
          'failure',
          LibraryFileDeletionFailure.transactionFailed,
        ),
      ),
    );

    expect(storage.deleteCalls, 0);
    expect(await db.query('library_files'), hasLength(1));
    expect(await db.query('project_files'), hasLength(1));
    expect(await db.query('conversation_files'), hasLength(1));
    expect(await db.query('library_file_folders'), hasLength(1));
    expect(await storage.managedFileExists(file.storageKey), isTrue);
  });

  test('unknown managed-byte ownership fails closed before DB mutation',
      () async {
    final file = await seedFile(storageKey: 'library/foreign-owner');

    await expectLater(
      service.deleteLibraryFile(file.fileId),
      throwsA(
        isA<LibraryFileDeletionException>().having(
          (error) => error.failure,
          'failure',
          LibraryFileDeletionFailure.managedBytesOwnershipUnknown,
        ),
      ),
    );

    final db = await DatabaseHelper.instance.database;
    expect(storage.deleteCalls, 0);
    expect(await repository.findById(file.fileId), file);
    expect(await storage.managedFileExists(file.storageKey), isTrue);
    expect(await db.query('library_files'), hasLength(1));
  });

  test('post-commit managed cleanup failure returns an observable orphan',
      () async {
    final file = await seedFile();
    storage.deleteError = StateError('synthetic managed cleanup failure');
    final observed = <LogRecord>[];
    LogWriter.setRecordHandler(observed.add);

    final result = await service.deleteLibraryFile(file.fileId);

    expect(
      result.managedBytesCleanup,
      LibraryFileManagedBytesCleanup.orphaned,
    );
    expect(await repository.findById(file.fileId), isNull);
    expect(await storage.managedFileExists(file.storageKey), isTrue);
    expect(
      observed.any(
        (record) =>
            record.module == 'LibraryFile' &&
            record.data['fileId'] == file.fileId &&
            record.data['status'] == 'orphaned' &&
            record.data['retryable'] == true,
      ),
      isTrue,
    );
  });
}

Future<void> seedReferences(Database db, String fileId) async {
  await db.insert('projects', <String, Object?>{
    'project_id': 'project-d2b-0001',
    'display_name': 'D2B Project',
    'created_at': 1,
  });
  await db.insert('project_files', <String, Object?>{
    'project_id': 'project-d2b-0001',
    'file_id': fileId,
  });
  await db.insert('conversations', <String, Object?>{
    'conversation_id': 'conversation-d2b-0001',
    'scope_kind': 'global',
    'project_id': null,
    'title': 'D2B conversation',
    'created_at': 1,
    'updated_at': 1,
  });
  await db.insert('conversation_files', <String, Object?>{
    'conversation_id': 'conversation-d2b-0001',
    'file_id': fileId,
    'attached_at': 1,
  });
  await db.insert('library_folders', <String, Object?>{
    'folder_id': 'folder-d2b-0001',
    'display_name': 'D2B folder',
    'created_at': 1,
  });
  await db.insert('library_file_folders', <String, Object?>{
    'file_id': fileId,
    'folder_id': 'folder-d2b-0001',
  });
}
