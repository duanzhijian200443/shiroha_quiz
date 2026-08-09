import 'package:flutter/material.dart';

import '../../application/u1_workspace/u1_workspace_facade.dart';
import 'assistant_screen.dart';
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
  const AssistantWorkspaceShell({super.key, required this.facade});

  final U1WorkspaceFacade facade;

  @override
  State<AssistantWorkspaceShell> createState() =>
      _AssistantWorkspaceShellState();
}

class _AssistantWorkspaceShellState extends State<AssistantWorkspaceShell> {
  late final LearningSpacesController _spacesController;
  late final FileLibraryController _fileController;
  _WorkspaceDestination _destination = _WorkspaceDestination.conversation;
  String? _conversationTitle;
  String? _projectId;

  @override
  void initState() {
    super.initState();
    _spacesController = LearningSpacesController(widget.facade)..load();
    _fileController = FileLibraryController(widget.facade)..load();
  }

  @override
  void dispose() {
    _spacesController.dispose();
    _fileController.dispose();
    super.dispose();
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
            if (_conversationTitle case final title?)
              Container(
                key: const ValueKey<String>('u1-ux01-conversation-banner'),
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                color: Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withValues(alpha: 0.55),
                child: Text('对话预览 · $title'),
              ),
            Expanded(
              child: AssistantScreen(
                spacesController: _spacesController,
                fileController: _fileController,
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
      _WorkspaceDestination.learningSpaceHome => LearningSpaceHomeWorkspace(
          controller: _spacesController,
          fileController: _fileController,
          projectId: _projectId!,
          onDeleted: () => setState(() {
            _projectId = null;
            _destination = _WorkspaceDestination.learningSpaces;
          }),
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
                  onNewConversation: () => setState(() {
                    _conversationTitle = null;
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
                  onOpenConversation: (title) => setState(() {
                    _conversationTitle = title;
                    _destination = _WorkspaceDestination.conversation;
                  }),
                  onOpenSpaceHome: _openSpaceHome,
                  onCreateSpace: _createSpace,
                  onFeedback: _feedback,
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: _buildWorkspace()),
            ],
          ),
        );
      },
    );
  }
}
