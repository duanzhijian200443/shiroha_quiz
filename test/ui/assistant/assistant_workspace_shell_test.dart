import 'package:flutter/material.dart';
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
import 'package:shiroha_quiz/ui/assistant/assistant_workspace_shell.dart';
import 'package:shiroha_quiz/ui/assistant/learning_spaces_screen.dart';
import 'package:shiroha_quiz/ui/assistant/workspace_controller.dart'
    show workspaceSafeError;
import 'package:shiroha_quiz/ui/assistant/workspace_pages.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';

const _sha = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

final class _Files implements LibraryFileRepositoryPort {
  bool failReads = false;
  final Map<String, LibraryFile> values = <String, LibraryFile>{};

  @override
  Future<List<LibraryFile>> findAll() async {
    if (failReads) throw StateError('file read failure');
    return values.values.toList();
  }

  @override
  Future<LibraryFile?> findById(String fileId) async {
    if (failReads) throw StateError('file read failure');
    return values[fileId];
  }

  @override
  Future<void> save(LibraryFile file) async => values[file.fileId] = file;
}

final class _Ingestion implements FileIngestionPort {
  @override
  Future<LibraryFile> ingest({
    required String externalPath,
    required String displayName,
    String? mimeType,
  }) {
    throw UnimplementedError();
  }
}

final class _Projects extends Fake implements ProjectRepository {
  bool failReads = false;
  final Map<String, Project> projects = <String, Project>{};
  final Map<String, Set<String>> files = <String, Set<String>>{};
  final Map<String, Set<String>> banks = <String, Set<String>>{};

  @override
  Future<List<Project>> listProjects() async {
    if (failReads) throw StateError('project read failure');
    return projects.values.toList();
  }

  @override
  Future<Project?> getProject(String projectId) async {
    if (failReads) throw StateError('project read failure');
    return projects[projectId];
  }

  @override
  Future<List<String>> listProjectFileIds(String projectId) async {
    if (failReads) throw StateError('project read failure');
    return (files[projectId]?.toList() ?? <String>[])..sort();
  }

  @override
  Future<List<String>> listProjectBankNames(String projectId) async {
    if (failReads) throw StateError('project read failure');
    return (banks[projectId]?.toList() ?? <String>[])..sort();
  }

  @override
  Future<List<String>> listProjectIdsForFile(String fileId) async {
    if (failReads) throw StateError('project read failure');
    return projects.keys
        .where((id) => files[id]?.contains(fileId) ?? false)
        .toList();
  }

  @override
  Future<List<String>> listProjectIdsForBank(String bankName) async {
    if (failReads) throw StateError('project read failure');
    return projects.keys
        .where((id) => banks[id]?.contains(bankName) ?? false)
        .toList();
  }

  @override
  Future<void> attachFile({
    required String projectId,
    required String fileId,
  }) async =>
      files.putIfAbsent(projectId, () => <String>{}).add(fileId);
  @override
  Future<void> detachFile({
    required String projectId,
    required String fileId,
  }) async =>
      files[projectId]?.remove(fileId);
  @override
  Future<void> attachBank({
    required String projectId,
    required String bankName,
  }) async =>
      banks.putIfAbsent(projectId, () => <String>{}).add(bankName);
  @override
  Future<void> detachBank({
    required String projectId,
    required String bankName,
  }) async =>
      banks[projectId]?.remove(bankName);
  @override
  Future<void> createProject(Project project) async {
    projects[project.projectId] = project;
  }

  @override
  Future<Project> renameProject({
    required String projectId,
    required String displayName,
  }) async {
    final existing = projects[projectId]!;
    return projects[projectId] = Project(
      projectId: projectId,
      displayName: displayName,
      createdAt: existing.createdAt,
    );
  }

  @override
  Future<void> deleteProject(String projectId) async {
    projects.remove(projectId);
    files.remove(projectId);
    banks.remove(projectId);
  }
}

final class _QuestionPort extends Fake implements StudyQuestionQueryPort {
  @override
  Future<StudyPage<QuestionBankSummary>> listStudyQuestionBanks({
    required int nowUnixSeconds,
    required int limit,
    String? afterBankName,
  }) async =>
      const StudyPage<QuestionBankSummary>(
        items: <QuestionBankSummary>[
          QuestionBankSummary(
            bankName: '真实题库',
            folderName: '未分类',
            questionCount: 42,
            dueCount: 2,
            masteredCount: 5,
          ),
        ],
        hasMore: false,
      );
}

final class _Metrics extends Fake implements StudyMetricsQueryPort {}

