import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../application/u1_workspace/u1_workspace_dtos.dart';
import 'workspace_controller.dart';

typedef LibraryFilePicker = Future<FilePickerResult?> Function();

class FileLibraryWorkspace extends StatelessWidget {
  const FileLibraryWorkspace({
    super.key,
    required this.controller,
    this.pickFile,
  });

  final FileLibraryController controller;
  final LibraryFilePicker? pickFile;

  Future<void> _addFile(BuildContext context) async {
    final result = await (pickFile?.call() ??
        FilePicker.platform.pickFiles(allowMultiple: false));
    if (result == null || result.files.isEmpty) return;
    final selected = result.files.single;
    final path = selected.path;
    if (path == null) {
      if (context.mounted) _feedback(context, '无法读取所选文件');
      return;
    }
    final success = await controller.ingest(
      externalPath: path,
      displayName: selected.name,
    );
    if (context.mounted) {
      _feedback(
        context,
        success ? '文件已添加到“未分类”' : controller.errorMessage!,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey<String>('u1-ux01-file-library-workspace'),
      appBar: AppBar(
        title: const Text('文件库'),
        actions: [
          TextButton.icon(
            key: const ValueKey<String>('u1-add-library-file'),
            onPressed: () => _addFile(context),
            icon: const Icon(Icons.add_rounded),
            label: const Text('添加文件'),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => LayoutBuilder(
          builder: (context, constraints) {
            final content = _FileLibraryContent(controller: controller);
            if (constraints.maxWidth < 760) {
              return Column(
                key: const ValueKey<String>('u1-ux01-file-library-compact'),
                children: [
                  _FileFilters(controller: controller, compact: true),
                  Expanded(child: content),
                ],
              );
            }
            return Row(
              children: [
                SizedBox(
                  key: const ValueKey<String>(
                    'u1-ux01-file-library-local-nav',
                  ),
                  width: 220,
                  child: _FileFilters(controller: controller),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: content),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _FileFilters extends StatelessWidget {
  const _FileFilters({required this.controller, this.compact = false});

  final FileLibraryController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final choices = <(FileLibraryView, String, IconData)>[
      (FileLibraryView.all, '全部文件', Icons.folder_copy_outlined),
      (FileLibraryView.recent, '最近', Icons.schedule_rounded),
      (FileLibraryView.unclassified, '未归类', Icons.inbox_outlined),
    ];
    if (compact) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Row(
              children: [
                for (final choice in choices)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      key: ValueKey<String>(
                        'f0-1-view-${choice.$1.name}',
                      ),
                      label: Text(choice.$2),
                      selected: controller.selectedFolderId == null &&
                          controller.view == choice.$1,
                      onSelected: (_) => controller.load(nextView: choice.$1),
                    ),
                  ),
              ],
            ),
          ),
          ExpansionTile(
            key: const ValueKey<String>('f0-1-mobile-folder-section'),
            initiallyExpanded: true,
            leading: const Icon(Icons.folder_outlined),
            title: const Text('文件夹'),
            children: _folderTiles(context),
          ),
        ],
      );
    }
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: ListView(
        padding: const EdgeInsets.all(10),
        children: [
          for (final choice in choices)
            ListTile(
              key: ValueKey<String>('f0-1-view-${choice.$1.name}'),
              selected: controller.selectedFolderId == null &&
                  controller.view == choice.$1,
              leading: Icon(choice.$3),
              title: Text(choice.$2),
              onTap: () => controller.load(nextView: choice.$1),
            ),
          const Divider(),
          const ListTile(
            dense: true,
            title: Text(
              '文件夹',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          ..._folderTiles(context),
        ],
      ),
    );
  }

  List<Widget> _folderTiles(BuildContext context) {
    return <Widget>[
      for (final folder in controller.folders)
        ListTile(
          key: ValueKey<String>('f0-1-folder-${folder.folderId}'),
          selected: controller.selectedFolderId == folder.folderId,
          leading: const Icon(Icons.folder_outlined),
          title: Text(folder.displayName),
          onTap: () => controller.selectFolder(folder.folderId),
          trailing: PopupMenuButton<String>(
            key: ValueKey<String>('f0-1-folder-menu-${folder.folderId}'),
            onSelected: (action) async {
              if (action == 'rename') {
                await _renameFolder(context, controller, folder);
              } else if (action == 'delete') {
                await _deleteFolder(context, controller, folder);
              }
            },
            itemBuilder: (_) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'rename', child: Text('重命名')),
              PopupMenuItem<String>(value: 'delete', child: Text('删除')),
            ],
          ),
        ),
      ListTile(
        key: const ValueKey<String>('f0-1-create-folder'),
        leading: const Icon(Icons.create_new_folder_outlined),
        title: const Text('新建文件夹'),
        onTap: () => _createFolder(context, controller),
      ),
    ];
  }
}

class _FileLibraryContent extends StatelessWidget {
  const _FileLibraryContent({required this.controller});

  final FileLibraryController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.isLoading && controller.files.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
          child: TextField(
            key: const ValueKey<String>('u1-ux01-file-search'),
            onChanged: controller.setQuery,
            decoration: const InputDecoration(
              hintText: '搜索文件……',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
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
        Expanded(
          child: controller.visibleFiles.isEmpty
              ? const Center(child: Text('这里还没有文件'))
              : ListView.builder(
                  key: const ValueKey<String>('u1-ux01-file-list'),
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
                  itemCount: controller.visibleFiles.length,
                  itemBuilder: (context, index) {
                    final file = controller.visibleFiles[index];
                    return Card(
                      child: ListTile(
                        key: ValueKey<String>('u1-ux01-file-${file.fileId}'),
                        leading: Icon(_fileIcon(file.mimeType)),
                        title: Text(file.displayName),
                        subtitle: Text(
                          '${file.mimeType} · ${_size(file.sizeBytes)} · ${_date(file.createdAt)}',
                        ),
                        trailing: IconButton(
                          key: ValueKey<String>(
                            'f0-1-move-file-${file.fileId}',
                          ),
                          tooltip: '移动到文件夹',
                          onPressed: () => _moveFile(
                            context,
                            controller,
                            file.fileId,
                          ),
                          icon: const Icon(Icons.drive_file_move_outlined),
                        ),
                        onTap: () async {
                          await controller.select(file.fileId);
                          if (!context.mounted ||
                              (controller.selectedDetail == null &&
                                  controller.errorMessage == null)) {
                            return;
                          }
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => _FileDetailScreen(
                                controller: controller,
                                fileId: file.fileId,
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _FileDetailScreen extends StatelessWidget {
  const _FileDetailScreen({required this.controller, required this.fileId});

  final FileLibraryController controller;
  final String fileId;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('文件详情')),
        body: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final detail = controller.selectedDetail;
            if (detail == null || detail.file.fileId != fileId) {
              final error = controller.errorMessage;
              if (error != null) {
                return WorkspaceErrorState(
                  message: error,
                  onRetry: () => controller.select(fileId),
                );
              }
              return const Center(child: CircularProgressIndicator());
            }
            final related = {
              for (final space in detail.relatedSpaces) space.projectId,
            };
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                ListTile(
                    title: const Text('名称'),
                    subtitle: Text(detail.file.displayName)),
                ListTile(
                    title: const Text('类型'),
                    subtitle: Text(detail.file.mimeType)),
                ListTile(
                    title: const Text('大小'),
                    subtitle: Text(_size(detail.file.sizeBytes))),
                ListTile(
                    title: const Text('添加时间'),
                    subtitle: Text(_date(detail.file.createdAt))),
                ListTile(
                  key: const ValueKey<String>('f0-1-file-folder-detail'),
                  title: const Text('文件夹'),
                  subtitle: Text(detail.folder?.displayName ?? '未分类'),
                  trailing: const Icon(Icons.drive_file_move_outlined),
                  onTap: () => _moveFile(context, controller, fileId),
                ),
                const Divider(height: 30),
                Text(
                  '关联学习空间',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (controller.spaces.isEmpty)
                  const ListTile(title: Text('暂无学习空间'))
                else
                  for (final space in controller.spaces)
                    SwitchListTile(
                      key: ValueKey<String>(
                        'u1-file-space-${space.projectId}',
                      ),
                      title: Text(space.displayName),
                      value: related.contains(space.projectId),
                      onChanged: (attached) => controller.setProjectRelation(
                        fileId: fileId,
                        projectId: space.projectId,
                        attached: attached,
                      ),
                    ),
                const SizedBox(height: 12),
                const Text('打开原文件将在安全的 managed-file 用例完成后提供。'),
              ],
            );
          },
        ),
      );
}

class LearningSpaceHomeWorkspace extends StatefulWidget {
  const LearningSpaceHomeWorkspace({
    super.key,
    required this.controller,
    required this.fileController,
    required this.projectId,
    required this.onDeleted,
  });

  final LearningSpacesController controller;
  final FileLibraryController fileController;
  final String projectId;
  final VoidCallback onDeleted;

  @override
  State<LearningSpaceHomeWorkspace> createState() =>
      _LearningSpaceHomeWorkspaceState();
}

class _LearningSpaceHomeWorkspaceState
    extends State<LearningSpaceHomeWorkspace> {
  @override
  void initState() {
    super.initState();
    if (widget.controller.selectedDetail?.summary.projectId !=
        widget.projectId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.controller.select(widget.projectId);
        }
      });
    }
  }

  Future<void> _rename(String currentName) async {
    final input = TextEditingController(text: currentName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名学习空间'),
        content: TextField(controller: input, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    input.dispose();
    if (name != null && name.isNotEmpty) {
      await widget.controller.rename(widget.projectId, name);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除学习空间？'),
        content: const Text('只会删除学习空间及其关联，不会删除文件、题库或题目。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true &&
        await widget.controller.delete(widget.projectId) &&
        mounted) {
      widget.onDeleted();
    }
  }

  Future<void> _addFile(LearningSpaceDetail detail) async {
    await widget.fileController.load();
    if (!mounted) return;
    final attached = {for (final file in detail.files) file.fileId};
    final candidates = widget.fileController.files
        .where((file) => !attached.contains(file.fileId))
        .toList();
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          children: [
            const ListTile(title: Text('添加文件')),
            if (candidates.isEmpty)
              const ListTile(title: Text('没有可添加的文件'))
            else
              for (final file in candidates)
                ListTile(
                  title: Text(file.displayName),
                  onTap: () async {
                    Navigator.pop(context);
                    await widget.controller.attachFile(
                      widget.projectId,
                      file.fileId,
                    );
                  },
                ),
          ],
        ),
      ),
    );
  }

  Future<void> _addBank(LearningSpaceDetail detail) async {
    final attached = {for (final bank in detail.banks) bank.bankName};
    final candidates = widget.controller.availableBanks
        .where((bank) => !attached.contains(bank.bankName))
        .toList();
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          children: [
            const ListTile(title: Text('添加题库')),
            if (candidates.isEmpty)
              const ListTile(title: Text('没有可添加的题库'))
            else
              for (final bank in candidates)
                ListTile(
                  title: Text(bank.bankName),
                  subtitle: Text('${bank.questionCount} 题'),
                  onTap: () async {
                    Navigator.pop(context);
                    await widget.controller.attachBank(
                      widget.projectId,
                      bank.bankName,
                    );
                  },
                ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final detail = widget.controller.selectedDetail;
        if (widget.controller.isLoading) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        if (detail == null || detail.summary.projectId != widget.projectId) {
          final error = widget.controller.errorMessage;
          if (error != null) {
            return Scaffold(
              body: WorkspaceErrorState(
                message: error,
                onRetry: () => widget.controller.select(widget.projectId),
              ),
            );
          }
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        return DefaultTabController(
          length: 2,
          child: Scaffold(
            key: const ValueKey<String>('u1-ux01-space-home-workspace'),
            appBar: AppBar(
              title: Text(detail.summary.displayName),
              bottom: const TabBar(
                tabs: [Tab(text: '资料'), Tab(text: '设置')],
              ),
            ),
            body: TabBarView(
              children: [
                ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    _sectionHeader(context, '文件', () => _addFile(detail)),
                    if (detail.files.isEmpty)
                      const ListTile(title: Text('尚未关联文件'))
                    else
                      for (final file in detail.files)
                        ListTile(
                          leading: const Icon(Icons.description_outlined),
                          title: Text(file.displayName),
                          subtitle: Text(file.mimeType),
                          trailing: IconButton(
                            tooltip: '从学习空间移除',
                            onPressed: () => widget.controller.detachFile(
                              widget.projectId,
                              file.fileId,
                            ),
                            icon: const Icon(Icons.link_off),
                          ),
                        ),
                    const SizedBox(height: 18),
                    _sectionHeader(context, '题库', () => _addBank(detail)),
                    if (detail.banks.isEmpty)
                      const ListTile(title: Text('尚未关联题库'))
                    else
                      for (final bank in detail.banks)
                        ListTile(
                          leading: Icon(
                            bank.isMissing
                                ? Icons.warning_amber_rounded
                                : Icons.library_books_outlined,
                          ),
                          title: Text(bank.bankName),
                          subtitle: Text(
                            bank.isMissing
                                ? '题库已不存在'
                                : '${bank.summary!.questionCount} 题',
                          ),
                          trailing: IconButton(
                            tooltip: '移除关联',
                            onPressed: () => widget.controller.detachBank(
                              widget.projectId,
                              bank.bankName,
                            ),
                            icon: const Icon(Icons.link_off),
                          ),
                        ),
                  ],
                ),
                ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    ListTile(
                      leading: const Icon(Icons.edit_outlined),
                      title: const Text('重命名学习空间'),
                      onTap: () => _rename(detail.summary.displayName),
                    ),
                    ListTile(
                      leading: Icon(
                        Icons.delete_outline,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      title: Text(
                        '删除学习空间',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      subtitle: const Text('文件和题库不会被删除'),
                      onTap: _delete,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _sectionHeader(
    BuildContext context,
    String label,
    VoidCallback onAdd,
  ) {
    return Row(
      children: [
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.titleMedium),
        ),
        TextButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add),
          label: const Text('添加'),
        ),
      ],
    );
  }
}

class McpWorkspace extends StatelessWidget {
  const McpWorkspace({super.key, required this.projection});

  final McpWorkspaceProjection projection;

  @override
  Widget build(BuildContext context) => Scaffold(
        key: const ValueKey<String>('u1-ux01-mcp-workspace'),
        appBar: AppBar(title: const Text('MCP')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                const _McpMetric(label: '状态', value: '已配置 / 可用'),
                _McpMetric(
                  label: '传输',
                  value: projection.transport == McpTransport.localStdio
                      ? 'Local stdio'
                      : '未知',
                ),
                _McpMetric(
                  label: '权限',
                  value: projection.permission == McpPermission.readOnly
                      ? '只读'
                      : '未知',
                ),
                _McpMetric(
                  label: '可用工具',
                  value: '${projection.toolNames.length}',
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text('可用工具', style: Theme.of(context).textTheme.titleMedium),
            for (final tool in projection.toolNames)
              ListTile(
                leading: const Icon(Icons.build_circle_outlined),
                title: Text(tool),
                dense: true,
              ),
            const SizedBox(height: 12),
            const Text('Capability 可用不代表外部 MCP server process 当前正在运行。'),
          ],
        ),
      );
}

class _McpMetric extends StatelessWidget {
  const _McpMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
        width: 170,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
      );
}

IconData _fileIcon(String mimeType) {
  if (mimeType == 'application/pdf') return Icons.picture_as_pdf_outlined;
  if (mimeType.startsWith('image/')) return Icons.image_outlined;
  return Icons.description_outlined;
}

/// Shared failure state for the Assistant workspace: shows a safe message
/// with a retry action instead of an indefinite loading indicator.
class WorkspaceErrorState extends StatelessWidget {
  const WorkspaceErrorState({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      key: const ValueKey<String>('u1-ux0-error-state'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 40, color: colors.error),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              key: const ValueKey<String>('u1-ux0-error-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

String _size(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _date(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
}

void _feedback(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

Future<String?> _folderNameDialog(
  BuildContext context, {
  required String title,
  String initialValue = '',
}) async {
  var input = initialValue;
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: TextFormField(
        key: const ValueKey<String>('f0-1-folder-name-input'),
        initialValue: initialValue,
        autofocus: true,
        maxLength: 100,
        onChanged: (value) => input = value,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('f0-1-folder-name-save'),
          onPressed: () => Navigator.pop(dialogContext, input),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  return result;
}

Future<void> _createFolder(
  BuildContext context,
  FileLibraryController controller,
) async {
  final name = await _folderNameDialog(context, title: '新建文件夹');
  if (name == null || !context.mounted) return;
  final created = await controller.createFolder(name);
  if (!context.mounted) return;
  if (created == null) {
    _feedback(context, controller.errorMessage!);
  } else {
    _feedback(context, '文件夹已创建');
  }
}

Future<void> _renameFolder(
  BuildContext context,
  FileLibraryController controller,
  LibraryFolderSummary folder,
) async {
  final name = await _folderNameDialog(
    context,
    title: '重命名文件夹',
    initialValue: folder.displayName,
  );
  if (name == null || !context.mounted) return;
  final success = await controller.renameFolder(folder.folderId, name);
  if (!context.mounted) return;
  _feedback(context, success ? '文件夹已重命名' : controller.errorMessage!);
}

Future<void> _deleteFolder(
  BuildContext context,
  FileLibraryController controller,
  LibraryFolderSummary folder,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('删除文件夹？'),
      content: const Text('删除文件夹不会删除其中的文件，文件将移动到“未分类”。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('f0-1-confirm-delete-folder'),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final success = await controller.deleteFolder(folder.folderId);
  if (!context.mounted) return;
  _feedback(context, success ? '文件夹已删除' : controller.errorMessage!);
}

Future<void> _moveFile(
  BuildContext context,
  FileLibraryController controller,
  String fileId,
) async {
  final folderId = await showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('移动到文件夹')),
          ListTile(
            key: const ValueKey<String>('f0-1-move-unclassified'),
            leading: const Icon(Icons.inbox_outlined),
            title: const Text('未分类'),
            onTap: () => Navigator.pop(sheetContext, ''),
          ),
          for (final folder in controller.folders)
            ListTile(
              key: ValueKey<String>('f0-1-move-${folder.folderId}'),
              leading: const Icon(Icons.folder_outlined),
              title: Text(folder.displayName),
              onTap: () => Navigator.pop(sheetContext, folder.folderId),
            ),
        ],
      ),
    ),
  );
  if (folderId == null || !context.mounted) return;
  final success = await controller.moveFile(
    fileId: fileId,
    folderId: folderId.isEmpty ? null : folderId,
  );
  if (!context.mounted) return;
  _feedback(context, success ? '文件分类已更新' : controller.errorMessage!);
}
