import '../backup/backup_restore_gate.dart';
import '../capabilities/capability.dart';
import '../file_library/library_folder_service.dart';
import '../projects/project_service.dart';
import 'external_authorization.dart';

/// Only compiled first-party composition receives this policy-management service.
/// It contains no authentication, execution or external capability entrypoint.
final class LocalAuthorizationService {
  LocalAuthorizationService({
    required ExternalAuthorizationRepository repository,
    required ExternalProfileQuery profiles,
    required LibraryFolderService files,
    required ProjectService projects,
    required String Function() mintProfileId,
    required bool Function() compositionIsCurrent,
  })  : _repository = repository,
        _profiles = profiles,
        _files = files,
        _projects = projects,
        _mintProfileId = mintProfileId,
        _compositionIsCurrent = compositionIsCurrent;

  final ExternalAuthorizationRepository _repository;
  final ExternalProfileQuery _profiles;
  final LibraryFolderService _files;
  final ProjectService _projects;
  final String Function() _mintProfileId;
  final bool Function() _compositionIsCurrent;
  bool _active = true;
  bool get isCurrent => _active && _compositionIsCurrent();
  void invalidate() => _active = false;

  LocalAuthorizationView openView() {
    if (!isCurrent) externalAuthFail(ExternalAuthFailure.unauthorized);
    return LocalAuthorizationView._(this);
  }
}

/// Non-secret choice minted from trusted queries, bound to one local view.
final class LocalAuthorizationTarget {
  LocalAuthorizationTarget._(this._owner, this.scope, this.label);
  final LocalAuthorizationView _owner;
  final ExternalGrantScope scope;
  final String label;
}

final class LocalAuthorizationView {
  LocalAuthorizationView._(this._service) {
    _management = ExternalAuthorizationManagement(
      repository: _service._repository,
      compositionIsCurrent: () => isCurrent,
      mintProfileId: _service._mintProfileId,
    );
  }
  final LocalAuthorizationService _service;
  late final ExternalAuthorizationManagement _management;
  bool _active = true;
  bool get isCurrent => _active && _service.isCurrent;
  void close() {
    _active = false;
    _management.invalidate();
  }

  void _validate() {
    if (!isCurrent || BackupRestoreMutationGate.instance.isMaintenance) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
  }

  Future<T> _run<T>(Future<T> Function() action) async {
    _validate();
    try {
      final result = await action();
      _validate();
      return result;
    } on ExternalAuthException {
      rethrow;
    } catch (_) {
      externalAuthFail(ExternalAuthFailure.persistenceFailed);
    }
  }

  Future<ExternalProfilePage> profiles({String? afterId}) =>
      _run(() => _service._profiles.listProfiles(afterId: afterId));
  Future<ExternalProfileReference> create(String displayName) =>
      _run(() => _management.createProfile(
          displayName: displayName.trim(),
          adapter: 'local-policy',
          protocol: 'unconfigured'));
  Future<ExternalProfileReference> select(String profileId) =>
      _run(() => _management.selectProfile(profileId));
  Future<ExternalAuthorizationRecord> read(ExternalProfileReference ref) =>
      _run(() => _management.read(ref));

  /// Explicit first-party choice for all Shiroha content, including future
  /// content. This never widens an existing grant merely by displaying it.
  Future<ExternalAuthorizationRecord> saveAllContent(
          ExternalProfileReference ref, int revision,
          {required bool directWrite}) =>
      _run(() => _management.replaceGrant(
          ref,
          revision,
          ExternalGrantPolicy(
            permissions: const [
              CapabilityPermission.read,
              CapabilityPermission.stage,
            ],
            scopes: const [],
            categories: ExternalContentCategory.values,
            allContent: true,
            generationMode: directWrite
                ? ExternalGenerationMode.direct
                : ExternalGenerationMode.review,
          )));

