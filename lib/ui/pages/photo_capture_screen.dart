import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../services/import_pipeline/import_question_field_policy.dart';
import '../../services/import_pipeline/import_parse_request.dart';
import '../dependencies/ai_dependencies_scope.dart';

typedef PhotoPicker = Future<XFile?> Function(ImageSource source);
typedef PhotoRecognitionDispatcher = Future<void> Function(
  XFile image,
  ImportParseMode mode,
);
typedef PhotoBytesLoader = Future<Uint8List> Function();

enum PhotoCapturePurpose { questionImport, subjectiveAnswer }

class PhotoCaptureScreen extends StatefulWidget {
  const PhotoCaptureScreen({
    super.key,
    this.pickPhoto,
    this.onRecognitionRequested,
  }) : purpose = PhotoCapturePurpose.questionImport;

  const PhotoCaptureScreen.subjectiveAnswer({
    super.key,
    this.pickPhoto,
    required PhotoRecognitionDispatcher dispatcher,
  })  : purpose = PhotoCapturePurpose.subjectiveAnswer,
        onRecognitionRequested = dispatcher;

  final PhotoCapturePurpose purpose;
  final PhotoPicker? pickPhoto;
  final PhotoRecognitionDispatcher? onRecognitionRequested;

  @override
  State<PhotoCaptureScreen> createState() => _PhotoCaptureScreenState();
}

class _PhotoCaptureScreenState extends State<PhotoCaptureScreen> {
  final ImagePicker _picker = ImagePicker();
  bool _isPicking = false;

  String get _title => switch (widget.purpose) {
        PhotoCapturePurpose.questionImport => '拍照识题',
        PhotoCapturePurpose.subjectiveAnswer => '拍照作答',
      };

  String get _guidance => switch (widget.purpose) {
        PhotoCapturePurpose.questionImport => '对准试题，尽量完整拍入',
        PhotoCapturePurpose.subjectiveAnswer => '对准手写答案，尽量完整拍入',
      };

