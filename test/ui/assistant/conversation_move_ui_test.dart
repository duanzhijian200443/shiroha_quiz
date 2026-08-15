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
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/application/study_query/study_query_service.dart';
import 'package:shiroha_quiz/application/u1_workspace/u1_workspace_dtos.dart';
import 'package:shiroha_quiz/application/u1_workspace/u1_workspace_facade.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/assets/library_folder.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/conversations/conversation_message.dart';
import 'package:shiroha_quiz/domain/projects/project.dart';
import 'package:shiroha_quiz/ui/assistant/assistant_screen.dart';
import 'package:shiroha_quiz/ui/assistant/conversation_controller.dart';
import 'package:shiroha_quiz/ui/assistant/workspace_controller.dart';

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
  int moveCalls = 0;
  ConversationScope? lastMoveTargetScope;

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
  Future<MoveConversationResult> moveConversation({
    required String conversationId,
    required ConversationScope targetScope,
    required DateTime movedAt,
  }) async {
    moveCalls++;
    lastMoveTargetScope = targetScope;
    final current = conversations[conversationId];
    if (current == null) {
      throw const ConversationException(
          ConversationFailure.conversationNotFound);
    }
    if (current.scope == targetScope) {
      return MoveConversationResult(conversation: current, moved: false);
    }
    final updated = current.withScope(
      scope: targetScope,
      updatedAt: movedAt,
    );
    conversations[conversationId] = updated;
    return MoveConversationResult(conversation: updated, moved: true);
  }

  @override
  Future<List<ConversationFileRef>> listAttachableFiles(
          {required int limit}) async =>
      const <ConversationFileRef>[];

  @override
  Future<List<Conversation>> listRecentConversations(
          {required int limit}) async =>
      conversations.values.toList();

  @override
  Future<List<Conversation>> listConversationsForProject({
    required String projectId,
    required int limit,
  }) async =>
      conversations.values
          .where((c) => c.scope.projectId == projectId)
          .toList();
}

final class _MockProjects extends Fake implements ProjectRepository {
  final Map<String, Project> projects = <String, Project>{};

  @override
  Future<List<Project>> listProjects() async => projects.values.toList();

  @override
  Future<Project?> getProject(String projectId) async => projects[projectId];

  @override
  Future<List<String>> listProjectFileIds(String projectId) async =>
      const <String>[];

  @override
  Future<List<String>> listProjectBankNames(String projectId) async =>
      const <String>[];
}

final class _MockFiles extends Fake implements LibraryFileRepositoryPort {
  @override
  Future<List<LibraryFile>> findAll() async => const <LibraryFile>[];
}

final class _MockFolders extends Fake implements LibraryFolderRepositoryPort {
  @override
  Future<List<LibraryFolder>> listFolders() async => const <LibraryFolder>[];

  @override
  Future<List<LibraryFile>> listUnclassifiedFiles() async =>
      const <LibraryFile>[];
}

final class _MockIngestion extends Fake implements FileIngestionPort {}

final class _MockQuestionQuery extends Fake implements StudyQuestionQueryPort {}

final class _MockMetricsQuery extends Fake implements StudyMetricsQueryPort {}

