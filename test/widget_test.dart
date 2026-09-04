// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiroha_quiz/application/agent/agent_config.dart';
import 'package:shiroha_quiz/application/agent/agent_config_service.dart';
import 'package:shiroha_quiz/application/agent/agent_turn.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_commit_command.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_generation.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_provider.dart';
import 'package:shiroha_quiz/application/content/content_asset_authority.dart';
import 'package:shiroha_quiz/application/exam/exam_mutation_command.dart';
import 'package:shiroha_quiz/application/file_library/file_library_ports.dart';
import 'package:shiroha_quiz/application/conversations/conversation_repository.dart';
import 'package:shiroha_quiz/application/conversations/conversation_service.dart';
import 'package:shiroha_quiz/application/file_library/library_folder_repository.dart';
import 'package:shiroha_quiz/application/file_library/library_folder_service.dart';
import 'package:shiroha_quiz/application/projects/project_repository.dart';
import 'package:shiroha_quiz/application/projects/project_service.dart';
import 'package:shiroha_quiz/application/study_query/study_query_dtos.dart';
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/application/study_query/study_query_service.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_persistence.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_proposal_service.dart';
import 'package:shiroha_quiz/application/u1_workspace/u1_workspace_dtos.dart';
import 'package:shiroha_quiz/application/u1_workspace/u1_workspace_facade.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/domain/answers/answer_candidate.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';

import 'support/memory_engine_credential_store.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/assets/library_folder.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/conversations/conversation_message.dart';
import 'package:shiroha_quiz/domain/projects/project.dart';
import 'package:shiroha_quiz/main.dart';
import 'package:shiroha_quiz/services/ai_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_request_scheduler.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/main_screen.dart';
import 'package:shiroha_quiz/ui/pages/home_page.dart';
import 'package:shiroha_quiz/ui/pages/agent_settings_screen.dart';
import 'package:shiroha_quiz/ui/pages/ai_settings_screen.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class _EmptyFiles extends Fake implements LibraryFileRepositoryPort {
  @override
  Future<List<LibraryFile>> findAll() async => const <LibraryFile>[];
}

final class _EmptyIngestion extends Fake implements FileIngestionPort {}

final class _EmptyFolders extends Fake implements LibraryFolderRepositoryPort {
  @override
  Future<List<LibraryFolder>> listFolders() async => const <LibraryFolder>[];

  @override
  Future<List<LibraryFile>> listUnclassifiedFiles() async =>
      const <LibraryFile>[];
}

final class _EmptyProjects extends Fake implements ProjectRepository {
  @override
  Future<List<Project>> listProjects() async => const <Project>[];
}

final class _EmptyQuestions extends Fake implements StudyQuestionQueryPort {
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

  @override
  Future<StudyQuestionRead?> getStudyQuestionDetail(
    String questionId, {
    required int nowUnixSeconds,
  }) async =>
      null;
}

/// Fail-closed P7 provider: the navigation smoke never invokes AI, so any
/// accidental call must fail loudly instead of hitting a live provider.
final class _FailClosedAiProvider extends Fake implements AiAnswerProviderPort {
  @override
  Future<AiAnswerProviderResult> generateAnswer(
    AiAnswerProviderRequest request,
  ) {
    throw UnimplementedError();
  }
}

/// Fail-closed P7 commit persistence: never reached by the smoke test.
final class _FailClosedCommitPort implements AiAnswerCommitPersistencePort {
  @override
  Future<void> commitAnswer(AnswerCandidate candidate) {
    throw UnimplementedError();
  }
}

final class _EmptyMetrics extends Fake implements StudyMetricsQueryPort {}

final class _EmptyConversations extends Fake
    implements ConversationRepositoryPort {
  @override
  Future<ConversationThreadSlice> createWithFirstMessage({
    required Conversation conversation,
    required ConversationMessage firstMessage,
    required List<String> fileIds,
    required DateTime attachedAt,
  }) async =>
      ConversationThreadSlice(
        conversation: conversation,
        messages: <ConversationMessage>[firstMessage],
        files: const <ConversationFileRef>[],
        hasMoreBefore: false,
        nextBeforeSequence: null,
      );

  @override
  Future<List<ConversationFileRef>> listAttachableFiles(
          {required int limit}) async =>
      const <ConversationFileRef>[];

  @override
  Future<List<Conversation>> listRecentConversations(
          {required int limit}) async =>
      const <Conversation>[];
}

