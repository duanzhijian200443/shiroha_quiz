import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/file_library/library_folder_repository.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/library_file_repository.dart';
import 'package:shiroha_quiz/data/repositories/library_folder_repository.dart';
import 'package:shiroha_quiz/data/repositories/project_repository.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/assets/library_folder.dart';
import 'package:shiroha_quiz/domain/projects/project.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _sha =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

LibraryFile _file(String id, {int hour = 1}) => LibraryFile(
      fileId: id,
      displayName: '$id.pdf',
      mimeType: 'application/pdf',
      sizeBytes: hour,
      sha256: _sha,
      storageKey: 'library/$id',
      createdAt: DateTime.utc(2026, 8, 9, hour),
    );

LibraryFolder _folder(String id, String name, {int hour = 1}) => LibraryFolder(
      folderId: id,
      displayName: name,
      createdAt: DateTime.utc(2026, 8, 9, hour),
    );

final class _FileDatabaseHelper extends Fake implements DatabaseHelper {
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
    await db?.close();
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
    tempDir = await Directory.systemTemp.createTemp('f0_1_folder_repo_');
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('CRUD preserves stable identity and deterministic ordering', () async {
    final repository = SqliteLibraryFolderRepository();
    final later = _folder('folder-b', 'B', hour: 2);
    final first = _folder('folder-a', 'A');
    await repository.createFolder(later);
    await repository.createFolder(first);

    expect(await repository.listFolders(), <LibraryFolder>[first, later]);
    expect(await repository.findFolder(first.folderId), first);

    final renamed = await repository.renameFolder(
      folderId: first.folderId,
      displayName: 'A renamed',
    );
    expect(renamed.folderId, first.folderId);
    expect(renamed.createdAt, first.createdAt);
    expect(
      await repository.renameFolder(
        folderId: first.folderId,
        displayName: 'A renamed',
      ),
      renamed,
    );
  });

  test('NOCASE duplicate names fail without changing existing rows', () async {
    final repository = SqliteLibraryFolderRepository();
    await repository.createFolder(_folder('folder-a', 'Research'));
    await expectLater(
      repository.createFolder(_folder('folder-b', 'research')),
      throwsA(
        isA<LibraryFolderException>().having(
          (error) => error.failure,
          'failure',
          LibraryFolderFailure.duplicateName,
        ),
      ),
    );
    expect(await repository.listFolders(), hasLength(1));
  });

  test('move enforces one folder and remove returns file to unclassified',
      () async {
    final files = LibraryFileRepository();
    final repository = SqliteLibraryFolderRepository();
    await files.save(_file('file-1'));
    await files.save(_file('file-2', hour: 2));
    await repository.createFolder(_folder('folder-a', 'A'));
    await repository.createFolder(_folder('folder-b', 'B'));

    await repository.moveFileToFolder(
      fileId: 'file-1',
      folderId: 'folder-a',
    );
    await repository.moveFileToFolder(
      fileId: 'file-1',
      folderId: 'folder-b',
    );
    await repository.moveFileToFolder(
      fileId: 'file-1',
      folderId: 'folder-b',
    );

    expect(await repository.listFilesInFolder('folder-a'), isEmpty);
    expect(
      (await repository.listFilesInFolder('folder-b')).single.fileId,
      'file-1',
    );
    expect(
      (await repository.listUnclassifiedFiles()).single.fileId,
      'file-2',
    );

    await repository.removeFileFromFolder('file-1');
    await repository.removeFileFromFolder('file-1');
    expect(
      (await repository.listUnclassifiedFiles()).map((file) => file.fileId),
      <String>['file-2', 'file-1'],
    );
  });