  /// Explicit local generation choice over an existing READ grant. Unlike
  /// all-content setup, this preserves the original target and egress scopes.
  /// A null mode returns to question READ; direct requires a prior generation
  /// choice and can never be the implicit first upgrade.
  Future<ExternalAuthorizationRecord> saveQuestionGeneration(
          ExternalProfileReference ref, int revision,
          {required ExternalGenerationMode? mode}) =>
      _run(() async {
        final record = await _management.read(ref);
        final grant = record.grant;
        if (record.profile.grantRevision != revision) {
          externalAuthFail(ExternalAuthFailure.staleRevision);
        }
        if (record.profile.revokedAtUtcMs != null ||
            grant == null ||
            grant.revokedAtUtcMs != null ||
            !grant.policy.permissions.contains(CapabilityPermission.read) ||
            !grant.policy.categories
                .contains(ExternalContentCategory.questionContent) ||
            (mode == ExternalGenerationMode.direct &&
                !grant.policy.permissions
                    .contains(CapabilityPermission.stage))) {
          externalAuthFail(ExternalAuthFailure.unauthorized);
        }
        final previous = grant.policy;
        final permissions = {...previous.permissions};
        final categories = {...previous.categories};
        if (mode == null) {
          permissions.remove(CapabilityPermission.stage);
          categories.remove(ExternalContentCategory.proposalMetadata);
        } else {
          permissions.add(CapabilityPermission.stage);
          categories.add(ExternalContentCategory.proposalMetadata);
        }
        return _management.replaceGrant(
            ref,
            revision,
            ExternalGrantPolicy(
                permissions: permissions,
                scopes: previous.scopes,
                categories: categories,
                allContent: previous.allContent,
                generationMode: mode ?? ExternalGenerationMode.confirm));
      });

  /// Permission and Egress are separate; choices never accept freeform paths.
  Future<ExternalAuthorizationRecord> save(
          ExternalProfileReference ref, int revision,
          {required Iterable<CapabilityPermission> permissions,
          required Iterable<LocalAuthorizationTarget> targets,
          required Iterable<ExternalContentCategory> categories}) =>
      _run(() async {
        final selected = targets.toList();
        if (selected.any((t) => !identical(t._owner, this))) {
          externalAuthFail(ExternalAuthFailure.unauthorized);
        }
        return _management.replaceGrant(
            ref,
            revision,
            ExternalGrantPolicy(
                permissions: permissions,
                scopes: selected.map((t) => t.scope),
                categories: categories));
      });
  Future<ExternalAuthorizationRecord> revokeGrant(
          ExternalProfileReference ref, int revision) =>
      _run(() => _management.revokeGrant(ref, revision));
  Future<ExternalAuthorizationRecord> revokeProfile(
          ExternalProfileReference ref, int revision) =>
      _run(() => _management.revokeProfile(ref, revision));

  Future<List<LocalAuthorizationTarget>> targets() => _run(() async {
        final projects = {
          for (final p in await _service._projects.listProjects())
            p.projectId: p.displayName
        };
        final choices = <ExternalGrantScope, LocalAuthorizationTarget>{};
        void add(
            ExternalTargetKind kind, String id, String name, String? project) {
          final scope =
              ExternalGrantScope(kind: kind, targetId: id, projectId: project);
          final projectLabel = project == null ? '本地' : projects[project];
          if (projectLabel == null) {
            externalAuthFail(ExternalAuthFailure.unauthorized);
          }
          choices[scope] = LocalAuthorizationTarget._(this, scope,
              '${kind == ExternalTargetKind.bank ? '题库' : '文件'} · $projectLabel · $name');
        }

        for (final bank in await _service._profiles.listBankTargets()) {
          add(ExternalTargetKind.bank, bank, bank, null);
          for (final project
              in await _service._projects.listProjectIdsForBank(bank)) {
            add(ExternalTargetKind.bank, bank, bank, project);
          }
        }
        final files = [...await _service._files.listUnclassifiedFiles()];
        for (final folder in await _service._files.listFolders()) {
          files
              .addAll(await _service._files.listFilesInFolder(folder.folderId));
        }
        for (final file in files) {
          add(ExternalTargetKind.file, file.fileId, file.displayName, null);
          for (final project
              in await _service._projects.listProjectIdsForFile(file.fileId)) {
            add(ExternalTargetKind.file, file.fileId, file.displayName,
                project);
          }
        }
        return List.unmodifiable(choices.values);
      });
}