final class _EmptyAgentConfigStore implements AgentConfigStorePort {
  @override
  Future<String?> readAgentConfig() async => null;

  @override
  Future<void> writeAgentConfig(String encodedConfig) async {}
}

final class _EmptyAgentProfiles implements AgentProfileCatalogPort {
  @override
  Future<List<AgentProfileSummary>> listMainProfiles() async => const [];
}

final class _ConfiguredAgentConfigStore implements AgentConfigStorePort {
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

final class _ConfiguredAgentProfiles implements AgentProfileCatalogPort {
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

final class _EmptyExamMutationPersistence extends Fake
    implements ExamMutationPersistencePort {}

final class _EmptyWritePersistence implements AgentWritePersistencePort {
  @override
  Future<AgentWriteAdmissionResult> admitStagingTarget(
    AgentWriteAdmissionRequest request,
  ) async =>
      const AgentWriteAdmissionDenied();

  @override
  Future<void> commitApproved(AgentWriteCommitRequest request) async {}
}

AgentTurnSession _unusedAgentTurn({
  required String conversationId,
  required String userMessageId,
}) =>
    AgentTurnSession(
      events: const Stream<AgentTurnEvent>.empty(),
      result: Future<AgentTurnResult>.value(
        const AgentTurnFailed(AgentTurnFailure.internalError),
      ),
      cancel: () {},
    );

final class _PendingAgentTurn {
  final StreamController<AgentTurnEvent> events =
      StreamController<AgentTurnEvent>.broadcast();
  final Completer<AgentTurnResult> result = Completer<AgentTurnResult>();
  bool cancelled = false;
  int starts = 0;

  late final AgentTurnSession session = AgentTurnSession(
    events: events.stream,
    result: result.future,
    cancel: _cancel,
  );

  AgentTurnSession start({
    required String conversationId,
    required String userMessageId,
  }) {
    starts++;
    return session;
  }

  void complete() {
    if (result.isCompleted) return;
    result.complete(
      const AgentTurnFailed(AgentTurnFailure.temporarilyUnavailable),
    );
    unawaited(events.close());
  }

