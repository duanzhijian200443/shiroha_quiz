import 'package:flutter/material.dart';

import '../../pages/data_center_screen.dart';
import 'u1_ux0_workspace_controller.dart';
import 'u1_ux0_workspace_pages.dart';

class U1Ux0LearningSpacesScreen extends StatelessWidget {
  const U1Ux0LearningSpacesScreen({
    super.key,
    required this.controller,
    this.fileController,
    this.onOpenProject,
    this.onCreateProject,
  });

  final LearningSpacesController controller;
  final FileLibraryController? fileController;
  final ValueChanged<String>? onOpenProject;
  final VoidCallback? onCreateProject;

  Future<void> _create(BuildContext context) async {
    if (onCreateProject != null) {
      onCreateProject!();
      return;
    }
    final input = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建学习空间'),
        content: TextField(
          key: const ValueKey<String>('u1-create-space-name'),
          controller: input,
          autofocus: true,
          decoration: const InputDecoration(hintText: '学习空间名称'),
        ),
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
    final created = await controller.create(name);
    if (created != null && context.mounted) _open(context, created.projectId);
  }

  Future<void> _open(BuildContext context, String projectId) async {
    if (onOpenProject != null) {
      onOpenProject!(projectId);
      return;
    }
    final files = fileController;
    if (files == null) return;
    await controller.select(projectId);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => U1Ux0LearningSpaceHomeWorkspace(
          controller: controller,
          fileController: files,
          projectId: projectId,
          onDeleted: () => Navigator.maybePop(context),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('学习空间'),
        actions: [
          TextButton(
            key: const ValueKey<String>('u1-open-legacy-library'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DataCenterScreen()),
            ),
            child: const Text('按旧分类浏览'),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          if (controller.isLoading && controller.spaces.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          return RefreshIndicator(
            onRefresh: controller.load,
            child: ListView(
              key: const ValueKey<String>('u1-ux0-learning-spaces-list'),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                FilledButton.tonalIcon(
                  key: const ValueKey<String>('u1-create-space'),
                  onPressed: () => _create(context),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('新建学习空间'),
                ),
                const SizedBox(height: 20),
                if (controller.spaces.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('暂无学习空间')),
                  )
                else
                  for (final space in controller.spaces)
                    Card(
                      child: ListTile(
                        key: ValueKey<String>(
                          'u1-learning-space-${space.projectId}',
                        ),
                        leading: const Icon(Icons.space_dashboard_outlined),
                        title: Text(space.displayName),
                        subtitle: Text(
                          '${space.bankCount} 个题库 · ${space.fileCount} 个文件',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(context, space.projectId),
                      ),
                    ),
                const Divider(height: 36),
                Text(
                  '未归类内容',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 6),
                const Text('这是没有任何学习空间关联的内容视图，不是学习空间。'),
                const SizedBox(height: 10),
                Card(
                  child: ListTile(
                    key: const ValueKey<String>('u1-ux0-unclassified-view'),
                    leading: const Icon(Icons.inbox_outlined),
                    title: const Text('查看未归类内容'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await controller.loadUnclassified();
                      if (!context.mounted) return;
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => _UnclassifiedAssetsScreen(
                            controller: controller,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                if (controller.errorMessage case final error?)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(error),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _UnclassifiedAssetsScreen extends StatelessWidget {
  const _UnclassifiedAssetsScreen({required this.controller});

  final LearningSpacesController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('未归类内容')),
        body: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final assets = controller.unclassifiedAssets;
            if (assets == null) {
              final error = controller.errorMessage;
              if (error != null) {
                return U1Ux0ErrorState(
                  message: error,
                  onRetry: controller.loadUnclassified,
                );
              }
              return const Center(child: CircularProgressIndicator());
            }
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text('文件', style: Theme.of(context).textTheme.titleMedium),
                if (assets.files.isEmpty)
                  const ListTile(title: Text('没有未归类文件'))
                else
                  for (final file in assets.files)
                    ListTile(
                      leading: const Icon(Icons.description_outlined),
                      title: Text(file.displayName),
                      subtitle: Text(file.mimeType),
                    ),
                const SizedBox(height: 20),
                Text('题库', style: Theme.of(context).textTheme.titleMedium),
                if (assets.banks.isEmpty)
                  const ListTile(title: Text('没有未归类题库'))
                else
                  for (final bank in assets.banks)
                    ListTile(
                      leading: const Icon(Icons.library_books_outlined),
                      title: Text(bank.bankName),
                      subtitle: Text('${bank.questionCount} 题'),
                    ),
              ],
            );
          },
        ),
      );
}
