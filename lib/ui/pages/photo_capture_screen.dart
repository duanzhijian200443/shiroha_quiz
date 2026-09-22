import 'dart:typed_data';
import '../../domain/content/rich_content.dart';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../application/import/import_advanced_preferences.dart';
import '../../application/practice/photo_answer_judgement.dart';
import '../../services/import_pipeline/import_question_field_policy.dart';
import '../../services/import_pipeline/import_parse_request.dart';
import '../dependencies/ai_dependencies_scope.dart';
import '../widgets/photo_answer_transcription.dart';

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
    this.importPreferencesLoader,
  })  : purpose = PhotoCapturePurpose.questionImport,
        photoAnswerJudgement = null,
        questionKind = null,
        question = null,
        standardAnswer = null;

  const PhotoCaptureScreen.subjectiveAnswer({
    super.key,
    this.pickPhoto,
    required this.photoAnswerJudgement,
    required this.questionKind,
    required this.question,
    required this.standardAnswer,
  })  : purpose = PhotoCapturePurpose.subjectiveAnswer,
        onRecognitionRequested = null,
        importPreferencesLoader = null;

  final PhotoCapturePurpose purpose;
  final PhotoPicker? pickPhoto;
  final PhotoRecognitionDispatcher? onRecognitionRequested;
  final PhotoAnswerJudgementPort? photoAnswerJudgement;
  final PhotoAnswerQuestionKind? questionKind;
  final RichContent? question;
  final RichContent? standardAnswer;
  final ImportAdvancedPreferencesLoader? importPreferencesLoader;

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

      if (widget.purpose == PhotoCapturePurpose.subjectiveAnswer) {
        final recognition = widget.photoAnswerJudgement;
        if (recognition == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('答案识别暂不可用，请稍后重试。')),
          );
          return;
        }
        final recognizedText =
            await Navigator.of(context).push<ConfirmedPhotoAnswer>(
          MaterialPageRoute<ConfirmedPhotoAnswer>(
            builder: (_) => PhotoRecognitionConfirmationScreen.subjectiveAnswer(
              image: image,
              recognition: recognition,
              questionKind: widget.questionKind!,
              question: widget.question!,
              standardAnswer: widget.standardAnswer!,
            ),
          ),
        );
        if (!mounted || recognizedText == null) return;
        Navigator.of(context).pop(recognizedText);
      } else {
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
      }
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
    final preferencesLoader =
        widget.importPreferencesLoader ?? dependencies.importPreferencesLoader!;
    final preferences = await preferencesLoader();
    final maxConcurrency = preferences.effectiveOcrTaskConcurrency;
    await dependencies.importTaskCoordinator.dispatch(
      sourceDescription: '图片识别',
      mode: mode,
      explanationRetentionMode: explanationRetentionMode,
      allowAutoOpenReview: true,
      parse: (taskId) => dependencies.importPipelineService.parseFiles(
        ImportParseRequest(
          filePaths: <String>[image.path],
          fileNames: <String>[image.name],
          mode: mode,
          maxConcurrency: maxConcurrency,
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
                    widget.purpose == PhotoCapturePurpose.subjectiveAnswer
                        ? '拍照作答'
                        : '仅拍照，不识别',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    widget.purpose == PhotoCapturePurpose.subjectiveAnswer
                        ? '拍摄后由 AI 结合题目和标准答案理解并判定你的作答'
                        : '拍照后进入「确认照片与识别模式」',
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
  })  : purpose = PhotoCapturePurpose.questionImport,
        photoAnswerJudgement = null,
        questionKind = null,
        question = null,
        standardAnswer = null;

  const PhotoRecognitionConfirmationScreen.subjectiveAnswer({
    super.key,
    required this.image,
    required PhotoAnswerJudgementPort recognition,
    required this.questionKind,
    required this.question,
    required this.standardAnswer,
    this.loadBytes,
  })  : purpose = PhotoCapturePurpose.subjectiveAnswer,
        onRecognitionRequested = null,
        photoAnswerJudgement = recognition;

  final XFile image;
  final PhotoCapturePurpose purpose;
  final PhotoRecognitionDispatcher? onRecognitionRequested;
  final PhotoAnswerJudgementPort? photoAnswerJudgement;
  final PhotoAnswerQuestionKind? questionKind;
  final RichContent? question;
  final RichContent? standardAnswer;
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
  PhotoAnswerJudgementResult? _judgement;
  PhotoAnswerJudgementRequest get _request => PhotoAnswerJudgementRequest(
      imagePath: widget.image.path,
      imageName: widget.image.name,
      kind: widget.questionKind!,
      question: widget.question!,
      standardAnswer: widget.standardAnswer!);

  @override
  void initState() {
    super.initState();
    _imageBytes = widget.loadBytes?.call() ?? widget.image.readAsBytes();
  }

  Future<void> _startRecognition() async {
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);
    try {
      if (widget.purpose == PhotoCapturePurpose.subjectiveAnswer) {
        if (_judgement != null) {
          Navigator.of(context).pop(
              ConfirmedPhotoAnswer(request: _request, result: _judgement!));
          return;
        }
        final result = await widget.photoAnswerJudgement!.judge(_request);
        if (!mounted) return;
        if (!result.isSuccess) {
          setState(() => _isSubmitting = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_failureMessage(result.failure!))),
          );
          return;
        }
        setState(() {
          _judgement = result;
          _isSubmitting = false;
        });
      } else {
        await widget.onRecognitionRequested!(widget.image, _selectedMode);
        if (!mounted) return;
        Navigator.of(context).pop(true);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('识别任务启动失败，请稍后重试。')),
      );
    }
  }

  String _failureMessage(PhotoAnswerJudgementFailure failure) =>
      switch (failure) {
        PhotoAnswerJudgementFailure.contextAssetUnavailable =>
          '题目或标准答案中的图片资源不可用，暂时无法进行拍照判题。',
        PhotoAnswerJudgementFailure.contextUnsupported =>
          '题目或标准答案包含暂不支持的内容，无法进行拍照判题。',
        PhotoAnswerJudgementFailure.engineUnavailable => '未配置支持图片理解的 AI 模型',
        PhotoAnswerJudgementFailure.invalidInput => '图片或题目信息无效，请重新拍摄或改用文字输入',
        PhotoAnswerJudgementFailure.timeout => 'AI 判题超时，请稍后重试',
        PhotoAnswerJudgementFailure.malformedResponse => 'AI 返回的判题格式无效，请重试',
        PhotoAnswerJudgementFailure.outputTooLong => 'AI 返回内容过长，请重试',
        PhotoAnswerJudgementFailure.providerFailure => 'AI 判题失败，请稍后重试',
      };

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
                child: _judgement != null
                    ? ListView(children: [
                        const Text('已识别你的答案',
                            style: TextStyle(
                                fontSize: 20, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 16),
                        if (_judgement!.transcription.trim().isEmpty)
                          const Text('答案包含无法文本化的内容，请核对原照片后提交。')
                        else
                          PhotoAnswerTranscription(
                              text: _judgement!.transcription),
                        if (_judgement!.decision ==
                            PhotoAnswerDecision.uncertain)
                          const Text('AI 无法可靠判断这张作答图片。建议重新拍摄或改用文字输入。'),
                        FutureBuilder<Uint8List>(
                            future: _imageBytes,
                            builder: (context, snapshot) => snapshot.hasData
                                ? Image.memory(snapshot.data!,
                                    height: 180,
                                    cacheWidth: 720,
                                    errorBuilder: (_, __, ___) =>
                                        const Text('无法预览照片'))
                                : const SizedBox()),
                      ])
                    : ClipRRect(
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
                  if (widget.purpose == PhotoCapturePurpose.questionImport) ...[
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
                label: Text(_judgement == null ? '开始识别' : '提交答案'),
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
