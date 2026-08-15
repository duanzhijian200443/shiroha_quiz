import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_config.dart';
import 'package:shiroha_quiz/application/agent/agent_config_service.dart';
import 'package:shiroha_quiz/application/agent/agent_turn.dart';
import 'package:shiroha_quiz/application/conversations/conversation_repository.dart';
import 'package:shiroha_quiz/application/conversations/conversation_service.dart';
import 'package:shiroha_quiz/application/file_library/file_library_ports.dart';
import 'package:shiroha_quiz/application/file_library/library_folder_repository.dart';
import 'package:shiroha_quiz/application/file_library/library_folder_service.dart';
import 'package:shiroha_quiz/application/projects/project_repository.dart';
import 'package:shiroha_quiz/application/projects/project_service.dart';
import 'package:shiroha_quiz/application/study_query/study_query_dtos.dart';
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/application/study_query/study_query_service.dart';
import 'package:shiroha_quiz/application/u1_workspace/u1_workspace_dtos.dart';
import 'package:shiroha_quiz/application/u1_workspace/u1_workspace_facade.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/assets/library_folder.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/conversations/conversation_message.dart';
import 'package:shiroha_quiz/domain/projects/project.dart';
import 'package:shiroha_quiz/ui/assistant/assistant_workspace_shell.dart';
import 'package:shiroha_quiz/ui/assistant/learning_spaces_screen.dart';
import 'package:shiroha_quiz/ui/assistant/workspace_pages.dart';

final class _AgentConfigStore implements AgentConfigStorePort {
  String? encoded = const AgentConfigCodec().encode(
    AgentConfig(
      providerKind: AgentProviderKind.deepSeekResponses,
      mainProfileId: 'profile-test',
    ),
  );

  @override
  Future<String?> readAgentConfig() async => encoded;

  @override
  Future<void> writeAgentConfig(String encodedConfig) async {
    encoded = encodedConfig;
  }
}

final class _AgentProfiles implements AgentProfileCatalogPort {
  @override
  Future<List<AgentProfileSummary>> listMainProfiles() async =>
      <AgentProfileSummary>[
        AgentProfileSummary(
          profileId: 'profile-test',
          displayName: 'Test model',
          modelName: 'deepseek-v4-flash',
        ),
      ];
}

