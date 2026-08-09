import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/file_library/file_library_ports.dart';
import 'package:shiroha_quiz/application/projects/project_repository.dart';
import 'package:shiroha_quiz/application/projects/project_service.dart';
import 'package:shiroha_quiz/application/study_query/study_query_dtos.dart';
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/application/study_query/study_query_service.dart';
import 'package:shiroha_quiz/application/u1_workspace/u1_workspace_dtos.dart';
import 'package:shiroha_quiz/application/u1_workspace/u1_workspace_facade.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/projects/project.dart';

const _sha = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

LibraryFile _file(String id, int hour) => LibraryFile(
      fileId: id,
      displayName: '$id.pdf',
      mimeType: 'application/pdf',
      sizeBytes: hour,
      sha256: _sha,
      storageKey: 'library/$id',
      createdAt: DateTime.utc(2026, 8, 9, hour),
    );

final class _Files implements LibraryFileRepositoryPort {
  final Map<String, LibraryFile> values = <String, LibraryFile>{};

  @override
  Future<List<LibraryFile>> findAll() async => values.values.toList();

  @override
  Future<LibraryFile?> findById(String fileId) async => values[fileId];

  @override
  Future<void> save(LibraryFile file) async => values[file.fileId] = file;
}

final class _Ingestion implements FileIngestionPort {
  _Ingestion(this.files);

  final _Files files;
  String? receivedMimeType;

  @override
  Future<LibraryFile> ingest({
    required String externalPath,
    required String displayName,
    String? mimeType,
  }) async {
    receivedMimeType = mimeType;
    final value = LibraryFile(
      fileId: 'ingested-file',
      displayName: displayName,
      mimeType: mimeType ?? 'application/octet-stream',
      sizeBytes: 1,
      sha256: _sha,
      storageKey: 'library/ingested-file',
      createdAt: DateTime.utc(2026, 8, 9),
    );
    await files.save(value);
    return value;
  }
}

final class _Projects implements ProjectRepository {
  final Map<String, Project> projects = <String, Project>{};
  final Map<String, Set<String>> files = <String, Set<String>>{};
  final Map<String, Set<String>> banks = <String, Set<String>>{};

  @override
  Future<void> attachBank({
    required String projectId,
    required String bankName,
  }) async =>
      banks.putIfAbsent(projectId, () => <String>{}).add(bankName);

  @override
  Future<void> attachFile({
    required String projectId,
    required String fileId,
  }) async =>
      files.putIfAbsent(projectId, () => <String>{}).add(fileId);

  @override
  Future<void> createProject(Project project) async {
    projects[project.projectId] = project;
  }

  @override
  Future<void> deleteProject(String projectId) async {
    projects.remove(projectId);
    files.remove(projectId);
    banks.remove(projectId);
  }

  @override
  Future<void> detachBank({
    required String projectId,
    required String bankName,
  }) async =>
      banks[projectId]?.remove(bankName);

  @override
  Future<void> detachFile({
    required String projectId,
    required String fileId,
  }) async =>
      files[projectId]?.remove(fileId);

  @override
  Future<Project?> getProject(String projectId) async => projects[projectId];

  @override
  Future<List<Project>> listProjects() async => projects.values.toList();

  @override
  Future<List<String>> listProjectBankNames(String projectId) async =>
      (banks[projectId]?.toList() ?? <String>[])..sort();

  @override
  Future<List<String>> listProjectFileIds(String projectId) async =>
      (files[projectId]?.toList() ?? <String>[])..sort();

  @override
  Future<List<String>> listProjectIdsForBank(String bankName) async =>
      projects.keys
          .where((id) => banks[id]?.contains(bankName) ?? false)
          .toList();

  @override
  Future<List<String>> listProjectIdsForFile(String fileId) async =>
      projects.keys
          .where((id) => files[id]?.contains(fileId) ?? false)
          .toList();

  @override
  Future<Project> renameProject({
    required String projectId,
    required String displayName,
  }) async {
    final old = projects[projectId]!;
    final value = Project(
      projectId: projectId,
      displayName: displayName,
      createdAt: old.createdAt,
    );
    projects[projectId] = value;
    return value;
  }
}

