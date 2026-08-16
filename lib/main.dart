import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'application/agent/agent_config_service.dart';
import 'application/backup/backup_restore_coordinator.dart';
import 'application/agent/agent_runtime.dart';
import 'application/agent/agent_study_plan_tool_dispatcher.dart';
import 'application/agent/agent_study_tool_dispatcher.dart';
import 'application/agent/agent_turn.dart';
import 'application/agent/agent_write_proposal_tool_dispatcher.dart';
import 'application/agent/agent_retrieval_tool.dart';
import 'application/answers/ai_answer_commit_command.dart';
import 'application/answers/ai_answer_generation.dart';
import 'application/conversations/conversation_service.dart';
import 'application/exam/exam_mutation_command.dart';
import 'application/file_library/library_folder_service.dart';
import 'application/retrieval/retrieval_scope_resolver.dart';
import 'application/retrieval/retrieval_service.dart';
import 'application/safe_write/agent_write_proposal_service.dart';
import 'application/study_plan/study_plan_command_service.dart';
import 'application/study_plan/study_plan_draft_service.dart';
import 'application/study_plan/study_plan_pool_order.dart';
import 'application/study_plan/study_plan_selection_service.dart';
import 'core/database/database_helper.dart';
import 'core/review_engine_service.dart';
import 'core/observability/app_logger.dart';
import 'application/projects/project_service.dart';
import 'application/study_query/study_query_service.dart';
import 'application/u1_workspace/u1_workspace_dtos.dart';
import 'application/u1_workspace/u1_workspace_facade.dart';
import 'data/repositories/ai_engine_repository.dart';
import 'data/credentials/secure_engine_credential_store.dart';
import 'data/credentials/ai_engine_credential_activation.dart';
import 'data/repositories/agent_config_repository.dart';
import 'data/repositories/backup_database_authority.dart';
import 'data/repositories/backup_snapshot_repository.dart';
import 'data/repositories/agent_profile_repository.dart';
import 'data/repositories/approved_agent_write_repository.dart';
import 'data/repositories/conversation_repository.dart';
import 'data/repositories/exam_repository.dart';
import 'data/repositories/library_file_repository.dart';
import 'data/repositories/library_folder_repository.dart';
import 'data/repositories/project_repository.dart';
import 'data/repositories/parsed_artifact_repository.dart';
import 'data/repositories/retrieval_index_repository.dart';
import 'data/repositories/question_repository.dart';
import 'data/repositories/review_repository.dart';
import 'data/repositories/settings_repository.dart';
import 'data/repositories/ai_answer_commit_repository.dart';
import 'data/repositories/study_plan_persistence_repository.dart';
import 'data/repositories/study_plan_read_repository.dart';
import 'mcp/study_mcp_adapter.dart';
import 'services/ai_service.dart';
import 'services/answers/ai_answer_provider_adapter.dart';
import 'services/agent/deepseek_responses_provider.dart';
import 'services/backup/backup_restore_runtime.dart';
import 'services/bank_update_notifier.dart' as bank_updates;
import 'services/file_library/file_ingestion_service.dart';
import 'services/file_library/managed_file_storage_adapter.dart';
import 'services/file_library/managed_artifact_storage_adapter.dart';
import 'services/import_pipeline/import_pipeline_service.dart';
import 'services/import_pipeline/import_task_coordinator.dart';
import 'services/import_pipeline/ocr_request_scheduler.dart';
import 'services/task_manager.dart';
import 'services/llm_providers/zhipu_ocr_client.dart';
import 'services/parsed_artifacts/deterministic_parsed_artifact_generation_adapter.dart';
import 'services/parsed_artifacts/ocr_parsed_artifact_generation_adapter.dart';
import 'services/parsed_artifacts/parsed_artifact_generation_router.dart';
import 'services/parsed_artifacts/parsed_artifact_lifecycle_service.dart';
import 'services/retrieval/parsed_artifact_retrieval_source.dart';
import 'services/retrieval/deterministic_source_chunker.dart';
import 'services/study_plan/study_plan_practice_session_launcher.dart';
import 'ui/dependencies/ai_dependencies_scope.dart';
import 'ui/pages/backup/backup_restore_screen.dart';
import 'ui/pages/home_page.dart';
import 'ui/theme/app_theme.dart';
import 'ui/pages/main_screen.dart';
import 'package:flutter_tex/flutter_tex.dart';

