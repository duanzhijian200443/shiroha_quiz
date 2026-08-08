// F0 FileIngestionService acceptance: copy-only ingestion, durability across
// close/reopen, integrity, cleanup on metadata failure, same-display-name
// isolation, and zero OCR/import/project/question side effects.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/library_file_repository.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/services/file_library/file_ingestion_service.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _abcSha256 =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

/// File-backed DatabaseHelper seam: repository APIs run against a real
/// database opened only through the frozen openPathForTesting seam.
class _FileDatabaseHelper extends Fake implements DatabaseHelper {
  _FileDatabaseHelper(this.path);

  final String path;
  Database? _database;

  @override
  Future<Database> get database async =>
      _database ??= await DatabaseHelper.instance.openPathForTesting(path);

  @override
  Future<void> close() async {
    final db = _database;
    _database = null;
    if (db != null) await db.close();
  }
}

class _FailingSaveRepository extends LibraryFileRepository {
  LibraryFile? capturedFile;

  @override
  Future<void> save(LibraryFile file) async {
    capturedFile = file;
    throw StateError('metadata write failed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Directory managedRoot;
  late ManagedFileStorageAdapter storage;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    tempDir = await Directory.systemTemp.createTemp('f0_ingest_');
    managedRoot = Directory(p.join(tempDir.path, 'managed'));
    storage = ManagedFileStorageAdapter(managedRoot: managedRoot);
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<File> writeSource(String name, List<int> bytes) async {
    final source = File(p.join(tempDir.path, name));
    await source.writeAsBytes(bytes, flush: true);
    return source;
  }

  Future<File> writeSourceWithMarker(String name, String marker) {
    return writeSource(
      name,
      utf8.encode('$marker\nsynthetic-payload-${name.length}'),
    );
  }

  test('ingest copies, hashes, and returns a relative managed identity',
      () async {
    final source = await writeSource('exam.pdf', 'abc'.codeUnits);
    final service = FileIngestionService(
      storage: storage,
      repository: LibraryFileRepository(),
    );

    final file = await service.ingest(
      externalPath: source.path,
      displayName: 'exam.pdf',
      mimeType: 'application/pdf',
    );

    expect(file.displayName, 'exam.pdf');
    expect(file.mimeType, 'application/pdf');
    expect(file.sizeBytes, 3);
    expect(file.sha256, _abcSha256);
    expect(p.isAbsolute(file.storageKey), isFalse);
    expect(file.storageKey.startsWith('library/'), isTrue);
    expect(file.storageKey, isNot(contains('..')));

    final managed = storage.resolveManagedFile(file.storageKey);
    expect(await managed.readAsBytes(), 'abc'.codeUnits);
  });

  test('ingest + reopen keeps metadata and managed identity resolvable',
      () async {
    final source = await writeSourceWithMarker(
      'durable.bin',
      'F0_DURABLE_MARKER_77ac',
    );
    final dbPath = p.join(tempDir.path, 'ingest_durable.db');
    final firstHelper = _FileDatabaseHelper(dbPath);
    final service = FileIngestionService(
      storage: storage,
      repository: LibraryFileRepository(databaseHelper: firstHelper),
    );
    final ingested = await service.ingest(
      externalPath: source.path,
      displayName: 'durable.bin',
    );
    await firstHelper.close();

    // Reopen: fresh adapter over the same root and a fresh database handle.
    final reopenedStorage = ManagedFileStorageAdapter(
      managedRoot: managedRoot,
    );
    final secondHelper = _FileDatabaseHelper(dbPath);
    try {
      final repository = LibraryFileRepository(databaseHelper: secondHelper);
      final reloaded = await repository.findById(ingested.fileId);
      expect(reloaded, ingested);

      final resolved = reopenedStorage.resolveManagedFile(ingested.storageKey);
      expect(
        await reopenedStorage.managedFileExists(ingested.storageKey),
        isTrue,
      );
      expect(await resolved.readAsBytes(), await source.readAsBytes());
    } finally {
      await secondHelper.close();
    }
  });

  test('external original is untouched by ingestion', () async {
    final source = await writeSourceWithMarker(
      'precious.pdf',
      'F0_ORIGINAL_MARKER_e1b2',
    );
    final before = await source.readAsBytes();
    final service = FileIngestionService(
      storage: storage,
      repository: LibraryFileRepository(),
    );
    await service.ingest(
      externalPath: source.path,
      displayName: 'precious.pdf',
    );

    expect(await source.exists(), isTrue);
    expect(await source.readAsBytes(), before);
  });

  test('SQLite stores metadata only, never the original bytes', () async {
    final source = await writeSourceWithMarker(
      'no_blob.pdf',
      'F0_RAW_MARKER_9f3b',
    );
    final dbPath = p.join(tempDir.path, 'ingest_no_blob.db');
    final helper = _FileDatabaseHelper(dbPath);
    final service = FileIngestionService(
      storage: storage,
      repository: LibraryFileRepository(databaseHelper: helper),
    );
    await service.ingest(
      externalPath: source.path,
      displayName: 'no_blob.pdf',
    );
    final db = await helper.database;

    final columns = await db.rawQuery('PRAGMA table_info(library_files)');
    expect(
      columns.map((row) => row['type'].toString().toUpperCase()),
      isNot(contains('BLOB')),
    );
    final encoded = jsonEncode((await db.query('library_files')).single);
    expect(encoded, isNot(contains('F0_RAW_MARKER_9f3b')));
    expect(encoded, isNot(contains(r'C:\')));
    await helper.close();
  });

  test('metadata failure cleans up the just-copied managed bytes', () async {
    final source = await writeSourceWithMarker(
      'cleanup.pdf',
      'F0_CLEANUP_MARKER_5d11',
    );
    final failing = _FailingSaveRepository();
    final service = FileIngestionService(
      storage: storage,
      repository: failing,
    );

    await expectLater(
      service.ingest(externalPath: source.path, displayName: 'cleanup.pdf'),
      throwsA(isA<StateError>()),
    );

    expect(failing.capturedFile, isNotNull);
    final storageKey = failing.capturedFile!.storageKey;
    expect(await storage.managedFileExists(storageKey), isFalse);
    expect(await LibraryFileRepository().findAll(), isEmpty);
    expect(await source.exists(), isTrue);
  });

  test('invalid metadata leaves no managed bytes and no row', () async {
    final source = await writeSource('bad_name.pdf', 'abc'.codeUnits);
    final service = FileIngestionService(
      storage: storage,
      repository: LibraryFileRepository(),
    );

    await expectLater(
      service.ingest(externalPath: source.path, displayName: '   '),
      throwsA(isA<FormatException>()),
    );
    expect(await LibraryFileRepository().findAll(), isEmpty);
    final managedFiles = managedRoot.existsSync()
        ? managedRoot.listSync(recursive: true).whereType<File>().toList()
        : <File>[];
    expect(managedFiles, isEmpty);
  });

  test('same display name yields distinct files without overwrite', () async {
    final first = await writeSourceWithMarker(
      'shared_name.pdf',
      'F0_SAME_NAME_FIRST_11aa',
    );
    final second = await writeSourceWithMarker(
      'shared_name_copy.pdf',
      'F0_SAME_NAME_SECOND_22bb',
    );
    final repository = LibraryFileRepository();
    final service =
        FileIngestionService(storage: storage, repository: repository);

    final fileA = await service.ingest(
      externalPath: first.path,
      displayName: 'shared_name.pdf',
    );
    final fileB = await service.ingest(
      externalPath: second.path,
      displayName: 'shared_name.pdf',
    );

    expect(fileA.displayName, fileB.displayName);
    expect(fileA.fileId, isNot(fileB.fileId));
    expect(fileA.storageKey, isNot(fileB.storageKey));
    expect(await repository.findAll(), hasLength(2));
    expect(await storage.managedFileExists(fileA.storageKey), isTrue);
    expect(await storage.managedFileExists(fileB.storageKey), isTrue);
    expect(
      await storage.resolveManagedFile(fileA.storageKey).readAsBytes(),
      await first.readAsBytes(),
    );
    expect(
      await storage.resolveManagedFile(fileB.storageKey).readAsBytes(),
      await second.readAsBytes(),
    );
  });

  test('ingestion never touches OCR/import/project/question tables', () async {
    final source = await writeSource('standalone.pdf', 'abc'.codeUnits);
    final dbPath = p.join(tempDir.path, 'ingest_isolated.db');
    final helper = _FileDatabaseHelper(dbPath);
    final service = FileIngestionService(
      storage: storage,
      repository: LibraryFileRepository(databaseHelper: helper),
    );
    final ingested = await service.ingest(
      externalPath: source.path,
      displayName: 'standalone.pdf',
    );
    final db = await helper.database;

    expect(await db.query('questions'), isEmpty);
    expect(await db.query('question_v2_payloads'), isEmpty);
    expect(await db.query('review_states'), isEmpty);
    expect(await db.query('import_tasks'), isEmpty);
    expect(
        (await db.query('library_files')).single['file_id'], ingested.fileId);
    await helper.close();
  });

  test('copy failure leaves no database row and no managed file', () async {
    final service = FileIngestionService(
      storage: storage,
      repository: LibraryFileRepository(),
    );
    await expectLater(
      service.ingest(
        externalPath: p.join(tempDir.path, 'missing.pdf'),
        displayName: 'missing.pdf',
      ),
      throwsA(
        isA<ManagedFileStorageException>().having(
          (e) => e.failure,
          'failure',
          ManagedFileStorageFailure.sourceMissing,
        ),
      ),
    );
    expect(await LibraryFileRepository().findAll(), isEmpty);
    expect(managedRoot.existsSync(), isFalse);
  });
}