  Future<void> _pick(ImageSource source) async {
    if (_isPicking) return;
    setState(() => _isPicking = true);
    try {
      final image = widget.pickPhoto != null
          ? await widget.pickPhoto!(source)
          : await _picker.pickImage(source: source);
      if (!mounted || image == null) return;

      final completed = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => PhotoRecognitionConfirmationScreen(
            image: image,
            onRecognitionRequested:
                widget.onRecognitionRequested ?? _dispatchRecognition,
          ),
        ),
      );
      if (!mounted || completed != true) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法获取照片，请重试。')),
      );
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  Future<void> _dispatchRecognition(
    XFile image,
    ImportParseMode mode,
  ) async {
    final dependencies = AiDependenciesScope.of(context);
    const explanationRetentionMode = ExplanationRetentionMode.subjectiveOnly;
    await dependencies.importTaskCoordinator.dispatch(
      sourceDescription: '图片识别',
      mode: mode,
      explanationRetentionMode: explanationRetentionMode,
      parse: (taskId) => dependencies.importPipelineService.parseFiles(
        ImportParseRequest(
          filePaths: <String>[image.path],
          fileNames: <String>[image.name],
          mode: mode,
          maxConcurrency: 3,
          taskId: taskId,
          explanationRetentionMode: explanationRetentionMode,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: Container(
                key: const ValueKey<String>('photo-capture-preview-shell'),
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                decoration: BoxDecoration(
                  color: const Color(0xFF071019),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Icon(
                      Icons.document_scanner_outlined,
                      size: 88,
                      color: colors.primary.withValues(alpha: 0.72),
                    ),
                    Positioned(
                      left: 24,
                      right: 24,
                      bottom: 22,
                      child: Text(
                        _guidance,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton.filledTonal(
                    key: const ValueKey<String>('photo-gallery-action'),
                    tooltip: '从相册选择',
                    onPressed:
                        _isPicking ? null : () => _pick(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined),
                  ),
                  Semantics(
                    button: true,
                    label: '拍摄照片',
                    child: InkResponse(
                      key: const ValueKey<String>('photo-shutter-action'),
                      onTap:
                          _isPicking ? null : () => _pick(ImageSource.camera),
                      radius: 40,
                      child: Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: colors.primary,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colors.onSurface,
                            width: 4,
                          ),
                        ),
                        child: _isPicking
                            ? Padding(
                                padding: const EdgeInsets.all(22),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: colors.onPrimary,
                                ),
                              )
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: colors.outlineVariant),
              ),
              child: Column(
                children: [
                  Text(
                    '仅拍照，不识别',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '拍照后进入「确认照片与识别模式」',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PhotoRecognitionConfirmationScreen extends StatefulWidget {
  const PhotoRecognitionConfirmationScreen({
    super.key,
    required this.image,
    required this.onRecognitionRequested,
    this.loadBytes,
  });

  final XFile image;
  final PhotoRecognitionDispatcher onRecognitionRequested;
  final PhotoBytesLoader? loadBytes;

  @override
  State<PhotoRecognitionConfirmationScreen> createState() =>
      _PhotoRecognitionConfirmationScreenState();
}

class _PhotoRecognitionConfirmationScreenState
    extends State<PhotoRecognitionConfirmationScreen> {
  static const int _previewMaxDecodeDimension = 1440;

  ImportParseMode _selectedMode = ImportParseMode.ocr;
  late final Future<Uint8List> _imageBytes;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _imageBytes = widget.loadBytes?.call() ?? widget.image.readAsBytes();
  }

  Future<void> _startRecognition() async {
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);
    try {
      await widget.onRecognitionRequested(widget.image, _selectedMode);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('识别任务启动失败，请稍后重试。')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('确认照片')),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: ColoredBox(
                    color: const Color(0xFF071019),
                    child: SizedBox.expand(
                      child: FutureBuilder<Uint8List>(
                        future: _imageBytes,
                        builder: (context, snapshot) {
                          if (snapshot.hasData) {
                            return Image(
                              image: ResizeImage(
                                MemoryImage(snapshot.data!),
                                width: _previewMaxDecodeDimension,
                                height: _previewMaxDecodeDimension,
                                policy: ResizeImagePolicy.fit,
                              ),
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                            );
                          }
                          if (snapshot.hasError) {
                            return const Center(
                              child: Text(
                                '无法预览照片',
                                style: TextStyle(color: Colors.white70),
                              ),
                            );
                          }
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey<String>('photo-retake-action'),
                      onPressed:
                          _isSubmitting ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重新拍摄'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _RecognitionModeCard(
                      key: const ValueKey<String>('photo-mode-ocr'),
                      title: 'OCR',
                      subtitle: '文字识别',
                      icon: Icons.document_scanner_outlined,
                      color: colors.primary,
                      selected: _selectedMode == ImportParseMode.ocr,
                      onTap: _isSubmitting
                          ? null
                          : () => setState(
                                () => _selectedMode = ImportParseMode.ocr,
                              ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _RecognitionModeCard(
                      key: const ValueKey<String>('photo-mode-vision'),
                      title: '多模态',
                      subtitle: '视觉理解',
                      icon: Icons.visibility_outlined,
                      color: colors.secondary,
                      selected: _selectedMode == ImportParseMode.vision,
                      onTap: _isSubmitting
                          ? null
                          : () => setState(
                                () => _selectedMode = ImportParseMode.vision,
                              ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                key: const ValueKey<String>('photo-start-recognition-action'),
                onPressed: _isSubmitting ? null : _startRecognition,
                icon: _isSubmitting
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.onPrimary,
                        ),
                      )
                    : const Icon(Icons.arrow_forward_rounded),
                label: const Text('开始识别'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecognitionModeCard extends StatelessWidget {
  const _RecognitionModeCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: '$title，$subtitle',
      child: Material(
        color: selected ? color.withValues(alpha: 0.12) : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected ? color : colors.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Column(
              children: [
                Icon(icon, color: selected ? color : colors.onSurfaceVariant),
                const SizedBox(height: 5),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: selected ? color : colors.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: selected ? color : colors.onSurfaceVariant,
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