final ValueNotifier<String> globalThemeNotifier = ValueNotifier('light');
// 核心新增：全局消息总线钥匙，用于跨页面/后台任务弹窗
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
// 核心新增：全局路由钥匙，用于后台任务完成后弹出弹窗
final GlobalKey<NavigatorState> globalNavigatorKey =
    GlobalKey<NavigatorState>();

// 新增：题库刷新事件总线
final ValueNotifier<int> globalBankUpdateNotifier =
    bank_updates.globalBankUpdateNotifier;

class DevHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      // 强制流量走本地 7890 端口 (绝大多数代理软件的默认混合端口)
      ..findProxy = (uri) {
        return "PROXY 127.0.0.1:7890;";
      }
      // 忽略证书校验，防止代理软件的中间人劫持报错
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}

void main() {
  runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await AppLogger.initialize();

    FlutterError.onError = (details) {
      AppLogger.error(
        'Unhandled Flutter framework error',
        module: 'Flutter',
        error: details.exception,
        stackTrace: details.stack,
      );
      FlutterError.presentError(details);
    };

    PlatformDispatcher.instance.onError = (error, stackTrace) {
      AppLogger.error(
        'Unhandled platform error',
        module: 'Platform',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    };

    // 桌面端（Windows / Linux）需通过 FFI 加载 SQLite 原生库
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final databaseHelper = DatabaseHelper.instance;
    final supportDirectory = await getApplicationSupportDirectory();
    final managedFileStorage = await ManagedFileStorageAdapter.appManaged();
    final backupSnapshotRepository = BackupSnapshotRepository(
      databaseHelper: databaseHelper,
    );
    late Future<void> Function() relaunchApp;
    final backupRestore = BackupRestoreCoordinator(
      compositionReload: () => relaunchApp(),
      operations: BackupRestoreRuntime(
        databaseAuthority: SqliteBackupDatabaseAuthority(
          databaseHelper: databaseHelper,
          snapshotRepository: backupSnapshotRepository,
        ),
        snapshotRepository: backupSnapshotRepository,
        managedFileStorage: managedFileStorage,
        restoreRoot: Directory(p.join(supportDirectory.path, 'restore')),
        managedFilesRoot:
            Directory(p.join(supportDirectory.path, 'library_files')),
      ),
    );
    // Hard B0-I0 startup order: unfinished restore journal recovery MUST
    // complete before any production DatabaseHelper open.
    final b0StartupRecovery = await backupRestore.recoverStartupIfNeeded();
    if (b0StartupRecovery.blocked) {
      AppLogger.error(
        'B0 restore startup recovery blocked normal initialization',
        module: 'Backup',
        data: <String, Object?>{
          'stage': 'startup_recovery',
          'status': 'blocked',
          'failureCode': b0StartupRecovery.failure?.name,
        },
      );
      runApp(
        BackupMaintenanceScreen(diagnosticId: b0StartupRecovery.diagnosticId),
      );
      return;
    }

    var isFirstComposition = true;

    Future<void> composeAndRun() async {
      if (!isFirstComposition) {
        // B0-I0 in-memory invalidation: clear process-lifetime transient
        // state before constructing a fresh composition over the restored DB.
        SettingsRepository.instance.clearCache();
        await TaskManager.instance.resetTransientStateForRestore();
        ReviewEngineService().resetTransientStateForRestore();
        ApprovedAgentWriteRepository.instance.clearTransientState();
      }
      isFirstComposition = false;

      final libraryFileRepository = LibraryFileRepository(
        databaseHelper: databaseHelper,
      );
      final fileIngestionService = FileIngestionService(
        storage: managedFileStorage,
        repository: libraryFileRepository,
      );
      final projectRepository =
          SqliteProjectRepository(databaseHelper: databaseHelper);
      final projectService = ProjectService(repository: projectRepository);
      const uuid = Uuid();
      final conversationService = ConversationService(
        repository:
            SqliteConversationRepository(databaseHelper: databaseHelper),
        conversationIdFactory: uuid.v4,
        messageIdFactory: uuid.v4,
        clock: () => DateTime.now().toUtc(),
      );
      final folderService = LibraryFolderService(
        repository: SqliteLibraryFolderRepository(
          databaseHelper: databaseHelper,
        ),
        folderIdFactory: uuid.v4,
      );
      final questionRepository = QuestionRepository(
        databaseHelper: databaseHelper,
      );
      final examMutationCommand = ExamMutationCommand(
        ExamRepository(databaseHelper: databaseHelper),
      );
      final studyQueryService = StudyQueryService(
        questionQuery: questionRepository,
        metricsQuery: ReviewRepository(databaseHelper: databaseHelper),
      );
      final engineRepository = await activateAiEngineRepository(
        openDatabase: () async {
          await databaseHelper.database;
        },
        store: databaseHelper,
        migrationStore: databaseHelper,
        createCredentialStore: SecureEngineCredentialStore.new,
      );
      // P7 composition: Presentation only sees the Application seams.
      final answerGenerationService = AiAnswerGenerationService(
        questionPort: questionRepository,
        providerPort:
            AiAnswerProviderAdapter(engineRepository: engineRepository),
        idFactory: uuid.v4,
        clock: () => DateTime.now().toUtc(),
      );
      final answerCommitCommand = AiAnswerCommitCommand(
        persistencePort:
            AiAnswerCommitRepository(databaseHelper: databaseHelper),
      );
      final agentConfigStore =
          SqliteAgentConfigStore(databaseHelper: databaseHelper);
      final agentProfileRepository = AiEngineAgentProfileRepository(
        engineRepository: engineRepository,
      );
      final agentSettingsService = AgentSettingsService(
        configStore: agentConfigStore,
        profileCatalog: agentProfileRepository,
      );
      // W0 composition enablement point: removing this dispatcher registration
      // (and the proposalService wiring below) turns the proposal capability
      // off while keeping the six read tools.
      final agentWritePersistence = ApprovedAgentWriteRepository.instance;
      final agentWriteProposalService =
          AgentWriteProposalService(agentWritePersistence);
      final studyPlanReadRepository =
          StudyPlanReadRepository(databaseHelper: databaseHelper);
      final studyPlanDraftService = StudyPlanDraftService(
        planningPort: studyPlanReadRepository,
        draftIdFactory: uuid.v4,
        clock: () => DateTime.now().toUtc(),
      );
      final studyPlanPersistenceRepository =
          StudyPlanPersistenceRepository(databaseHelper: databaseHelper);
      final studyPlanCommandService = StudyPlanCommandService(
        draftService: studyPlanDraftService,
        persistencePort: studyPlanPersistenceRepository,
        planIdFactory: uuid.v4,
        clock: () => DateTime.now().toUtc(),
      );
      // SPL-1-U0 focused seams: deterministic dynamic selection + the narrow
      // Practice materialization/session adapter. All read from the same
      // long-lived StudyPlan repositories; nothing new is persisted.
      final studyPlanSelectionService = StudyPlanSelectionService(
        persistencePort: studyPlanPersistenceRepository,
        planningPort: studyPlanReadRepository,
        candidateQueryPort: studyPlanReadRepository,
        poolOrder: const StudyPlanPoolOrder(),
        clock: () => DateTime.now().toUtc(),
      );
      final studyPlanSessionLauncher = StudyPlanPracticeSessionLauncher();
      final parsedArtifactRepository =
          ParsedArtifactRepository(databaseHelper: databaseHelper);
      final parsedArtifactLifecycle = ParsedArtifactLifecycleService(
        libraryFileRepository: libraryFileRepository,
        artifactRepository: parsedArtifactRepository,
        artifactStorage: ManagedArtifactStorageAdapter(
          managedRoot:
              Directory(p.join(supportDirectory.path, 'library_files')),
        ),
        generationPort: ParsedArtifactGenerationRouter(
          deterministicGeneration: DeterministicParsedArtifactGenerationAdapter(
            managedFileStorage: managedFileStorage,
          ),
          ocrGeneration: OcrParsedArtifactGenerationAdapter(
            managedFileStorage: managedFileStorage,
            ocrClient: const ZhipuOcrClient(),
            activeOcrProfileLoader: engineRepository.getActiveOcrEngine,
          ),
        ),
      );
      final u1WorkspaceFacade = U1WorkspaceFacade(
        projectService: projectService,
        fileRepository: libraryFileRepository,
        fileIngestion: fileIngestionService,
        folderService: folderService,
        studyQueryService: studyQueryService,
        parsedArtifactLifecycle: parsedArtifactLifecycle,
        mcpProjection: McpWorkspaceProjection(
          state: McpCapabilityState.configuredAvailable,
          transport: McpTransport.localStdio,
          permission: McpPermission.readOnly,
          toolNames: StudyMcpAdapter.toolNames,
        ),
      );
      final retrievalService = RetrievalService(
        scopeResolver: ApplicationRetrievalScopeResolver(
          projectRepository: projectRepository,
          conversationService: conversationService,
        ),
        artifactSource: ParsedArtifactRetrievalSource(
          lifecycle: parsedArtifactLifecycle,
          metadata: parsedArtifactRepository,
        ),
        index: SqliteRetrievalIndexRepository(databaseHelper: databaseHelper),
        chunker: const DeterministicSourceChunker(),
      );
      final agentRuntime = ShirohaAgentRuntime(
        conversationService: conversationService,
        configResolver: AgentRuntimeConfigResolver(
          configStore: agentConfigStore,
          profileResolver: agentProfileRepository,
        ),
        providerFactory: (resolved) => DeepSeekResponsesProvider(
          profile: resolved.profile,
          clientFactory: () => http.Client(),
        ),
        toolDispatcher: AgentStudyToolDispatcher(service: studyQueryService),
        proposalDispatcher: AgentWriteProposalToolDispatcher(
          persistence: agentWritePersistence,
          proposalService: agentWriteProposalService,
        ),
        studyPlanDispatcher: AgentStudyPlanToolDispatcher(
          draftService: studyPlanDraftService,
        ),
        retrievalDispatcher: AgentRetrievalToolDispatcher(
          retrieval: retrievalService,
        ),
      );
      final taskManager = TaskManager.instance;
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
        parser: importPipelineService.parseFiles,
        requestScheduler: ocrRequestScheduler,
        onReadyForReview: (sourceDescription) {
          rootScaffoldMessengerKey.currentState?.showSnackBar(SnackBar(
            content: Text('$sourceDescription 解析完成，请前往传输中心校对入库'),
            backgroundColor: Colors.orange,
          ));
        },
      );

      final savedTheme = await SettingsRepository.instance.getAppTheme();
      if (savedTheme.isNotEmpty) {
        globalThemeNotifier.value = savedTheme;
      }

      // 初始化 flutter_tex MathJax 渲染服务
      // Windows/Linux/macOS 桌面端的 webview_flutter 无完整实现，跳过
      if (Platform.isAndroid || Platform.isIOS) {
        await TeXRenderingServer.start();
      }

      AppLogger.info('Application started', module: 'Application');
      runApp(ShirohaQuizApp(
        engineRepository: engineRepository,
        aiService: aiService,
        importPipelineService: importPipelineService,
        importTaskCoordinator: importTaskCoordinator,
        answerGenerationService: answerGenerationService,
        answerCommitCommand: answerCommitCommand,
        examMutationCommand: examMutationCommand,
        u1WorkspaceFacade: u1WorkspaceFacade,
        conversationService: conversationService,
        agentSettingsService: agentSettingsService,
        startAgentTurn: agentRuntime.startTurn,
        startRetrievalTurn: agentRuntime.startTurnWithRetrieval,
        proposalService: agentWriteProposalService,
        studyPlanDraftService: studyPlanDraftService,
        studyPlanCommandService: studyPlanCommandService,
        studyPlanSelectionService: studyPlanSelectionService,
        studyPlanSessionLauncher: studyPlanSessionLauncher,
        backupRestore: backupRestore,
        onRestoreCompleted: () {},
      ));
    }

    relaunchApp = composeAndRun;
    await composeAndRun();
  }, (error, stackTrace) {
    AppLogger.error(
      'Unhandled root-zone error',
      module: 'Application',
      error: error,
      stackTrace: stackTrace,
    );
    Error.throwWithStackTrace(error, stackTrace);
  });
}

