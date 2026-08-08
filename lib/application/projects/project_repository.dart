/// J0 Project repository port.
///
/// The data layer implements this port; the application layer never sees
/// SQL, database rows, or absolute paths. Presentation adapters must not
/// depend on this file directly.
///
/// Persistence is strictly additive to the J0 contract:
///
/// - Projects are metadata rows only; project deletion removes the project
///   row and its relation rows and never touches `library_files`, banks,
///   questions, sidecars, or review state.
/// - `project_files` / `project_banks` are many-to-many relation tables.
///   One file or bank may belong to many projects, and unassigned assets
///   remain valid.
/// - Bank relations use the frozen J0-P0 Decision A compatibility key:
///   the current `bank_name` string. J0 provides no bank rename, no
///   registry, and no inference of a rename from relation updates.
library;

import '../../domain/projects/project.dart';

abstract interface class ProjectRepository {
  /// Persists one new project. Fails with
  /// [ProjectRepositoryFailure.projectAlreadyExists] when [project.projectId]
  /// is already stored.
  Future<void> createProject(Project project);

  /// All projects ordered by creation time, then project id.
  Future<List<Project>> listProjects();

  /// One project by stable id, or null when absent.
  Future<Project?> getProject(String projectId);

  /// Renames [projectId] and returns the updated project. Renaming changes
  /// only the metadata row; relation rows stay keyed by the stable id.
  Future<Project> renameProject({
    required String projectId,
    required String displayName,
  });

  /// Deletes the project metadata and its relation rows only.
  Future<void> deleteProject(String projectId);

  /// Attaches [fileId] to [projectId]. Idempotent for an existing relation;
  /// fails with [ProjectRepositoryFailure.projectNotFound] or
  /// [ProjectRepositoryFailure.fileNotFound] when the referenced rows are
  /// missing. Never modifies the `library_files` row itself.
  Future<void> attachFile({required String projectId, required String fileId});

  /// Removes one file relation. Idempotent when the relation is absent;
  /// never deletes the underlying `library_files` row.
  Future<void> detachFile({required String projectId, required String fileId});

  /// Attaches [bankName] (a J0 compatibility relation key) to [projectId].
  /// Idempotent for an existing relation; fails with
  /// [ProjectRepositoryFailure.projectNotFound] when the project is missing.
  /// Bank authority stays with the existing name-based consumers; J0 never
  /// renames banks or treats the relation as a stable bank identity.
  Future<void> attachBank({
    required String projectId,
    required String bankName,
  });

  /// Removes one bank relation. Idempotent when the relation is absent;
  /// never touches the bank's questions, folders, or other consumers.
  Future<void> detachBank({
    required String projectId,
    required String bankName,
  });

  /// File ids attached to [projectId], ordered by file id.
  Future<List<String>> listProjectFileIds(String projectId);

  /// Bank names attached to [projectId], ordered by bank name.
  Future<List<String>> listProjectBankNames(String projectId);

  /// Project ids referencing [fileId], ordered by project id.
  Future<List<String>> listProjectIdsForFile(String fileId);

  /// Project ids referencing [bankName], ordered by project id.
  Future<List<String>> listProjectIdsForBank(String bankName);
}

/// Failure taxonomy raised by [ProjectRepository] implementations. The
/// exception never carries SQL, paths, payloads, or raw causes.
enum ProjectRepositoryFailure {
  projectNotFound,
  fileNotFound,
  projectAlreadyExists,
}

final class ProjectRepositoryException implements Exception {
  const ProjectRepositoryException(this.failure);

  final ProjectRepositoryFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      ProjectRepositoryFailure.projectNotFound => 'The project does not exist.',
      ProjectRepositoryFailure.fileNotFound =>
        'The library file does not exist.',
      ProjectRepositoryFailure.projectAlreadyExists =>
        'A project with that id already exists.',
    };
    return 'ProjectRepositoryException(${failure.name}): $detail';
  }
}
