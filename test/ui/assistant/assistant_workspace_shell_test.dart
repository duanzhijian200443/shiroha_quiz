import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_config.dart';
import 'package:shiroha_quiz/application/agent/agent_config_service.dart';
import 'package:shiroha_quiz/application/agent/agent_provider.dart';
import 'package:shiroha_quiz/application/agent/agent_turn.dart';
import 'package:shiroha_quiz/application/conversations/conversation_repository.dart';
import 'package:shiroha_quiz/application/conversations/conversation_service.dart';
import 'package:shiroha_quiz/application/file_library/file_library_ports.dart';
import 'package:shiroha_quiz/application/file_library/library_file_deletion.dart';
import 'package:shiroha_quiz/application/file_library/library_folder_repository.dart';
import 'package:shiroha_quiz/application/file_library/library_folder_service.dart';
import 'package:shiroha_quiz/application/projects/project_repository.dart';
import 'package:shiroha_quiz/application/projects/project_service.dart';
import 'package:shiroha_quiz/application/study_query/study_query_dtos.dart';
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/application/study_query/study_query_service.dart';
import 'package:shiroha_quiz/application/u1_workspace/u1_workspace_dtos.dart';
import 'package:shiroha_quiz/application/u1_workspace/u1_workspace_facade.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_persistence.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_proposal.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_proposal_service.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/assets/library_folder.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/conversations/conversation_message.dart';
import 'package:shiroha_quiz/domain/projects/project.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/ui/assistant/assistant_screen.dart';
import 'package:shiroha_quiz/ui/assistant/assistant_content_renderer.dart';
import 'package:shiroha_quiz/ui/assistant/assistant_workspace_shell.dart';
import 'package:shiroha_quiz/ui/assistant/conversation_controller.dart';
import 'package:shiroha_quiz/ui/assistant/global_sidebar.dart';
import 'package:shiroha_quiz/ui/assistant/learning_spaces_screen.dart';
import 'package:shiroha_quiz/ui/assistant/workspace_controller.dart'
    show FileLibraryController, LearningSpacesController, workspaceSafeError;
import 'package:shiroha_quiz/ui/assistant/workspace_pages.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';

const _sha = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

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

AgentSettingsService _agentSettingsService() => AgentSettingsService(
      configStore: _AgentConfigStore(),
      profileCatalog: _AgentProfiles(),
    );

AgentTurnSession _failedAgentTurn({
  required String conversationId,
  required String userMessageId,
}) {
  return AgentTurnSession(
    events: const Stream<AgentTurnEvent>.empty(),
    result: Future<AgentTurnResult>.value(
      const AgentTurnFailed(AgentTurnFailure.temporarilyUnavailable),
    ),
    cancel: () {},
  );
}

final class _UiTurnHarness {
  final StreamController<AgentTurnEvent> events =
      StreamController<AgentTurnEvent>.broadcast();
  final Completer<AgentTurnResult> result = Completer<AgentTurnResult>();
  bool cancelled = false;

  late final AgentTurnSession session = AgentTurnSession(
    events: events.stream,
    result: result.future,
    cancel: _cancel,
  );

  AgentTurnSession start({
    required String conversationId,
    required String userMessageId,
  }) =>
      session;

  void complete(AgentTurnResult terminal) {
    if (result.isCompleted) return;
    result.complete(terminal);
    if (!events.isClosed) unawaited(events.close());
  }

  void _cancel() {
    cancelled = true;
    complete(const AgentTurnFailed(AgentTurnFailure.cancelled));
  }
}

final class _EmptyConversations extends Fake
    implements ConversationRepositoryPort {
  @override
  Future<List<ConversationFileRef>> listAttachableFiles(
          {required int limit}) async =>
      const <ConversationFileRef>[];

  @override
  Future<List<Conversation>> listRecentConversations(
          {required int limit}) async =>
      const <Conversation>[];
}