final class _QuestionPort extends Fake implements StudyQuestionQueryPort {
  _QuestionPort(this.banks);

  final List<QuestionBankSummary> banks;

  @override
  Future<StudyPage<QuestionBankSummary>> listStudyQuestionBanks({
    required int nowUnixSeconds,
    required int limit,
    String? afterBankName,
  }) async {
    final start = afterBankName == null
        ? 0
        : banks.indexWhere((bank) => bank.bankName == afterBankName) + 1;
    final remaining = banks.skip(start).toList();
    return StudyPage<QuestionBankSummary>(
      items: remaining.take(limit).toList(),
      hasMore: remaining.length > limit,
    );
  }
}

final class _MetricsPort extends Fake implements StudyMetricsQueryPort {}

void main() {
  late _Files files;
  late _Ingestion ingestion;
  late _Projects projects;
  late U1WorkspaceFacade facade;

  setUp(() {
    files = _Files();
    ingestion = _Ingestion(files);
    projects = _Projects();
    facade = U1WorkspaceFacade(
      projectService: ProjectService(
        repository: projects,
        projectIdFactory: () => 'project-new',
      ),
      fileRepository: files,
      fileIngestion: ingestion,
      studyQueryService: StudyQueryService(
        questionQuery: _QuestionPort(const <QuestionBankSummary>[
          QuestionBankSummary(
            bankName: 'existing-bank',
            folderName: '未分类',
            questionCount: 3,
            dueCount: 1,
            masteredCount: 1,
          ),
        ]),
        metricsQuery: _MetricsPort(),
      ),
      mcpProjection: McpWorkspaceProjection(
        state: McpCapabilityState.configuredAvailable,
        transport: McpTransport.localStdio,
        permission: McpPermission.readOnly,
        toolNames: const <String>['list_question_banks'],
      ),
    );
  });

  test('lists newest files and caps the recent view at twenty', () async {
    for (var hour = 0; hour < 21; hour++) {
      final id = 'file-${hour.toString().padLeft(2, '0')}';
      files.values[id] = _file(id, hour);
    }

    final all = await facade.listLibraryFiles();
    final recent = await facade.listLibraryFiles(view: FileLibraryView.recent);

    expect(all.first.fileId, 'file-20');
    expect(recent, hasLength(20));
    expect(recent.last.fileId, 'file-01');
  });

  test('projects aggregate counts and preserve dangling bank references',
      () async {
    final project = Project(
      projectId: 'project-a',
      displayName: '深度学习',
      createdAt: DateTime.utc(2026, 8, 9),
    );
    projects.projects[project.projectId] = project;
    files.values['file-a'] = _file('file-a', 1);
    projects.files[project.projectId] = <String>{'file-a'};
    projects.banks[project.projectId] = <String>{
      'existing-bank',
      'missing-bank',
    };

    final detail = await facade.getLearningSpace(project.projectId);

    expect(detail!.summary.fileCount, 1);
    expect(detail.summary.bankCount, 2);
    expect(
      detail.banks
          .singleWhere((bank) => bank.bankName == 'missing-bank')
          .isMissing,
      isTrue,
    );
  });

  test('unclassified projection uses empty reverse relations', () async {
    files.values['free-file'] = _file('free-file', 1);

    final result = await facade.getUnclassifiedAssets();

    expect(result.files.single.fileId, 'free-file');
    expect(result.banks.single.bankName, 'existing-bank');
  });

  test('ingestion infers known MIME types and safely falls back', () async {
    await facade.ingestSelectedFile(
      externalPath: 'ephemeral-input',
      displayName: 'notes.md',
    );
    expect(ingestion.receivedMimeType, 'text/markdown');
    expect(
      U1WorkspaceFacade.mimeTypeForDisplayName('unknown.data'),
      'application/octet-stream',
    );
  });

  test('MCP projection describes capability without a running state', () {
    expect(facade.mcpProjection.state, McpCapabilityState.configuredAvailable);
    expect(facade.mcpProjection.transport, McpTransport.localStdio);
    expect(facade.mcpProjection.permission, McpPermission.readOnly);
    expect(facade.mcpProjection.toolNames, <String>['list_question_banks']);
  });
}
