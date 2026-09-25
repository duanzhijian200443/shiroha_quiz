import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../application/supplemental_answers/supplemental_answer_activation_service.dart';
import '../../application/supplemental_answers/supplemental_answer_failure.dart';
import '../../application/supplemental_answers/supplemental_answer_review_session.dart';
import '../../application/supplemental_answers/supplemental_answer_source_acquisition_service.dart';
import '../../application/u1_workspace/u1_workspace_dtos.dart';
import '../../domain/supplemental_answers/supplemental_answer_scope.dart';
import '../dependencies/supplemental_answer_dependencies_scope.dart';

/// Opens the bounded supplemental-source picker for one P6 target scope.
///
/// Resolves to the started review session, or to null when the user cancels.
Future<SupplementalAnswerReviewSession?> showSupplementalAnswerSourcePicker({
  required BuildContext context,
  required SupplementalAnswerActivationService service,
  required SupplementalAnswerSourceAcquisitionService sourceAcquisition,
  required SupplementalAnswerTargetScope targetScope,
  SupplementalAnswerFilePicker? pickFile,
}) {
  return showModalBottomSheet<SupplementalAnswerReviewSession>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SupplementalAnswerSourcePickerSheet(
      service: service,
      sourceAcquisition: sourceAcquisition,
      targetScope: targetScope,
      pickFile: pickFile,
    ),
  );
}

/// Bounded P6 supplemental-source picker.
///
/// Two ways in:
///
/// - **添加答案文件** adds one external file the user explicitly picked. The
///   file enters the File Library through the existing F0 ingestion, is parsed
///   deterministically through the existing F1 lifecycle, and then reaches the
///   existing P6 session. A scanned PDF needs one explicit OCR decision first;
///   `auto` never degrades into OCR.
/// - **从资料库选择** reuses the frozen existing-file path: it starts a session
///   from the file's current artifact and never ensures, reparses, or OCRs.
///
/// The sheet never uploads implicitly, never picks more than one file, and
/// mutates nothing when the user cancels or when an operation fails.
class SupplementalAnswerSourcePickerSheet extends StatefulWidget {
  const SupplementalAnswerSourcePickerSheet({
    super.key,
    required this.service,
    required this.sourceAcquisition,
    required this.targetScope,
    this.pickFile,
  });

  final SupplementalAnswerActivationService service;
  final SupplementalAnswerSourceAcquisitionService sourceAcquisition;
  final SupplementalAnswerTargetScope targetScope;
  final SupplementalAnswerFilePicker? pickFile;

  @override
  State<SupplementalAnswerSourcePickerSheet> createState() =>
      _SupplementalAnswerSourcePickerSheetState();
}

