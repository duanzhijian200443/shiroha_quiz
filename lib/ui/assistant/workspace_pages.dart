import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../application/file_library/library_file_deletion.dart';
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
        title: const Text('资料库'),
        actions: [
          PopupMenuButton<String>(
            key: const ValueKey<String>('u1-library-add-menu'),
            tooltip: '添加',
            icon: const Icon(Icons.add_rounded),
            onSelected: (action) {
              if (action == 'file') {
                _addFile(context);
              } else if (action == 'folder') {
                _createFolder(context, controller);
              }
            },
            itemBuilder: (_) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                key: ValueKey<String>('u1-add-library-file'),
                value: 'file',
                child: ListTile(
                  leading: Icon(Icons.upload_file_outlined),
                  title: Text('上传文件'),
                ),
              ),
              PopupMenuItem<String>(
                key: ValueKey<String>('f0-1-create-folder'),
                value: 'folder',
                child: ListTile(
                  leading: Icon(Icons.create_new_folder_outlined),
                  title: Text('新建文件夹'),
                ),
              ),
            ],
          ),
          const SizedBox(width: 8),
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
      (FileLibraryView.all, '全部', Icons.folder_copy_outlined),
      (FileLibraryView.recent, '最近', Icons.schedule_rounded),
      (FileLibraryView.unclassified, '未分类', Icons.inbox_outlined),
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
    final normalizedQuery = controller.query.trim().toLowerCase();
    final visibleFolders = normalizedQuery.isEmpty
        ? controller.folders
        : controller.folders
            .where(
              (folder) =>
                  folder.displayName.toLowerCase().contains(normalizedQuery),
            )
            .toList(growable: false);
    return <Widget>[
      for (final folder in visibleFolders)
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
              hintText: '搜索文件、文件夹…',
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
                          '${_fileTypeLabel(file.mimeType)} · ${_size(file.sizeBytes)} · ${_date(file.createdAt)}',
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
                    subtitle: Text(_fileTypeLabel(detail.file.mimeType))),
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
                _FileArtifactCard(controller: controller, fileId: fileId),
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
                ListTile(
                  key: const ValueKey<String>('dm-d5-delete-library-file'),
                  leading: Icon(
                    Icons.delete_outline,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(
                    '删除文件',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  subtitle: const Text('永久删除文件记录和受管原文件'),
                  onTap: controller.isFileDeletionPending(fileId)
                      ? null
                      : () => _deleteLibraryFile(
                            context,
                            controller,
                            fileId,
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

class _FileArtifactCard extends StatelessWidget {
  const _FileArtifactCard({
    required this.controller,
    required this.fileId,
  });

  final FileLibraryController controller;
  final String fileId;

  String _formatRoute(String? route) {
    return switch (route) {
      'pdf_text' => 'PDF 文本',
      'docx_text' => 'Word 文本',
      'txt' => '纯文本',
      'markdown' => 'Markdown',
      'ocr_pdf' => 'OCR (PDF)',
      'ocr_image' => 'OCR (图片)',
      _ => route ?? '自动',
    };
  }

  Future<void> _handleParse(BuildContext context) async {
    if (controller.isArtifactBusy) return;
    final state = await controller.ensureFileParsed(fileId);
    if (!context.mounted) return;

    if (state.status == LibraryFileArtifactStatus.ocrRecommended) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const ValueKey<String>('ocr-confirmation-dialog'),
          title: const Text('未检测到可提取文本'),
          content: const Text(
            '这个 PDF 可能是扫描版。\n'
            '是否使用 OCR 识别文件内容？\n\n'
            '继续后，文件内容会发送到当前配置的 OCR 服务。\n'
            'OCR 只用于生成可检索的文件内容，不会自动生成或修改题目。',
          ),
          actions: [
            TextButton(
              key: const ValueKey<String>('ocr-dialog-cancel'),
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey<String>('ocr-dialog-confirm'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('使用 OCR'),
            ),
          ],
        ),
      );

      if (confirmed == true && context.mounted) {
        await controller.ensureFileOcrPdf(fileId);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = controller.artifactState;
    final isBusy = controller.isArtifactBusy;

    return Card(
      key: const ValueKey<String>('file-detail-artifact-section'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.article_outlined,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  '内容解析',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const Spacer(),
                if (isBusy)
                  const SizedBox(
                    key: ValueKey<String>('artifact-progress-indicator'),
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (state == null ||
                state.status == LibraryFileArtifactStatus.none) ...[
              const Text('尚未解析文件内容'),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                key: const ValueKey<String>('file-detail-parse-button'),
                onPressed: isBusy ? null : () => _handleParse(context),
                icon: const Icon(Icons.document_scanner_outlined, size: 18),
                label: const Text('解析内容'),
              ),
            ] else if (state.status == LibraryFileArtifactStatus.available) ...[
              Text(
                state.parserRoute == 'ocr_pdf' ||
                        state.parserRoute == 'ocr_image'
                    ? '内容已通过 OCR 解析'
                    : '内容已解析',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                '解析方式：${_formatRoute(state.parserRoute)} · 版本：revision ${state.revision ?? 1}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ] else if (state.status ==
                LibraryFileArtifactStatus.ocrRecommended) ...[
              const Text(
                '未检测到可提取文本，可能是扫描版 PDF。',
                style: TextStyle(color: Colors.orange),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const ValueKey<String>('file-detail-ocr-button'),
                onPressed: isBusy ? null : () => _handleParse(context),
                icon: const Icon(Icons.psychology_outlined, size: 18),
                label: const Text('使用 OCR 识别'),
              ),
            ] else if (state.status == LibraryFileArtifactStatus.unavailable ||
                state.status == LibraryFileArtifactStatus.failed) ...[
              Text(
                state.errorMessage ?? '文件解析不可用',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                key: const ValueKey<String>('file-detail-parse-button'),
                onPressed: isBusy ? null : () => _handleParse(context),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试解析'),
              ),
            ],
          ],
        ),
      ),
    );
  }
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
        content: const Text(
          '将删除学习空间及其关联。\n\n'
          '• 空间内的文件和题库仅解除关联，不会被删除；\n'
          '• 空间内的对话将保留为历史记录（因原空间删除变为不可用状态），之后仍可移动到全局或其他学习空间；\n'
          '• 此操作无法撤销。',
        ),
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

  void _showRuntimeBoundary(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('关于扩展能力'),
        content: const Text(
          '这里展示已配置的本地只读能力。当前版本尚未提供运行状态检测、启动停止或连接测试。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final capabilities =
        projection.toolNames.map(_describeMcpTool).toList(growable: false);
    return Scaffold(
      key: const ValueKey<String>('u1-ux01-mcp-workspace'),
      appBar: AppBar(
        title: const Text('扩展能力'),
        actions: [
          IconButton(
            key: const ValueKey<String>('mcp-runtime-boundary-help'),
            tooltip: '关于扩展能力',
            onPressed: () => _showRuntimeBoundary(context),
            icon: const Icon(Icons.help_outline_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        children: [
          _McpServerCard(projection: projection),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: Text(
                  '已配置能力',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${capabilities.length}',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final capability in capabilities) ...[
            _McpCapabilityCard(capability: capability),
            const SizedBox(height: 10),
          ],
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded,
                    color: colors.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '能力已配置不代表本地服务进程当前正在运行。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _McpServerCard extends StatelessWidget {
  const _McpServerCard({required this.projection});

  final McpWorkspaceProjection projection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final stateLabel = switch (projection.state) {
      McpCapabilityState.configuredAvailable => '已配置',
    };
    final transportLabel = switch (projection.transport) {
      McpTransport.localStdio => '本地连接',
    };
    final permissionLabel = switch (projection.permission) {
      McpPermission.readOnly => '只读权限',
    };
    return Container(
      key: const ValueKey<String>('mcp-local-server-card'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.dns_outlined, color: colors.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Shiroha 本地数据服务',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '为 Shiroha Agent 提供题库检索与学情分析',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  stateLabel,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Divider(height: 1, color: colors.outlineVariant),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _McpStatusChip(label: transportLabel),
              _McpStatusChip(label: permissionLabel),
              const _McpStatusChip(label: '运行状态未检测'),
            ],
          ),
        ],
      ),
    );
  }
}

class _McpStatusChip extends StatelessWidget {
  const _McpStatusChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: colors.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _McpCapabilityCard extends StatelessWidget {
  const _McpCapabilityCard({required this.capability});

  final _McpCapabilityDescriptor capability;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = capability.accent(colors);
    return Container(
      key: ValueKey<String>('mcp-capability-${capability.toolName}'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(capability.icon, color: accent),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 3,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      capability.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      capability.toolName,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  capability.description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.check_circle_rounded, color: colors.primary, size: 20),
        ],
      ),
    );
  }
}

class _McpCapabilityDescriptor {
  const _McpCapabilityDescriptor({
    required this.toolName,
    required this.title,
    required this.description,
    required this.icon,
    required this.accent,
  });

  final String toolName;
  final String title;
  final String description;
  final IconData icon;
  final Color Function(ColorScheme colors) accent;
}

_McpCapabilityDescriptor _describeMcpTool(String toolName) {
  return switch (toolName) {
    'search_questions' => _McpCapabilityDescriptor(
        toolName: toolName,
        title: '题库检索与定位',
        description: '按关键词和题型查找所需题目。',
        icon: Icons.search_rounded,
        accent: (colors) => colors.primary,
      ),
    'get_study_overview' => _McpCapabilityDescriptor(
        toolName: toolName,
        title: '学情与进度概览',
        description: '查看学习进度、掌握情况与趋势。',
        icon: Icons.trending_up_rounded,
        accent: (colors) => colors.primary,
      ),
    'get_due_review_summary' => _McpCapabilityDescriptor(
        toolName: toolName,
        title: '到期复习统计',
        description: '汇总当前到期复习题目。',
        icon: Icons.event_available_outlined,
        accent: (colors) => colors.tertiary,
      ),
    'get_weak_questions' => _McpCapabilityDescriptor(
        toolName: toolName,
        title: '错题与薄弱项分析',
        description: '定位错题与低掌握知识点。',
        icon: Icons.warning_amber_rounded,
        accent: (colors) => colors.tertiary,
      ),
    'list_question_banks' => _McpCapabilityDescriptor(
        toolName: toolName,
        title: '题库列表',
        description: '查看可用于学习和检索的题库。',
        icon: Icons.library_books_outlined,
        accent: (colors) => colors.primary,
      ),
    'get_question_detail' => _McpCapabilityDescriptor(
        toolName: toolName,
        title: '题目详情',
        description: '读取单道题目的结构化详情。',
        icon: Icons.description_outlined,
        accent: (colors) => colors.primary,
      ),
    _ => _McpCapabilityDescriptor(
        toolName: toolName,
        title: '其他只读能力',
        description: '已配置的本地只读工具。',
        icon: Icons.extension_outlined,
        accent: (colors) => colors.primary,
      ),
  };
}

IconData _fileIcon(String mimeType) {
  if (mimeType == 'application/pdf') return Icons.picture_as_pdf_outlined;
  if (mimeType.startsWith('image/')) return Icons.image_outlined;
  return Icons.description_outlined;
}

String _fileTypeLabel(String mimeType) {
  final normalized = mimeType.trim().toLowerCase();
  return switch (normalized) {
    'application/pdf' => 'PDF',
    'text/markdown' || 'text/x-markdown' => 'Markdown',
    'text/plain' => 'TXT',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document' =>
      'DOCX',
    'image/png' => 'PNG',
    'image/jpeg' => 'JPG',
    _ when normalized.startsWith('image/') => '图片',
    _ => '文件',
  };
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

Future<void> _deleteLibraryFile(
  BuildContext context,
  FileLibraryController controller,
  String fileId,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('永久删除文件？'),
      content: const Text(
        '将删除文件库记录和受管原文件，并解除学习空间、对话及文件夹关联；'
        '当前解析产物也会清理。不会删除用户电脑或外部位置的原始来源文件，'
        '也不会删除已经确认入库的 Questions。此操作不可撤销。\n\n'
        '建议先在数据中心导出备份。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('dm-d5-confirm-delete-library-file'),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('永久删除'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  final success = await controller.deleteFile(fileId);
  if (!context.mounted) return;
  if (!success) {
    _feedback(context, controller.errorMessage!);
    return;
  }

  final result = controller.lastDeletionResult;
  final hasOrphan =
      result?.managedBytesCleanup == LibraryFileManagedBytesCleanup.orphaned ||
          result?.parsedArtifactCleanup ==
              LibraryFileParsedArtifactCleanup.orphaned;
  Navigator.of(context).pop();
  _feedback(
    context,
    hasOrphan ? '文件记录已删除，部分本地清理待处理' : '文件已永久删除',
  );
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
