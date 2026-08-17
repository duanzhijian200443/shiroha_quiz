// F0 LibraryFileRepository contract on a real SQLite database: metadata
// round trips, close/reopen durability through the frozen openPathForTesting
// seam, no BLOB / raw byte storage, and a unique managed storage key.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/library_file_repository.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _sha256 =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

LibraryFile file({
  String fileId = 'file-repo-0001',
  String storageKey = 'library/file-repo-0001',
  String displayName = 'report.pdf',
}) {
  return LibraryFile(
    fileId: fileId,
    displayName: displayName,
    mimeType: 'application/pdf',
    sizeBytes: 3,
    sha256: _sha256,
    storageKey: storageKey,
    createdAt: DateTime.utc(2026, 8, 8, 12),
  );
}

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    tempDir = await Directory.systemTemp.createTemp('f0_library_repo_');
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('save and findById round-trip the full model', () async {
    final repository = LibraryFileRepository();
    final expected = file();
    await repository.save(expected);

    final reloaded = await repository.findById(expected.fileId);
    expect(reloaded, expected);
  });

  test('findAll returns rows in creation order', () async {
    final repository = LibraryFileRepository();
    final first = file(
      fileId: 'file-repo-aaaa',
      storageKey: 'library/file-repo-aaaa',
      displayName: 'first.pdf',
    );
    final second = LibraryFile(
      fileId: 'file-repo-bbbb',
      displayName: 'second.pdf',
      mimeType: 'text/plain',
      sizeBytes: 0,
      sha256:
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      storageKey: 'library/file-repo-bbbb',
      createdAt: DateTime.utc(2026, 8, 8, 13),
    );
    await repository.save(first);
    await repository.save(second);

    final all = await repository.findAll();
    expect(all.map((f) => f.fileId), <String>[
      'file-repo-aaaa',
      'file-repo-bbbb',
    ]);
  });

  test('findById returns null for an unknown id', () async {
    final repository = LibraryFileRepository();
    expect(await repository.findById('file-missing'), isNull);
  });

  test('metadata survives close and reopen (durable identity)', () async {
    final path = p.join(tempDir.path, 'library_repo.db');
    final firstHelper = _FileDatabaseHelper(path);
    final repository = LibraryFileRepository(databaseHelper: firstHelper);
    final expected = file();
    await repository.save(expected);
    await firstHelper.close();

    final secondHelper = _FileDatabaseHelper(path);
    final reopened = LibraryFileRepository(databaseHelper: secondHelper);
    final reloaded = await reopened.findById(expected.fileId);
    expect(reloaded, expected);
    expect(await reopened.findAll(), <LibraryFile>[expected]);

    final version =
        await (await secondHelper.database).rawQuery('PRAGMA user_version');
    expect(version.single['user_version'], 23);
    await secondHelper.close();
  });

  test('SQLite row holds metadata only, never raw bytes or BLOBs', () async {
    final path = p.join(tempDir.path, 'library_repo_blob.db');
    final helper = _FileDatabaseHelper(path);
    final repository = LibraryFileRepository(databaseHelper: helper);
    final expected = file(displayName: 'report.pdf');
    await repository.save(expected);
    final db = await helper.database;

    final columns = await db.rawQuery('PRAGMA table_info(library_files)');
    final affinities =
        columns.map((row) => row['type'].toString().toUpperCase()).toList();
    expect(affinities, isNot(contains('BLOB')));
    expect(affinities, containsAll(<String>['TEXT', 'INTEGER']));

    final rows = await db.query('library_files');
    expect(rows, hasLength(1));
    final encoded = jsonEncode(rows.single);
    expect(encoded, isNot(contains('F0_RAW_MARKER_9f3b')));
    expect(encoded, contains(expected.sha256));
    expect(encoded, contains(expected.storageKey));
    expect(encoded, isNot(contains(r'C:\')));
    await helper.close();
  });

  test('duplicate storage keys are rejected by the unique index', () async {
    final repository = LibraryFileRepository();
    await repository.save(file());
    await expectLater(
      repository.save(
        file(
          fileId: 'file-repo-0002',
          storageKey: 'library/file-repo-0001',
        ),
      ),
      throwsA(isA<DatabaseException>()),
    );
  });
}
