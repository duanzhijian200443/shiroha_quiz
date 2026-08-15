import 'package:flutter/material.dart';

import '../../application/conversations/conversation_repository.dart';
import '../../application/safe_write/agent_write_proposal.dart';
import '../../domain/study_plan/study_plan_values.dart';
import '../../domain/conversations/conversation.dart';
import '../../domain/conversations/conversation_message.dart';
import 'assistant_content_renderer.dart';
import 'conversation_controller.dart';
import 'global_sidebar.dart';
import 'learning_spaces_screen.dart';
import 'workspace_controller.dart';
import 'workspace_pages.dart';

/// Shiroha conversation presentation backed by the C0 application boundary.
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({
    super.key,
    required this.spacesController,
    required this.fileController,
    required this.conversationController,
    this.showGlobalMenu = true,
  });

  final LearningSpacesController spacesController;
  final FileLibraryController fileController;
  final ConversationController conversationController;
  final bool showGlobalMenu;

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  static const double _nearBottomThreshold = 120;

  final TextEditingController _composerController = TextEditingController();
  final ScrollController _messageScrollController = ScrollController();
  bool _followLatest = true;
  bool _scrollScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.conversationController.addListener(_handleConversationChanged);
    _scheduleScrollToLatest();
  }

  @override
  void didUpdateWidget(covariant AssistantScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationController == widget.conversationController) {
      return;
    }
    oldWidget.conversationController.removeListener(
      _handleConversationChanged,
    );
    widget.conversationController.addListener(_handleConversationChanged);
    _followLatest = true;
    _scheduleScrollToLatest();
  }

  String get _currentSpace {
    final scope = widget.conversationController.currentScope;
    if (scope.kind == ConversationScopeKind.global) return '全局对话';
    final projectId = scope.projectId;
    if (projectId == null) return '原学习空间已删除';
    for (final space in widget.spacesController.spaces) {
      if (space.projectId == projectId) return space.displayName;
    }
    return '学习空间不可用';
  }

  @override
  void dispose() {
    widget.conversationController.removeListener(_handleConversationChanged);
    _messageScrollController.dispose();
    _composerController.dispose();
    super.dispose();
  }

  void _handleConversationChanged() {
    if (_followLatest) _scheduleScrollToLatest();
  }

  bool _handleUserScroll(UserScrollNotification notification) {
    _followLatest = notification.metrics.extentAfter <= _nearBottomThreshold;
    return false;
  }

  void _scheduleScrollToLatest({bool force = false}) {
    if (force) _followLatest = true;
    if (_scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!mounted || !_followLatest || !_messageScrollController.hasClients) {
        return;
      }
      final position = _messageScrollController.position;
      if (position.pixels == position.maxScrollExtent) return;
      position.jumpTo(position.maxScrollExtent);
    });
  }

  void _feedback(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _startNewConversation() {
    if (widget.showGlobalMenu) Navigator.maybePop(context);
    widget.conversationController.startNew();
    _composerController.clear();
  }

  Future<void> _openConversation(String conversationId) async {
    if (widget.showGlobalMenu) Navigator.pop(context);
    _followLatest = true;
    await widget.conversationController.openConversation(conversationId);
    _scheduleScrollToLatest();
  }

  void _drawerFeedback(String message) {
    Navigator.pop(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _feedback(message);
    });
  }

  void _pushFromDrawer(Widget page) {
    Navigator.pop(context);
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  Future<void> _showContextPicker() async {
    final refreshed =
        await widget.conversationController.refreshAttachableFiles();
    if (!mounted) return;
    if (!refreshed) {
      _feedback(
        widget.conversationController.errorMessage ?? conversationReadSafeError,
      );
      return;
    }
    final fileId = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _FileContextPicker(
        controller: widget.conversationController,
      ),
    );
    if (!mounted || fileId == null) return;
    await widget.conversationController.toggleFile(fileId);
  }

  Future<void> _showDraftSpacePicker() async {
    final currentProjectId = widget.conversationController.draftScope.projectId;
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('选择对话范围'),
                titleTextStyle: Theme.of(sheetContext)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              ListTile(
                leading: const Icon(Icons.public_rounded),
                title: const Text('全局对话'),
                trailing: currentProjectId == null
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(sheetContext, ''),
              ),
              if (widget.spacesController.spaces.isEmpty)
                const ListTile(title: Text('暂无学习空间')),
              for (final space in widget.spacesController.spaces)
                ListTile(
                  leading: const Icon(Icons.space_dashboard_outlined),
                  title: Text(space.displayName),
                  trailing: currentProjectId == space.projectId
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () => Navigator.pop(sheetContext, space.projectId),
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.grid_view_rounded),
                title: const Text('查看全部学习空间'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => LearningSpacesScreen(
                        controller: widget.spacesController,
                        fileController: widget.fileController,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || selected == null) return;
    widget.conversationController.selectDraftScope(
      selected.isEmpty
          ? ConversationScope.global()
          : ConversationScope.learningSpace(selected),
    );
  }

  Future<void> _showMoveSpacePicker() async {
    final controller = widget.conversationController;
    if (controller.hasActiveTurn || controller.isSending) {
      _feedback('请先停止当前生成');
      return;
    }
    if (controller.proposalActionPending ||
        controller.studyPlanActionPending ||
        controller.isMovingConversation) {
      return;
    }

    final currentScope = controller.currentScope;
    final currentProjectId = currentScope.projectId;
    final isUnavailable = currentScope.isUnavailableLearningSpace;

    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('移动对话'),
                titleTextStyle: Theme.of(sheetContext)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
                subtitle: isUnavailable ? const Text('原学习空间已删除') : null,
              ),
              ListTile(
                leading: const Icon(Icons.public_rounded),
                title: const Text('全局对话'),
                trailing: currentScope.kind == ConversationScopeKind.global
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(sheetContext, ''),
              ),
              if (widget.spacesController.spaces.isEmpty)
                const ListTile(title: Text('暂无学习空间')),
              for (final space in widget.spacesController.spaces)
                ListTile(
                  leading: const Icon(Icons.space_dashboard_outlined),
                  title: Text(space.displayName),
                  trailing: currentProjectId == space.projectId
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () => Navigator.pop(sheetContext, space.projectId),
                ),
            ],
          ),
        ),
      ),
    );

    if (!mounted || selected == null) return;

    final targetScope = selected.isEmpty
        ? ConversationScope.global()
        : ConversationScope.learningSpace(selected);

    if (targetScope == currentScope) {
      return;
    }

    final targetName = selected.isEmpty
        ? '全局对话'
        : widget.spacesController.spaces
                .where((s) => s.projectId == selected)
                .map((s) => s.displayName)
                .firstOrNull ??
            '学习空间';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey<String>('conv-move-confirmation-dialog'),
        title: const Text('移动对话？'),
        content: Text(
          '将此对话移动到「$targetName」。\n\n'
          '历史消息和已附加文件不会改变。\n'
          '之后 Shiroha 的回复和本地检索将使用新的对话范围。',
        ),
        actions: [
          TextButton(
            key: const ValueKey<String>('conv-move-dialog-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey<String>('conv-move-dialog-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('移动'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final success = await controller.moveActiveConversation(targetScope);
    if (success && mounted) {
      _feedback('已移动到「$targetName」');
    }
  }

  Future<void> _showSpacePicker() async {
    if (widget.conversationController.isDraft) {
      await _showDraftSpacePicker();
    } else {
      await _showMoveSpacePicker();
    }
  }

  Future<void> _createSpace() async {
    final input = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建学习空间'),
        content: TextField(controller: input, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    input.dispose();
    if (name == null || name.isEmpty) return;
    final created = await widget.spacesController.create(name);
    if (created != null && mounted && widget.conversationController.isDraft) {
      widget.conversationController.selectDraftScope(
        ConversationScope.learningSpace(created.projectId),
      );
    }
  }

  Future<void> _openSpaceHome(String projectId) async {
    await widget.spacesController.select(projectId);
    if (!mounted) return;
    _pushFromDrawer(
      LearningSpaceHomeWorkspace(
        controller: widget.spacesController,
        fileController: widget.fileController,
        projectId: projectId,
        onDeleted: () {
          widget.conversationController.refreshAfterProjectDeleted(projectId);
          Navigator.maybePop(context);
        },
      ),
    );
  }

  Future<void> _sendMessage() async {
    final content = _composerController.text;
    if (content.trim().isEmpty) {
      _feedback('先写下你想问 Shiroha 的问题');
      return;
    }
    final saved = await widget.conversationController.send(content);
    if (saved) {
      _composerController.clear();
      _scheduleScrollToLatest(force: true);
    }
  }

  Future<void> _deleteConversation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除对话？'),
        content: const Text('对话和消息将被删除；文件、学习空间和题库不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey<String>('c0-confirm-delete-conversation'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.conversationController.deleteActiveConversation();
      _composerController.clear();
    }
  }

  Drawer? _buildDrawer() {
    if (!widget.showGlobalMenu) return null;
    return Drawer(
      child: GlobalSidebar(
        controller: widget.spacesController,
        conversationController: widget.conversationController,
        onNewConversation: _startNewConversation,
        onOpenFileLibrary: () => _pushFromDrawer(
          FileLibraryWorkspace(controller: widget.fileController),
        ),
        onOpenLearningSpaces: () => _pushFromDrawer(
          LearningSpacesScreen(
            controller: widget.spacesController,
            fileController: widget.fileController,
          ),
        ),
        onOpenMcp: () => _pushFromDrawer(
          McpWorkspace(projection: widget.spacesController.mcpProjection),
        ),
        onOpenConversation: _openConversation,
        onOpenSpaceHome: _openSpaceHome,
        onCreateSpace: _createSpace,
        onFeedback: _drawerFeedback,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        widget.spacesController,
        widget.conversationController,
      ]),
      builder: (context, _) => _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final conversations = widget.conversationController;
    final active = conversations.activeThread;
    return Scaffold(
      key: const ValueKey<String>('u1-ux0-assistant-shell'),
      backgroundColor: theme.scaffoldBackgroundColor,
      drawer: _buildDrawer(),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        toolbarHeight: 76,
        leading: widget.showGlobalMenu
            ? Builder(
                builder: (drawerContext) => IconButton(
                  key: const ValueKey<String>('u1-ux0-open-drawer'),
                  tooltip: '打开菜单',
                  icon: const Icon(Icons.menu_rounded),
                  onPressed: () => Scaffold.of(drawerContext).openDrawer(),
                ),
              )
            : null,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Shiroha',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 3),
            InkWell(
              key: const ValueKey<String>('u1-ux0-space-selector'),
              borderRadius: BorderRadius.circular(20),
              onTap: _showSpacePicker,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _currentSpace,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 17,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (active != null)
            IconButton(
              key: const ValueKey<String>('c0-delete-conversation'),
              tooltip: '删除对话',
              onPressed: _deleteConversation,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          IconButton(
            key: const ValueKey<String>('u1-ux0-new-conversation'),
            tooltip: '新对话',
            onPressed:
                conversations.hasActiveTurn ? null : _startNewConversation,
            icon: const Icon(Icons.add_comment_outlined),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              children: [
                Expanded(child: _buildConversationContent(theme)),
                _Composer(
                  controller: _composerController,
                  selectedFiles: conversations.selectedFiles,
                  isSending: conversations.isSending,
                  hasActiveTurn: conversations.hasActiveTurn,
                  retrievalApproved: conversations.retrievalApprovedForNextTurn,
                  onRetrievalApprovalChanged:
                      conversations.setRetrievalApproval,
                  onAddContext: _showContextPicker,
                  onRemoveContext: (file) {
                    conversations.toggleFile(file.fileId);
                  },
                  onSend: _sendMessage,
                  onCancel: conversations.cancelActiveTurn,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConversationContent(ThemeData theme) {
    final controller = widget.conversationController;
    final active = controller.activeThread;
    final colors = theme.colorScheme;
    if (controller.isLoading && active == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return NotificationListener<UserScrollNotification>(
      onNotification: _handleUserScroll,
      child: ListView(
        key: const ValueKey<String>('u1-ux0-assistant-content'),
        controller: _messageScrollController,
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
        children: [
          Text(
            active?.conversation.title ?? '今天想学什么？',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            active == null ? '从一个问题开始，或试试下面的建议' : '消息历史已保存到本地',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          if (controller.currentScope.isUnavailableLearningSpace) ...[
            const SizedBox(height: 16),
            const _StatusCard(
              icon: Icons.warning_amber_rounded,
              message: '原学习空间已删除；历史仍可查看，但不能继续发送消息。',
            ),
          ],
          if (controller.errorMessage case final error?
              when controller.turnPhase != AssistantTurnPhase.failed &&
                  controller.turnPhase != AssistantTurnPhase.cancelled) ...[
            const SizedBox(height: 16),
            _StatusCard(icon: Icons.error_outline, message: error),
          ],
          if (active == null) ...[
            const SizedBox(height: 24),
            _PromptCard(
              icon: Icons.insights_outlined,
              text: '分析我最近的错题',
              onTap: () => _composerController.text = '分析我最近的错题',
            ),
            const SizedBox(height: 12),
            _PromptCard(
              icon: Icons.event_note_outlined,
              text: '帮我规划今天的复习',
              onTap: () => _composerController.text = '帮我规划今天的复习',
            ),
          ] else ...[
            if (active.hasMoreBefore) ...[
              const SizedBox(height: 20),
              Center(
                child: TextButton(
                  key: const ValueKey<String>('c0-load-older-messages'),
                  onPressed: controller.isLoadingOlder
                      ? null
                      : controller.loadOlderMessages,
                  child: Text(controller.isLoadingOlder ? '加载中…' : '加载更早消息'),
                ),
              ),
            ],
            const SizedBox(height: 20),
            for (final message in active.messages) ...[
              _MessageBubble(message: message),
              const SizedBox(height: 12),
            ],
          ],
          if (controller.transientAssistantText.isNotEmpty) ...[
            _TransientAssistantBubble(
              text: controller.transientAssistantText,
              isUnsaved: controller.turnPhase == AssistantTurnPhase.failed ||
                  controller.turnPhase == AssistantTurnPhase.cancelled,
            ),
            const SizedBox(height: 12),
          ],
          if (controller.hasProposalCard) ...[
            const SizedBox(height: 12),
            _ProposalCard(controller: controller),
          ],
          if (controller.hasStudyPlanCard) ...[
            const SizedBox(height: 12),
            _StudyPlanProposalCard(controller: controller),
          ],
          if (controller.turnStatusMessage case final status?) ...[
            _StatusCard(
              key: const ValueKey<String>('a0-agent-turn-status'),
              icon: _turnStatusIcon(controller.turnPhase),
              message: status,
            ),
            if (controller.turnPhase == AssistantTurnPhase.failed ||
                controller.turnPhase == AssistantTurnPhase.cancelled) ...[
              const SizedBox(height: 10),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (controller.canRetry)
                    FilledButton.icon(
                      key: const ValueKey<String>('a0-agent-retry'),
                      onPressed: controller.retryLastTurn,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重试'),
                    ),
                  if (controller.needsAgentSettings)
                    const Chip(
                      key: ValueKey<String>('a0-agent-settings-hint'),
                      avatar: Icon(Icons.settings_outlined, size: 18),
                      label: Text('请前往“我的 → Shiroha Agent 设置”'),
                    ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _PromptCard extends StatelessWidget {
  const _PromptCard({
    required this.icon,
    required this.text,
    required this.onTap,
  });

  final IconData icon;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      elevation: 1,
      shadowColor: colors.shadow.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(18),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        leading: Icon(icon, color: colors.primary),
        title: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
        trailing: const Icon(Icons.north_west_rounded, size: 18),
        onTap: onTap,
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ConversationMessage message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isUser = message.role == ConversationMessageRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        key: ValueKey<String>('c0-message-${message.messageId}'),
        constraints: const BoxConstraints(maxWidth: 600),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isUser ? colors.primaryContainer : colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(18),
        ),
        child: isUser
            ? Text(message.content)
            : AssistantContentRenderer(text: message.content),
      ),
    );
  }
}

class _TransientAssistantBubble extends StatelessWidget {
  const _TransientAssistantBubble({
    required this.text,
    required this.isUnsaved,
  });

  final String text;
  final bool isUnsaved;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: const ValueKey<String>('a0-transient-assistant'),
        constraints: const BoxConstraints(maxWidth: 600),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isUnsaved
                ? colors.error
                : colors.primary.withValues(alpha: 0.25),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AssistantContentRenderer(text: text),
            const SizedBox(height: 6),
            Text(
              isUnsaved ? '未保存' : '正在生成',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: isUnsaved ? colors.error : colors.primary,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    super.key,
    required this.icon,
    required this.message,
  });

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(icon, color: colors.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}

/// W0 proposal approval card rendered from the typed staged-event preview.
/// Approve submits only the proposal identity; Reject performs zero writes.
class _ProposalCard extends StatelessWidget {
  const _ProposalCard({required this.controller});

  final ConversationController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = controller.proposalPreview;
    final bankName = preview['bank_name'];
    final stem = _proposalNodesText(preview['stem']);
    final options = _proposalOptions(preview['options']);
    final answer = _proposalAnswerText(preview['proposed_answer']);
    final status = controller.proposalStatusText;
    final actionMessage = controller.proposalActionMessage;

    return Card(
      key: const ValueKey<String>('w0-proposal-card'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Agent \u63d0\u8bae\u8865\u5168\u7b54\u6848',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            if (bankName is String && bankName.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('\u9898\u5e93\uff1a$bankName'),
            ],
            if (stem.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(stem),
            ],
            for (final option in options) ...[
              const SizedBox(height: 4),
              Text('${option.$1}. ${option.$2}'),
            ],
            const SizedBox(height: 8),
            const Text('\u5f53\u524d\u7b54\u6848\uff1a\u672a\u586b\u5199'),
            const SizedBox(height: 4),
            Text('\u62df\u5199\u5165\u7b54\u6848\uff1a$answer'),
            const Divider(height: 16),
            Text(
              '\u53ea\u4fee\u6539\u7b54\u6848\uff0c\u590d\u4e60\u72b6\u6001'
              '\u4e0d\u53d8',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (status != null) ...[
              const SizedBox(height: 8),
              Text(
                status,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (actionMessage != null) ...[
              const SizedBox(height: 6),
              Text(
                actionMessage,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (controller.proposalOutcome ==
                AgentWriteProposalOutcome.pending) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  OutlinedButton(
                    key: const ValueKey<String>('w0-proposal-reject'),
                    onPressed: controller.canRejectProposal
                        ? controller.rejectProposal
                        : null,
                    child: const Text('\u62d2\u7edd'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey<String>('w0-proposal-approve'),
                    onPressed: controller.canApproveProposal
                        ? controller.approveProposal
                        : null,
                    child: const Text('\u6279\u51c6\u5e76\u5199\u5165'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Projects the structured tool-contract node list into bounded display
/// text. Unsupported nodes render as a fixed placeholder.
String _proposalNodesText(Object? rawNodes) {
  if (rawNodes is! List) return '';
  final buffer = StringBuffer();
  for (final item in rawNodes) {
    if (item is! Map) continue;
    switch (item['type']) {
      case 'text':
        final text = item['text'];
        if (text is String) buffer.write(text);
      case 'inline_math':
        final latex = item['latex'];
        if (latex is String) buffer.write('\\($latex\\)');
      case 'block_math':
        final latex = item['latex'];
        if (latex is String) buffer.write('\\[$latex\\]');
      default:
        buffer.write('[Unsupported content]');
    }
  }
  return buffer.toString();
}

/// Parses the preview `options` list into (label, projected content) pairs.
List<(String, String)> _proposalOptions(Object? rawOptions) {
  if (rawOptions is! List) return const <(String, String)>[];
  final options = <(String, String)>[];
  for (final item in rawOptions) {
    if (item is! Map) continue;
    final label = item['label'];
    if (label is! String) continue;
    options.add((label, _proposalNodesText(item['content'])));
  }
  return options;
}

/// Projects the preview `proposed_answer` into bounded display text.
String _proposalAnswerText(Object? rawAnswer) {
  if (rawAnswer is! Map) return '';
  return switch (rawAnswer['kind']) {
    'choice' => _proposalLabelsText(rawAnswer['labels']),
    'content' => _proposalNodesText(rawAnswer['nodes']),
    _ => '',
  };
}

String _proposalLabelsText(Object? rawLabels) {
  if (rawLabels is! List) return '';
  return rawLabels.whereType<String>().join(', ');
}

/// Replacement confirmation text bound to the exact observed active plan.
/// Shows only Application-owned plan data (bank name, optional goal); never
/// provider/model identity.
String _replacementConfirmationText({
  String? currentBankName,
  String? currentGoal,
}) {
  final hasBank = currentBankName != null && currentBankName.isNotEmpty;
  final hasGoal = currentGoal != null && currentGoal.isNotEmpty;
  final buffer = StringBuffer('当前已有学习计划');
  if (hasBank || hasGoal) {
    buffer.write('（');
    if (hasBank) {
      buffer.write('题库：');
      buffer.write(currentBankName);
    }
    if (hasBank && hasGoal) buffer.write('，');
    if (hasGoal) {
      buffer.write('目标：');
      buffer.write(currentGoal);
    }
    buffer.write('）');
  }
  buffer.write('。采用此草案将替换现有计划，确定要替换吗？');
  return buffer.toString();
}

/// SPL-1 StudyPlan proposal card rendered from the typed staged-event preview.
/// Adopt calls StudyPlanCommandService (with replacement confirmation if
/// needed); Reject performs zero durable writes.
class _StudyPlanProposalCard extends StatelessWidget {
  const _StudyPlanProposalCard({required this.controller});

  final ConversationController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final preview = controller.studyPlanPreview;
    final bankName = preview['bank_name']?.toString() ?? '';
    final goal = preview['goal']?.toString();
    final dailyTarget = preview['daily_target'];
    final priorityCode = preview['priority']?.toString();
    final horizonDays = preview['horizon_days'];
    final questionCount = preview['question_count'];
    final masteredCount = preview['mastered_count'];
    final dueCount = preview['due_count'];
    final weakCount = preview['weak_count'];
    final newCount = preview['new_count'];
    final estimatedDays = preview['estimated_days'];
    final status = controller.studyPlanStatusText;
    final actionMessage = controller.studyPlanActionMessage;
    // Exact observed ActiveStudyPlan used as the replacement CAS baseline.
    final currentPlan = controller.pendingReplacementActivePlan;
    final currentBankName = currentPlan?.bankName;
    final currentGoal = currentPlan?.goal;

    return Card(
      key: const ValueKey<String>('study-plan-draft-card'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: [
                Icon(Icons.event_note_outlined,
                    size: 20, color: colors.primary),
                const SizedBox(width: 8),
                Text(
                  '学习计划草案',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (bankName.isNotEmpty) Text('题库：$bankName'),
            if (goal != null && goal.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('目标：$goal'),
            ],
            if (dailyTarget != null) ...[
              const SizedBox(height: 4),
              Text('每日特训量：$dailyTarget 题'),
            ],
            if (priorityCode != null) ...[
              const SizedBox(height: 4),
              Text('优先策略：${_priorityLabel(priorityCode)}'),
            ],
            if (horizonDays != null) ...[
              const SizedBox(height: 4),
              Text('计划周期：$horizonDays 天'),
            ],
            if (questionCount != null) ...[
              const SizedBox(height: 6),
              Text(
                '题库概况：共 $questionCount 题 · '
                '已掌握 ${masteredCount ?? 0} · '
                '待复习 ${dueCount ?? 0} · '
                '薄弱 ${weakCount ?? 0} · 新题 ${newCount ?? 0}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
            if (estimatedDays != null) ...[
              const SizedBox(height: 4),
              Text(
                '预计约 $estimatedDays 天完成',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '采用此计划不会修改 FSRS / '
              '现有复习记录。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.outline,
                fontStyle: FontStyle.italic,
              ),
            ),
            if (status != null) ...[
              const SizedBox(height: 8),
              Text(
                status,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            if (actionMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                actionMessage,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.error,
                ),
              ),
            ],
            if (controller.showReplacementConfirmation) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.errorContainer.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: colors.error.withValues(alpha: 0.5),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _replacementConfirmationText(
                        currentBankName: currentBankName,
                        currentGoal: currentGoal,
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onErrorContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          key: const ValueKey<String>(
                            'study-plan-cancel-replace',
                          ),
                          onPressed: controller.cancelReplacement,
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          key: const ValueKey<String>(
                            'study-plan-confirm-replace',
                          ),
                          onPressed: controller.canAdoptStudyPlan
                              ? controller.confirmReplacement
                              : null,
                          child: const Text('确认替换'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ] else if (controller.studyPlanOutcome ==
                StudyPlanDraftOutcome.pending) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  OutlinedButton(
                    key: const ValueKey<String>('study-plan-draft-reject'),
                    onPressed: controller.canRejectStudyPlan
                        ? controller.rejectStudyPlan
                        : null,
                    child: const Text('不采用'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey<String>('study-plan-draft-adopt'),
                    onPressed: controller.canAdoptStudyPlan
                        ? controller.initiateAdoptStudyPlan
                        : null,
                    child: const Text('采用计划'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _priorityLabel(String code) {
    return switch (code) {
      'balanced' => '均衡',
      'due_first' => '到期复习优先',
      'weak_first' => '薄弱题优先',
      'new_first' => '新题优先',
      _ => code,
    };
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.selectedFiles,
    required this.isSending,
    required this.hasActiveTurn,
    required this.retrievalApproved,
    required this.onRetrievalApprovalChanged,
    required this.onAddContext,
    required this.onRemoveContext,
    required this.onSend,
    required this.onCancel,
  });

  final TextEditingController controller;
  final List<ConversationFileRef> selectedFiles;
  final bool isSending;
  final bool hasActiveTurn;
  final bool retrievalApproved;
  final ValueChanged<bool> onRetrievalApprovalChanged;
  final VoidCallback onAddContext;
  final ValueChanged<ConversationFileRef> onRemoveContext;
  final VoidCallback onSend;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: colors.outlineVariant),
          boxShadow: [
            BoxShadow(
              color: colors.shadow.withValues(alpha: 0.10),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (selectedFiles.isNotEmpty)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final file in selectedFiles)
                        InputChip(
                          key: ValueKey<String>('c0-context-${file.fileId}'),
                          label: Text(file.displayName),
                          avatar:
                              const Icon(Icons.description_outlined, size: 17),
                          onDeleted:
                              isSending ? null : () => onRemoveContext(file),
                        ),
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(8, 4, 8, 0),
                    child: Text(
                      '附件默认仅提供元数据；正文读取需要下面的本轮授权。',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
            if (selectedFiles.isNotEmpty)
              CheckboxListTile(
                key: const ValueKey<String>('rag1-turn-content-approval'),
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                value: retrievalApproved,
                onChanged: isSending
                    ? null
                    : (value) => onRetrievalApprovalChanged(value ?? false),
                title: const Text('允许 Shiroha 在本轮读取所选文件内容'),
                subtitle: const Text('仅本轮有效；重试、新消息、切换模型或重启后失效'),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  key: const ValueKey<String>('u1-ux0-add-context'),
                  tooltip: '添加上下文',
                  onPressed: isSending ? null : onAddContext,
                  icon: const Icon(Icons.add_circle_outline_rounded),
                ),
                Expanded(
                  child: TextField(
                    key: const ValueKey<String>('u1-ux0-composer'),
                    controller: controller,
                    enabled: !isSending,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: '问问 Shiroha……',
                      border: InputBorder.none,
                    ),
                  ),
                ),
                IconButton.filled(
                  key: ValueKey<String>(
                    hasActiveTurn ? 'a0-agent-cancel' : 'u1-ux0-send',
                  ),
                  tooltip: hasActiveTurn ? '停止' : '发送',
                  onPressed: hasActiveTurn
                      ? onCancel
                      : isSending
                          ? null
                          : onSend,
                  icon: hasActiveTurn
                      ? const Icon(Icons.stop_rounded)
                      : isSending
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.arrow_upward_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

IconData _turnStatusIcon(AssistantTurnPhase phase) {
  return switch (phase) {
    AssistantTurnPhase.searchingWeb => Icons.travel_explore_rounded,
    AssistantTurnPhase.usingLocalTool => Icons.manage_search_rounded,
    AssistantTurnPhase.failed => Icons.error_outline_rounded,
    AssistantTurnPhase.cancelled => Icons.stop_circle_outlined,
    _ => Icons.auto_awesome_rounded,
  };
}

class _FileContextPicker extends StatelessWidget {
  const _FileContextPicker({required this.controller});

  final ConversationController controller;

  @override
  Widget build(BuildContext context) {
    final selected =
        controller.selectedFiles.map((file) => file.fileId).toSet();
    return SafeArea(
      child: ListView(
        key: const ValueKey<String>('c0-context-picker'),
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        children: [
          ListTile(
            title: const Text('添加到本次对话'),
            titleTextStyle: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const ListTile(
            leading: Icon(Icons.description_outlined),
            title: Text('文件'),
          ),
          if (controller.attachableFiles.isEmpty)
            const ListTile(title: Text('文件库中暂无文件'))
          else
            for (final file in controller.attachableFiles)
              ListTile(
                key: ValueKey<String>('c0-context-file-${file.fileId}'),
                leading: const Icon(Icons.description_outlined),
                title: Text(file.displayName),
                subtitle: Text(file.mimeType),
                trailing: selected.contains(file.fileId)
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(context, file.fileId),
              ),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.library_books_outlined),
            title: Text('题库'),
            subtitle: Text('题库附件将在稳定题库身份建立后接入'),
            enabled: false,
          ),
        ],
      ),
    );
  }
}