  void _cancel() {
    cancelled = true;
    complete();
  }
}

ConversationService _emptyConversationService({
  ConversationRepositoryPort? repository,
}) =>
    ConversationService(
      repository: repository ?? _EmptyConversations(),
      conversationIdFactory: () => 'conversation-empty',
      messageIdFactory: () => 'message-empty',
      clock: () => DateTime.fromMillisecondsSinceEpoch(1, isUtc: true),
    );

U1WorkspaceFacade _emptyWorkspaceFacade() {
  return U1WorkspaceFacade(
    projectService: ProjectService(repository: _EmptyProjects()),
    fileRepository: _EmptyFiles(),
    fileIngestion: _EmptyIngestion(),
    folderService: LibraryFolderService(
      repository: _EmptyFolders(),
      folderIdFactory: () => 'folder-empty',
    ),
    studyQueryService: StudyQueryService(
      questionQuery: _EmptyQuestions(),
      metricsQuery: _EmptyMetrics(),
    ),
    mcpProjection: McpWorkspaceProjection(
      state: McpCapabilityState.configuredAvailable,
      transport: McpTransport.localStdio,
      permission: McpPermission.readOnly,
      toolNames: const <String>[],
    ),
  );
}

void main() {
  setUpAll(() {
    // Initialize sqflite ffi for desktop/testing
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets(
      'App exposes the canonical Assistant navigation and selected state',
      (WidgetTester tester) async {
    // A tall viewport materializes the whole Profile ListView so the key
    // settings rows are built without scrolling.
    await pumpApp(tester, const Size(800, 2000));

    // Verify that MainScreen is shown initially.
    expect(find.byType(MainScreen), findsOneWidget);
    expect(find.text('今日'), findsOneWidget);
    expect(find.text('助手'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);

    // Final primary navigation is exactly 今日 | 助手 | 我的: the top-level
    // 模考 destination is retired from primary navigation.
    expect(find.text('模考'), findsNothing);
    final navLabels = tester
        .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
        .items
        .map((item) => item.label)
        .toList();
    expect(navLabels, <String>['今日', '助手', '我的']);
    expect(
      tester
          .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
          .selectedItemColor,
      AppTheme.shirohaCyanForeground,
    );

    await tester.tap(find.text('助手'));
    await tester.pump();

    expect(
      tester
          .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
          .currentIndex,
      1,
    );
    expect(
      find.byKey(const ValueKey<String>('u1-ux0-assistant-shell')),
      findsOneWidget,
    );

    await tester.tap(find.text('我的'));
    await tester.pump();

    expect(
      tester
          .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
          .currentIndex,
      2,
    );
    final selectedProfileIcon = tester.widget<Container>(
      find.byKey(const ValueKey<String>('main-nav-selected-profile')),
    );
    final decoration = selectedProfileIcon.decoration! as BoxDecoration;
    final selectedTheme = Theme.of(tester.element(
      find.byKey(const ValueKey<String>('main-nav-selected-profile')),
    ));
    expect(decoration.color, selectedTheme.colorScheme.primaryContainer);
    expect(decoration.borderRadius, BorderRadius.circular(12));

    // Profile key settings entries remain reachable after the 3-tab
    // migration.
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('profile-ai-service-row')),
    );
    expect(
      find.byKey(const ValueKey<String>('profile-ai-service-row')),
      findsOneWidget,
    );

    // Profile routes remain navigable without touching provider/config/
    // network: open each settings screen and return.
    final aiServiceRow =
        find.byKey(const ValueKey<String>('profile-ai-service-row'));
    await tester.tap(aiServiceRow);
    await pumpUntilFound(tester, find.byType(AiSettingsScreen));
    expect(find.byType(AiSettingsScreen), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('ai-service-agent-settings-row')),
    );
    await pumpUntilFound(tester, find.byType(AgentSettingsScreen));
    expect(find.byType(AgentSettingsScreen), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pump();
    await pumpUntilFound(tester, find.byType(AiSettingsScreen));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pump();

    expect(tester.takeException(), isNull);
    await drainBackgroundWork(tester);
  });

  testWidgets(
    'Today handoff selects conversation, consumes prefill, and never auto-sends',
    (WidgetTester tester) async {
      await pumpApp(tester, const Size(1024, 1200));

      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('home-bank-card')),
      );
      await tester.tap(
        find.descendant(
          of: find.byType(BottomNavigationBar),
          matching: find.text('助手'),
        ),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('u1-ux01-open-file-library')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('u1-ux01-open-file-library')),
      );
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byType(BottomNavigationBar),
          matching: find.text('今日'),
        ),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('home-bank-card')),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('home-ask-assistant')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('home-ask-assistant')),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('u1-ux0-composer')),
      );

      expect(
        tester
            .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
            .currentIndex,
        1,
      );
      final composer = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('u1-ux0-composer')),
      );
      expect(composer.controller!.text, contains('今天可以开始新题'));
      expect(
        find.byKey(const ValueKey<String>('u1-ux0-send')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('a0-agent-cancel')),
        findsNothing,
      );

      await tester.enterText(
        find.byKey(const ValueKey<String>('u1-ux0-composer')),
        '保留中的草稿',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(BottomNavigationBar),
          matching: find.text('今日'),
        ),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('home-bank-card')),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('home-ask-assistant')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('home-ask-assistant')),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('u1-ux0-composer')),
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey<String>('u1-ux0-composer')),
            )
            .controller!
            .text,
        '保留中的草稿',
      );

      tester
          .widget<TextField>(
            find.byKey(const ValueKey<String>('u1-ux0-composer')),
          )
          .controller!
          .clear();
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('u1-ux01-open-file-library')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('u1-ux01-new-conversation')),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('u1-ux0-composer')),
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey<String>('u1-ux0-composer')),
            )
            .controller!
            .text,
        isEmpty,
      );

      expect(tester.takeException(), isNull);
      await drainBackgroundWork(tester);
    },
  );

  testWidgets('Today handoff preserves an active Agent turn', (
    WidgetTester tester,
  ) async {
    final turn = _PendingAgentTurn();
    addTearDown(turn.complete);
    await pumpApp(
      tester,
      const Size(1024, 1200),
      conversationService: _emptyConversationService(),
      agentSettingsService: AgentSettingsService(
        configStore: _ConfiguredAgentConfigStore(),
        profileCatalog: _ConfiguredAgentProfiles(),
      ),
      startAgentTurn: turn.start,
    );

    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('home-bank-card')),
    );
    await tester.tap(
      find.descendant(
        of: find.byType(BottomNavigationBar),
        matching: find.text('助手'),
      ),
    );
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('u1-ux0-composer')),
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('u1-ux0-composer')),
      '保持当前生成',
    );
    await tester.tap(find.byKey(const ValueKey<String>('u1-ux0-send')));
    await tester.pump();
    await tester.pump();
    expect(turn.starts, 1);
    expect(
      find.byKey(const ValueKey<String>('a0-agent-cancel')),
      findsOneWidget,
    );

    await tester.tap(
      find.descendant(
        of: find.byType(BottomNavigationBar),
        matching: find.text('今日'),
      ),
    );
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('home-bank-card')),
    );
    expect(turn.cancelled, isFalse);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey<String>('home-ask-assistant')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey<String>('home-ask-assistant')));
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('a0-agent-cancel')),
    );

    expect(turn.cancelled, isFalse);
    expect(
      tester
          .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
          .currentIndex,
      1,
    );
    expect(tester.takeException(), isNull);

    turn.complete();
    await tester.pump();
    await drainBackgroundWork(tester);
  });

  testWidgets('mobile Assistant drawer and edge gesture stay tab-scoped', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, const Size(360, 720));
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('home-bank-card')),
    );
    await tester.tap(
      find.descendant(
        of: find.byType(BottomNavigationBar),
        matching: find.text('助手'),
      ),
    );
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('u1-ux0-open-drawer')),
    );
    await tester.dragFrom(
      const Offset(1, 300),
      const Offset(300, 0),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final drawerScaffold = find
        .ancestor(of: find.byType(Drawer), matching: find.byType(Scaffold))
        .first;
    final navigationScaffold = find
        .ancestor(
          of: find.byType(BottomNavigationBar),
          matching: find.byType(Scaffold),
        )
        .first;
    expect(tester.element(drawerScaffold),
        same(tester.element(navigationScaffold)));
    final navigationScaffoldState =
        tester.state<ScaffoldState>(navigationScaffold);
    expect(navigationScaffoldState.isDrawerOpen, isTrue);

    navigationScaffoldState.closeDrawer();
    await tester.pump(const Duration(milliseconds: 500));
    expect(navigationScaffoldState.isDrawerOpen, isFalse);
    tester
        .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
        .onTap!(0);
    await tester.pump(const Duration(milliseconds: 500));
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('home-bank-card')),
    );
    expect(navigationScaffoldState.isDrawerOpen, isFalse);
    await tester.dragFrom(
      const Offset(1, 300),
      const Offset(300, 0),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(navigationScaffoldState.isDrawerOpen, isFalse);

    tester
        .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
        .onTap!(1);
    await tester.pump();
    await tester.dragFrom(
      const Offset(1, 300),
      const Offset(300, 0),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(navigationScaffoldState.isDrawerOpen, isTrue);
    navigationScaffoldState.closeDrawer();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(navigationScaffoldState.isDrawerOpen, isFalse);

    tester
        .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
        .onTap!(2);
    await tester.pump();
    await tester.dragFrom(
      const Offset(1, 300),
      const Offset(300, 0),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(navigationScaffoldState.isDrawerOpen, isFalse);
    expect(tester.takeException(), isNull);
    await drainBackgroundWork(tester);
  });

  testWidgets('mobile Assistant menu opens the global drawer', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, const Size(360, 720));
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('home-bank-card')),
    );
    await tester.tap(
      find.descendant(
        of: find.byType(BottomNavigationBar),
        matching: find.text('助手'),
      ),
    );
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('u1-ux0-open-drawer')),
    );

    final menuButton = find.byKey(
      const ValueKey<String>('u1-ux0-open-drawer'),
    );
    expect(menuButton.hitTestable(), findsOneWidget);
    await tester.tap(menuButton);
    await tester.pump(const Duration(milliseconds: 500));

    final navigationScaffold = find
        .ancestor(
          of: find.byType(BottomNavigationBar),
          matching: find.byType(Scaffold),
        )
        .first;
    expect(
      tester.state<ScaffoldState>(navigationScaffold).isDrawerOpen,
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await drainBackgroundWork(tester);
  });

  testWidgets('Assistant drawer owner follows responsive layout changes', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, const Size(360, 720));
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('home-bank-card')),
    );
    await tester.tap(
      find.descendant(
        of: find.byType(BottomNavigationBar),
        matching: find.text('助手'),
      ),
    );
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('u1-ux0-open-drawer')),
    );

    final navigationScaffold = find
        .ancestor(
          of: find.byType(BottomNavigationBar),
          matching: find.byType(Scaffold),
        )
        .first;
    final navigationScaffoldState =
        tester.state<ScaffoldState>(navigationScaffold);

    tester.view.physicalSize = const Size(1024, 768);
    await tester.pump();
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('u1-ux01-workspace-shell')),
    );
    final desktopScaffold = tester.widget<Scaffold>(navigationScaffold);
    expect(desktopScaffold.drawer, isNull);
    expect(desktopScaffold.drawerEnableOpenDragGesture, isFalse);
    await tester.dragFrom(
      const Offset(1, 300),
      const Offset(300, 0),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(navigationScaffoldState.isDrawerOpen, isFalse);

    tester.view.physicalSize = const Size(360, 720);
    await tester.pump();
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('u1-ux0-open-drawer')),
    );
    await tester.dragFrom(
      const Offset(1, 300),
      const Offset(300, 0),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(navigationScaffoldState.isDrawerOpen, isTrue);

    navigationScaffoldState.closeDrawer();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    await drainBackgroundWork(tester);
  });

  testWidgets('full responsive primary navigation is reachable at 360x720',
      (WidgetTester tester) async {
    await pumpApp(tester, const Size(360, 720));
    await expectResponsiveNavigation(
      tester,
      assistantShellKey: 'u1-ux0-assistant-shell',
      expectProfileAiServiceRow: false,
    );
    await drainBackgroundWork(tester);
  });

  testWidgets('full responsive primary navigation is reachable at 1024x768',
      (WidgetTester tester) async {
    await pumpApp(tester, const Size(1024, 768));
    await expectResponsiveNavigation(
      tester,
      assistantShellKey: 'u1-ux01-workspace-shell',
      expectProfileAiServiceRow: true,
    );
    await drainBackgroundWork(tester);
  });

  testWidgets(
      'production composition forwards configured question and asset seams',
      (WidgetTester tester) async {
    final temp = Directory.systemTemp.createTempSync('wiring_assets_');
    try {
      final contentAssetStore = ManagedContentAssetStore(managedRoot: temp);
      final configured = QuestionRepository(
        databaseHelper: DatabaseHelper.instance,
        mapper: QuestionV2PersistenceMapper(
          contentAssetAuthority: contentAssetStore,
        ),
      );
      await tester.pumpWidget(
        _buildTestApp(
          questionRepository: configured,
          contentAssetResolver: contentAssetStore,
        ),
      );
      await tester.pump();

      final app = tester.widget<ShirohaQuizApp>(
        find.byType(ShirohaQuizApp),
      );
      expect(app.questionListQuery, same(configured));
      expect(app.questionMutationPersistence, same(configured));
      expect(app.typedAnswerPersistence, same(configured));
      expect(app.questionBankMutationPersistence, same(configured));
      expect(app.folderQuery, same(configured));
      expect(app.contentAssetResolver, same(contentAssetStore));
      expect(
        tester.widget<MainScreen>(find.byType(MainScreen)).questionListQuery,
        same(configured),
      );
      expect(
        tester.widget<HomePage>(find.byType(HomePage)).questionListQuery,
        same(configured),
      );
      expect(tester.takeException(), isNull);
      await drainBackgroundWork(tester);
    } finally {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    }
  });
}

