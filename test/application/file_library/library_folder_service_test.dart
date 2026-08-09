import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/file_library/library_folder_repository.dart';
import 'package:shiroha_quiz/application/file_library/library_folder_service.dart';
import 'package:shiroha_quiz/domain/assets/library_folder.dart';

final class _FolderRepository extends Fake
    implements LibraryFolderRepositoryPort {
  final Map<String, LibraryFolder> folders = <String, LibraryFolder>{};
  final Map<String, String> memberships = <String, String>{};
  final List<String> calls = <String>[];

  @override
  Future<void> createFolder(LibraryFolder folder) async {
    calls.add('create:${folder.folderId}:${folder.displayName}');
    if (folders.containsKey(folder.folderId)) {
      throw const LibraryFolderException(
        LibraryFolderFailure.folderIdConflict,
      );
    }
    if (folders.values.any(
      (value) =>
          value.displayName.toLowerCase() == folder.displayName.toLowerCase(),
    )) {
      throw const LibraryFolderException(LibraryFolderFailure.duplicateName);
    }
    folders[folder.folderId] = folder;
  }

  @override
  Future<List<LibraryFolder>> listFolders() async => folders.values.toList();

  @override
  Future<LibraryFolder?> findFolder(String folderId) async => folders[folderId];

  @override
  Future<LibraryFolder> renameFolder({
    required String folderId,
    required String displayName,
  }) async {
    calls.add('rename:$folderId:$displayName');
    final existing = folders[folderId];
    if (existing == null) {
      throw const LibraryFolderException(LibraryFolderFailure.folderNotFound);
    }
    final renamed = LibraryFolder(
      folderId: folderId,
      displayName: displayName,
      createdAt: existing.createdAt,
    );
    folders[folderId] = renamed;
    return renamed;
  }

  @override
  Future<void> deleteFolder(String folderId) async {
    if (folders.remove(folderId) == null) {
      throw const LibraryFolderException(LibraryFolderFailure.folderNotFound);
    }
    memberships.removeWhere((_, value) => value == folderId);
  }

  @override
  Future<void> moveFileToFolder({
    required String fileId,
    required String folderId,
  }) async {
    memberships[fileId] = folderId;
  }

  @override
  Future<void> removeFileFromFolder(String fileId) async {
    memberships.remove(fileId);
  }
}

void main() {
  late _FolderRepository repository;
  late LibraryFolderService service;

  setUp(() {
    repository = _FolderRepository();
    service = LibraryFolderService(
      repository: repository,
      folderIdFactory: () => 'folder-fixed',
    );
  });

  test('create normalizes the label and delegates with a stable id', () async {
    final created = await service.createFolder('  考研真题  ');
    expect(created.folderId, 'folder-fixed');
    expect(created.displayName, '考研真题');
    expect(repository.folders[created.folderId], created);
  });

  test('invalid name fails safely before persistence', () async {
    await expectLater(
      service.createFolder('未分类'),
      throwsA(
        isA<LibraryFolderException>().having(
          (error) => error.failure,
          'failure',
          LibraryFolderFailure.invalidName,
        ),
      ),
    );
    expect(repository.calls, isEmpty);
  });

  test('duplicate and invalid generated id retain safe failures', () async {
    var sequence = 0;
    final duplicateService = LibraryFolderService(
      repository: repository,
      folderIdFactory: () => 'folder-${sequence++}',
    );
    await duplicateService.createFolder('A');
    await expectLater(
      duplicateService.createFolder('a'),
      throwsA(
        isA<LibraryFolderException>().having(
          (error) => error.failure,
          'failure',
          LibraryFolderFailure.duplicateName,
        ),
      ),
    );

    final invalidIdService = LibraryFolderService(
      repository: repository,
      folderIdFactory: () => '../invalid',
    );
    await expectLater(
      invalidIdService.createFolder('B'),
      throwsA(
        isA<LibraryFolderException>().having(
          (error) => error.failure,
          'failure',
          LibraryFolderFailure.folderIdConflict,
        ),
      ),
    );
  });

  test('rename keeps identity and move/remove delegates', () async {
    final created = await service.createFolder('旧名称');
    final renamed = await service.renameFolder(
      folderId: created.folderId,
      displayName: ' 新名称 ',
    );
    expect(renamed.folderId, created.folderId);
    expect(renamed.createdAt, created.createdAt);

    await service.moveFileToFolder(
      fileId: 'file-1',
      folderId: created.folderId,
    );
    expect(repository.memberships['file-1'], created.folderId);
    await service.removeFileFromFolder('file-1');
    expect(repository.memberships, isEmpty);
  });

  test('delete removes only folder membership in the port contract', () async {
    final created = await service.createFolder('资料');
    repository.memberships['file-1'] = created.folderId;
    await service.deleteFolder(created.folderId);
    expect(repository.folders, isEmpty);
    expect(repository.memberships, isEmpty);
  });
}
