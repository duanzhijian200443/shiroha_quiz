import 'package:flutter/material.dart';
import '../../application/agent/agent_config_service.dart';
import '../../application/backup/backup_restore_coordinator.dart';
import '../../application/agent/agent_turn.dart';
import '../../application/conversations/conversation_service.dart';
import '../../application/safe_write/agent_write_proposal_service.dart';
import '../../application/study_plan/study_plan_command_service.dart';
import '../../application/study_plan/study_plan_draft_service.dart';
import '../../application/study_plan/study_plan_selection_service.dart';
import '../../application/u1_workspace/u1_workspace_facade.dart';
import '../../application/questions/folder_query_port.dart';
import '../../application/questions/question_bank_mutation_command.dart';
import '../../application/questions/question_list_query_port.dart';
import '../../application/questions/question_mutation_command.dart';
import '../../application/safe_write/typed_answer_command.dart';
import '../../services/study_plan/study_plan_practice_session_launcher.dart';
import 'home_page.dart';
import 'profile_screen.dart';
import '../dependencies/ai_dependencies_scope.dart';
import '../assistant/assistant_workspace_shell.dart';
import '../assistant/assistant_screen.dart';
import '../assistant/workspace_controller.dart';
import '../assistant/workspace_pages.dart';
import '../../services/import_review/import_commit_service.dart';
import '../theme/app_theme.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({
    super.key,
    required this.u1WorkspaceFacade,
    required this.conversationService,
    required this.agentSettingsService,
    required this.startAgentTurn,
    this.questionListQuery,
    this.questionMutationPersistence,
    this.typedAnswerPersistence,
    this.questionBankMutationPersistence,
    this.folderQuery,
    this.importCommitService,
    this.startRetrievalTurn,
    this.proposalService,
    this.studyPlanDraftService,
    this.studyPlanCommandService,
    this.studyPlanSelectionService,
    this.studyPlanSessionLauncher,
    this.backupRestore,
    this.onRestoreCompleted,
  });

  final U1WorkspaceFacade u1WorkspaceFacade;
  final ConversationService conversationService;
  final AgentSettingsService agentSettingsService;
  final AgentTurnStarter startAgentTurn;
  final QuestionListQueryPort? questionListQuery;
  final QuestionMutationPersistencePort? questionMutationPersistence;
  final TypedAnswerPersistencePort? typedAnswerPersistence;
  final QuestionBankMutationPersistencePort? questionBankMutationPersistence;
  final FolderQueryPort? folderQuery;
  final ImportCommitService? importCommitService;
  final AgentRetrievalTurnStarter? startRetrievalTurn;
  final AgentWriteProposalService? proposalService;
  final StudyPlanDraftService? studyPlanDraftService;
  final StudyPlanCommandService? studyPlanCommandService;
  final StudyPlanSelectionService? studyPlanSelectionService;
  final StudyPlanPracticeSessionLauncher? studyPlanSessionLauncher;
  final BackupRestoreCoordinator? backupRestore;
  final VoidCallback? onRestoreCompleted;
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final GlobalKey<ScaffoldState> _mainScaffoldKey = GlobalKey<ScaffoldState>();
  int _currentIndex = 0;
  int _assistantPrefillEpoch = 0;
  String? _assistantPrefillText;
  Object? _assistantDrawerOwner;
  WidgetBuilder? _assistantDrawerBuilder;

  /// Today-activation signal (SPL-1-U0): incremented whenever bottom
  /// navigation transitions INTO Today. HomePage observes it and refreshes
  /// the live focused state when still in 特训 mode; HomePage itself is
  /// never recreated (ordinary-mode state stays preserved).
  int _todayActivationEpoch = 0;

  void _handleNavigation(int index) {
    if (index != 1) {
      _mainScaffoldKey.currentState?.closeDrawer();
    }
    setState(() {
      if (index == 0 && _currentIndex != 0) {
        _todayActivationEpoch++;
      }
      _currentIndex = index;
    });
  }

  void _openFileLibrary() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            _ProfileFileLibraryRoute(facade: widget.u1WorkspaceFacade),
      ),
    );
  }

  void _openAssistantWithContext(String text) {
    setState(() {
      _assistantPrefillEpoch++;
      _assistantPrefillText = text;
      _currentIndex = 1;
    });
  }

  void _consumeAssistantPrefill(int epoch) {
    if (!mounted ||
        epoch != _assistantPrefillEpoch ||
        _assistantPrefillText == null) {
      return;
    }
    setState(() => _assistantPrefillText = null);
  }

  void _registerAssistantDrawer(Object owner, WidgetBuilder drawerBuilder) {
    if (!mounted ||
        (identical(owner, _assistantDrawerOwner) &&
            drawerBuilder == _assistantDrawerBuilder)) {
      return;
    }
    setState(() {
      _assistantDrawerOwner = owner;
      _assistantDrawerBuilder = drawerBuilder;
    });
  }

  void _unregisterAssistantDrawer(Object owner) {
    if (!mounted || !identical(owner, _assistantDrawerOwner)) return;
    setState(() {
      _assistantDrawerOwner = null;
      _assistantDrawerBuilder = null;
    });
  }

  void _openAssistantDrawer() {
    if (_currentIndex != 1) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _currentIndex != 1) return;
      _mainScaffoldKey.currentState?.openDrawer();
    });
  }

  @override
  Widget build(BuildContext context) {
    final dependencies = AiDependenciesScope.of(context);
    final pages = <Widget>[
      HomePage(
        questionListQuery: widget.questionListQuery,
        questionMutationPersistence: widget.questionMutationPersistence,
        typedAnswerPersistence: widget.typedAnswerPersistence,
        questionBankMutationPersistence: widget.questionBankMutationPersistence,
        folderQuery: widget.folderQuery,
        importCommitService: widget.importCommitService,
        studyPlanSelectionService: widget.studyPlanSelectionService,
        studyPlanCommandService: widget.studyPlanCommandService,
        studyPlanSessionLauncher: widget.studyPlanSessionLauncher,
        todayActivationEpoch: _todayActivationEpoch,
        onAskAssistant: _openAssistantWithContext,
      ), // Tab 0 — 今日 (Today: 普通 / 特训 / 考试)
      AssistantComposerPrefillScope(
        request: _assistantPrefillText == null
            ? null
            : AssistantComposerPrefillRequest(
                epoch: _assistantPrefillEpoch,
                text: _assistantPrefillText!,
              ),
        onConsumed: _consumeAssistantPrefill,
        child: AssistantWorkspaceShell(
          facade: widget.u1WorkspaceFacade,
          conversationService: widget.conversationService,
          agentSettingsService: widget.agentSettingsService,
          startAgentTurn: widget.startAgentTurn,
          startRetrievalTurn: widget.startRetrievalTurn,
          proposalService: widget.proposalService,
          studyPlanDraftService: widget.studyPlanDraftService,
          studyPlanCommandService: widget.studyPlanCommandService,
          conversationFocusEpoch: _assistantPrefillEpoch,
        ),
      ), // Tab 1 — 助手
      ProfileScreen(
        engineRepository: dependencies.engineRepository,
        agentSettingsService: widget.agentSettingsService,
        backupRestore: widget.backupRestore,
        onRestoreCompleted: widget.onRestoreCompleted,
        onOpenFileLibrary: _openFileLibrary,
      ), // Tab 2 — 我的
    ];
    final theme = Theme.of(context);
    final selectedNavigationColor = theme.brightness == Brightness.light
        ? AppTheme.shirohaCyanForeground
        : theme.colorScheme.primary;
    final assistantDrawerEnabled = _currentIndex == 1 &&
        MediaQuery.sizeOf(context).width < 900 &&
        _assistantDrawerBuilder != null;
    return AssistantGlobalDrawerScope(
      registerDrawer: _registerAssistantDrawer,
      unregisterDrawer: _unregisterAssistantDrawer,
      openDrawer: _openAssistantDrawer,
      child: Scaffold(
        key: _mainScaffoldKey,
        drawer: assistantDrawerEnabled
            ? _assistantDrawerBuilder!.call(context)
            : null,
        drawerEnableOpenDragGesture: assistantDrawerEnabled,
        body: IndexedStack(index: _currentIndex, children: pages),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: _handleNavigation,
          type: BottomNavigationBarType.fixed,
          selectedItemColor: selectedNavigationColor,
          unselectedItemColor: theme.colorScheme.onSurfaceVariant,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.psychology_outlined),
              activeIcon: _SelectedNavigationIcon(
                icon: Icons.psychology_outlined,
                itemKey: ValueKey<String>('main-nav-selected-home'),
              ),
              label: '今日',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.auto_awesome_outlined),
              activeIcon: _SelectedNavigationIcon(
                icon: Icons.auto_awesome_outlined,
                itemKey: ValueKey<String>('main-nav-selected-assistant'),
              ),
              label: '助手',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.school_outlined),
              activeIcon: _SelectedNavigationIcon(
                icon: Icons.school_outlined,
                itemKey: ValueKey<String>('main-nav-selected-profile'),
              ),
              label: '我的',
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectedNavigationIcon extends StatelessWidget {
  const _SelectedNavigationIcon({required this.icon, required this.itemKey});

  final IconData icon;
  final Key itemKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      key: itemKey,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: isDark
            ? theme.colorScheme.primary.withValues(alpha: 0.16)
            : theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        icon,
        color:
            isDark ? theme.colorScheme.primary : AppTheme.shirohaCyanForeground,
      ),
    );
  }
}

class _ProfileFileLibraryRoute extends StatefulWidget {
  const _ProfileFileLibraryRoute({required this.facade});

  final U1WorkspaceFacade facade;

  @override
  State<_ProfileFileLibraryRoute> createState() =>
      _ProfileFileLibraryRouteState();
}

class _ProfileFileLibraryRouteState extends State<_ProfileFileLibraryRoute> {
  late final FileLibraryController _controller;

  @override
  void initState() {
    super.initState();
    _controller = FileLibraryController(widget.facade)..load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FileLibraryWorkspace(controller: _controller);
  }
}
