import 'package:flutter/material.dart';

import '../../application/conversations/conversation_repository.dart';
import '../../domain/conversations/conversation.dart';
import '../../domain/conversations/conversation_message.dart';
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

  Future<void> _showSpacePicker() async {
    if (!widget.conversationController.isDraft) {
      _feedback('对话范围已在首条消息发送时锁定');
      return;
    }
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
                    Icon(
                      conversations.isDraft
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.lock_outline_rounded,
                      size: 17,
                      color: colors.onSurfaceVariant,
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
        child: Text(message.content),
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
            Text(text),
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

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.selectedFiles,
    required this.isSending,
    required this.hasActiveTurn,
    required this.onAddContext,
    required this.onRemoveContext,
    required this.onSend,
    required this.onCancel,
  });

  final TextEditingController controller;
  final List<ConversationFileRef> selectedFiles;
  final bool isSending;
  final bool hasActiveTurn;
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
                      '当前 Shiroha 可识别附件信息，文件内容理解将在后续版本接入。',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                ],
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
