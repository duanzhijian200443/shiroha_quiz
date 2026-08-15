import 'package:flutter/material.dart';

import '../../application/u1_workspace/u1_workspace_dtos.dart';
import '../../domain/conversations/conversation.dart';
import 'conversation_controller.dart';
import 'workspace_controller.dart';

class GlobalSidebar extends StatelessWidget {
  const GlobalSidebar({
    super.key,
    required this.controller,
    required this.conversationController,
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
  final ConversationController conversationController;
  final VoidCallback onNewConversation;
  final VoidCallback onOpenFileLibrary;
  final VoidCallback onOpenLearningSpaces;
  final VoidCallback onOpenMcp;
  final ValueChanged<String> onOpenConversation;
  final ValueChanged<String> onOpenSpaceHome;
  final VoidCallback onCreateSpace;
  final ValueChanged<String> onFeedback;

  Future<void> _confirmDeleteConversation(
    BuildContext context,
    Conversation conversation,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除对话？'),
        content: Text(
          '将删除对话「${conversation.title}」及其所有消息。\n\n'
          '• 对话引用的文件和题库不会被删除；\n'
          '• 对话所属的学习空间不会受到影响；\n'
          '• 此操作无法撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await conversationController.deleteConversation(
        conversation.conversationId,
      );
    }
  }

  Future<void> _confirmDeleteSpace(
    BuildContext context,
    LearningSpaceSummary space,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除学习空间？'),
        content: Text(
          '将删除学习空间「${space.displayName}」。\n\n'
          '• 空间内的文件和题库仅解除关联，不会被删除；\n'
          '• 空间内的对话将保留为历史记录（因原空间删除变为不可用状态），之后仍可移动到全局或其他学习空间；\n'
          '• 此操作无法撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final success = await controller.delete(space.projectId);
      if (success) {
        await conversationController.refreshAfterProjectDeleted(
          space.projectId,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        controller,
        conversationController,
      ]),
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
              const _SidebarLabel('最近对话'),
              if (conversationController.isLoading)
                const Center(child: CircularProgressIndicator())
              else if (conversationController.recent.isEmpty)
                const ListTile(
                  leading: Icon(Icons.inbox_outlined),
                  title: Text('暂无最近对话'),
                )
              else
                for (final conversation in conversationController.recent)
                  _ConversationTile(
                    key: ValueKey<String>(
                      'c0-recent-${conversation.conversationId}',
                    ),
                    conversation: conversation,
                    onTap: () =>
                        onOpenConversation(conversation.conversationId),
                    onDelete: () =>
                        _confirmDeleteConversation(context, conversation),
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
                  ExpansionTile(
                    key: ValueKey<String>('u1-space-${space.projectId}'),
                    shape: const RoundedRectangleBorder(side: BorderSide.none),
                    collapsedShape:
                        const RoundedRectangleBorder(side: BorderSide.none),
                    leading: const Icon(Icons.space_dashboard_outlined),
                    title: Text(space.displayName),
                    subtitle: Text(
                      '${space.bankCount} 个题库 · ${space.fileCount} 个文件',
                    ),
                    trailing: PopupMenuButton<String>(
                      key: ValueKey<String>('u1-space-menu-${space.projectId}'),
                      tooltip: '更多操作',
                      icon: const Icon(Icons.more_horiz_rounded),
                      onSelected: (action) {
                        if (action == 'home') {
                          onOpenSpaceHome(space.projectId);
                        } else if (action == 'delete') {
                          _confirmDeleteSpace(context, space);
                        }
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem<String>(
                          key: ValueKey<String>(
                            'u1-ux01-space-home-${space.projectId}',
                          ),
                          value: 'home',
                          child: const Row(
                            children: [
                              Icon(Icons.home_outlined, size: 18),
                              SizedBox(width: 8),
                              Text('进入主页'),
                            ],
                          ),
                        ),
                        PopupMenuItem<String>(
                          key: ValueKey<String>(
                            'u1-space-delete-${space.projectId}',
                          ),
                          value: 'delete',
                          child: const Row(
                            children: [
                              Icon(
                                Icons.delete_outline_rounded,
                                size: 18,
                                color: Colors.red,
                              ),
                              SizedBox(width: 8),
                              Text(
                                '删除学习空间',
                                style: TextStyle(color: Colors.red),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    onExpansionChanged: (expanded) {
                      if (expanded) {
                        conversationController.loadProjectConversations(
                          space.projectId,
                        );
                      }
                    },
                    children: [
                      if (conversationController.loadingProjectIds
                          .contains(space.projectId))
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(),
                        )
                      else if ((conversationController
                                  .projectConversations[space.projectId] ??
                              const [])
                          .isEmpty)
                        const ListTile(
                          dense: true,
                          leading: Icon(Icons.inbox_outlined),
                          title: Text('暂无对话'),
                        )
                      else
                        for (final conversation in conversationController
                            .projectConversations[space.projectId]!)
                          _ConversationTile(
                            key: ValueKey<String>(
                              'c0-space-conversation-'
                              '${conversation.conversationId}',
                            ),
                            contentPadding:
                                const EdgeInsets.only(left: 48, right: 16),
                            conversation: conversation,
                            onTap: () => onOpenConversation(
                              conversation.conversationId,
                            ),
                            onDelete: () => _confirmDeleteConversation(
                              context,
                              conversation,
                            ),
                          ),
                    ],
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
              if (conversationController.errorMessage case final error?)
                ListTile(
                  leading: const Icon(Icons.error_outline),
                  title: Text(error),
                  trailing: IconButton(
                    onPressed: conversationController.load,
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

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    super.key,
    required this.conversation,
    required this.onTap,
    required this.onDelete,
    this.contentPadding,
  });

  final Conversation conversation;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: contentPadding,
      leading: const Icon(Icons.chat_bubble_outline_rounded),
      title: Text(
        conversation.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onTap,
      trailing: PopupMenuButton<String>(
        key: ValueKey<String>(
          'c0-conversation-menu-${conversation.conversationId}',
        ),
        tooltip: '更多操作',
        icon: const Icon(Icons.more_horiz_rounded),
        onSelected: (action) {
          if (action == 'delete') {
            onDelete();
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem<String>(
            key: ValueKey<String>(
              'c0-conversation-delete-${conversation.conversationId}',
            ),
            value: 'delete',
            child: const Row(
              children: [
                Icon(
                  Icons.delete_outline_rounded,
                  size: 18,
                  color: Colors.red,
                ),
                SizedBox(width: 8),
                Text('删除对话', style: TextStyle(color: Colors.red)),
              ],
            ),
          ),
        ],
      ),
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