void main() {
  late _MockConversationRepository convRepo;
  late _MockProjects projRepo;
  late U1WorkspaceFacade facade;
  late ConversationService convService;
  late LearningSpacesController spacesController;
  late FileLibraryController fileController;
  late ConversationController convController;

  setUp(() {
    convRepo = _MockConversationRepository();
    projRepo = _MockProjects();
    final fileRepo = _MockFiles();
    final folderRepo = _MockFolders();

    facade = U1WorkspaceFacade(
      projectService: ProjectService(repository: projRepo),
      fileRepository: fileRepo,
      fileIngestion: _MockIngestion(),
      folderService: LibraryFolderService(
        repository: folderRepo,
        folderIdFactory: () => 'folder-1',
      ),
      studyQueryService: StudyQueryService(
        questionQuery: _MockQuestionQuery(),
        metricsQuery: _MockMetricsQuery(),
      ),
      mcpProjection: McpWorkspaceProjection(
        state: McpCapabilityState.configuredAvailable,
        transport: McpTransport.localStdio,
        permission: McpPermission.readOnly,
        toolNames: const <String>[],
      ),
    );

    convService = ConversationService(
      repository: convRepo,
      conversationIdFactory: () => 'conv-1',
      messageIdFactory: () => 'msg-1',
      clock: () => DateTime.utc(2026, 8, 14),
    );

    spacesController = LearningSpacesController(facade);
    fileController = FileLibraryController(facade);
    convController = ConversationController(
      convService,
      agentSettingsService: AgentSettingsService(
        configStore: _AgentConfigStore(),
        profileCatalog: _AgentProfiles(),
      ),
      startAgentTurn: ({required conversationId, required userMessageId}) {
        return AgentTurnSession(
          events: const Stream<AgentTurnEvent>.empty(),
          result: Completer<AgentTurnResult>().future,
          cancel: () {},
        );
      },
    );
  });

  Widget buildApp() {
    return MaterialApp(
      home: Scaffold(
        body: AssistantScreen(
          conversationController: convController,
          spacesController: spacesController,
          fileController: fileController,
        ),
      ),
    );
  }

  testWidgets(
      'draft scope selector opens draft picker and changes draft scope without confirmation dialog',
      (tester) async {
    projRepo.projects['proj-1'] = Project(
      projectId: 'proj-1',
      displayName: 'Math Project',
      createdAt: DateTime.utc(2026, 8, 14),
    );
    await spacesController.load();
    await convController.load();

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text('全局对话'), findsOneWidget);

    // Tap space selector
    await tester
        .tap(find.byKey(const ValueKey<String>('u1-ux0-space-selector')));
    await tester.pumpAndSettle();

    expect(find.text('选择对话范围'), findsOneWidget);
    expect(find.text('Math Project'), findsOneWidget);

    // Select Math Project
    await tester.tap(find.text('Math Project'));
    await tester.pumpAndSettle();

    // No confirmation dialog should appear
    expect(find.byKey(const ValueKey<String>('conv-move-confirmation-dialog')),
        findsNothing);
    expect(
        convController.draftScope, ConversationScope.learningSpace('proj-1'));
    expect(find.text('Math Project'), findsOneWidget);
    expect(convRepo.moveCalls, 0);
  });

  testWidgets(
      'persisted conversation space selector opens move picker with live spaces and global',
      (tester) async {
    projRepo.projects['proj-1'] = Project(
      projectId: 'proj-1',
      displayName: 'Math Space',
      createdAt: DateTime.utc(2026, 8, 14),
    );
    projRepo.projects['proj-2'] = Project(
      projectId: 'proj-2',
      displayName: 'Physics Space',
      createdAt: DateTime.utc(2026, 8, 14),
    );
    await spacesController.load();

    // Seed a global conversation
    final conv = Conversation(
      conversationId: 'conv-persisted',
      scope: ConversationScope.global(),
      title: 'Global Question',
      createdAt: DateTime.utc(2026, 8, 14),
      updatedAt: DateTime.utc(2026, 8, 14),
    );
    await convRepo.createWithFirstMessage(
      conversation: conv,
      firstMessage: ConversationMessage(
        messageId: 'msg-1',
        conversationId: 'conv-persisted',
        sequence: 1,
        role: ConversationMessageRole.user,
        content: 'Hello',
        createdAt: DateTime.utc(2026, 8, 14),
      ),
      fileIds: const <String>[],
      attachedAt: DateTime.utc(2026, 8, 14),
    );

    await convController.openConversation('conv-persisted');

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // Persisted header
    expect(find.text('全局对话'), findsOneWidget);

    // Tap space selector
    await tester
        .tap(find.byKey(const ValueKey<String>('u1-ux0-space-selector')));
    await tester.pumpAndSettle();

    expect(find.text('移动对话'), findsOneWidget);
    expect(find.text('全局对话'), findsWidgets);
    expect(find.text('Math Space'), findsOneWidget);
    expect(find.text('Physics Space'), findsOneWidget);
  });

  testWidgets(
      'selecting current scope in move picker dismisses with zero move calls and zero confirmation',
      (tester) async {
    projRepo.projects['proj-1'] = Project(
      projectId: 'proj-1',
      displayName: 'Math Space',
      createdAt: DateTime.utc(2026, 8, 14),
    );
    await spacesController.load();

    final conv = Conversation(
      conversationId: 'conv-persisted',
      scope: ConversationScope.learningSpace('proj-1'),
      title: 'Math Question',
      createdAt: DateTime.utc(2026, 8, 14),
      updatedAt: DateTime.utc(2026, 8, 14),
    );
    await convRepo.createWithFirstMessage(
      conversation: conv,
      firstMessage: ConversationMessage(
        messageId: 'msg-1',
        conversationId: 'conv-persisted',
        sequence: 1,
        role: ConversationMessageRole.user,
        content: 'Math content',
        createdAt: DateTime.utc(2026, 8, 14),
      ),
      fileIds: const <String>[],
      attachedAt: DateTime.utc(2026, 8, 14),
    );

    await convController.openConversation('conv-persisted');

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey<String>('u1-ux0-space-selector')));
    await tester.pumpAndSettle();

    // Tap current scope (Math Space) in bottom sheet
    await tester.tap(find.widgetWithText(ListTile, 'Math Space'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('conv-move-confirmation-dialog')),
        findsNothing);
    expect(convRepo.moveCalls, 0);
  });

  testWidgets(
      'selecting different scope shows confirmation dialog with required text, cancel makes 0 calls, confirm makes 1 call and updates UI',
      (tester) async {
    projRepo.projects['proj-1'] = Project(
      projectId: 'proj-1',
      displayName: 'Math Space',
      createdAt: DateTime.utc(2026, 8, 14),
    );
    await spacesController.load();

    final conv = Conversation(
      conversationId: 'conv-persisted',
      scope: ConversationScope.global(),
      title: 'Global Question',
      createdAt: DateTime.utc(2026, 8, 14),
      updatedAt: DateTime.utc(2026, 8, 14),
    );
    await convRepo.createWithFirstMessage(
      conversation: conv,
      firstMessage: ConversationMessage(
        messageId: 'msg-1',
        conversationId: 'conv-persisted',
        sequence: 1,
        role: ConversationMessageRole.user,
        content: 'Global content',
        createdAt: DateTime.utc(2026, 8, 14),
      ),
      fileIds: const <String>[],
      attachedAt: DateTime.utc(2026, 8, 14),
    );

    await convController.openConversation('conv-persisted');

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 1. Test Cancel
    await tester
        .tap(find.byKey(const ValueKey<String>('u1-ux0-space-selector')));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ListTile, 'Math Space'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('conv-move-confirmation-dialog')),
        findsOneWidget);
    expect(find.text('移动对话？'), findsOneWidget);
    expect(find.textContaining('将此对话移动到「Math Space」'), findsOneWidget);
    expect(find.textContaining('历史消息和已附加文件不会改变'), findsOneWidget);
    expect(find.textContaining('之后 Shiroha 的回复和本地检索将使用新的对话范围'), findsOneWidget);

    await tester
        .tap(find.byKey(const ValueKey<String>('conv-move-dialog-cancel')));
    await tester.pumpAndSettle();

    expect(convRepo.moveCalls, 0);
    expect(convController.currentScope, ConversationScope.global());

    // 2. Test Confirm
    await tester
        .tap(find.byKey(const ValueKey<String>('u1-ux0-space-selector')));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ListTile, 'Math Space'));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey<String>('conv-move-dialog-confirm')));
    await tester.pumpAndSettle();

    expect(convRepo.moveCalls, 1);
    expect(convRepo.lastMoveTargetScope,
        ConversationScope.learningSpace('proj-1'));
    expect(
        convController.currentScope, ConversationScope.learningSpace('proj-1'));
    expect(find.text('Math Space'), findsOneWidget);
    expect(find.text('已移动到「Math Space」'), findsOneWidget);
  });

  testWidgets(
      'unavailable historical conversation shows subtitle and can be relocated to Global',
      (tester) async {
    await spacesController.load();

    final conv = Conversation(
      conversationId: 'conv-unavail',
      scope: ConversationScope.unavailableLearningSpace(),
      title: 'Orphaned Conversation',
      createdAt: DateTime.utc(2026, 8, 14),
      updatedAt: DateTime.utc(2026, 8, 14),
    );
    await convRepo.createWithFirstMessage(
      conversation: conv,
      firstMessage: ConversationMessage(
        messageId: 'msg-1',
        conversationId: 'conv-unavail',
        sequence: 1,
        role: ConversationMessageRole.user,
        content: 'Orphaned content',
        createdAt: DateTime.utc(2026, 8, 14),
      ),
      fileIds: const <String>[],
      attachedAt: DateTime.utc(2026, 8, 14),
    );

    await convController.openConversation('conv-unavail');

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text('原学习空间已删除'), findsWidgets);

    // Open space selector
    await tester
        .tap(find.byKey(const ValueKey<String>('u1-ux0-space-selector')));
    await tester.pumpAndSettle();

    expect(find.text('移动对话'), findsOneWidget);
    expect(find.text('原学习空间已删除'), findsWidgets);

    // Select Global
    await tester.tap(find.widgetWithText(ListTile, '全局对话'));
    await tester.pumpAndSettle();

    expect(find.text('移动对话？'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey<String>('conv-move-dialog-confirm')));
    await tester.pumpAndSettle();

    expect(convRepo.moveCalls, 1);
    expect(convController.currentScope, ConversationScope.global());
    expect(find.text('已移动到「全局对话」'), findsOneWidget);
  });

  testWidgets('active turn blocks move picker with feedback "请先停止当前生成"',
      (tester) async {
    final conv = Conversation(
      conversationId: 'conv-active',
      scope: ConversationScope.global(),
      title: 'Active Question',
      createdAt: DateTime.utc(2026, 8, 14),
      updatedAt: DateTime.utc(2026, 8, 14),
    );
    await convRepo.createWithFirstMessage(
      conversation: conv,
      firstMessage: ConversationMessage(
        messageId: 'msg-1',
        conversationId: 'conv-active',
        sequence: 1,
        role: ConversationMessageRole.user,
        content: 'Running turn',
        createdAt: DateTime.utc(2026, 8, 14),
      ),
      fileIds: const <String>[],
      attachedAt: DateTime.utc(2026, 8, 14),
    );

    await convController.openConversation('conv-active');
    // Simulate active turn
    convController.isSending = true;

    await tester.pumpWidget(buildApp());
    await tester.pump();

    await tester
        .tap(find.byKey(const ValueKey<String>('u1-ux0-space-selector')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('移动对话'), findsNothing);
    expect(find.text('请先停止当前生成'), findsOneWidget);
  });
}
