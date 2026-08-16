import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../application/backup/backup_contracts.dart';
import '../../../application/backup/backup_restore_coordinator.dart';
import '../../../domain/backup/backup_failure.dart';
import '../../../domain/backup/backup_manifest.dart';

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
          '恢复将替换当前本机 Shiroha 数据。\n\n'
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
    final busy = _state != _BackupUiState.idle &&
        _state != _BackupUiState.readyToConfirm &&
        _state != _BackupUiState.failed &&
        _state != _BackupUiState.success;
    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            Text(
              'Shiroha 备份',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text('导出为 .shiroha 文件；恢复会替换当前本机数据，不会上传或合并。'),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: busy ? null : _export,
              icon: const Icon(Icons.save_alt),
              label: const Text('导出备份'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: busy || _prepared ? null : _pickRestore,
              icon: const Icon(Icons.settings_backup_restore),
              label: const Text('恢复备份'),
            ),
            if (_preview != null &&
                _state == _BackupUiState.readyToConfirm) ...<Widget>[
              const SizedBox(height: 20),
              const Divider(),
              Text('备份信息', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Text('包版本：${_preview!.packageVersion}'),
              Text('数据版本：${_preview!.schemaVersion}'),
              Text('文件数：${_preview!.fileCount}'),
              Text('大小：${_formatBytes(_preview!.totalSizeBytes)}'),
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
            if (busy) ...<Widget>[
              const SizedBox(height: 24),
              const Center(child: CircularProgressIndicator()),
            ],
            if (_message != null) ...<Widget>[
              const SizedBox(height: 20),
              Text(_message!, textAlign: TextAlign.center),
            ],
          ],
        ),
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