U1WorkspaceFacade _facade({_Files? files, _Projects? projects}) {
  final resolvedFiles = files ?? _Files();
  resolvedFiles.values['file-notes'] = LibraryFile(
    fileId: 'file-notes',
    displayName: 'notes.md',
    mimeType: 'text/markdown',
    sizeBytes: 1024,
    sha256: _sha,
    storageKey: 'library/file-notes',
    createdAt: DateTime.utc(2026, 8, 9),
  );
  final resolvedProjects = projects ?? _Projects();
  resolvedProjects.projects['project-deep'] = Project(
    projectId: 'project-deep',
    displayName: '深度学习',
    createdAt: DateTime.utc(2026, 8, 9),
  );
  resolvedProjects.files['project-deep'] = <String>{'file-notes'};
  resolvedProjects.banks['project-deep'] = <String>{'真实题库', '失效题库'};
  return U1WorkspaceFacade(
    projectService: ProjectService(
      repository: resolvedProjects,
      projectIdFactory: () => 'project-created',
    ),
    fileRepository: resolvedFiles,
    fileIngestion: _Ingestion(),
    studyQueryService: StudyQueryService(
      questionQuery: _QuestionPort(),
      metricsQuery: _Metrics(),
    ),
    mcpProjection: McpWorkspaceProjection(
      state: McpCapabilityState.configuredAvailable,
      transport: McpTransport.localStdio,
      permission: McpPermission.readOnly,
      toolNames: const <String>[
        'list_question_banks',
        'get_study_overview',
        'get_due_review_summary',
        'search_questions',
        'get_question_detail',
        'get_weak_questions',
      ],
    ),
  );
}

void main() {
  testWidgets('desktop shell renders real files, relations, and MCP capability',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1300, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: AssistantWorkspaceShell(facade: _facade()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('深度学习'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux01-open-file-library')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FileLibraryWorkspace), findsOneWidget);
    expect(find.text('notes.md'), findsOneWidget);
    expect(find.text('文件夹（后续版本）'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux01-file-file-notes')),
    );
    await tester.pumpAndSettle();
    expect(find.text('文件详情'), findsOneWidget);
    expect(find.text('关联学习空间'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(
        const ValueKey<String>('u1-ux01-space-home-project-deep'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('资料'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('题库已不存在'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux01-open-mcp')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(McpWorkspace), findsOneWidget);
    expect(find.text('已配置 / 可用'), findsOneWidget);
    expect(find.text('Local stdio'), findsOneWidget);
    expect(find.textContaining('不代表'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile drawer opens the real learning-space list',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: AssistantWorkspaceShell(facade: _facade()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux0-open-drawer')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux01-open-learning-spaces')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LearningSpacesScreen), findsOneWidget);
    expect(find.text('未归类内容'), findsOneWidget);
    expect(find.text('按旧分类浏览'), findsOneWidget);
    expect(find.text('2 个题库 · 1 个文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('learning-space home shows the failure state and retries',
      (tester) async {
    final projects = _Projects();
    final facade = _facade(projects: projects);
    await tester.binding.setSurfaceSize(const Size(1300, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: AssistantWorkspaceShell(facade: facade),
      ),
    );
    await tester.pumpAndSettle();

    projects.failReads = true;
    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux01-space-home-project-deep')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('u1-ux0-error-state')),
      findsOneWidget,
    );
    expect(find.text(workspaceSafeError), findsWidgets);

    projects.failReads = false;
    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux0-error-retry')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('u1-ux01-space-home-workspace')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('u1-ux0-error-state')),
      findsNothing,
    );
  });

  testWidgets('unclassified view shows the failure state and retries',
      (tester) async {
    final projects = _Projects();
    final facade = _facade(projects: projects);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: AssistantWorkspaceShell(facade: facade),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux0-open-drawer')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux01-open-learning-spaces')),
    );
    await tester.pumpAndSettle();

    projects.failReads = true;
    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux0-unclassified-view')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('u1-ux0-error-state')),
      findsOneWidget,
    );
    expect(find.text(workspaceSafeError), findsOneWidget);

    projects.failReads = false;
    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux0-error-retry')),
    );
    await tester.pumpAndSettle();

    expect(find.text('没有未归类文件'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('u1-ux0-error-state')),
      findsNothing,
    );
  });

  testWidgets('file detail shows the failure state and retries',
      (tester) async {
    final files = _Files();
    final projects = _Projects();
    final facade = _facade(files: files, projects: projects);
    files.values['file-other'] = LibraryFile(
      fileId: 'file-other',
      displayName: 'other.md',
      mimeType: 'text/markdown',
      sizeBytes: 512,
      sha256: _sha,
      storageKey: 'library/file-other',
      createdAt: DateTime.utc(2026, 8, 9, 2),
    );
    await tester.binding.setSurfaceSize(const Size(1300, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: AssistantWorkspaceShell(facade: facade),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux01-open-file-library')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux01-file-file-notes')),
    );
    await tester.pumpAndSettle();
    expect(find.text('文件详情'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    files.failReads = true;
    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux01-file-file-other')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('u1-ux0-error-state')),
      findsOneWidget,
    );

    files.failReads = false;
    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux0-error-retry')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('u1-file-space-project-deep')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('u1-ux0-error-state')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