/// Builds the full app with deterministic fail-closed fakes. Never touches a
/// live provider, network, or real credential store.
Widget _buildTestApp({
  QuestionRepository? questionRepository,
  ContentAssetResolver? contentAssetResolver,
  ConversationService? conversationService,
  AgentSettingsService? agentSettingsService,
  AgentTurnStarter? startAgentTurn,
}) {
  final engineRepository = AiEngineRepository(
    store: DatabaseHelper.instance,
    credentialStore: MemoryEngineCredentialStore(),
  );
  final taskManager = TaskManager.forTesting();
  final aiService = AiService(
    engineRepository: engineRepository,
    taskManager: taskManager,
  );
  final ocrRequestScheduler = OcrRequestScheduler();
  final importPipelineService = ImportPipelineService(
    aiService: aiService,
    engineRepository: engineRepository,
    taskManager: taskManager,
    ocrRequestScheduler: ocrRequestScheduler,
  );
  final importTaskCoordinator = ImportTaskCoordinator(
    taskManager: taskManager,
    requestScheduler: ocrRequestScheduler,
  );
  // P7 seams: real Application services over deterministic fail-closed
  // ports. The navigation smoke never triggers an AI action, so no
  // provider/network/database path can run.
  final answerGenerationService = AiAnswerGenerationService(
    questionPort: _EmptyQuestions(),
    providerPort: _FailClosedAiProvider(),
    idFactory: () => 'gen-empty',
    clock: () => DateTime.fromMillisecondsSinceEpoch(1, isUtc: true),
  );
  final answerCommitCommand = AiAnswerCommitCommand(
    persistencePort: _FailClosedCommitPort(),
  );
  final examMutationCommand = ExamMutationCommand(
    _EmptyExamMutationPersistence(),
  );
  final configuredQuestionRepository = questionRepository ??
      QuestionRepository(
        databaseHelper: DatabaseHelper.instance,
        mapper: const QuestionV2PersistenceMapper(),
      );
  return ShirohaQuizApp(
    engineRepository: engineRepository,
    aiService: aiService,
    importPipelineService: importPipelineService,
    importTaskCoordinator: importTaskCoordinator,
    answerGenerationService: answerGenerationService,
    answerCommitCommand: answerCommitCommand,
    examMutationCommand: examMutationCommand,
    questionListQuery: configuredQuestionRepository,
    questionMutationPersistence: configuredQuestionRepository,
    typedAnswerPersistence: configuredQuestionRepository,
    questionBankMutationPersistence: configuredQuestionRepository,
    folderQuery: configuredQuestionRepository,
    contentAssetResolver: contentAssetResolver,
    u1WorkspaceFacade: _emptyWorkspaceFacade(),
    conversationService: conversationService ?? _emptyConversationService(),
    agentSettingsService: agentSettingsService ??
        AgentSettingsService(
          configStore: _EmptyAgentConfigStore(),
          profileCatalog: _EmptyAgentProfiles(),
        ),
    startAgentTurn: startAgentTurn ?? _unusedAgentTurn,
    proposalService: AgentWriteProposalService(_EmptyWritePersistence()),
  );
}

