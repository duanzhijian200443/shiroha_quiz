import 'dart:async';
import 'package:uuid/uuid.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/local_authorization_service.dart';
import 'package:shiroha_quiz/application/file_library/library_folder_service.dart';
import 'package:shiroha_quiz/application/projects/project_service.dart';
import 'package:shiroha_quiz/data/repositories/external_authorization_repository.dart';
import 'package:shiroha_quiz/data/repositories/library_folder_repository.dart';
import 'package:shiroha_quiz/data/repositories/project_repository.dart';
import '../generated_question/generated_test_support.dart';
export '../generated_question/generated_test_support.dart';

final class DelayedProfileQuery implements ExternalProfileQuery {
  DelayedProfileQuery(this.delegate);
  final ExternalProfileQuery delegate;
  Completer<void>? pause;
  @override
  Future<List<String>> listBankTargets() => delegate.listBankTargets();
  @override
  Future<ExternalProfilePage> listProfiles(
      {int limit = 50, String? afterId}) async {
    final result = await delegate.listProfiles(limit: limit, afterId: afterId);
    await pause?.future;
    return result;
  }
}

final class LocalAuthorizationHarness {
  final h = GeneratedHarness();
  late SqliteExternalAuthorizationRepository repository;
  late LocalAuthorizationService service;
  late DelayedProfileQuery query;
  Future<void> open() async {
    await h.open();
    await h.db.insert(
        'bank_folders', {'bank_name': 'second', 'folder_name': 'folder'});
    await h.db.insert('projects',
        {'project_id': 'space', 'display_name': 'Space', 'created_at': 0});
    await h.db
        .insert('project_banks', {'project_id': 'space', 'bank_name': 'bank'});
    for (final id in ['file1', 'file2']) {
      await h.db.insert('library_files', {
        'file_id': id,
        'display_name': 'Synthetic $id',
        'mime_type': 'text/plain',
        'size_bytes': 0,
        'sha256': '0' * 64,
        'storage_key': id,
        'created_at': 0,
      });
    }
    await h.db
        .insert('project_files', {'project_id': 'space', 'file_id': 'file1'});
    compose();
  }

  void compose() {
    final capturedDatabase = h.db;
    repository =
        SqliteExternalAuthorizationRepository(databaseHelper: h.helper);
    query = DelayedProfileQuery(repository);
    service = LocalAuthorizationService(
      repository: repository,
      profiles: query,
      files: LibraryFolderService(
          repository: SqliteLibraryFolderRepository(databaseHelper: h.helper),
          folderIdFactory: const Uuid().v4),
      projects: ProjectService(
          repository: SqliteProjectRepository(databaseHelper: h.helper)),
      mintProfileId: const Uuid().v4,
      compositionIsCurrent: () => capturedDatabase.isOpen,
    );
  }

  Future<void> close() async {
    service.invalidate();
    await h.close();
  }
}
