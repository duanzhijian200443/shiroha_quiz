import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/projects/project_repository.dart';
import 'package:shiroha_quiz/application/projects/project_service.dart';
import 'package:shiroha_quiz/domain/projects/project.dart';

/// In-memory port double recording every call; keeps the service test
/// focused on orchestration and validation without SQLite.
final class _FakeProjectRepository implements ProjectRepository {
  final Map<String, Project> projects = <String, Project>{};
  final Map<String, Set<String>> files = <String, Set<String>>{};
  final Map<String, Set<String>> banks = <String, Set<String>>{};
  final List<String> calls = <String>[];

  @override
  Future<void> createProject(Project project) async {
    calls.add('create:${project.projectId}');
    if (projects.containsKey(project.projectId)) {
      throw const ProjectRepositoryException(
        ProjectRepositoryFailure.projectAlreadyExists,
      );
    }
    projects[project.projectId] = project;
  }

  @override
  Future<List<Project>> listProjects() async {
    calls.add('list');
    return projects.values.toList(growable: false);
  }

  @override
  Future<Project?> getProject(String projectId) async {
    calls.add('get:$projectId');
    return projects[projectId];
  }

  @override
  Future<Project> renameProject({
    required String projectId,
    required String displayName,
  }) async {
    calls.add('rename:$projectId');
    final existing = projects[projectId];
    if (existing == null) {
      throw const ProjectRepositoryException(
        ProjectRepositoryFailure.projectNotFound,
      );
    }
    final updated = Project(
      projectId: projectId,
      displayName: displayName,
      createdAt: existing.createdAt,
    );
    projects[projectId] = updated;
    return updated;
  }

  @override
  Future<void> deleteProject(String projectId) async {
    calls.add('delete:$projectId');
    if (!projects.containsKey(projectId)) {
      throw const ProjectRepositoryException(
        ProjectRepositoryFailure.projectNotFound,
      );
    }
    projects.remove(projectId);
    files.remove(projectId);
    banks.remove(projectId);
  }

  @override
  Future<void> attachFile({
    required String projectId,
    required String fileId,
  }) async {
    calls.add('attachFile:$projectId:$fileId');
    files.putIfAbsent(projectId, () => <String>{}).add(fileId);
  }

  @override
  Future<void> detachFile({
    required String projectId,
    required String fileId,
  }) async {
    calls.add('detachFile:$projectId:$fileId');
    files[projectId]?.remove(fileId);
  }

  @override
  Future<void> attachBank({
    required String projectId,
    required String bankName,
  }) async {
    calls.add('attachBank:$projectId:$bankName');
    banks.putIfAbsent(projectId, () => <String>{}).add(bankName);
  }

  @override
  Future<void> detachBank({
    required String projectId,
    required String bankName,
  }) async {
    calls.add('detachBank:$projectId:$bankName');
    banks[projectId]?.remove(bankName);
  }

  @override
  Future<List<String>> listProjectFileIds(String projectId) async {
    calls.add('files:$projectId');
    final ids = files[projectId]?.toList() ?? <String>[];
    ids.sort();
    return ids;
  }

  @override
  Future<List<String>> listProjectBankNames(String projectId) async {
    calls.add('banks:$projectId');
    final names = banks[projectId]?.toList() ?? <String>[];
    names.sort();
    return names;
  }

  @override
  Future<List<String>> listProjectIdsForFile(String fileId) async {
    calls.add('forFile:$fileId');
    final ids = files.entries
        .where((entry) => entry.value.contains(fileId))
        .map((entry) => entry.key)
        .toList()
      ..sort();
    return ids;
  }

  @override
  Future<List<String>> listProjectIdsForBank(String bankName) async {
    calls.add('forBank:$bankName');
    final ids = banks.entries
        .where((entry) => entry.value.contains(bankName))
        .map((entry) => entry.key)
        .toList()
      ..sort();
    return ids;
  }
}