class ShirohaQuizApp extends StatelessWidget {
  const ShirohaQuizApp({
    super.key,
    required this.engineRepository,
    required this.aiService,
    required this.importPipelineService,
    required this.importTaskCoordinator,
    required this.answerGenerationService,
    required this.answerCommitCommand,
    required this.examMutationCommand,
    required this.u1WorkspaceFacade,
    required this.conversationService,
    required this.agentSettingsService,
    required this.startAgentTurn,
    this.startRetrievalTurn,
    this.proposalService,
    this.studyPlanDraftService,
    this.studyPlanCommandService,
    this.studyPlanSelectionService,
    this.studyPlanSessionLauncher,
    this.backupRestore,
    this.onRestoreCompleted,
  });

  final AiEngineRepository engineRepository;
  final AiService aiService;
  final ImportPipelineService importPipelineService;
  final ImportTaskCoordinator importTaskCoordinator;

  /// P7 Application seams for the AI answer review UI.
  final AiAnswerGenerationService answerGenerationService;
  final AiAnswerCommitCommand answerCommitCommand;
  final ExamMutationCommand examMutationCommand;
  final U1WorkspaceFacade u1WorkspaceFacade;
  final ConversationService conversationService;
  final AgentSettingsService agentSettingsService;
  final AgentTurnStarter startAgentTurn;
  final AgentRetrievalTurnStarter? startRetrievalTurn;
  final AgentWriteProposalService? proposalService;
  final StudyPlanDraftService? studyPlanDraftService;
  final StudyPlanCommandService? studyPlanCommandService;

