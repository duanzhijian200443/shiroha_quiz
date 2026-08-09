import 'package:flutter/material.dart';

import 'workspace_controller.dart';

class GlobalSidebar extends StatelessWidget {
  const GlobalSidebar({
    super.key,
    required this.controller,
    required this.onNewConversation,
    required this.onOpenFileLibrary,
    required this.onOpenLearningSpaces,
    required this.onOpenMcp,
    required this.onOpenConversation,
    required this.onOpenSpaceHome,
    required this.onCreateSpace,
    required this.onFeedback,
  });

  final LearningSpacesController controller;
  final VoidCallback onNewConversation;
  final VoidCallback onOpenFileLibrary;
  final VoidCallback onOpenLearningSpaces;
  final VoidCallback onOpenMcp;
  final ValueChanged<String> onOpenConversation;
  final ValueChanged<String> onOpenSpaceHome;
  final VoidCallback onCreateSpace;
  final ValueChanged<String> onFeedback;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Material(
        key: const ValueKey<String>('u1-ux01-global-sidebar'),
        color: colors.surfaceContainerLow,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 17,
                      backgroundColor: colors.primary,
                      foregroundColor: colors.onPrimary,
                      child: const Icon(Icons.auto_awesome_rounded, size: 18),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'Shiroha',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
              _item(Icons.add_comment_outlined, '新对话', onNewConversation),
              _item(
                Icons.folder_copy_outlined,
                '文件库',
                onOpenFileLibrary,
                key: const ValueKey<String>('u1-ux01-open-file-library'),
              ),
              _item(
                Icons.space_dashboard_outlined,
                '学习空间',
                onOpenLearningSpaces,
                key: const ValueKey<String>('u1-ux01-open-learning-spaces'),
              ),
              _item(
                Icons.cable_rounded,
                'MCP',
                onOpenMcp,
                key: const ValueKey<String>('u1-ux01-open-mcp'),
              ),
              const Divider(height: 28),
              const _SidebarLabel('最近对话（预览）'),
              for (final title in const <String>[
                '分析数学一错题',
                '今天该复习什么',
              ])
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.chat_bubble_outline_rounded),
                  title: Text(title),
                  onTap: () => onOpenConversation(title),
                ),
              const Divider(height: 28),
              const _SidebarLabel('学习空间'),
              if (controller.isLoading)
                const Center(child: CircularProgressIndicator())
              else if (controller.spaces.isEmpty)
                const ListTile(
                  leading: Icon(Icons.inbox_outlined),
                  title: Text('暂无学习空间'),
                )
              else
                for (final space in controller.spaces)
                  ListTile(
                    key: ValueKey<String>('u1-space-${space.projectId}'),
                    dense: true,
                    leading: const Icon(Icons.space_dashboard_outlined),
                    title: Text(space.displayName),
                    subtitle: Text(
                      '${space.bankCount} 个题库 · ${space.fileCount} 个文件',
                    ),
                    trailing: IconButton(
                      key: ValueKey<String>(
                        'u1-ux01-space-home-${space.projectId}',
                      ),
                      tooltip: '${space.displayName}主页',
                      onPressed: () => onOpenSpaceHome(space.projectId),
                      icon: const Icon(Icons.home_outlined),
                    ),
                    onTap: () => onOpenSpaceHome(space.projectId),
                  ),
              ListTile(
                key: const ValueKey<String>('u1-sidebar-create-space'),
                dense: true,
                leading: const Icon(Icons.add_rounded),
                title: const Text('新建学习空间'),
                onTap: onCreateSpace,
              ),
              if (controller.errorMessage case final error?)
                ListTile(
                  leading: const Icon(Icons.error_outline),
                  title: Text(error),
                  trailing: IconButton(
                    onPressed: controller.load,
                    icon: const Icon(Icons.refresh),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item(
    IconData icon,
    String label,
    VoidCallback onTap, {
    Key? key,
  }) {
    return ListTile(
      key: key,
      dense: true,
      leading: Icon(icon),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onTap: onTap,
    );
  }
}

class _SidebarLabel extends StatelessWidget {
  const _SidebarLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
        ),
      );
}
