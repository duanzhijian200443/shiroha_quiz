import 'package:flutter/material.dart';

import '../../application/agent/agent_config_service.dart';
import '../../application/agent/agent_turn.dart';
import '../../application/conversations/conversation_service.dart';
import '../../application/safe_write/agent_write_proposal_service.dart';
import '../../application/study_plan/study_plan_command_service.dart';
import '../../application/study_plan/study_plan_draft_service.dart';
import '../../application/u1_workspace/u1_workspace_facade.dart';
import 'assistant_screen.dart';
import 'conversation_controller.dart';
import 'global_sidebar.dart';
import 'learning_spaces_screen.dart';
import 'workspace_controller.dart';
import 'workspace_pages.dart';

enum _WorkspaceDestination {
  conversation,
  fileLibrary,
  learningSpaces,
  learningSpaceHome,
  mcp,
}

class AssistantWorkspaceShell extends StatefulWidget {
  const AssistantWorkspaceShell({
    super.key,
    required this.facade,
    required this.conversationService,
    required this.agentSettingsService,
    required this.startAgentTurn,
    this.startRetrievalTurn,
    this.proposalService,
    this.studyPlanDraftService,
    this.studyPlanCommandService,
  });

  final U1WorkspaceFacade facade;
  final ConversationService conversationService;
  final AgentSettingsService agentSettingsService;
  final AgentTurnStarter startAgentTurn;
  final AgentRetrievalTurnStarter? startRetrievalTurn;
  final AgentWriteProposalService? proposalService;
  final StudyPlanDraftService? studyPlanDraftService;
  final StudyPlanCommandService? studyPlanCommandService;

  @override
  State<AssistantWorkspaceShell> createState() =>
      _AssistantWorkspaceShellState();
}

class _AssistantWorkspaceShellState extends State<AssistantWorkspaceShell> {
  late final LearningSpacesController _spacesController;
  late final FileLibraryController _fileController;
  late final ConversationController _conversationController;
  _WorkspaceDestination _destination = _WorkspaceDestination.conversation;
  String? _projectId;

  @override
  void initState() {
    super.initState();
    _conversationController = ConversationController(
      widget.conversationService,
      agentSettingsService: widget.agentSettingsService,
      startAgentTurn: widget.startAgentTurn,
      startRetrievalTurn: widget.startRetrievalTurn,
      proposalService: widget.proposalService,
      studyPlanDraftService: widget.studyPlanDraftService,
      studyPlanCommandService: widget.studyPlanCommandService,
    )..load();
    _spacesController = LearningSpacesController(
      widget.facade,
      deleteGuard: _learningSpaceDeleteBlockReason,
    )
      ..addListener(_handleSpacesChanged)
      ..load();
    _fileController = FileLibraryController(widget.facade)..load();
  }

  @override
  void dispose() {
    _spacesController.removeListener(_handleSpacesChanged);
    _spacesController.dispose();
    _fileController.dispose();
    _conversationController.dispose();
    super.dispose();
  }

  String? _learningSpaceDeleteBlockReason(String projectId) {
    final activeProjectId =
        _conversationController.activeThread?.conversation.scope.projectId;
    if (activeProjectId != projectId) return null;
    if (_conversationController.hasActiveTurn ||
        _conversationController.isSending) {
      return '请先停止当前生成';
    }
    if (_conversationController.isMovingConversation) {
      return '请等待对话移动完成';
    }
    return null;
  }

  void _handleSpacesChanged() {
    if (!mounted || _spacesController.isLoading) return;
    final projectId = _projectId;
    if (_destination != _WorkspaceDestination.learningSpaceHome ||
        projectId == null ||
        _spacesController.spaces.any((space) => space.projectId == projectId)) {
      return;
    }
    setState(() {
      _projectId = null;
      _destination = _WorkspaceDestination.learningSpaces;
    });
  }

  void _feedback(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openSpaceHome(String projectId) async {
    await _spacesController.select(projectId);
    if (!mounted) return;
    setState(() {
      _projectId = projectId;
      _destination = _WorkspaceDestination.learningSpaceHome;
    });
  }

  Future<void> _openConversation(String conversationId) async {
    await _conversationController.openConversation(conversationId);
    if (!mounted || _conversationController.activeThread == null) return;
    setState(() => _destination = _WorkspaceDestination.conversation);
  }

  Future<void> _createSpace() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建学习空间'),
        content: TextField(
          key: const ValueKey<String>('u1-create-space-name'),
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '学习空间名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    final created = await _spacesController.create(name);
    if (created != null && mounted) await _openSpaceHome(created.projectId);
  }

  Widget _buildWorkspace() {
    return switch (_destination) {
      _WorkspaceDestination.conversation => Column(
          children: [
            Expanded(
              child: AssistantScreen(
                spacesController: _spacesController,
                fileController: _fileController,
                conversationController: _conversationController,
                showGlobalMenu: false,
              ),
            ),
          ],
        ),
      _WorkspaceDestination.fileLibrary => FileLibraryWorkspace(
          controller: _fileController,
        ),
      _WorkspaceDestination.learningSpaces => LearningSpacesScreen(
          controller: _spacesController,
          fileController: _fileController,
          onOpenProject: _openSpaceHome,
          onCreateProject: _createSpace,
        ),
      _WorkspaceDestination.learningSpaceHome => _projectId != null &&
              _spacesController.spaces
                  .any((space) => space.projectId == _projectId)
          ? LearningSpaceHomeWorkspace(
              controller: _spacesController,
              fileController: _fileController,
              projectId: _projectId!,
              onDeleted: () => setState(() {
                _projectId = null;
                _destination = _WorkspaceDestination.learningSpaces;
                _conversationController.load();
              }),
            )
          : LearningSpacesScreen(
              controller: _spacesController,
              fileController: _fileController,
              onOpenProject: _openSpaceHome,
              onCreateProject: _createSpace,
            ),
      _WorkspaceDestination.mcp => McpWorkspace(
          projection: _spacesController.mcpProjection,
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 900) {
          return AssistantScreen(
            spacesController: _spacesController,
            fileController: _fileController,
            conversationController: _conversationController,
          );
        }
        return Scaffold(
          key: const ValueKey<String>('u1-ux01-workspace-shell'),
          body: Row(
            children: [
              SizedBox(
                width: 300,
                child: GlobalSidebar(
                  controller: _spacesController,
                  conversationController: _conversationController,
                  onNewConversation: () => setState(() {
                    _conversationController.startNew();
                    _destination = _WorkspaceDestination.conversation;
                  }),
                  onOpenFileLibrary: () => setState(
                    () => _destination = _WorkspaceDestination.fileLibrary,
                  ),
                  onOpenLearningSpaces: () => setState(
                    () => _destination = _WorkspaceDestination.learningSpaces,
                  ),
                  onOpenMcp: () => setState(
                    () => _destination = _WorkspaceDestination.mcp,
                  ),
                  onOpenConversation: _openConversation,
                  onOpenSpaceHome: _openSpaceHome,
                  onCreateSpace: _createSpace,
                  onFeedback: _feedback,
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: AnimatedBuilder(
                  animation: _spacesController,
                  builder: (context, _) => _buildWorkspace(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