  /// SPL-1-U0 focused seams (selection + Practice materialization adapter).
  final StudyPlanSelectionService? studyPlanSelectionService;
  final StudyPlanPracticeSessionLauncher? studyPlanSessionLauncher;
  final BackupRestoreCoordinator? backupRestore;
  final VoidCallback? onRestoreCompleted;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: globalThemeNotifier,
      builder: (context, themeName, _) {
        return AiDependenciesScope(
          engineRepository: engineRepository,
          aiService: aiService,
          importPipelineService: importPipelineService,
          importTaskCoordinator: importTaskCoordinator,
          answerGenerationService: answerGenerationService,
          answerCommitCommand: answerCommitCommand,
          examMutationCommand: examMutationCommand,
          child: MaterialApp(
            title: 'Shiroha Quiz',
            navigatorKey: globalNavigatorKey, // 核心新增：挂载全局路由引擎
            scaffoldMessengerKey: rootScaffoldMessengerKey, // 挂载全局钥匙
            debugShowCheckedModeBanner: false,
            theme: AppTheme.getTheme(themeName),
            home: MainScreen(
              u1WorkspaceFacade: u1WorkspaceFacade,
              conversationService: conversationService,
              agentSettingsService: agentSettingsService,
              startAgentTurn: startAgentTurn,
              startRetrievalTurn: startRetrievalTurn,
              proposalService: proposalService,
              studyPlanDraftService: studyPlanDraftService,
              studyPlanCommandService: studyPlanCommandService,
              studyPlanSelectionService: studyPlanSelectionService,
              studyPlanSessionLauncher: studyPlanSessionLauncher,
              backupRestore: backupRestore,
              onRestoreCompleted: onRestoreCompleted,
            ),
          ),
        );
      },
    );
  }
}