class _SupplementalAnswerSourcePickerSheetState
    extends State<SupplementalAnswerSourcePickerSheet> {
  late Future<List<LibraryFileSummary>> _files;
  String? _errorMessage;
  String? _noticeMessage;
  String? _busyLabel;
  String? _startingFileId;
  bool _picking = false;

  bool get _busy => _busyLabel != null || _startingFileId != null || _picking;

  @override
  void initState() {
    super.initState();
    _files = widget.service.listSupplementalFiles();
  }

  void _reloadFiles() {
    setState(() {
      _files = widget.service.listSupplementalFiles();
    });
  }

  void _onPhase(SupplementalAnswerSourcePhase phase) {
    if (!mounted) return;
    setState(() {
      _busyLabel = switch (phase) {
        SupplementalAnswerSourcePhase.ingesting => '正在添加文件…',
        SupplementalAnswerSourcePhase.preparing => '正在解析内容…',
        SupplementalAnswerSourcePhase.matching => '正在匹配答案…',
      };
    });
  }

  Future<void> _addNewFile() async {
    if (_busy) return;
    setState(() {
      _picking = true;
      _errorMessage = null;
      _noticeMessage = null;
    });

    final FilePickerResult? result;
    try {
      result = await (widget.pickFile?.call() ??
          FilePicker.platform.pickFiles(
            allowMultiple: false,
            type: FileType.custom,
            allowedExtensions: supplementalAnswerSourceFileExtensions,
          ));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _picking = false;
        _errorMessage = _messageForSourceFailure(
          SupplementalAnswerSourceFailure.unreadableFile,
        );
      });
      return;
    }
    if (!mounted) return;

    final selected =
        (result == null || result.files.isEmpty) ? null : result.files.single;
    final externalPath = selected?.path;
    if (selected == null) {
      setState(() => _picking = false);
      return;
    }
    if (externalPath == null) {
      setState(() {
        _picking = false;
        _errorMessage = _messageForSourceFailure(
          SupplementalAnswerSourceFailure.unreadableFile,
        );
      });
      return;
    }

    setState(() {
      _picking = false;
      _busyLabel = '正在添加文件…';
    });
    final outcome = await widget.sourceAcquisition.addSourceAndStart(
      targetScope: widget.targetScope,
      externalPath: externalPath,
      displayName: selected.name,
      onPhase: _onPhase,
    );
    if (!mounted) return;
    await _handleOutcome(outcome);
  }

  Future<void> _startExistingFile(LibraryFileSummary file) async {
    if (_busy) return;
    setState(() {
      _startingFileId = file.fileId;
      _errorMessage = null;
      _noticeMessage = null;
    });
    try {
      final session = await widget.service.startSession(
        targetScope: widget.targetScope,
        supplementalFileId: file.fileId,
      );
      if (!mounted) return;
      Navigator.of(context).pop(session);
    } on SupplementalAnswerException catch (error) {
      if (!mounted) return;
      setState(() {
        _startingFileId = null;
        _errorMessage = _messageFor(error.failure);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _startingFileId = null;
        _errorMessage = '发生内部错误，请稍后重试。';
      });
    }
  }

  Future<void> _handleOutcome(SupplementalAnswerSourceOutcome outcome) async {
    switch (outcome) {
      case SupplementalAnswerSourceReady(:final session):
        setState(() => _busyLabel = null);
        Navigator.of(context).pop(session);
      case SupplementalAnswerSourceOcrRequired(:final fileId):
        setState(() => _busyLabel = null);
        _reloadFiles();
        final confirmed = await _confirmOcr();
        if (!mounted) return;
        if (confirmed != true) {
          setState(() {
            _noticeMessage = '已取消 OCR 识别。该文件已添加到文件库，可稍后解析。';
          });
          return;
        }
        setState(() => _busyLabel = '正在解析内容…');
        final next = await widget.sourceAcquisition.continueWithOcr(
          targetScope: widget.targetScope,
          fileId: fileId,
          onPhase: _onPhase,
        );
        if (!mounted) return;
        await _handleOutcome(next);
      case SupplementalAnswerSourceFailed(:final failure):
        setState(() {
          _busyLabel = null;
          _errorMessage = _messageForSourceFailure(failure);
        });
    }
  }

  /// The canonical OCR-UX confirmation: OCR happens only after this explicit
  /// user decision, and cancelling keeps the ingested file untouched.
  Future<bool?> _confirmOcr() {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey<String>('supplemental-ocr-dialog'),
        title: const Text('未检测到可提取文本'),
        content: const Text(
          '这个 PDF 可能是扫描版。\n'
          '是否使用 OCR 识别文件内容？\n\n'
          '继续后，文件内容会发送到当前配置的 OCR 服务。\n'
          'OCR 只用于生成可检索的文件内容，不会自动生成或修改题目。',
        ),
        actions: [
          TextButton(
            key: const ValueKey<String>('supplemental-ocr-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey<String>('supplemental-ocr-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('使用 OCR'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: size.height * 0.7),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '从文件补充答案',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              const Text(
                '添加一份新的答案 / 解析文件，或从文件库中选择已有的解析资料。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const ValueKey<String>('supplemental-add-file-button'),
                  onPressed: _busy ? null : _addNewFile,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加答案文件'),
                ),
              ),
              if (_busyLabel case final busyLabel?) ...[
                const SizedBox(height: 10),
                Row(
                  key: const ValueKey<String>(
                    'supplemental-direct-source-busy',
                  ),
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      busyLabel,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ],
              if (_noticeMessage case final notice?) ...[
                const SizedBox(height: 10),
                _NoticeBanner(message: notice),
              ],
              if (_errorMessage case final message?) ...[
                const SizedBox(height: 10),
                _ErrorBanner(message: message),
              ],
              const SizedBox(height: 8),
              const Row(
                children: [
                  Expanded(child: Divider()),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      '或从资料库选择',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                  Expanded(child: Divider()),
                ],
              ),
              const SizedBox(height: 8),
              Flexible(
                child: FutureBuilder<List<LibraryFileSummary>>(
                  future: _files,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const _SheetNotice(
                        child: CircularProgressIndicator(),
                      );
                    }
                    if (snapshot.hasError) {
                      return _SheetNotice(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('文件库暂时不可用，请稍后重试。'),
                            const SizedBox(height: 8),
                            TextButton(
                              onPressed: _reloadFiles,
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      );
                    }
                    final files = snapshot.data ?? const <LibraryFileSummary>[];
                    if (files.isEmpty) {
                      return const _SheetNotice(
                        child: Text('文件库中还没有文件，可先添加一份答案文件。'),
                      );
                    }
                    return ListView.separated(
                      shrinkWrap: true,
                      itemCount: files.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final file = files[index];
                        final starting = _startingFileId == file.fileId;
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.description_outlined),
                          title: Text(
                            file.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${file.mimeType} · ${_formatSize(file.sizeBytes)}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: starting
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.arrow_forward_ios, size: 14),
                          onTap: _busy ? null : () => _startExistingFile(file),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _messageFor(SupplementalAnswerFailure failure) {
  return switch (failure) {
    SupplementalAnswerFailure.sourceUnavailable => '该文件尚未完成内容解析，请先在文件库中解析后再试。',
    SupplementalAnswerFailure.artifactCorrupt => '该文件的解析结果不可用，请重新解析后再试。',
    SupplementalAnswerFailure.unsupportedArtifact => '当前解析结果暂不支持补充答案。',
    SupplementalAnswerFailure.noUsableAnswers => '没有从该文件中找到可用于匹配的答案。',
    SupplementalAnswerFailure.targetUnavailable => '当前题库没有可用于补充答案的结构化题目。',
    SupplementalAnswerFailure.temporarilyUnavailable => '暂时无法完成匹配，请稍后重试。',
    SupplementalAnswerFailure.internalError => '发生内部错误，请稍后重试。',
    SupplementalAnswerFailure.ambiguousMatch ||
    SupplementalAnswerFailure.unmatched ||
    SupplementalAnswerFailure.conflict ||
    SupplementalAnswerFailure.staleTarget ||
    SupplementalAnswerFailure.invalidCandidate =>
      '暂时无法完成匹配，请稍后重试。',
  };
}

String _messageForSourceFailure(SupplementalAnswerSourceFailure failure) {
  return switch (failure) {
    SupplementalAnswerSourceFailure.unreadableFile => '无法读取所选文件，请重新选择。',
    SupplementalAnswerSourceFailure.unsupportedFile => '当前文件类型暂不支持补充答案。',
    SupplementalAnswerSourceFailure.ingestionFailed => '无法添加文件，请确认文件可读取后重试。',
    SupplementalAnswerSourceFailure.parseFailed => '文件解析失败，请稍后重试。',
    SupplementalAnswerSourceFailure.ocrUnavailable =>
      '当前 OCR 服务不可用，请检查 OCR 引擎配置后重试。',
    SupplementalAnswerSourceFailure.artifactCorrupt => '该文件的解析结果不可用，请重新解析后再试。',
    SupplementalAnswerSourceFailure.unsupportedArtifact => '当前解析结果暂不支持补充答案。',
    SupplementalAnswerSourceFailure.noUsableAnswers => '没有从该文件中找到可用于匹配的答案。',
    SupplementalAnswerSourceFailure.targetUnavailable => '当前题库没有可用于补充答案的结构化题目。',
    SupplementalAnswerSourceFailure.temporarilyUnavailable => '暂时无法完成匹配，请稍后重试。',
    SupplementalAnswerSourceFailure.internalError => '发生内部错误，请稍后重试。',
  };
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class _SheetNotice extends StatelessWidget {
  const _SheetNotice({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(child: child),
    );
  }
}

class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: const TextStyle(fontSize: 13),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)),
      ),
      child: Text(
        message,
        style: const TextStyle(color: Colors.redAccent, fontSize: 13),
      ),
    );
  }
}