/// Pumps the full app at [size] and registers viewport teardown.
Future<void> pumpApp(
  WidgetTester tester,
  Size size, {
  ConversationService? conversationService,
  AgentSettingsService? agentSettingsService,
  AgentTurnStarter? startAgentTurn,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    _buildTestApp(
      conversationService: conversationService,
      agentSettingsService: agentSettingsService,
      startAgentTurn: startAgentTurn,
    ),
  );
}

/// Proves every final primary destination is reachable at the current
/// viewport: 今日 | 助手 | 我的, no 模考, Today loads, Assistant shell for the
/// viewport form appears, Profile loads and a stable settings row is
/// reachable.
Future<void> expectResponsiveNavigation(
  WidgetTester tester, {
  required String assistantShellKey,
  required bool expectProfileAiServiceRow,
}) async {
  expect(find.byType(MainScreen), findsOneWidget);
  expect(find.text('模考'), findsNothing);
  final navLabels = tester
      .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
      .items
      .map((item) => item.label)
      .toList();
  expect(navLabels, <String>['今日', '助手', '我的']);

  // Default Today destination is reachable.
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey<String>('home-bank-card')),
  );

  await tester.tap(find.text('助手'));
  await tester.pump();
  expect(
    tester
        .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
        .currentIndex,
    1,
  );
  expect(
    find.byKey(ValueKey<String>(assistantShellKey)),
    findsOneWidget,
  );

  await tester.tap(find.text('我的'));
  await tester.pump();
  expect(
    tester
        .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
        .currentIndex,
    2,
  );
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey<String>('profile-wrong-book-row')),
  );
  expect(
    find.byKey(const ValueKey<String>('profile-wrong-book-row')),
    findsOneWidget,
  );
  if (expectProfileAiServiceRow) {
    expect(
      find.byKey(const ValueKey<String>('profile-ai-service-row')),
      findsOneWidget,
    );
  }
  expect(tester.takeException(), isNull);
}

/// Lets any remaining background DB work finish, then elapses fake time so
/// no sqflite lock-warning timer is left pending at teardown.
Future<void> drainBackgroundWork(WidgetTester tester) async {
  for (var frame = 0; frame < 20; frame++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
  await tester.pump(const Duration(seconds: 11));
}

Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 80,
}) async {
  for (var frame = 0; frame < maxFrames; frame++) {
    await tester.pump();
    if (finder.evaluate().isNotEmpty) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
  }
  fail('Expected widget did not appear within ${maxFrames * 25} ms: $finder');
}