  test('Folder and Project relations mutate independently', () async {
    final files = LibraryFileRepository();
    final folders = SqliteLibraryFolderRepository();
    final projects = SqliteProjectRepository();
    final file = _file('file-independent');
    final folder = _folder('folder-independent', '论文');
    final project = Project(
      projectId: 'project-independent',
      displayName: '深度学习',
      createdAt: DateTime.utc(2026, 8, 9),
    );
    await files.save(file);
    await folders.createFolder(folder);
    await projects.createProject(project);
    await folders.moveFileToFolder(
      fileId: file.fileId,
      folderId: folder.folderId,
    );
    await projects.attachFile(
      projectId: project.projectId,
      fileId: file.fileId,
    );

    await projects.detachFile(
      projectId: project.projectId,
      fileId: file.fileId,
    );
    expect(await folders.getFolderForFile(file.fileId), folder);

    await projects.attachFile(
      projectId: project.projectId,
      fileId: file.fileId,
    );
    await folders.removeFileFromFolder(file.fileId);
    expect(await projects.listProjectIdsForFile(file.fileId), <String>[
      project.projectId,
    ]);
  });

  test('deleting Folder preserves file metadata and Project relation',
      () async {
    final files = LibraryFileRepository();
    final folders = SqliteLibraryFolderRepository();
    final projects = SqliteProjectRepository();
    final file = _file('file-preserved');
    final folder = _folder('folder-delete', '待删除');
    final project = Project(
      projectId: 'project-preserved',
      displayName: '保留关系',
      createdAt: DateTime.utc(2026, 8, 9),
    );
    await files.save(file);
    await folders.createFolder(folder);
    await projects.createProject(project);
    await folders.moveFileToFolder(
      fileId: file.fileId,
      folderId: folder.folderId,
    );
    await projects.attachFile(
      projectId: project.projectId,
      fileId: file.fileId,
    );

    await folders.deleteFolder(folder.folderId);

    expect(await files.findById(file.fileId), file);
    expect(await folders.getFolderForFile(file.fileId), isNull);
    expect(await projects.listProjectIdsForFile(file.fileId), <String>[
      project.projectId,
    ]);
    expect(
      (await DatabaseHelper.instance.database)
          .rawQuery('PRAGMA foreign_key_check'),
      completion(isEmpty),
    );
  });

  test('missing file/folder operations fail deterministically', () async {
    final repository = SqliteLibraryFolderRepository();
    await repository.createFolder(_folder('folder-existing', 'Existing'));

    await expectLater(
      repository.moveFileToFolder(
        fileId: 'file-missing',
        folderId: 'folder-existing',
      ),
      throwsA(
        isA<LibraryFolderException>().having(
          (error) => error.failure,
          'failure',
          LibraryFolderFailure.fileNotFound,
        ),
      ),
    );
    await LibraryFileRepository().save(_file('file-existing'));
    await expectLater(
      repository.moveFileToFolder(
        fileId: 'file-existing',
        folderId: 'folder-missing',
      ),
      throwsA(
        isA<LibraryFolderException>().having(
          (error) => error.failure,
          'failure',
          LibraryFolderFailure.folderNotFound,
        ),
      ),
    );
  });

  test('folders and membership survive close and reopen', () async {
    final path = p.join(tempDir.path, 'folder_repo.db');
    final firstHelper = _FileDatabaseHelper(path);
    final firstFiles = LibraryFileRepository(databaseHelper: firstHelper);
    final firstFolders = SqliteLibraryFolderRepository(
      databaseHelper: firstHelper,
    );
    final file = _file('file-durable');
    final folder = _folder('folder-durable', 'Durable');
    await firstFiles.save(file);
    await firstFolders.createFolder(folder);
    await firstFolders.moveFileToFolder(
      fileId: file.fileId,
      folderId: folder.folderId,
    );
    await firstHelper.close();

    final secondHelper = _FileDatabaseHelper(path);
    final reopened = SqliteLibraryFolderRepository(
      databaseHelper: secondHelper,
    );
    expect(await reopened.findFolder(folder.folderId), folder);
    expect(await reopened.getFolderForFile(file.fileId), folder);
    final version = await (await secondHelper.database).rawQuery(
      'PRAGMA user_version',
    );
    expect(version.single['user_version'], 21);
    await secondHelper.close();
  });
}
