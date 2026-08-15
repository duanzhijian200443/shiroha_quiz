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
import 'package:shiroha_quiz/application/study_plan/study_plan_command_service.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_draft_service.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_ports.dart';
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
import 'package:shiroha_quiz/domain/study_plan/active_study_plan.dart';
import 'package:shiroha_quiz/domain/study_plan/study_plan_values.dart';
import 'package:shiroha_quiz/ui/assistant/assistant_screen.dart';
import 'package:shiroha_quiz/ui/assistant/conversation_controller.dart';
import 'package:shiroha_quiz/ui/assistant/workspace_controller.dart';

final class _MemoryConversations extends Fake
    implements ConversationRepositoryPort {
  final List<Conversation> conversations = <Conversation>[];
  final List<ConversationMessage> messages = <ConversationMessage>[];
  final List<ConversationFileRef> candidates = <ConversationFileRef>[];

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
  Future<AppendMessageResult> appendMessage({
    required String conversationId,
    required String messageId,
    required ConversationMessageRole role,
    required String content,
    required DateTime createdAt,
  }) async {
    final msg = ConversationMessage(
      messageId: messageId,
      conversationId: conversationId,
      sequence: messages.length + 1,
      role: role,
      content: content,
      createdAt: createdAt,
    );
    messages.add(msg);
    final conv =
        conversations.firstWhere((c) => c.conversationId == conversationId);
    return AppendMessageResult(
      conversation: conv,
      message: msg,
    );
  }

  @override
  Future<List<ConversationFileRef>> listAttachableFiles(
          {required int limit}) async =>
      candidates.take(limit).toList(growable: false);

  @override
  Future<List<Conversation>> listRecentConversations(
          {required int limit}) async =>
      conversations.reversed.take(limit).toList(growable: false);

  @override
  Future<ConversationThreadSlice> loadConversation({
    required String conversationId,
    required int limit,
    int? beforeSequence,
  }) async {
    final conversation = conversations.firstWhere(
      (c) => c.conversationId == conversationId,
    );
    final convMessages =
        messages.where((m) => m.conversationId == conversationId).toList();
    return ConversationThreadSlice(
      conversation: conversation,
      messages: convMessages,
      files: const <ConversationFileRef>[],
      hasMoreBefore: false,
      nextBeforeSequence: null,
    );
  }
}

final class _AgentConfigStore implements AgentConfigStorePort {
  @override
  Future<String?> readAgentConfig() async => const AgentConfigCodec().encode(
        AgentConfig(
          providerKind: AgentProviderKind.deepSeekResponses,
          mainProfileId: 'profile-test',
        ),
      );

  @override
  Future<void> writeAgentConfig(String encodedConfig) async {}
}

final class _AgentProfiles implements AgentProfileCatalogPort {
  @override
  Future<List<AgentProfileSummary>> listMainProfiles() async =>
      <AgentProfileSummary>[
        AgentProfileSummary(
          profileId: 'profile-test',
          displayName: 'Test Profile',
          modelName: 'deepseek-v4-flash',
        ),
      ];
}

final class _FakePersistencePort implements StudyPlanPersistencePort {
  ActiveStudyPlan? currentActivePlan;
  int adoptCalls = 0;
  List<
      ({
        String draftId,
        String? expectedActivePlanId,
        bool replacementConfirmed
      })> adoptHistory = [];
  Completer<StudyPlanPersistenceCommitResult>? adoptCompleter;
  StudyPlanPersistenceCommitResult nextAdoptResult =
      const StudyPlanPersistenceCommitStaleScope();

  @override
  Future<ActiveStudyPlan?> loadActivePlan() async => currentActivePlan;

  @override
  Future<StudyPlanPersistenceCommitResult> commitAdoption({
    required String planId,
    required String bankName,
    String? goal,
    required int dailyTarget,
    required StudyPlanPriority priority,
    int? horizonDays,
    String? sourceConversationId,
    String? sourceUserMessageId,
    required ConversationScope sourceScope,
    required DateTime adoptedAt,
    String? expectedActivePlanId,
    required bool replacementConfirmed,
  }) async {
    adoptCalls++;
    adoptHistory.add((
      draftId: planId,
      expectedActivePlanId: expectedActivePlanId,
      replacementConfirmed: replacementConfirmed,
    ));
    if (adoptCompleter != null) {
      return adoptCompleter!.future;
    }
    return nextAdoptResult;
  }

  @override
  Future<StudyPlanPersistenceStopResult> stopActivePlan({
    required String expectedPlanId,
  }) async {
    return const StudyPlanPersistenceStopSuccess();
  }
}

