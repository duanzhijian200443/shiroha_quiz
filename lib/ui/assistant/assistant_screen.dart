import 'package:flutter/material.dart';

import 'global_sidebar.dart';
import 'learning_spaces_screen.dart';
import 'workspace_controller.dart';
import 'workspace_pages.dart';

/// Shiroha conversation presentation shell.
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({
    super.key,
    required this.spacesController,
    required this.fileController,
    this.showGlobalMenu = true,
  });

  final LearningSpacesController spacesController;
  final FileLibraryController fileController;
  final bool showGlobalMenu;

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final TextEditingController _composerController = TextEditingController();
  final List<_MockContextItem> _selectedContexts = <_MockContextItem>[];
  String? _currentProjectId;
  String? _activeConversation;

  String get _currentSpace {
    for (final space in widget.spacesController.spaces) {
      if (space.projectId == _currentProjectId) return space.displayName;
    }
    return '未选择学习空间';
  }

  @override
  void dispose() {
    _composerController.dispose();
    super.dispose();
  }

  void _feedback(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _startNewConversation() {
    if (widget.showGlobalMenu) Navigator.maybePop(context);
    setState(() {
      _activeConversation = null;
      _composerController.clear();
      _selectedContexts.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _feedback('已开始一段新的对话预览');
    });
  }

  void _openConversation(String title) {
    if (widget.showGlobalMenu) Navigator.pop(context);
    setState(() => _activeConversation = title);
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
    final selected = await showModalBottomSheet<_MockContextItem>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _MockContextPicker(),
    );
    if (!mounted || selected == null || _selectedContexts.contains(selected)) {
      return;
    }
    setState(() => _selectedContexts.add(selected));
  }

  Future<void> _showSpacePicker() async {
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
                title: const Text('切换学习空间'),
                titleTextStyle: Theme.of(sheetContext)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              if (widget.spacesController.spaces.isEmpty)
                const ListTile(title: Text('暂无学习空间')),
              for (final space in widget.spacesController.spaces)
                ListTile(
                  leading: const Icon(Icons.space_dashboard_outlined),
                  title: Text(space.displayName),
                  trailing: _currentProjectId == space.projectId
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
    if (mounted && selected != null) {
      setState(() => _currentProjectId = selected);
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
    if (created != null && mounted) {
      setState(() => _currentProjectId = created.projectId);
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
        onDeleted: () => Navigator.maybePop(context),
      ),
    );
  }

  void _sendMockMessage() {
    if (_composerController.text.trim().isEmpty) {
      _feedback('先写下你想问 Shiroha 的问题');
      return;
    }
    _feedback('当前版本暂不支持发送或保存消息');
    _composerController.clear();
  }

  Drawer? _buildDrawer() {
    if (!widget.showGlobalMenu) return null;
    return Drawer(
      child: GlobalSidebar(
        controller: widget.spacesController,
        onNewConversation: _startNewConversation,
        onOpenFileLibrary: () => _pushFromDrawer(FileLibraryWorkspace(
          controller: widget.fileController,
        )),
        onOpenLearningSpaces: () => _pushFromDrawer(LearningSpacesScreen(
          controller: widget.spacesController,
          fileController: widget.fileController,
        )),
        onOpenMcp: () => _pushFromDrawer(McpWorkspace(
          projection: widget.spacesController.mcpProjection,
        )),
        onOpenConversation: _openConversation,
        onOpenSpaceHome: _openSpaceHome,
        onCreateSpace: _createSpace,
        onFeedback: _drawerFeedback,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
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
                      Icons.keyboard_arrow_down_rounded,
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
          IconButton(
            key: const ValueKey<String>('u1-ux0-new-conversation'),
            tooltip: '新对话',
            onPressed: _startNewConversation,
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
                Expanded(
                  child: ListView(
                    key: const ValueKey<String>('u1-ux0-assistant-content'),
                    padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
                    children: [
                      Text(
                        _activeConversation ?? '今天想学什么？',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _activeConversation == null
                            ? '从一个问题开始，或试试下面的建议'
                            : '这是对话界面预览，当前版本不会发送或保存消息',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 24),
                      _PromptCard(
                        icon: Icons.insights_outlined,
                        text: '分析我最近的错题',
                        onTap: () => setState(
                          () => _composerController.text = '分析我最近的错题',
                        ),
                      ),
                      const SizedBox(height: 12),
                      _PromptCard(
                        icon: Icons.event_note_outlined,
                        text: '帮我规划今天的复习',
                        onTap: () => setState(
                          () => _composerController.text = '帮我规划今天的复习',
                        ),
                      ),
                      const SizedBox(height: 28),
                      const _AssistantInsightCard(),
                    ],
                  ),
                ),
                _Composer(
                  controller: _composerController,
                  selectedContexts: _selectedContexts,
                  onAddContext: _showContextPicker,
                  onRemoveContext: (item) =>
                      setState(() => _selectedContexts.remove(item)),
                  onSend: _sendMockMessage,
                ),
              ],
            ),
          ),
        ),
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

class _AssistantInsightCard extends StatelessWidget {
  const _AssistantInsightCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: colors.primary.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: colors.primary,
                foregroundColor: colors.onPrimary,
                child: const Icon(Icons.auto_awesome_rounded, size: 18),
              ),
              const SizedBox(width: 10),
              const Text('Shiroha',
                  style: TextStyle(fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 14),
          const Text('你最近“极限与连续”的错误率比较高，建议今天优先复习这一部分。'),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('极限与连续',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(
                  '最近正确率 58% · 错题 12',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                Text(
                  '示例数据',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: () => _mockFeedback(context, '当前版本暂未接入查看错题'),
                      child: const Text('查看错题'),
                    ),
                    FilledButton.tonal(
                      onPressed: () => _mockFeedback(context, '当前版本暂未接入开始训练'),
                      child: const Text('开始训练'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.selectedContexts,
    required this.onAddContext,
    required this.onRemoveContext,
    required this.onSend,
  });

  final TextEditingController controller;
  final List<_MockContextItem> selectedContexts;
  final VoidCallback onAddContext;
  final ValueChanged<_MockContextItem> onRemoveContext;
  final VoidCallback onSend;

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
            if (selectedContexts.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final item in selectedContexts)
                    InputChip(
                      key: ValueKey<String>('u1-ux0-context-${item.id}'),
                      label: Text(item.label),
                      avatar: Icon(item.icon, size: 17),
                      onDeleted: () => onRemoveContext(item),
                    ),
                ],
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  key: const ValueKey<String>('u1-ux0-add-context'),
                  tooltip: '添加上下文',
                  onPressed: onAddContext,
                  icon: const Icon(Icons.add_circle_outline_rounded),
                ),
                Expanded(
                  child: TextField(
                    key: const ValueKey<String>('u1-ux0-composer'),
                    controller: controller,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: '问问 Shiroha……',
                      border: InputBorder.none,
                    ),
                  ),
                ),
                IconButton.filled(
                  key: const ValueKey<String>('u1-ux0-send'),
                  tooltip: '发送',
                  onPressed: onSend,
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MockContextPicker extends StatelessWidget {
  const _MockContextPicker();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        key: const ValueKey<String>('u1-ux0-context-picker'),
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
          const _ContextHeader(Icons.description_outlined, '文件'),
          for (final item in _mockFiles)
            ListTile(
              leading: Icon(item.icon),
              title: Text(item.label),
              onTap: () => Navigator.pop(context, item),
            ),
          const Divider(),
          const _ContextHeader(Icons.library_books_outlined, '题库'),
          for (final item in _mockBanks)
            ListTile(
              leading: Icon(item.icon),
              title: Text(item.label),
              onTap: () => Navigator.pop(context, item),
            ),
        ],
      ),
    );
  }
}

class _ContextHeader extends StatelessWidget {
  const _ContextHeader(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 19, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

@immutable
class _MockContextItem {
  const _MockContextItem(this.id, this.label, this.icon);

  final String id;
  final String label;
  final IconData icon;
}

const _mockFiles = <_MockContextItem>[
  _MockContextItem(
    'math-2019-pdf',
    '2019数学一真题.pdf',
    Icons.picture_as_pdf_outlined,
  ),
  _MockContextItem(
    'backprop-notes',
    '反向传播笔记.md',
    Icons.description_outlined,
  ),
];

const _mockBanks = <_MockContextItem>[
  _MockContextItem('math-2019-bank', '2019数学一', Icons.menu_book_outlined),
  _MockContextItem('limits-bank', '极限专项训练', Icons.library_books_outlined),
];

void _mockFeedback(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
