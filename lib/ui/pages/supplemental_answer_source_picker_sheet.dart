import 'package:flutter/material.dart';

import '../../application/supplemental_answers/supplemental_answer_activation_service.dart';
import '../../application/supplemental_answers/supplemental_answer_failure.dart';
import '../../application/supplemental_answers/supplemental_answer_review_session.dart';
import '../../application/u1_workspace/u1_workspace_dtos.dart';
import '../../domain/supplemental_answers/supplemental_answer_scope.dart';

/// Opens the bounded File Library source picker for one P6 target scope.
///
/// Resolves to the started review session, or to null when the user cancels.
Future<SupplementalAnswerReviewSession?> showSupplementalAnswerSourcePicker({
  required BuildContext context,
  required SupplementalAnswerActivationService service,
  required SupplementalAnswerTargetScope targetScope,
}) {
  return showModalBottomSheet<SupplementalAnswerReviewSession>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SupplementalAnswerSourcePickerSheet(
      service: service,
      targetScope: targetScope,
    ),
  );
}

/// Bounded P6 supplemental-source picker.
///
/// It selects exactly one already-managed `LibraryFile` and starts the existing
/// P6 matching session through the Application activation seam. It never opens
/// the system file picker, never uploads, never parses/OCRs, and mutates
/// nothing when the user cancels or when activation fails.
class SupplementalAnswerSourcePickerSheet extends StatefulWidget {
  const SupplementalAnswerSourcePickerSheet({
    super.key,
    required this.service,
    required this.targetScope,
  });

  final SupplementalAnswerActivationService service;
  final SupplementalAnswerTargetScope targetScope;

  @override
  State<SupplementalAnswerSourcePickerSheet> createState() =>
      _SupplementalAnswerSourcePickerSheetState();
}

class _SupplementalAnswerSourcePickerSheetState
    extends State<SupplementalAnswerSourcePickerSheet> {
  late Future<List<LibraryFileSummary>> _files;
  String? _errorMessage;
  String? _startingFileId;

  @override
  void initState() {
    super.initState();
    _files = widget.service.listSupplementalFiles();
  }

  void _retryLoad() {
    setState(() {
      _files = widget.service.listSupplementalFiles();
      _errorMessage = null;
    });
  }

  Future<void> _start(LibraryFileSummary file) async {
    if (_startingFileId != null) return;
    setState(() {
      _startingFileId = file.fileId;
      _errorMessage = null;
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
                '选择文件库中一份已经解析好的补充答案 / 解析资料。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              if (_errorMessage case final message?) ...[
                const SizedBox(height: 12),
                _ErrorBanner(message: message),
              ],
              const SizedBox(height: 12),
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
                              onPressed: _retryLoad,
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      );
                    }
                    final files = snapshot.data ?? const <LibraryFileSummary>[];
                    if (files.isEmpty) {
                      return const _SheetNotice(
                        child: Text('文件库中还没有可用文件，请先在文件库中上传并解析后再试。'),
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
                          onTap: _startingFileId == null
                              ? () => _start(file)
                              : null,
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