final class _FakePlanningPort implements StudyPlanPlanningPort {
  @override
  Future<StudyPlanPlanningAdmission> loadPlanningContext({
    required ConversationScope sourceScope,
    required String bankName,
    required DateTime now,
  }) async {
    return StudyPlanPlanningAdmitted(
      StudyPlanPlanningContext(
        bankName: bankName,
        questionCount: 100,
        masteredCount: 30,
        dueCount: 20,
        weakCount: 10,
        newCount: 40,
      ),
    );
  }
}

final class _Projects extends Fake implements ProjectRepository {
  @override
  Future<List<Project>> listProjects() async => <Project>[];
  @override
  Future<Project?> getProject(String projectId) async => null;
  @override
  Future<List<String>> listProjectFileIds(String projectId) async => <String>[];
  @override
  Future<List<String>> listProjectBankNames(String projectId) async =>
      <String>[];
  @override
  Future<List<String>> listProjectIdsForFile(String fileId) async => <String>[];
  @override
  Future<List<String>> listProjectIdsForBank(String bankName) async =>
      <String>[];
}

final class _Files implements LibraryFileRepositoryPort {
  @override
  Future<List<LibraryFile>> findAll() async => <LibraryFile>[];
  @override
  Future<LibraryFile?> findById(String fileId) async => null;
  @override
  Future<void> save(LibraryFile file) async {}
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

final class _Folders extends Fake implements LibraryFolderRepositoryPort {
  @override
  Future<List<LibraryFolder>> listFolders() async => <LibraryFolder>[];
  @override
  Future<LibraryFolder?> getFolderForFile(String fileId) async => null;
  @override
  Future<List<LibraryFile>> listFilesInFolder(String folderId) async =>
      <LibraryFile>[];
  @override
  Future<List<LibraryFile>> listUnclassifiedFiles() async => <LibraryFile>[];
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
            bankName: 'Math',
            folderName: '未分类',
            questionCount: 100,
            dueCount: 20,
            masteredCount: 30,
          ),
        ],
        hasMore: false,
      );
}

final class _Metrics extends Fake implements StudyMetricsQueryPort {}

U1WorkspaceFacade _facade() {
  return U1WorkspaceFacade(
    projectService: ProjectService(repository: _Projects()),
    fileRepository: _Files(),
    fileIngestion: _Ingestion(),
    folderService: LibraryFolderService(
      repository: _Folders(),
      folderIdFactory: () => 'folder-1',
    ),
    studyQueryService: StudyQueryService(
      questionQuery: _QuestionPort(),
      metricsQuery: _Metrics(),
    ),
    mcpProjection: McpWorkspaceProjection(
      state: McpCapabilityState.configuredAvailable,
      transport: McpTransport.localStdio,
      permission: McpPermission.readOnly,
      toolNames: <String>[],
    ),
  );
}

Widget _wrap(Widget child) {
  return MaterialApp(
    home: child,
  );
}