/// Displays the app logo / name while the database is initialised
/// in the background. On success, replaces itself with [HomePage].
/// On failure, shows an error with a retry button.
class SplashScreen extends StatefulWidget {
  const SplashScreen({
    super.key,
    required this.u1WorkspaceFacade,
    required this.conversationService,
    required this.agentSettingsService,
    required this.startAgentTurn,
    this.proposalService,
    this.studyPlanDraftService,
    this.studyPlanCommandService,
    this.studyPlanSelectionService,
    this.studyPlanSessionLauncher,
  });

  final U1WorkspaceFacade u1WorkspaceFacade;
  final ConversationService conversationService;
  final AgentSettingsService agentSettingsService;
  final AgentTurnStarter startAgentTurn;
  final AgentWriteProposalService? proposalService;
  final StudyPlanDraftService? studyPlanDraftService;
  final StudyPlanCommandService? studyPlanCommandService;
  final StudyPlanSelectionService? studyPlanSelectionService;
  final StudyPlanPracticeSessionLauncher? studyPlanSessionLauncher;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    try {
      // Offload the heavy I/O to the database isolate.
      await DatabaseHelper.instance.database;
      if (!mounted) return;
      _navigateToHome();
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.toString());
    }
  }

  void _navigateToHome() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => MainScreen(
          u1WorkspaceFacade: widget.u1WorkspaceFacade,
          conversationService: widget.conversationService,
          agentSettingsService: widget.agentSettingsService,
          startAgentTurn: widget.startAgentTurn,
          proposalService: widget.proposalService,
          studyPlanDraftService: widget.studyPlanDraftService,
          studyPlanCommandService: widget.studyPlanCommandService,
          studyPlanSelectionService: widget.studyPlanSelectionService,
          studyPlanSessionLauncher: widget.studyPlanSessionLauncher,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colors.surface,
      body: Center(
        child: _errorMessage != null ? _buildError(colors) : _buildLoading(),
      ),
    );
  }

  Widget _buildLoading() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.school,
            size: 64, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 24),
        Text(
          'Shiroha Quiz',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 24),
        const CircularProgressIndicator(),
        const SizedBox(height: 12),
        Text(
          '正在准备题库...',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }

  Widget _buildError(ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 48, color: colors.error),
          const SizedBox(height: 16),
          Text(
            '初始化失败',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: colors.error,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            _errorMessage!,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () {
              setState(() => _errorMessage = null);
              _initApp();
            },
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