final class _MemoryConversations extends Fake
    implements ConversationRepositoryPort {
  bool failListReads = false;
  final List<Conversation> conversations = <Conversation>[];
  final List<ConversationMessage> messages = <ConversationMessage>[];
  final List<ConversationFileRef> candidates = <ConversationFileRef>[
    const ConversationFileRef(
      fileId: 'file-notes',
      displayName: 'notes.md',
      mimeType: 'text/markdown',
      sizeBytes: 12,
    ),
  ];

  @override
  Future<ConversationThreadSlice> createWithFirstMessage({
    required Conversation conversation,
    required ConversationMessage firstMessage,
    required List<String> fileIds,
    required DateTime attachedAt,
  }) async {
    conversations.add(conversation);
    messages.add(firstMessage);
    return ConversationThreadSlice(
      conversation: conversation,
      messages: <ConversationMessage>[firstMessage],
      files: candidates
          .where((file) => fileIds.contains(file.fileId))
          .toList(growable: false),
      hasMoreBefore: false,
      nextBeforeSequence: null,
    );
  }

  @override
  Future<List<ConversationFileRef>> listAttachableFiles(
          {required int limit}) async =>
      candidates.take(limit).toList(growable: false);

  @override
  Future<List<Conversation>> listRecentConversations(
      {required int limit}) async {
    if (failListReads) throw StateError('list read failure');
    return conversations.reversed.take(limit).toList(growable: false);
  }
}

ConversationService _conversationService({ConversationRepositoryPort? repo}) =>
    ConversationService(
      repository: repo ?? _EmptyConversations(),
      conversationIdFactory: () => 'conversation-test',
      messageIdFactory: () => 'message-test',
      clock: () => DateTime.fromMillisecondsSinceEpoch(1, isUtc: true),
    );

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

final class _Deletion implements LibraryFileDeletionPort {
  _Deletion(this.files);

  final _Files files;
  int calls = 0;
  bool fail = false;
  bool orphan = false;
  Completer<void>? release;

  @override
  Future<LibraryFileDeletionResult> deleteLibraryFile(String fileId) async {
    calls++;
    final pendingRelease = release;
    if (pendingRelease != null) await pendingRelease.future;
    if (fail) throw StateError('synthetic delete failure');
    files.values.remove(fileId);
    return LibraryFileDeletionResult(
      fileId: fileId,
      projectReferenceCount: 1,
      conversationReferenceCount: 1,
      managedBytesCleanup: orphan
          ? LibraryFileManagedBytesCleanup.orphaned
          : LibraryFileManagedBytesCleanup.deleted,
      parsedArtifactCleanup: LibraryFileParsedArtifactCleanup.notPresent,
    );
  }
}

final class _Folders extends Fake implements LibraryFolderRepositoryPort {
  _Folders(this.files);

  final _Files files;
  final Map<String, LibraryFolder> values = <String, LibraryFolder>{};
  final Map<String, String> memberships = <String, String>{};

  @override
  Future<void> createFolder(LibraryFolder folder) async {
    values[folder.folderId] = folder;
  }

  @override
  Future<List<LibraryFolder>> listFolders() async => values.values.toList();

  @override
  Future<LibraryFolder?> findFolder(String folderId) async => values[folderId];

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
      files.values.values
          .where((file) => memberships[file.fileId] == folderId)
          .toList();

