/// J0 application service for optional Project learning contexts.
///
/// Owns use-case orchestration and domain validation; persistence stays
/// behind [ProjectRepository]. The service is pure Dart and depends only on
/// the domain model and the repository port, so UI, Agent, and MCP adapters
/// can share the same semantics later.
///
/// J0 semantics frozen here:
///
/// - Projects are optional; no asset ever requires a project assignment.
/// - Project deletion removes metadata and relations only, never files,
///   banks, questions, sidecars, or review state.
/// - A project id is stable for its lifetime; only [displayName] renames.
/// - Bank relations are Decision A compatibility keys; J0 never renames a
///   bank.
library;

import '../../domain/projects/project.dart';
import '../backup/backup_restore_gate.dart';
import '../observability/destructive_mutation_trace.dart';
import 'project_repository.dart';

final class ProjectService {
  ProjectService({
    required ProjectRepository repository,
    String Function()? projectIdFactory,
  }) : _repository = repository {
    _projectIdFactory = projectIdFactory ?? _generateProjectId;
  }

  final ProjectRepository _repository;
  late final String Function() _projectIdFactory;
  int _sequence = 0;

  /// Bounded, collision-resistant default id. Callers may inject a factory
  /// (for example a UUID source at the composition root) without making the
  /// application layer depend on a third-party package.
  String _generateProjectId() {
    _sequence++;
    final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    return 'project_${stamp}_$_sequence';
  }

  Future<Project> createProject({required String displayName}) {
    return BackupRestoreMutationGate.instance.runMutation(() async {
      final project = Project(
        projectId: _projectIdFactory(),
        displayName: displayName,
        createdAt: DateTime.now().toUtc(),
      );
      await _repository.createProject(project);
      return project;
    });
  }

  Future<List<Project>> listProjects() => _repository.listProjects();

  Future<Project?> getProject(String projectId) =>
      _repository.getProject(projectId);

  Future<Project> renameProject({
    required String projectId,
    required String displayName,
  }) {
    return BackupRestoreMutationGate.instance.runMutation(() async {
      Project.validateDisplayName(displayName);
      return _repository.renameProject(
        projectId: projectId,
        displayName: displayName,
      );
    });
  }

  Future<void> deleteProject(String projectId) =>
      DestructiveMutationTrace.run<void>(
        kind: DestructiveMutationKind.projectDelete,
        action: () => BackupRestoreMutationGate.instance.runMutation(
          () => _repository.deleteProject(projectId),
        ),
      );

  Future<void> attachFile({
    required String projectId,
    required String fileId,
  }) =>
      BackupRestoreMutationGate.instance.runMutation(
        () => _repository.attachFile(projectId: projectId, fileId: fileId),
      );

  Future<void> detachFile({
    required String projectId,
    required String fileId,
  }) =>
      BackupRestoreMutationGate.instance.runMutation(
        () => _repository.detachFile(projectId: projectId, fileId: fileId),
      );

  Future<void> attachBank({
    required String projectId,
    required String bankName,
  }) {
    return BackupRestoreMutationGate.instance.runMutation(() async {
      if (bankName.trim().isEmpty) {
        throw const FormatException('Bank relation keys must not be empty.');
      }
      return _repository.attachBank(projectId: projectId, bankName: bankName);
    });
  }

  Future<void> detachBank({
    required String projectId,
    required String bankName,
  }) =>
      BackupRestoreMutationGate.instance.runMutation(
        () => _repository.detachBank(
          projectId: projectId,
          bankName: bankName,
        ),
      );

  Future<List<String>> listProjectFileIds(String projectId) =>
      _repository.listProjectFileIds(projectId);

  Future<List<String>> listProjectBankNames(String projectId) =>
      _repository.listProjectBankNames(projectId);

  Future<List<String>> listProjectIdsForFile(String fileId) =>
      _repository.listProjectIdsForFile(fileId);

  Future<List<String>> listProjectIdsForBank(String bankName) =>
      _repository.listProjectIdsForBank(bankName);
}