void main() {
  late _FakeProjectRepository repository;
  late ProjectService service;

  setUp(() {
    repository = _FakeProjectRepository();
    service = ProjectService(
      repository: repository,
      projectIdFactory: () => 'project-fixed-0001',
    );
  });

  group('ProjectService', () {
    test(
      'createProject delegates persistence and returns the domain model',
      () async {
        final created = await service.createProject(displayName: '数学');

        expect(created.projectId, 'project-fixed-0001');
        expect(created.displayName, '数学');
        expect(repository.projects[created.projectId], created);
        expect(repository.calls, <String>['create:project-fixed-0001']);
      },
    );

    test(
      'createProject rejects a blank name before any repository write',
      () async {
        await expectLater(
          service.createProject(displayName: '   '),
          throwsFormatException,
        );
        expect(repository.calls, isEmpty);
        expect(repository.projects, isEmpty);
      },
    );

    test('renameProject validates the label and delegates', () async {
      final created = await service.createProject(displayName: 'old');
      final renamed = await service.renameProject(
        projectId: created.projectId,
        displayName: 'new name',
      );

      expect(renamed.displayName, 'new name');
      expect(renamed.projectId, created.projectId);
      expect(repository.projects[created.projectId]!.displayName, 'new name');
    });

    test('renameProject rejects a blank label without delegating', () async {
      final created = await service.createProject(displayName: 'old');
      await expectLater(
        service.renameProject(projectId: created.projectId, displayName: ' '),
        throwsFormatException,
      );
      expect(repository.calls, <String>['create:project-fixed-0001']);
    });

    test('renameProject propagates repository notFound', () async {
      await expectLater(
        service.renameProject(projectId: 'project-missing', displayName: 'new'),
        throwsA(
          isA<ProjectRepositoryException>().having(
            (error) => error.failure,
            'failure',
            ProjectRepositoryFailure.projectNotFound,
          ),
        ),
      );
    });

    test('get, list, and delete delegate to the repository', () async {
      final created = await service.createProject(displayName: 'math');
      expect(await service.getProject(created.projectId), created);
      expect(await service.listProjects(), <Project>[created]);

      await service.deleteProject(created.projectId);
      expect(repository.projects, isEmpty);
      expect(await service.getProject(created.projectId), isNull);
    });

    test(
      'attach/detach file and bank delegate with project-scoped calls',
      () async {
        final created = await service.createProject(displayName: 'math');
        await service.attachFile(
          projectId: created.projectId,
          fileId: 'file-0001',
        );
        await service.attachBank(
          projectId: created.projectId,
          bankName: '高中数学',
        );
        await service.detachFile(
          projectId: created.projectId,
          fileId: 'file-0001',
        );
        await service.detachBank(
          projectId: created.projectId,
          bankName: '高中数学',
        );

        expect(await service.listProjectFileIds(created.projectId), isEmpty);
        expect(await service.listProjectBankNames(created.projectId), isEmpty);
        expect(repository.calls, <String>[
          'create:project-fixed-0001',
          'attachFile:project-fixed-0001:file-0001',
          'attachBank:project-fixed-0001:高中数学',
          'detachFile:project-fixed-0001:file-0001',
          'detachBank:project-fixed-0001:高中数学',
          'files:project-fixed-0001',
          'banks:project-fixed-0001',
        ]);
      },
    );

    test('attachBank rejects an empty compatibility key', () async {
      final created = await service.createProject(displayName: 'math');
      await expectLater(
        service.attachBank(projectId: created.projectId, bankName: ''),
        throwsFormatException,
      );
    });

    test('reverse membership queries delegate to the repository', () async {
      final a = await service.createProject(displayName: 'a');
      await service.attachFile(projectId: a.projectId, fileId: 'file-1');
      await service.attachBank(projectId: a.projectId, bankName: 'bank-1');

      expect(await service.listProjectIdsForFile('file-1'), <String>[
        a.projectId,
      ]);
      expect(await service.listProjectIdsForBank('bank-1'), <String>[
        a.projectId,
      ]);
    });
  });
}