  @override
  Future<List<LibraryFile>> listUnclassifiedFiles() async => files.values.values
      .where((file) => !memberships.containsKey(file.fileId))
      .toList();
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

U1WorkspaceFacade _facade({
  _Files? files,
  _Projects? projects,
  _Folders? folders,
  LibraryFileDeletionPort? deletion,
}) {
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
  final resolvedFolders = folders ?? _Folders(resolvedFiles);
  resolvedFolders.values['folder-papers'] = LibraryFolder(
    folderId: 'folder-papers',
    displayName: '论文',
    createdAt: DateTime.utc(2026, 8, 9),
  );
  resolvedFolders.memberships['file-notes'] = 'folder-papers';
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
    folderService: LibraryFolderService(
      repository: resolvedFolders,
      folderIdFactory: () => 'folder-created',
    ),
    libraryFileDeletion: deletion,
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

final class _PreparedAssistantPresentation {
  _PreparedAssistantPresentation({
    required this.spacesController,
    required this.fileController,
    required this.conversationController,
  });

  final LearningSpacesController spacesController;
  final FileLibraryController fileController;
  final ConversationController conversationController;

  void dispose() {
    spacesController.dispose();
    fileController.dispose();
    conversationController.dispose();
  }
}

Future<void> _waitForControllerState(
  ConversationController controller,
  bool Function() condition,
) async {
  if (condition()) return;
  final ready = Completer<void>();
  void listener() {
    if (condition() && !ready.isCompleted) {
      ready.complete();
    }
  }

  controller.addListener(listener);
  try {
    listener();
    await ready.future.timeout(const Duration(seconds: 2));
  } finally {
    controller.removeListener(listener);
  }
}

Future<_PreparedAssistantPresentation> _prepareSuccessPresentation() async {
  final facade = _facade();
  final turn = _UiTurnHarness();
  final controller = ConversationController(
    _conversationService(repo: _MemoryConversations()),
    agentSettingsService: _agentSettingsService(),
    startAgentTurn: turn.start,
  );
  await controller.load();
  await controller.send('terminal success');
  final assistant = ConversationMessage(
    messageId: 'assistant-ui',
    conversationId: 'conversation-test',
    sequence: 2,
    role: ConversationMessageRole.assistant,
    content: 'done',
    createdAt: DateTime.fromMillisecondsSinceEpoch(2, isUtc: true),
  );
  final terminal = _waitForControllerState(
    controller,
    () {
      final messages = controller.activeThread?.messages;
      return !controller.hasActiveTurn &&
          !controller.isSending &&
          controller.turnPhase == AssistantTurnPhase.idle &&
          messages != null &&
          messages.length == 2 &&
          messages.last.role == ConversationMessageRole.assistant;
    },
  );
  turn.complete(AgentTurnSuccess(assistantMessage: assistant));
  await terminal;
  return _PreparedAssistantPresentation(
    spacesController: LearningSpacesController(facade),
    fileController: FileLibraryController(facade),
    conversationController: controller,
  );
}

Future<_PreparedAssistantPresentation> _prepareFailurePresentation() async {
  final facade = _facade();
  final turn = _UiTurnHarness();
  final controller = ConversationController(
    _conversationService(repo: _MemoryConversations()),
    agentSettingsService: _agentSettingsService(),
    startAgentTurn: turn.start,
  );
  await controller.load();
  await controller.send('terminal failure');
  final streamed = _waitForControllerState(
    controller,
    () => controller.transientAssistantText == 'partial',
  );
  turn.events.add(const AgentTurnTextDelta('partial'));
  await streamed;
  final terminal = _waitForControllerState(
    controller,
    () =>
        !controller.hasActiveTurn &&
        !controller.isSending &&
        controller.turnPhase == AssistantTurnPhase.failed &&
        controller.transientAssistantText == 'partial' &&
        controller.canRetry,
  );
  turn.complete(
    const AgentTurnFailed(AgentTurnFailure.temporarilyUnavailable),
  );
  await terminal;
  return _PreparedAssistantPresentation(
    spacesController: LearningSpacesController(facade),
    fileController: FileLibraryController(facade),
    conversationController: controller,
  );
}

void main() {
  testWidgets('context picker refreshes files added after initial load',
      (tester) async {
    final conversations = _MemoryConversations()..candidates.clear();
    await tester.binding.setSurfaceSize(const Size(1300, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: AssistantWorkspaceShell(
          facade: _facade(),
          conversationService: _conversationService(repo: conversations),
          agentSettingsService: _agentSettingsService(),
          startAgentTurn: _failedAgentTurn,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(conversations.candidates, isEmpty);

    conversations.candidates.add(
      const ConversationFileRef(
        fileId: 'file-live',
        displayName: 'live.txt',
        mimeType: 'text/plain',
        sizeBytes: 8,
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux0-add-context')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('c0-context-file-file-live')),
      findsOneWidget,
    );
  });

  testWidgets(
      'C0 first send persists one User Message with selected File context',
      (tester) async {
    final conversations = _MemoryConversations();
    await tester.binding.setSurfaceSize(const Size(1300, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: AssistantWorkspaceShell(
          facade: _facade(),
          conversationService: _conversationService(repo: conversations),
          agentSettingsService: _agentSettingsService(),
          startAgentTurn: _failedAgentTurn,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(conversations.conversations, isEmpty);
    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux0-add-context')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('c0-context-file-file-notes')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('c0-context-file-notes')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('u1-ux0-composer')),
      '  first question  ',
    );
    await tester.tap(find.byKey(const ValueKey<String>('u1-ux0-send')));
    await tester.pumpAndSettle();

    expect(conversations.conversations, hasLength(1));
    expect(conversations.messages, hasLength(1));
    expect(conversations.messages.single.role, ConversationMessageRole.user);
    expect(conversations.messages.single.content, 'first question');
    expect(
      find.byKey(const ValueKey<String>('c0-message-message-test')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('c0-recent-conversation-test')),
      findsOneWidget,
    );
  });

  test('send stays successful when the post-save recency refresh fails',
      () async {
    final repo = _MemoryConversations()..failListReads = true;
    final controller = ConversationController(
      _conversationService(repo: repo),
      agentSettingsService: _agentSettingsService(),
      startAgentTurn: _failedAgentTurn,
    );

    final saved = await controller.send('first message');

    expect(saved, isTrue);
    expect(controller.activeThread!.messages, hasLength(1));
    expect(controller.errorMessage, conversationReadSafeError);
    expect(controller.errorMessage, isNot(conversationWriteSafeError));
  });

  testWidgets('Assistant projects thinking, Web, tool, and streaming state',
      (tester) async {
    final conversations = _MemoryConversations();
    final turn = _UiTurnHarness();
    await tester.binding.setSurfaceSize(const Size(1300, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: AssistantWorkspaceShell(
          facade: _facade(),
          conversationService: _conversationService(repo: conversations),
          agentSettingsService: _agentSettingsService(),
          startAgentTurn: turn.start,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    await tester.enterText(
      find.byKey(const ValueKey<String>('u1-ux0-composer')),
      'stream this',
    );
    await tester.tap(find.byKey(const ValueKey<String>('u1-ux0-send')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Shiroha 正在思考…'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('a0-agent-cancel')),
      findsOneWidget,
    );

    turn.events.add(
      const AgentTurnWebSearchEvent(AgentProviderWebSearchPhase.searching),
    );
    await tester.pump();
    expect(find.text('正在搜索网页…'), findsOneWidget);

    turn.events.add(
      const AgentTurnToolCall(callId: 'hidden', name: 'search_questions'),
    );
    await tester.pump();
    expect(find.text('正在搜索题目…'), findsOneWidget);
    expect(find.text('hidden'), findsNothing);

    turn.events
      ..add(const AgentTurnTextDelta('A'))
      ..add(const AgentTurnTextDelta('B'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('a0-transient-assistant')),
      findsOneWidget,
    );
    expect(find.byType(AssistantContentRenderer), findsOneWidget);
    expect(find.text('AB'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(turn.cancelled, isTrue);
    expect(turn.result.isCompleted, isTrue);
    expect(turn.events.isClosed, isTrue);
  });

  group('Assistant terminal success presentation', () {
    late _PreparedAssistantPresentation prepared;

    setUp(() async {
      prepared = await _prepareSuccessPresentation();
    });

    tearDown(() => prepared.dispose());

    testWidgets('Assistant renders persisted terminal success snapshot',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1300, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: AssistantScreen(
            spacesController: prepared.spacesController,
            fileController: prepared.fileController,
            conversationController: prepared.conversationController,
            showGlobalMenu: false,
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('c0-message-assistant-ui')),
        findsOneWidget,
      );
      expect(find.byType(AssistantContentRenderer), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('a0-transient-assistant')),
        findsNothing,
      );
    });
  });

  group('Assistant terminal failure presentation', () {
    late _PreparedAssistantPresentation prepared;

    setUp(() async {
      prepared = await _prepareFailurePresentation();
    });

    tearDown(() => prepared.dispose());

    testWidgets('Assistant renders terminal failure and retry snapshot',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1300, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: AssistantScreen(
            spacesController: prepared.spacesController,
            fileController: prepared.fileController,
            conversationController: prepared.conversationController,
            showGlobalMenu: false,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('partial'), findsOneWidget);
      expect(find.byType(AssistantContentRenderer), findsOneWidget);
      expect(find.text('未保存'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('a0-agent-retry')),
        findsOneWidget,
      );
    });
  });

  testWidgets('streaming preserves position after the User scrolls away',
      (tester) async {
    final conversations = _MemoryConversations();
    final turn = _UiTurnHarness();
    await tester.binding.setSurfaceSize(const Size(1300, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: AssistantWorkspaceShell(
          facade: _facade(),
          conversationService: _conversationService(repo: conversations),
          agentSettingsService: _agentSettingsService(),
          startAgentTurn: turn.start,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('u1-ux0-composer')),
      List<String>.filled(120, 'long question').join(' '),
    );
    await tester.tap(find.byKey(const ValueKey<String>('u1-ux0-send')));
    await tester.pump();
    await tester.pump();
    turn.events.add(
      AgentTurnTextDelta(List<String>.filled(100, 'stream').join(' ')),
    );
    await tester.pump();
    await tester.pump();

    final content = find.byKey(
      const ValueKey<String>('u1-ux0-assistant-content'),
    );
    final scrollable = find.descendant(
      of: content,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.extentAfter, lessThanOrEqualTo(1));

    await tester.drag(content, const Offset(0, 360));
    await tester.pump();
    final userPosition = position.pixels;
    expect(position.extentAfter, greaterThan(120));

    turn.events.add(const AgentTurnTextDelta(' tail'));
    await tester.pump();
    await tester.pump();
    expect(position.pixels, closeTo(userPosition, 1));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(turn.cancelled, isTrue);
    expect(turn.result.isCompleted, isTrue);
    expect(turn.events.isClosed, isTrue);
  });

  testWidgets('desktop shell renders real files, relations, and MCP capability',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1300, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: AssistantWorkspaceShell(
          facade: _facade(),
          conversationService: _conversationService(),
          agentSettingsService: _agentSettingsService(),
          startAgentTurn: _failedAgentTurn,
        ),
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
    expect(find.text('论文'), findsOneWidget);

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
        const ValueKey<String>('u1-space-menu-project-deep'),
      ),
    );
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

  testWidgets(
      'DM-D5 LibraryFile confirmation calls Controller to Facade authority',
      (tester) async {
    final files = _Files();
    final deletion = _Deletion(files);
    final facade = _facade(files: files, deletion: deletion);
    final controller = FileLibraryController(facade);
    addTearDown(controller.dispose);
    await controller.load();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: FileLibraryWorkspace(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux01-file-file-notes')),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('dm-d5-delete-library-file')),
    );
    await tester.pumpAndSettle();

    expect(find.text('永久删除文件？'), findsOneWidget);
    expect(find.textContaining('建议先在数据中心导出备份'), findsOneWidget);
    expect(find.textContaining('外部位置'), findsOneWidget);
    expect(find.textContaining('Questions'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(deletion.calls, 0);
    expect(files.values, contains('file-notes'));

    deletion.fail = true;
    await tester.tap(
      find.byKey(const ValueKey<String>('dm-d5-delete-library-file')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey<String>('dm-d5-confirm-delete-library-file'),
      ),
    );
    await tester.pumpAndSettle();

    expect(deletion.calls, 1);
    expect(files.values, contains('file-notes'));
    expect(controller.isFileDeletionPending('file-notes'), isFalse);
    expect(find.textContaining('删除失败，请稍后重试'), findsOneWidget);
    expect(find.textContaining('synthetic delete failure'), findsNothing);

    deletion.fail = false;
    await tester.tap(
      find.byKey(const ValueKey<String>('dm-d5-delete-library-file')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey<String>('dm-d5-confirm-delete-library-file'),
      ),
    );
    await tester.pumpAndSettle();

    expect(deletion.calls, 2);
    expect(files.values, isNot(contains('file-notes')));
    expect(find.text('文件已永久删除'), findsOneWidget);
    expect(controller.errorMessage, isNull);
  });

  test('DM-D5 LibraryFile deletion is single-flight per file id', () async {
    final files = _Files();
    final deletion = _Deletion(files)..release = Completer<void>();
    final controller = FileLibraryController(
      _facade(files: files, deletion: deletion),
    );
    addTearDown(controller.dispose);
    await controller.load();

    final first = controller.deleteFile('file-notes');
    await Future<void>.delayed(Duration.zero);
    expect(deletion.calls, 1);
    expect(controller.isFileDeletionPending('file-notes'), isTrue);

    final second = controller.deleteFile('file-notes');
    expect(deletion.calls, 1);

    deletion.release!.complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(controller.isFileDeletionPending('file-notes'), isFalse);
  });

  testWidgets('DM-D5 LibraryFile pending deletion disables the widget entry',
      (tester) async {
    final files = _Files();
    final deletion = _Deletion(files)..release = Completer<void>();
    final controller = FileLibraryController(
      _facade(files: files, deletion: deletion),
    );
    addTearDown(controller.dispose);
    await controller.load();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: FileLibraryWorkspace(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux01-file-file-notes')),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();

    final deleteEntry = find.byKey(
      const ValueKey<String>('dm-d5-delete-library-file'),
    );
    await tester.tap(deleteEntry);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey<String>('dm-d5-confirm-delete-library-file'),
      ),
    );
    await tester.pumpAndSettle();

    expect(deletion.calls, 1);
    expect(controller.isFileDeletionPending('file-notes'), isTrue);
    expect(
      find.byKey(
        const ValueKey<String>('dm-d5-confirm-delete-library-file'),
      ),
      findsNothing,
    );
    expect(
      tester.widget<ListTile>(deleteEntry).onTap,
      isNull,
    );

    await tester.tap(deleteEntry);
    await tester.pump();
    expect(deletion.calls, 1);
    expect(
      find.byKey(
        const ValueKey<String>('dm-d5-confirm-delete-library-file'),
      ),
      findsNothing,
    );

    deletion.release!.complete();
    await tester.pumpAndSettle();

    expect(controller.isFileDeletionPending('file-notes'), isFalse);
    expect(deletion.calls, 1);
    expect(find.text('文件已永久删除'), findsOneWidget);
  });

  testWidgets('Folder local navigation supports CRUD, move, and safe delete',
      (tester) async {
    final files = _Files();
    final folders = _Folders(files);
    final facade = _facade(files: files, folders: folders);
    await tester.binding.setSurfaceSize(const Size(1300, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: AssistantWorkspaceShell(
          facade: facade,
          conversationService: _conversationService(),
          agentSettingsService: _agentSettingsService(),
          startAgentTurn: _failedAgentTurn,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux01-open-file-library')),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(GlobalSidebar),
        matching: find.text('论文'),
      ),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('f0-1-folder-folder-papers')),
    );
    await tester.pumpAndSettle();
    expect(find.text('notes.md'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('f0-1-move-file-file-notes')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('f0-1-move-unclassified')),
    );
    await tester.pumpAndSettle();
    expect(find.text('notes.md'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('f0-1-view-unclassified')),
    );
    await tester.pumpAndSettle();
    expect(find.text('notes.md'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('f0-1-create-folder')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('f0-1-folder-name-input')),
      '新资料',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('f0-1-folder-name-save')),
    );
    await tester.pumpAndSettle();
    expect(find.text('新资料'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('f0-1-folder-menu-folder-created')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('f0-1-folder-name-input')),
      '重命名资料',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('f0-1-folder-name-save')),
    );
    await tester.pumpAndSettle();
    expect(find.text('重命名资料'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('f0-1-folder-menu-folder-papers')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(
      find.text('删除文件夹不会删除其中的文件，文件将移动到“未分类”。'),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('f0-1-confirm-delete-folder')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('f0-1-folder-folder-papers')),
      findsNothing,
    );
    expect(find.text('notes.md'), findsOneWidget);
  });

  testWidgets('mobile File Library keeps Folder in local navigation',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: AssistantWorkspaceShell(
          facade: _facade(),
          conversationService: _conversationService(),
          agentSettingsService: _agentSettingsService(),
          startAgentTurn: _failedAgentTurn,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux0-open-drawer')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('u1-ux01-open-file-library')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('f0-1-mobile-folder-section')),
      findsOneWidget,
    );
    expect(find.text('论文'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile drawer opens the real learning-space list',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: AssistantWorkspaceShell(
          facade: _facade(),
          conversationService: _conversationService(),
          agentSettingsService: _agentSettingsService(),
          startAgentTurn: _failedAgentTurn,
        ),
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
        home: AssistantWorkspaceShell(
          facade: facade,
          conversationService: _conversationService(),
          agentSettingsService: _agentSettingsService(),
          startAgentTurn: _failedAgentTurn,
        ),
      ),
    );
    await tester.pumpAndSettle();

    projects.failReads = true;
    await tester.tap(
      find.byKey(const ValueKey<String>('u1-space-menu-project-deep')),
    );
    await tester.pumpAndSettle();
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
        home: AssistantWorkspaceShell(
          facade: facade,
          conversationService: _conversationService(),
          agentSettingsService: _agentSettingsService(),
          startAgentTurn: _failedAgentTurn,
        ),
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
        home: AssistantWorkspaceShell(
          facade: facade,
          conversationService: _conversationService(),
          agentSettingsService: _agentSettingsService(),
          startAgentTurn: _failedAgentTurn,
        ),
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

  group('W0 proposal approval presentation', () {
    testWidgets(
      'renders the exact preview card and approves through the proposal '
      'identity',
      (tester) async {
        final facade = _facade();
        final turn = _UiTurnHarness();
        final persistence = _FakeProposalPersistence();
        final service = AgentWriteProposalService(persistence);
        final controller = ConversationController(
          _conversationService(repo: _MemoryConversations()),
          agentSettingsService: _agentSettingsService(),
          startAgentTurn: turn.start,
          proposalService: service,
        );
        addTearDown(controller.dispose);
        await controller.load();
        await controller.send('question');
        final proposal = await _primeProposal(persistence, service);
        final staged = _waitForControllerState(
          controller,
          () => controller.hasProposalCard,
        );
        turn.events.add(
          AgentTurnProposalStaged(
            proposalId: proposal.id,
            outcome: 'pending',
            preview: _proposalPreviewMap(),
          ),
        );
        await staged;

        await tester.binding.setSurfaceSize(const Size(1300, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            home: AssistantScreen(
              spacesController: LearningSpacesController(facade),
              fileController: FileLibraryController(facade),
              conversationController: controller,
              showGlobalMenu: false,
            ),
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const ValueKey<String>('w0-proposal-card')),
          findsOneWidget,
        );
        expect(find.textContaining('w0_u1_synthetic_bank'), findsOneWidget);
        expect(find.textContaining('Stem.'), findsOneWidget);
        expect(find.textContaining('A. first'), findsOneWidget);
        expect(
          find.text('\u5f53\u524d\u7b54\u6848\uff1a\u672a\u586b\u5199'),
          findsOneWidget,
        );
        expect(
          find.text('\u62df\u5199\u5165\u7b54\u6848\uff1aanswer'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey<String>('w0-proposal-approve')),
              )
              .onPressed,
          isNull,
        );

        final assistant = ConversationMessage(
          messageId: 'assistant-ui',
          conversationId: 'conversation-test',
          sequence: 2,
          role: ConversationMessageRole.assistant,
          content: 'done',
          createdAt: DateTime.fromMillisecondsSinceEpoch(2, isUtc: true),
        );
        await tester.runAsync<void>(() async {
          final terminal = _waitForControllerState(
            controller,
            () => !controller.hasActiveTurn,
          );
          turn.complete(AgentTurnSuccess(assistantMessage: assistant));
          await terminal;
        });
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey<String>('w0-proposal-approve')),
              )
              .onPressed,
          isNotNull,
        );

        await tester.tap(
          find.byKey(const ValueKey<String>('w0-proposal-approve')),
        );
        await tester.pump();
        await _waitForControllerState(
          controller,
          () =>
              controller.proposalOutcome == AgentWriteProposalOutcome.committed,
        );
        await tester.pump();

        expect(
          find.textContaining('\u5df2\u5199\u5165\u7b54\u6848'),
          findsOneWidget,
        );
        expect(persistence.commitCalls, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('failed admission leaves no preview card', (tester) async {
      final prepared = (await tester.runAsync(_prepareSuccessPresentation))!;
      addTearDown(prepared.dispose);
      await tester.binding.setSurfaceSize(const Size(1300, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: AssistantScreen(
            spacesController: prepared.spacesController,
            fileController: prepared.fileController,
            conversationController: prepared.conversationController,
            showGlobalMenu: false,
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('w0-proposal-card')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  });
}

final class _FakeProposalPersistence implements AgentWritePersistencePort {
  _FakeProposalPersistence({AgentWriteAdmissionResult? admissionResult})
      : admissionResult = admissionResult ??
            AgentWriteAdmissionGranted(
              AgentWriteAdmittedTarget(
                storageId: 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
                bankName: 'w0_u1_synthetic_bank',
                draft: _w0Draft(),
              ),
            );

  AgentWriteAdmissionResult admissionResult;
  final commitCalls = <AgentWriteCommitRequest>[];

  @override
  Future<AgentWriteAdmissionResult> admitStagingTarget(
    AgentWriteAdmissionRequest request,
  ) async {
    return admissionResult;
  }

  @override
  Future<void> commitApproved(AgentWriteCommitRequest request) async {
    commitCalls.add(request);
  }
}

RichContent _w0Text(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

QuestionDraftV2 _w0Draft() {
  return QuestionDraftV2(
    questionId: 'w0_u1_content_q',
    kind: QuestionKind.shortAnswer,
    questionNumber: 1,
    stem: _w0Text('Stem.'),
    explanation: _w0Text('Explanation.'),
  );
}

/// Structured preview mirroring the Application-owned tool contract.
Map<String, Object?> _proposalPreviewMap() {
  return <String, Object?>{
    'bank_name': 'w0_u1_synthetic_bank',
    'stem': <Map<String, Object?>>[
      <String, Object?>{'type': 'text', 'text': 'Stem.'},
    ],
    'options': <Map<String, Object?>>[
      <String, Object?>{
        'label': 'A',
        'content': <Map<String, Object?>>[
          <String, Object?>{'type': 'text', 'text': 'first'},
        ],
      },
    ],
    'proposed_answer': <String, Object?>{
      'kind': 'content',
      'nodes': <Map<String, Object?>>[
        <String, Object?>{'type': 'text', 'text': 'answer'},
      ],
    },
  };
}

Future<AgentWriteProposal> _primeProposal(
  _FakeProposalPersistence persistence,
  AgentWriteProposalService service,
) async {
  final staged = await service.stageProposal(
    admissionRequest: AgentWriteAdmissionRequest(
      sourceConversationId: 'conversation-test',
      sourceMessageId: 'message-1',
      scope: ConversationScope.global(),
      targetStorageId: 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
    ),
    proposedAnswer: ContentAnswer(content: _w0Text('answer')),
  );
  return (staged as AgentWriteStageResultStaged).proposal;
}
