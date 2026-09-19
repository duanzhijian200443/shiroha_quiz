import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../application/backup/backup_contracts.dart';
import '../../../application/backup/backup_restore_coordinator.dart';
import '../../../domain/backup/backup_failure.dart';
import '../../../domain/backup/backup_manifest.dart';
import '../../theme/design_tokens.dart';

enum _BackupUiState {
  idle,
  exporting,
  validatingRestore,
  readyToConfirm,
  restoring,
  success,
  failed,
}

class BackupRestoreScreen extends StatefulWidget {
  const BackupRestoreScreen({
    super.key,
    required this.backupRestore,
    required this.onRestoreCompleted,
  });

  final BackupRestoreCoordinator backupRestore;
  final VoidCallback onRestoreCompleted;

  @override
  State<BackupRestoreScreen> createState() => _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends State<BackupRestoreScreen> {
  _BackupUiState _state = _BackupUiState.idle;
  String? _message;
  BackupRestorePreview? _preview;
  String? _packagePath;

  bool get _prepared => widget.backupRestore.preparedRestore != null;

  @override
  void initState() {
    super.initState();
    final prepared = widget.backupRestore.preparedRestore;
    if (prepared != null) {
      _preview = prepared.preview;
      _state = _BackupUiState.readyToConfirm;
    }
  }

  bool get _commitStarted => _state == _BackupUiState.restoring;

  Future<void> _export() async {
    final destination = await FilePicker.platform.saveFile(
      dialogTitle: '导出 Shiroha 备份',
      fileName: 'shiroha_backup.shiroha',
      type: FileType.custom,
      allowedExtensions: const <String>['shiroha'],
    );
    if (destination == null || !mounted) return;
    setState(() {
      _state = _BackupUiState.exporting;
      _message = null;
    });
    try {
      final summary = await widget.backupRestore.exportTo(destination);
      if (!mounted) return;
      setState(() {
        _state = _BackupUiState.success;
        _message = '备份已导出：${summary.fileName}（${summary.fileCount} 个文件）';
      });
    } catch (error) {
      if (!mounted) return;
      _fail(error);
    }
  }

  Future<void> _pickRestore() async {
    if (_prepared) return;
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 .shiroha 备份文件',
      type: FileType.custom,
      allowedExtensions: const <String>['shiroha'],
    );
    final path = picked?.files.single.path;
    if (path == null || !mounted || _prepared) return;
    setState(() {
      _state = _BackupUiState.validatingRestore;
      _message = null;
    });
    try {
      final preview = await widget.backupRestore.inspectPackage(path);
      if (!mounted) return;
      setState(() {
        _packagePath = path;
        _preview = preview;
        _state = _BackupUiState.readyToConfirm;
      });
    } catch (error) {
      if (!mounted) return;
      _fail(error);
    }
  }