final class _MockConversationRepository extends Fake
    implements ConversationRepositoryPort {
  final Map<String, Conversation> conversations = <String, Conversation>{};
  final Map<String, List<ConversationMessage>> messagesByConv =
      <String, List<ConversationMessage>>{};
  int deleteCalls = 0;
  String? lastDeletedId;

  @override
  Future<ConversationThreadSlice> createWithFirstMessage({
    required Conversation conversation,
    required ConversationMessage firstMessage,
    required List<String> fileIds,
    required DateTime attachedAt,
  }) async {
    conversations[conversation.conversationId] = conversation;
    messagesByConv[conversation.conversationId] = <ConversationMessage>[
      firstMessage
    ];
    return ConversationThreadSlice(
      conversation: conversation,
      messages: <ConversationMessage>[firstMessage],
      files: const <ConversationFileRef>[],
      hasMoreBefore: false,
      nextBeforeSequence: null,
    );
  }

  @override
  Future<ConversationThreadSlice> loadConversation({
    required String conversationId,
    required int limit,
    int? beforeSequence,
  }) async {
    final conv = conversations[conversationId];
    if (conv == null) {
      throw const ConversationException(
          ConversationFailure.conversationNotFound);
    }
    return ConversationThreadSlice(
      conversation: conv,
      messages: messagesByConv[conversationId] ?? <ConversationMessage>[],
      files: const <ConversationFileRef>[],
      hasMoreBefore: false,
      nextBeforeSequence: null,
    );
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    deleteCalls++;
    lastDeletedId = conversationId;
    conversations.remove(conversationId);
    messagesByConv.remove(conversationId);
  }

  @override
  Future<List<Conversation>> listRecentConversations(
          {required int limit}) async =>
      conversations.values
          .where((c) =>
              c.scope.kind == ConversationScopeKind.global ||
              c.scope.isUnavailableLearningSpace)
          .toList();

  @override
  Future<List<Conversation>> listConversationsForProject({
    required String projectId,
    required int limit,
  }) async {
    return conversations.values
        .where((c) => c.scope.projectId == projectId)
        .toList();
  }

  @override
  Future<List<ConversationFileRef>> listAttachableFiles(
          {required int limit}) async =>
      const <ConversationFileRef>[];

  void seedConversation(
    String id, {
    required String title,
    ConversationScope? scope,
  }) {
    final timestamp = DateTime.utc(2026, 8, 16);
    final conv = Conversation(
      conversationId: id,
      scope: scope ?? ConversationScope.global(),
      title: title,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
    conversations[id] = conv;
    messagesByConv[id] = <ConversationMessage>[
      ConversationMessage(
        messageId: 'msg-$id',
        conversationId: id,
        sequence: 1,
        role: ConversationMessageRole.user,
        content: 'Seed message for $title',
        createdAt: timestamp,
      ),
    ];
  }
}

final class _MockProjectRepository extends Fake implements ProjectRepository {
  final Map<String, Project> projects = <String, Project>{};
  final Map<String, Set<String>> files = <String, Set<String>>{};
  final Map<String, Set<String>> banks = <String, Set<String>>{};
  int deleteCalls = 0;
  String? lastDeletedId;

  @override
  Future<List<Project>> listProjects() async => projects.values.toList();

  @override
  Future<Project?> getProject(String projectId) async => projects[projectId];

  @override
  Future<List<String>> listProjectFileIds(String projectId) async =>
      files[projectId]?.toList() ?? const <String>[];

  @override
  Future<List<String>> listProjectBankNames(String projectId) async =>
      banks[projectId]?.toList() ?? const <String>[];

  @override
  Future<List<String>> listProjectIdsForFile(String fileId) async =>
      projects.keys
          .where((id) => files[id]?.contains(fileId) ?? false)
          .toList();

  @override
  Future<List<String>> listProjectIdsForBank(String bankName) async =>
      projects.keys
          .where((id) => banks[id]?.contains(bankName) ?? false)
          .toList();

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

  void Function(String projectId)? onDeleteProject;

  @override
  Future<void> deleteProject(String projectId) async {
    deleteCalls++;
    lastDeletedId = projectId;
    projects.remove(projectId);
    files.remove(projectId);
    banks.remove(projectId);
    onDeleteProject?.call(projectId);
  }

  void seedProject(String id, String name) {
    final timestamp = DateTime.utc(2026, 8, 16);
    projects[id] = Project(
      projectId: id,
      displayName: name,
      createdAt: timestamp,
    );
  }
}

final class _MockFiles implements LibraryFileRepositoryPort {
  final Map<String, LibraryFile> values = <String, LibraryFile>{};

  @override
  Future<List<LibraryFile>> findAll() async => values.values.toList();

  @override
  Future<LibraryFile?> findById(String fileId) async => values[fileId];

  @override
  Future<void> save(LibraryFile file) async => values[file.fileId] = file;
}

final class _MockFolders extends Fake implements LibraryFolderRepositoryPort {
  final Map<String, LibraryFolder> values = <String, LibraryFolder>{};
  final Map<String, String> memberships = <String, String>{};

  @override
  Future<List<LibraryFolder>> listFolders() async => values.values.toList();

  @override
  Future<LibraryFolder?> findFolder(String folderId) async => values[folderId];

  @override
  Future<void> createFolder(LibraryFolder folder) async {
    values[folder.folderId] = folder;
  }

  @override
  Future<LibraryFolder> renameFolder({
    required String folderId,
    required String displayName,
  }) async {
    final old = values[folderId]!;
    return values[folderId] = LibraryFolder(
      folderId: folderId,
      displayName: displayName,
      createdAt: old.createdAt,
    );
  }

  @override
  Future<void> deleteFolder(String folderId) async {
    values.remove(folderId);
    memberships.removeWhere((_, value) => value == folderId);
  }

  @override
  Future<LibraryFolder?> getFolderForFile(String fileId) async {
    final folderId = memberships[fileId];
    return folderId == null ? null : values[folderId];
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

  @override
  Future<List<LibraryFile>> listFilesInFolder(String folderId) async =>
      const <LibraryFile>[];

  @override
  Future<List<LibraryFile>> listUnclassifiedFiles() async =>
      const <LibraryFile>[];
}

final class _MockIngestion implements FileIngestionPort {
  @override
  Future<LibraryFile> ingest({
    required String externalPath,
    required String displayName,
    String? mimeType,
  }) {
    throw UnimplementedError();
  }
}

final class _MockQuestionPort extends Fake implements StudyQuestionQueryPort {
  @override
  Future<StudyPage<QuestionBankSummary>> listStudyQuestionBanks({
    required int nowUnixSeconds,
    required int limit,
    String? afterBankName,
  }) async =>
      const StudyPage<QuestionBankSummary>(
        items: <QuestionBankSummary>[],
        hasMore: false,
      );
}

final class _MockMetrics extends Fake implements StudyMetricsQueryPort {}

U1WorkspaceFacade _buildFacade({
  required _MockProjectRepository projectRepo,
  _MockFiles? fileRepo,
  _MockFolders? folderRepo,
}) {
  final resolvedFiles = fileRepo ?? _MockFiles();
  final resolvedFolders = folderRepo ?? _MockFolders();
  return U1WorkspaceFacade(
    projectService: ProjectService(
      repository: projectRepo,
      projectIdFactory: () => 'project-created',
    ),
    fileRepository: resolvedFiles,
    fileIngestion: _MockIngestion(),
    folderService: LibraryFolderService(
      repository: resolvedFolders,
      folderIdFactory: () => 'folder-created',
    ),
    studyQueryService: StudyQueryService(
      questionQuery: _MockQuestionPort(),
      metricsQuery: _MockMetrics(),
    ),
    mcpProjection: McpWorkspaceProjection(
      state: McpCapabilityState.configuredAvailable,
      transport: McpTransport.localStdio,
      permission: McpPermission.readOnly,
      toolNames: const <String>[],
    ),
  );
}

AgentTurnSession _stubTurn({
  required String conversationId,
  required String userMessageId,
}) {
  return AgentTurnSession(
    events: const Stream<AgentTurnEvent>.empty(),
    result: Completer<AgentTurnResult>().future,
    cancel: () {},
  );
}

Widget _buildTestApp({
  required U1WorkspaceFacade facade,
  required ConversationService convService,
}) {
  return MaterialApp(
    home: AssistantWorkspaceShell(
      facade: facade,
      conversationService: convService,
      agentSettingsService: AgentSettingsService(
        configStore: _AgentConfigStore(),
        profileCatalog: _AgentProfiles(),
      ),
      startAgentTurn: _stubTurn,
    ),
  );
}

void main() {
  group('U1-LIFECYCLE-UX Conversation Item UI', () {
    testWidgets('8. conversation action menu appears on right side',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final convRepo = _MockConversationRepository();
      convRepo.seedConversation('conv-1', title: 'Calculus Discussion');
      final projectRepo = _MockProjectRepository();
      final facade = _buildFacade(projectRepo: projectRepo);
      final convService = ConversationService(
        repository: convRepo,
        conversationIdFactory: () => 'conv-new',
        messageIdFactory: () => 'msg-new',
      );

      await tester.pumpWidget(
        _buildTestApp(facade: facade, convService: convService),
      );
      await tester.pumpAndSettle();

      expect(find.text('Calculus Discussion'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('c0-conversation-menu-conv-1')),
        findsOneWidget,
      );
    });

    testWidgets('9. tapping row opens conversation', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final convRepo = _MockConversationRepository();
      convRepo.seedConversation('conv-1', title: 'Physics Notes');
      final projectRepo = _MockProjectRepository();
      final facade = _buildFacade(projectRepo: projectRepo);
      final convService = ConversationService(
        repository: convRepo,
        conversationIdFactory: () => 'conv-new',
        messageIdFactory: () => 'msg-new',
      );

      await tester.pumpWidget(
        _buildTestApp(facade: facade, convService: convService),
      );
      await tester.pumpAndSettle();

      // Tap conversation row
      await tester.tap(find.text('Physics Notes'));
      await tester.pumpAndSettle();

      expect(find.text('Seed message for Physics Notes'), findsOneWidget);
    });

    testWidgets('10. tapping ... opens menu without opening conversation',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final convRepo = _MockConversationRepository();
      convRepo.seedConversation('conv-1', title: 'Discrete Math');
      final projectRepo = _MockProjectRepository();
      final facade = _buildFacade(projectRepo: projectRepo);
      final convService = ConversationService(
        repository: convRepo,
        conversationIdFactory: () => 'conv-new',
        messageIdFactory: () => 'msg-new',
      );

      await tester.pumpWidget(
        _buildTestApp(facade: facade, convService: convService),
      );
      await tester.pumpAndSettle();

      // Tap action menu ...
      await tester.tap(
        find.byKey(const ValueKey<String>('c0-conversation-menu-conv-1')),
      );
      await tester.pumpAndSettle();

      // Menu is open
      expect(
        find.byKey(const ValueKey<String>('c0-conversation-delete-conv-1')),
        findsOneWidget,
      );
      expect(find.text('删除对话'), findsOneWidget);
      // Conversation was not opened
      expect(find.text('Seed message for Discrete Math'), findsNothing);
    });

    testWidgets(
        '11-13. delete action invokes confirmation; cancel/confirm behavior',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final convRepo = _MockConversationRepository();
      convRepo.seedConversation('conv-1', title: 'Linear Algebra');
      final projectRepo = _MockProjectRepository();
      final facade = _buildFacade(projectRepo: projectRepo);
      final convService = ConversationService(
        repository: convRepo,
        conversationIdFactory: () => 'conv-new',
        messageIdFactory: () => 'msg-new',
      );

      await tester.pumpWidget(
        _buildTestApp(facade: facade, convService: convService),
      );
      await tester.pumpAndSettle();

      // 11. Open menu and tap delete
      await tester.tap(
        find.byKey(const ValueKey<String>('c0-conversation-menu-conv-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除对话'));
      await tester.pumpAndSettle();

      expect(find.text('删除对话？'), findsOneWidget);
      expect(find.textContaining('将删除对话「Linear Algebra」'), findsOneWidget);

      // 12. Cancel = 0 delete call
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(convRepo.deleteCalls, 0);
      expect(find.text('Linear Algebra'), findsOneWidget);

      // 13. Confirm = 1 delete call
      await tester.tap(
        find.byKey(const ValueKey<String>('c0-conversation-menu-conv-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除对话'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(convRepo.deleteCalls, 1);
      expect(convRepo.lastDeletedId, 'conv-1');
      expect(find.text('Linear Algebra'), findsNothing);
    });
  });

  group('U1-LIFECYCLE-UX Learning Space Expand & Menu UX', () {
    testWidgets(
        '14-17. clicking card expands/collapses; no chevron; menu tap isolates expansion',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final convRepo = _MockConversationRepository();
      convRepo.seedConversation(
        'conv-space-1',
        title: 'Space Topic 1',
        scope: ConversationScope.learningSpace('space-1'),
      );
      final projectRepo = _MockProjectRepository();
      projectRepo.seedProject('space-1', 'Biology Space');
      final facade = _buildFacade(projectRepo: projectRepo);
      final convService = ConversationService(
        repository: convRepo,
        conversationIdFactory: () => 'conv-new',
        messageIdFactory: () => 'msg-new',
      );

      await tester.pumpWidget(
        _buildTestApp(facade: facade, convService: convService),
      );
      await tester.pumpAndSettle();

      expect(find.text('Biology Space'), findsOneWidget);
      expect(find.text('Space Topic 1'), findsNothing);

      // 16. No independent chevron button
      expect(find.byIcon(Icons.expand_more), findsNothing);

      // 17. Tapping menu does NOT expand
      await tester.tap(
        find.byKey(const ValueKey<String>('u1-space-menu-space-1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('进入主页'), findsOneWidget);
      expect(find.text('Space Topic 1'), findsNothing);

      // Dismiss menu
      await tester.tapAt(const Offset(600, 400));
      await tester.pumpAndSettle();

      // 14. Clicking card body expands space
      await tester.tap(find.text('Biology Space'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey<String>('c0-space-conversation-conv-space-1'),
        ),
        findsOneWidget,
      );

      // 15. Clicking same card body collapses space
      await tester.tap(find.text('Biology Space'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey<String>('c0-space-conversation-conv-space-1'),
        ),
        findsNothing,
      );
    });

    testWidgets(
        '18-21. menu contains home & delete; home navigates; delete shows confirmation',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final convRepo = _MockConversationRepository();
      final projectRepo = _MockProjectRepository();
      projectRepo.seedProject('space-1', 'Chemistry Space');
      final facade = _buildFacade(projectRepo: projectRepo);
      final convService = ConversationService(
        repository: convRepo,
        conversationIdFactory: () => 'conv-new',
        messageIdFactory: () => 'msg-new',
      );

      await tester.pumpWidget(
        _buildTestApp(facade: facade, convService: convService),
      );
      await tester.pumpAndSettle();

      // Open menu
      await tester.tap(
        find.byKey(const ValueKey<String>('u1-space-menu-space-1')),
      );
      await tester.pumpAndSettle();

      // 18. Contains "进入主页"
      expect(find.text('进入主页'), findsOneWidget);
      // 19. Contains "删除学习空间"
      expect(find.text('删除学习空间'), findsOneWidget);

      // 20. Choosing "进入主页" navigates correctly
      await tester.tap(find.text('进入主页'));
      await tester.pumpAndSettle();
      expect(find.byType(LearningSpaceHomeWorkspace), findsOneWidget);

      // Open menu again
      await tester.tap(
        find.byKey(const ValueKey<String>('u1-space-menu-space-1')),
      );
      await tester.pumpAndSettle();

      // 21. Choosing "删除学习空间" shows confirmation
      await tester.tap(find.text('删除学习空间'));
      await tester.pumpAndSettle();
      expect(find.text('删除学习空间？'), findsOneWidget);
      expect(find.textContaining('将删除学习空间「Chemistry Space」'), findsOneWidget);
    });

    testWidgets(
        '22-26. learning space delete: cancel/confirm; UI removal; safe fallback',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final convRepo = _MockConversationRepository();
      convRepo.seedConversation(
        'conv-space-1',
        title: 'Space Conv 1',
        scope: ConversationScope.learningSpace('space-1'),
      );
      final projectRepo = _MockProjectRepository();
      projectRepo.seedProject('space-1', 'Target Space');
      projectRepo.onDeleteProject = (id) {
        final existing = convRepo.conversations['conv-space-1'];
        if (existing != null && existing.scope.projectId == id) {
          convRepo.conversations['conv-space-1'] = existing.withScope(
            scope: ConversationScope.unavailableLearningSpace(),
            updatedAt: DateTime.utc(2026, 8, 16),
          );
        }
      };
      final facade = _buildFacade(projectRepo: projectRepo);
      final convService = ConversationService(
        repository: convRepo,
        conversationIdFactory: () => 'conv-new',
        messageIdFactory: () => 'msg-new',
      );

      await tester.pumpWidget(
        _buildTestApp(facade: facade, convService: convService),
      );
      await tester.pumpAndSettle();

      // Open space home
      await tester.tap(
        find.byKey(const ValueKey<String>('u1-space-menu-space-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('进入主页'));
      await tester.pumpAndSettle();
      expect(find.byType(LearningSpaceHomeWorkspace), findsOneWidget);

      // Open menu from sidebar while viewing home
      await tester.tap(
        find.byKey(const ValueKey<String>('u1-space-menu-space-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除学习空间'));
      await tester.pumpAndSettle();

      // 22. Cancel = 0 delete call
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(projectRepo.deleteCalls, 0);

      // 23. Confirm = 1 delete call
      await tester.tap(
        find.byKey(const ValueKey<String>('u1-space-menu-space-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除学习空间'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(projectRepo.deleteCalls, 1);
      expect(projectRepo.lastDeletedId, 'space-1');

      // 24. Space removed from UI
      expect(find.text('Target Space'), findsNothing);

      // 25. Workspace safely falls back without crash or dangling state
      expect(find.byType(LearningSpacesScreen), findsOneWidget);

      // 26. Associated conversations remain reachable/recoverable in recent list
      expect(find.text('Space Conv 1'), findsOneWidget);
    });
  });
}
