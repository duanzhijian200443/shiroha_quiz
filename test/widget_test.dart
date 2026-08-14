// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiroha_quiz/application/agent/agent_config_service.dart';
import 'package:shiroha_quiz/application/agent/agent_turn.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_commit_command.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_generation.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_provider.dart';
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
import 'package:shiroha_quiz/domain/answers/answer_candidate.dart';

import 'support/memory_engine_credential_store.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/assets/library_folder.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/projects/project.dart';
import 'package:shiroha_quiz/main.dart';
import 'package:shiroha_quiz/services/ai_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_request_scheduler.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/main_screen.dart';

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

ConversationService _emptyConversationService() => ConversationService(
      repository: _EmptyConversations(),
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

    // Build our app and trigger a frame.
    await tester.pumpWidget(ShirohaQuizApp(
      engineRepository: engineRepository,
      aiService: aiService,
      importPipelineService: importPipelineService,
      importTaskCoordinator: importTaskCoordinator,
      answerGenerationService: answerGenerationService,
      answerCommitCommand: answerCommitCommand,
      u1WorkspaceFacade: _emptyWorkspaceFacade(),
      conversationService: _emptyConversationService(),
      agentSettingsService: AgentSettingsService(
        configStore: _EmptyAgentConfigStore(),
        profileCatalog: _EmptyAgentProfiles(),
      ),
      startAgentTurn: _unusedAgentTurn,
      proposalService: AgentWriteProposalService(_EmptyWritePersistence()),
    ));

    // Verify that MainScreen is shown initially.
    expect(find.byType(MainScreen), findsOneWidget);
    expect(find.text('今日'), findsOneWidget);
    expect(find.text('助手'), findsOneWidget);
    expect(find.text('模考'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);

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
      3,
    );
    final selectedProfileIcon = tester.widget<Container>(
      find.byKey(const ValueKey<String>('main-nav-selected-profile')),
    );
    final decoration = selectedProfileIcon.decoration! as BoxDecoration;
    expect(decoration.color, const Color(0xFFEAF1FF));
    expect(decoration.borderRadius, BorderRadius.circular(12));
  });
}