  Future<void> _confirmRestore() async {
    final preview = _preview;
    final packagePath = _packagePath;
    if (_prepared || preview == null || packagePath == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复备份？'),
        content: Text(
          '恢复将覆盖当前本机 Shiroha 数据，不会自动合并。\n\n'
          '包版本：${preview.packageVersion}\n'
          '数据版本：${preview.schemaVersion}\n'
          '创建时间：${preview.createdAtUtc.toLocal()}\n'
          '文件数：${preview.fileCount}\n'
          '大小：${_formatBytes(preview.totalSizeBytes)}',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _prepared) return;

    setState(() {
      _state = _BackupUiState.validatingRestore;
      _message = null;
    });
    try {
      await widget.backupRestore.prepareRestore(packagePath);
      if (!mounted) return;
      setState(() {
        _preview = widget.backupRestore.preparedRestore?.preview;
        _packagePath = null;
        _state = _BackupUiState.readyToConfirm;
      });
    } catch (error) {
      if (!mounted) return;
      _fail(error);
    }
  }

  Future<void> _commitRestore() async {
    if (widget.backupRestore.preparedRestore == null) return;
    setState(() {
      _state = _BackupUiState.restoring;
      _message = null;
    });
    try {
      final result = await widget.backupRestore.commitPreparedRestore();
      if (!mounted) return;
      setState(() {
        _state = _BackupUiState.success;
        _message = '恢复成功（${result.fileCount} 个文件）';
      });
      widget.onRestoreCompleted();
    } catch (error) {
      if (!mounted) return;
      _fail(error);
    }
  }

  Future<void> _cancelStaged() async {
    try {
      await widget.backupRestore.cancelPreparedRestore();
      if (!mounted) return;
      setState(() {
        _state = _BackupUiState.idle;
        _preview = null;
        _packagePath = null;
        _message = '已取消恢复，当前数据未改变';
      });
    } catch (error) {
      if (!mounted) return;
      _fail(error);
    }
  }

  void _fail(Object error) {
    final failure = error is BackupException ? error.failure : null;
    final message = switch (failure) {
      BackupFailure.invalidPackage => '备份文件无效',
      BackupFailure.unsupportedPackageVersion => '备份版本过新',
      BackupFailure.unsupportedSchemaVersion => '数据库版本过新',
      BackupFailure.integrityMismatch => '备份文件已损坏',
      BackupFailure.resourceLimitExceeded => '存储空间不足',
      BackupFailure.rollbackFailed => '恢复失败，需要维护处理',
      BackupFailure.restoreBlocked => '恢复维护中，暂时无法操作',
      BackupFailure.restoreBusy => '已有备份/恢复任务正在进行',
      BackupFailure.journalInvalid => '恢复记录无效，需要维护处理',
      _ => '操作失败，请稍后重试',
    };
    setState(() {
      _state = _BackupUiState.failed;
      _message = message;
    });
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final busy = _state != _BackupUiState.idle &&
        _state != _BackupUiState.readyToConfirm &&
        _state != _BackupUiState.failed &&
        _state != _BackupUiState.success;
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('备份与数据管理')),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: DesignTokens.contentMaxWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                DesignTokens.pageHorizontalPadding,
                DesignTokens.pageHorizontalPadding,
                DesignTokens.pageHorizontalPadding,
                DesignTokens.pageBottomPadding,
              ),
              children: <Widget>[
                const _BackupSectionTitle('全量备份与迁移'),
                const SizedBox(height: 8),
                _BackupSurface(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: colors.primary.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(
                                  DesignTokens.prominentIconContainerRadius,
                                ),
                              ),
                              child: Icon(
                                Icons.cloud_upload_outlined,
                                color: colors.primary,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Shiroha 全量备份',
                                    style: TextStyle(
                                      color: colors.onSurface,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '备份全部本地学习数据与设置',
                                    style: TextStyle(
                                      color: colors.onSurfaceVariant,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            TextButton(
                              key: const ValueKey<String>(
                                'backup-restore-picker',
                              ),
                              onPressed:
                                  busy || _prepared ? null : _pickRestore,
                              child: const Text('从备份恢复'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Text(
                          '恢复会覆盖现有本机数据，不会上传或自动合并。',
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          key: const ValueKey<String>('backup-export-button'),
                          onPressed: busy ? null : _export,
                          icon: const Icon(Icons.save_alt_outlined),
                          label: const Text('导出全量备份 (.shiroha)'),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_preview != null &&
                    _state == _BackupUiState.readyToConfirm) ...<Widget>[
                  const SizedBox(height: DesignTokens.sectionGap),
                  const _BackupSectionTitle('恢复预检查'),
                  const SizedBox(height: 8),
                  _BackupSurface(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '备份信息',
                            style: TextStyle(
                              color: colors.onSurface,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 10),
                          _BackupDetailRow(
                            label: '包版本',
                            value: '${_preview!.packageVersion}',
                          ),
                          _BackupDetailRow(
                            label: '数据版本',
                            value: '${_preview!.schemaVersion}',
                          ),
                          _BackupDetailRow(
                            label: '文件数',
                            value: '${_preview!.fileCount}',
                          ),
                          _BackupDetailRow(
                            label: '大小',
                            value: _formatBytes(_preview!.totalSizeBytes),
                          ),
                          const SizedBox(height: 16),
                          if (!_prepared)
                            FilledButton.icon(
                              onPressed: _confirmRestore,
                              icon: const Icon(Icons.verified_outlined),
                              label: const Text('验证并准备恢复'),
                            )
                          else
                            FilledButton.icon(
                              onPressed: _commitRestore,
                              icon: const Icon(Icons.swap_horiz),
                              label: const Text('开始恢复'),
                            ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: _commitStarted ? null : _cancelStaged,
                            child: const Text('取消'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (busy) ...<Widget>[
                  const SizedBox(height: DesignTokens.sectionGap),
                  const Center(child: CircularProgressIndicator()),
                ],
                if (_message != null) ...<Widget>[
                  const SizedBox(height: 20),
                  Text(
                    _message!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _state == _BackupUiState.failed
                          ? colors.error
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: DesignTokens.sectionGap),
                const _BackupSectionTitle('题库分发与导入'),
                const SizedBox(height: 8),
                _BackupSurface(
                  child: ListTile(
                    key: const ValueKey<String>(
                      'structured-bank-import-unavailable',
                    ),
                    contentPadding: const EdgeInsets.all(
                      DesignTokens.cardInternalPadding,
                    ),
                    leading: Icon(
                      Icons.inventory_2_outlined,
                      color: colors.onSurfaceVariant,
                    ),
                    title: const Text('导入结构化题库包'),
                    subtitle: const Text('暂未开放'),
                    trailing: const Icon(Icons.lock_outline_rounded),
                    enabled: false,
                  ),
                ),
                const SizedBox(height: DesignTokens.sectionGap),
                const _BackupSectionTitle('存储空间与清理'),
                const SizedBox(height: 8),
                const _BackupSurface(
                  child: Padding(
                    padding: EdgeInsets.all(
                      DesignTokens.cardInternalPadding,
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.storage_outlined),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text('本地存储统计'),
                              SizedBox(height: 4),
                              Text('当前版本尚无可信的统一空间统计 authority'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: DesignTokens.sectionGap),
                const _BackupSectionTitle('危险区域'),
                const SizedBox(height: 8),
                Container(
                  key: const ValueKey<String>('clear-all-data-unavailable'),
                  padding: const EdgeInsets.all(
                    DesignTokens.cardInternalPadding,
                  ),
                  decoration: BoxDecoration(
                    color: colors.errorContainer,
                    borderRadius: BorderRadius.circular(
                      DesignTokens.cardRadius,
                    ),
                    border: Border.all(color: colors.error),
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.delete_forever_outlined, color: colors.error),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '清空所有本地数据',
                              style: TextStyle(
                                color: colors.onErrorContainer,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '暂不可用；完整安全清理能力将在独立版本提供。',
                              style: TextStyle(color: colors.onErrorContainer),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.lock_outline, color: colors.error),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BackupSectionTitle extends StatelessWidget {
  const _BackupSectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _BackupSurface extends StatelessWidget {
  const _BackupSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(DesignTokens.cardRadius),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: DesignTokens.surfaceShadow(theme.brightness),
      ),
      child: child,
    );
  }
}

class _BackupDetailRow extends StatelessWidget {
  const _BackupDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text('$label：', style: TextStyle(color: colors.onSurfaceVariant)),
          const Spacer(),
          Text(value, style: TextStyle(color: colors.onSurface)),
        ],
      ),
    );
  }
}

class BackupMaintenanceScreen extends StatelessWidget {
  const BackupMaintenanceScreen({super.key, this.diagnosticId});

  final String? diagnosticId;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.settings_backup_restore, size: 48),
                const SizedBox(height: 16),
                const Text('恢复维护中'),
                const SizedBox(height: 8),
                const Text('上次恢复未完成且无法自动还原，请保留本页面并联系维护。'),
                if (diagnosticId != null) ...<Widget>[
                  const SizedBox(height: 12),
                  Text('诊断编号：$diagnosticId'),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