void main() {
  late ConversationService convService;
  late AgentSettingsService agentSettingsService;
  late _FakePlanningPort planningPort;
  late _FakePersistencePort persistencePort;
  late StudyPlanDraftService draftService;
  late StudyPlanCommandService commandService;

  setUp(() async {
    final convRepo = _MemoryConversations();
    convService = ConversationService(
      repository: convRepo,
      conversationIdFactory: () => 'conv_1',
      messageIdFactory: () => 'msg_1',
      clock: () => DateTime.utc(2026, 8, 15),
    );
    agentSettingsService = AgentSettingsService(
      configStore: _AgentConfigStore(),
      profileCatalog: _AgentProfiles(),
    );
    planningPort = _FakePlanningPort();
    persistencePort = _FakePersistencePort();
    var draftSeq = 0;
    var planSeq = 0;
    draftService = StudyPlanDraftService(
      planningPort: planningPort,
      draftIdFactory: () => 'draft_${++draftSeq}',
      clock: () => DateTime.utc(2026, 8, 15),
    );
    commandService = StudyPlanCommandService(
      draftService: draftService,
      persistencePort: persistencePort,
      planIdFactory: () => 'plan_${++planSeq}',
      clock: () => DateTime.utc(2026, 8, 15),
    );

    // Real conversation + user message for the source turn.
    await convService.startWithUserMessage(
      scope: ConversationScope.global(),
      content: '帮我制定复习计划',
    );
  });

  ConversationController makeController() {
    return ConversationController(
      convService,
      agentSettingsService: agentSettingsService,
      startAgentTurn: ({required conversationId, required userMessageId}) {
        return AgentTurnSession(
          events: const Stream<AgentTurnEvent>.empty(),
          result: Future.value(
            const AgentTurnFailed(AgentTurnFailure.cancelled),
          ),
          cancel: () {},
        );
      },
      studyPlanDraftService: draftService,
      studyPlanCommandService: commandService,
    );
  }

  StudyPlanPriority? priorityOf(Object? code) {
    return switch (code) {
      'balanced' => StudyPlanPriority.balanced,
      'due_first' => StudyPlanPriority.dueFirst,
      'weak_first' => StudyPlanPriority.weakFirst,
      'new_first' => StudyPlanPriority.newFirst,
      _ => null,
    };
  }

  Future<ConversationController> controllerWithPendingDraft(
    Map<String, Object?> preview,
  ) async {
    final controller = makeController();
    await controller.load();
    await controller.openConversation('conv_1');
    final staged = await draftService.stage(
      sourceConversationId: 'conv_1',
      sourceMessageId: 'msg_1',
      sourceScope: ConversationScope.global(),
      bankName: preview['bank_name'] as String? ?? 'Math',
      goal: preview['goal'] as String?,
      dailyTarget: preview['daily_target'] as int?,
      priority: priorityOf(preview['priority']),
      horizonDays: preview['horizon_days'] as int?,
    ) as StudyPlanStageResultStaged;
    controller.studyPlanDraftId = staged.draft.draftId;
    controller.studyPlanOutcome = staged.draft.outcome;
    controller.studyPlanPreview = Map<String, Object?>.unmodifiable(preview);
    controller.notifyListeners();
    return controller;
  }

  Future<void> pumpCard(WidgetTester tester, ConversationController c) async {
    final facade = _facade();
    await tester.pumpWidget(_wrap(AssistantScreen(
      spacesController: LearningSpacesController(facade),
      fileController: FileLibraryController(facade),
      conversationController: c,
      showGlobalMenu: false,
    )));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'Section 43: Pending StudyPlan card renders accurate preview details and actions',
      (tester) async {
    final controller = await controllerWithPendingDraft(<String, Object?>{
      'bank_name': '高等数学',
      'goal': '期末冲刺 90 分',
      'daily_target': 35,
      'priority': 'weak_first',
      'horizon_days': 21,
      'question_count': 100,
      'mastered_count': 30,
      'due_count': 20,
      'weak_count': 10,
      'new_count': 40,
      'estimated_days': 2,
    });
    addTearDown(controller.dispose);
    await pumpCard(tester, controller);

    // Verify card content
    expect(find.byKey(const ValueKey<String>('study-plan-draft-card')),
        findsOneWidget);
    expect(find.text('学习计划草案'), findsOneWidget);
    expect(find.text('题库：高等数学'), findsOneWidget);
    expect(find.text('目标：期末冲刺 90 分'), findsOneWidget);
    expect(find.text('每日特训量：35 题'), findsOneWidget);
    expect(find.text('优先策略：薄弱题优先'), findsOneWidget);
    expect(find.text('计划周期：21 天'), findsOneWidget);
    expect(
        find.textContaining('题库概况：共 100 题 · 已掌握 30 · 待复习 20 · 薄弱 10 · 新题 40'),
        findsOneWidget);
    expect(find.text('预计约 2 天完成'), findsOneWidget);
    expect(find.text('采用此计划不会修改 FSRS / 现有复习记录。'), findsOneWidget);

    // Verify action buttons
    expect(find.byKey(const ValueKey<String>('study-plan-draft-adopt')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('study-plan-draft-reject')),
        findsOneWidget);
  });

  testWidgets(
      'Section 44: Explicit adoption with no active plan commits immediately',
      (tester) async {
    final controller = await controllerWithPendingDraft(<String, Object?>{
      'bank_name': 'Math',
      'daily_target': 30,
      'priority': 'balanced',
      'question_count': 100,
    });
    addTearDown(controller.dispose);

    persistencePort.currentActivePlan = null;
    persistencePort.nextAdoptResult = StudyPlanPersistenceCommitSuccess(
      ActiveStudyPlan(
        planId: 'plan_1',
        bankName: 'Math',
        dailyTarget: 30,
        priority: StudyPlanPriority.balanced,
        sourceConversationId: 'conv_1',
        sourceUserMessageId: 'msg_1',
        adoptedAt: DateTime.utc(2026, 8, 15),
      ),
    );

    await pumpCard(tester, controller);

    // Tap Adopt
    await tester
        .tap(find.byKey(const ValueKey<String>('study-plan-draft-adopt')));
    await tester.pumpAndSettle();

    expect(persistencePort.adoptCalls, 1);
    expect(persistencePort.adoptHistory.last.expectedActivePlanId, isNull);
    expect(persistencePort.adoptHistory.last.replacementConfirmed, isFalse);

    // Card shows committed status
    expect(find.text('已采用该计划'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('study-plan-draft-adopt')),
        findsNothing);
  });

  testWidgets(
      'Section 45: Active plan exists -> prompts replacement confirmation',
      (tester) async {
    final controller = await controllerWithPendingDraft(<String, Object?>{
      'bank_name': 'Math',
      'daily_target': 30,
      'priority': 'balanced',
    });
    addTearDown(controller.dispose);

    // Active plan exists
    persistencePort.currentActivePlan = ActiveStudyPlan(
      planId: 'current_active_plan_999',
      bankName: 'Math',
      goal: '冲刺高分',
      dailyTarget: 20,
      priority: StudyPlanPriority.balanced,
      sourceConversationId: 'conv_old',
      sourceUserMessageId: 'msg_old',
      adoptedAt: DateTime.utc(2026, 8, 1),
    );

    await pumpCard(tester, controller);

    // Tap Adopt
    await tester
        .tap(find.byKey(const ValueKey<String>('study-plan-draft-adopt')));
    await tester.pumpAndSettle();

    // Zero adopt calls yet; confirmation banner is displayed
    expect(persistencePort.adoptCalls, 0);
    // The confirmation binds the exact observed active plan identity:
    // Application-owned bank/goal shown, provider/model identity never.
    expect(
      find.text('当前已有学习计划（题库：Math，目标：冲刺高分）。采用此草案将替换现有计划，确定要替换吗？'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('study-plan-cancel-replace')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('study-plan-confirm-replace')),
        findsOneWidget);

    // 1. Cancel replacement
    await tester
        .tap(find.byKey(const ValueKey<String>('study-plan-cancel-replace')));
    await tester.pumpAndSettle();

    expect(persistencePort.adoptCalls, 0);
    expect(
      find.text('当前已有学习计划（题库：Math，目标：冲刺高分）。采用此草案将替换现有计划，确定要替换吗？'),
      findsNothing,
    );
    expect(find.byKey(const ValueKey<String>('study-plan-draft-adopt')),
        findsOneWidget);

    // 2. Open confirmation again and confirm
    persistencePort.nextAdoptResult = StudyPlanPersistenceCommitSuccess(
      ActiveStudyPlan(
        planId: 'plan_new_1',
        bankName: 'Math',
        dailyTarget: 30,
        priority: StudyPlanPriority.balanced,
        sourceConversationId: 'conv_1',
        sourceUserMessageId: 'msg_1',
        adoptedAt: DateTime.utc(2026, 8, 15),
      ),
    );

    await tester
        .tap(find.byKey(const ValueKey<String>('study-plan-draft-adopt')));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey<String>('study-plan-confirm-replace')));
    await tester.pumpAndSettle();

    expect(persistencePort.adoptCalls, 1);
    expect(persistencePort.adoptHistory.last.expectedActivePlanId,
        'current_active_plan_999');
    expect(persistencePort.adoptHistory.last.replacementConfirmed, isTrue);

    expect(find.text('已采用该计划'), findsOneWidget);
  });

  testWidgets(
      'Section 46: Stale replacement failure displays error without auto-retry',
      (tester) async {
    final controller = await controllerWithPendingDraft(<String, Object?>{
      'bank_name': 'Math',
      'daily_target': 30,
      'priority': 'balanced',
    });
    addTearDown(controller.dispose);

    persistencePort.currentActivePlan = ActiveStudyPlan(
      planId: 'plan_old',
      bankName: 'Math',
      dailyTarget: 20,
      priority: StudyPlanPriority.balanced,
      sourceConversationId: 'c',
      sourceUserMessageId: 'm',
      adoptedAt: DateTime.utc(2026, 8, 1),
    );
    persistencePort.nextAdoptResult =
        const StudyPlanPersistenceCommitStaleActivePlan();

    await pumpCard(tester, controller);

    await tester
        .tap(find.byKey(const ValueKey<String>('study-plan-draft-adopt')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey<String>('study-plan-confirm-replace')));
    await tester.pumpAndSettle();

    expect(persistencePort.adoptCalls, 1);
    expect(find.text('当前计划状态已变化，请重新确认。'), findsOneWidget);
    // Draft remains pending and buttons remain actionable
    expect(find.byKey(const ValueKey<String>('study-plan-draft-adopt')),
        findsOneWidget);
  });

  testWidgets(
      'Section 47: Already-active failure displays guidance and card remains actionable',
      (tester) async {
    final controller = await controllerWithPendingDraft(<String, Object?>{
      'bank_name': 'Math',
      'daily_target': 30,
      'priority': 'balanced',
    });
    addTearDown(controller.dispose);

    persistencePort.currentActivePlan = null;
    persistencePort.nextAdoptResult =
        const StudyPlanPersistenceCommitAlreadyActive();

    await pumpCard(tester, controller);

    await tester
        .tap(find.byKey(const ValueKey<String>('study-plan-draft-adopt')));
    await tester.pumpAndSettle();

    expect(persistencePort.adoptCalls, 1);
    expect(find.text('已有生效中的学习计划，请确认是否替换。'), findsOneWidget);
    // Card remains pending and actionable
    expect(find.byKey(const ValueKey<String>('study-plan-draft-adopt')),
        findsOneWidget);
  });

  testWidgets(
      'Section 48: Explicit reject transitions draft and disables action buttons',
      (tester) async {
    final controller = await controllerWithPendingDraft(<String, Object?>{
      'bank_name': 'Math',
      'daily_target': 30,
      'priority': 'balanced',
    });
    addTearDown(controller.dispose);
    await pumpCard(tester, controller);

    await tester
        .tap(find.byKey(const ValueKey<String>('study-plan-draft-reject')));
    await tester.pumpAndSettle();

    expect(persistencePort.adoptCalls, 0);
    expect(find.text('已不采用该计划'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('study-plan-draft-adopt')),
        findsNothing);
  });

  testWidgets(
      'Section 49: Duplicate taps while in flight issue at most one command call',
      (tester) async {
    final controller = await controllerWithPendingDraft(<String, Object?>{
      'bank_name': 'Math',
      'daily_target': 30,
      'priority': 'balanced',
    });
    addTearDown(controller.dispose);

    persistencePort.currentActivePlan = null;
    final completer = Completer<StudyPlanPersistenceCommitResult>();
    persistencePort.adoptCompleter = completer;

    await pumpCard(tester, controller);

    // First tap
    await tester
        .tap(find.byKey(const ValueKey<String>('study-plan-draft-adopt')));
    await tester.pump();

    // Second tap while in flight
    await tester
        .tap(find.byKey(const ValueKey<String>('study-plan-draft-adopt')));
    await tester.pump();

    expect(persistencePort.adoptCalls, 1);

    // Complete the in-flight adopt
    completer.complete(StudyPlanPersistenceCommitSuccess(
      ActiveStudyPlan(
        planId: 'p1',
        bankName: 'Math',
        dailyTarget: 30,
        priority: StudyPlanPriority.balanced,
        sourceConversationId: 'conv_1',
        sourceUserMessageId: 'msg_1',
        adoptedAt: DateTime.utc(2026, 8, 15),
      ),
    ));
    await tester.pumpAndSettle();

    expect(persistencePort.adoptCalls, 1);
    expect(find.text('已采用该计划'), findsOneWidget);
  });

  testWidgets(
      'Section 51: Unknown staged outcome fails closed (no actionable card)',
      (tester) async {
    final events = StreamController<AgentTurnEvent>.broadcast();
    final result = Completer<AgentTurnResult>();
    final session = AgentTurnSession(
      events: events.stream,
      result: result.future,
      cancel: () {},
    );
    final controller = ConversationController(
      convService,
      agentSettingsService: agentSettingsService,
      startAgentTurn: ({required conversationId, required userMessageId}) =>
          session,
      studyPlanDraftService: draftService,
      studyPlanCommandService: commandService,
    );
    addTearDown(controller.dispose);
    await controller.load();
    await controller.send('制定计划');

    events.add(const AgentTurnStudyPlanDraftStaged(
      draftId: 'draft_unknown_outcome',
      outcome: 'weird_outcome',
      preview: <String, Object?>{'bank_name': 'Math'},
    ));
    await tester.pump();

    // Unknown staged outcomes must fail closed: no card, no actionable state,
    // and no transient draft was registered.
    expect(controller.hasStudyPlanCard, isFalse);
    expect(controller.studyPlanDraftId, isNull);
    expect(
      () => draftService.draftById('draft_unknown_outcome'),
      throwsArgumentError,
    );

    await events.close();
    result.complete(const AgentTurnFailed(AgentTurnFailure.cancelled));
    await tester.pump();
  });
}
