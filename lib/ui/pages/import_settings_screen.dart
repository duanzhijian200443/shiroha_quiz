import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import '../dependencies/ai_dependencies_scope.dart';
import '../../services/import_pipeline/import_parse_result.dart';
import '../../services/import_pipeline/import_parse_request.dart';
import '../../services/import_pipeline/import_question_field_policy.dart';
import '../../services/import_pipeline/import_task_coordinator.dart';
import '../../main.dart';
import 'paste_text_screen.dart';

typedef ImportFilePicker = Future<FilePickerResult?> Function();
typedef ImportImagePicker = Future<XFile?> Function(ImageSource source);
typedef ImportTaskParser = Future<List<Map<String, dynamic>>> Function(
  String taskId,
);
typedef ImportTaskDispatcher = void Function(
  String sourceDescription,
  ImportTaskParser parseTask,
);

class ImportSettingsScreen extends StatefulWidget {
  const ImportSettingsScreen({
    Key? key,
    this.pickFiles,
    this.pickImage,
    this.taskDispatcher,
    this.requestParser,
    this.retainObjectiveExplanations = false,
    this.onRetainObjectiveExplanationsChanged,
  }) : super(key: key);

  final ImportFilePicker? pickFiles;
  final ImportImagePicker? pickImage;
  final ImportTaskDispatcher? taskDispatcher;
  final ImportRequestParser? requestParser;
  final bool retainObjectiveExplanations;
  final ValueChanged<bool>? onRetainObjectiveExplanationsChanged;

  @override
  State<ImportSettingsScreen> createState() => _ImportSettingsScreenState();
}

class _ImportSettingsScreenState extends State<ImportSettingsScreen> {
  ImportParseMode _selectedMode = ImportParseMode.vision;
  late ExplanationRetentionMode _explanationRetentionMode;
  double _maxConcurrency = 3.0; // 默认多图并发线程
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _explanationRetentionMode = widget.retainObjectiveExplanations
        ? ExplanationRetentionMode.allQuestionTypes
        : ExplanationRetentionMode.subjectiveOnly;
  }

  @override
  void didUpdateWidget(covariant ImportSettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.retainObjectiveExplanations !=
        widget.retainObjectiveExplanations) {
      _explanationRetentionMode = widget.retainObjectiveExplanations
          ? ExplanationRetentionMode.allQuestionTypes
          : ExplanationRetentionMode.subjectiveOnly;
    }
  }

  void _setRetainObjectiveExplanations(bool value) {
    final nextMode = value
        ? ExplanationRetentionMode.allQuestionTypes
        : ExplanationRetentionMode.subjectiveOnly;
    if (_explanationRetentionMode == nextMode) return;
    setState(() => _explanationRetentionMode = nextMode);
    widget.onRetainObjectiveExplanationsChanged?.call(value);
  }

  ImportRequestParser _resolveRequestParser() {
    final requestParser = widget.requestParser;
    if (requestParser != null) return requestParser;
    return AiDependenciesScope.of(context).importPipelineService.parseFiles;
  }

  Future<void> _dispatchBackgroundTask(
    String sourceDesc,
    Future<ImportParseResult> Function(String taskId) parseTask, {
    required ImportParseMode mode,
    required ExplanationRetentionMode explanationRetentionMode,
  }) async {
    final testDispatcher = widget.taskDispatcher;
    if (testDispatcher != null) {
      testDispatcher(
        sourceDesc,
        (taskId) async => (await parseTask(taskId)).questions,
      );
      return;
    }

    final coordinator = ImportTaskCoordinator(
      onReadyForReview: (sourceDescription) {
        rootScaffoldMessengerKey.currentState?.showSnackBar(SnackBar(
          content: Text('$sourceDescription 解析完成，请前往传输中心校对入库'),
          backgroundColor: Colors.orange,
        ));
      },
    );
    await coordinator.dispatch(
      sourceDescription: sourceDesc,
      mode: mode,
      parse: parseTask,
      explanationRetentionMode: explanationRetentionMode,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('🚀 任务已派发！请在首页左上角“传输中心”查看实时进度。'),
        backgroundColor: Colors.blueAccent));
    Navigator.pop(context);
  }

  Future<void> _dispatchIndependentBackgroundTasks(
    List<ImportTaskBatchItem> items,
  ) async {
    final testDispatcher = widget.taskDispatcher;
    if (testDispatcher != null) {
      for (final item in items) {
        testDispatcher(
          item.sourceDescription,
          (taskId) async => (await item.parse(taskId)).questions,
        );
      }
      return;
    }

    final coordinator = ImportTaskCoordinator(
      onReadyForReview: (sourceDescription) {
        rootScaffoldMessengerKey.currentState?.showSnackBar(SnackBar(
          content: Text('$sourceDescription 解析完成，请前往传输中心校对入库'),
          backgroundColor: Colors.orange,
        ));
      },
    );
    await coordinator.dispatchIndependentBatch(items: items);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('🚀 任务已派发！请在首页左上角“传输中心”查看实时进度。'),
        backgroundColor: Colors.blueAccent));
    Navigator.pop(context);
  }

  Future<void> _pickImage(ImageSource source) async {
    if (_selectedMode == ImportParseMode.text) return;

    final selectedMode = _selectedMode;
    final maxConcurrency = _maxConcurrency.toInt();
    final explanationRetentionMode = _explanationRetentionMode;
    try {
      final XFile? image = widget.pickImage != null
          ? await widget.pickImage!(source)
          : await _picker.pickImage(source: source, imageQuality: 85);
      if (image == null) return;
      if (!mounted) return;
      final parseRequest = _resolveRequestParser();
      await _dispatchBackgroundTask('图片识别', (taskId) async {
        final request = ImportParseRequest(
          filePaths: <String>[image.path],
          fileNames: <String>[image.name],
          mode: selectedMode,
          maxConcurrency: maxConcurrency,
          taskId: taskId,
          explanationRetentionMode: explanationRetentionMode,
        );
        return parseRequest(request);
      },
          mode: selectedMode,
          explanationRetentionMode: explanationRetentionMode);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('获取图片失败: $e'), backgroundColor: Colors.redAccent));
      }
    }
  }

  Future<void> _pickAndParseFile() async {
    final selectedMode = _selectedMode;
    final maxConcurrency = _maxConcurrency.toInt();
    final explanationRetentionMode = _explanationRetentionMode;
    final result = widget.pickFiles != null
        ? await widget.pickFiles!()
        : await FilePicker.platform.pickFiles(
            type: FileType.custom,
            allowedExtensions: [
              'pdf',
              'txt',
              'png',
              'jpg',
              'jpeg',
              'docx',
              'md',
              'zip'
            ],
            allowMultiple: true,
          );

    if (result == null || result.files.isEmpty) return;
    if (!mounted) return;

    final incompatibleFiles = result.files
        .where((file) => !_isFileCompatible(file, selectedMode))
        .toList();
    if (incompatibleFiles.isNotEmpty) {
      _showIncompatibleFiles(selectedMode, incompatibleFiles);
      return;
    }
    final parseRequest = _resolveRequestParser();

    final isAllPdfBatch = result.files.length > 1 &&
        result.files.every((file) => _fileExtension(file) == 'pdf');

    if (isAllPdfBatch) {
      final items = result.files
          .map(
            (file) => ImportTaskBatchItem(
              sourceDescription: file.name,
              mode: selectedMode,
              explanationRetentionMode: explanationRetentionMode,
              parse: (taskId) => parseRequest(
                ImportParseRequest(
                  filePaths: <String>[file.path!],
                  fileNames: <String>[file.name],
                  mode: selectedMode,
                  maxConcurrency: maxConcurrency,
                  taskId: taskId,
                  explanationRetentionMode: explanationRetentionMode,
                ),
              ),
            ),
          )
          .toList(growable: false);

      await _dispatchIndependentBackgroundTasks(items);
      return;
    }

    final sourceDescription = result.files.length == 1
        ? result.files.single.name
        : '${result.files.first.name} 等 ${result.files.length} 个文件';

    await _dispatchBackgroundTask(
      sourceDescription,
      (taskId) async => parseRequest(
        ImportParseRequest(
          filePaths: result.files.map((file) => file.path!).toList(),
          fileNames: result.files.map((file) => file.name).toList(),
          mode: selectedMode,
          maxConcurrency: maxConcurrency,
          taskId: taskId,
          explanationRetentionMode: explanationRetentionMode,
        ),
      ),
      mode: selectedMode,
      explanationRetentionMode: explanationRetentionMode,
    );
  }

  bool _isFileCompatible(PlatformFile file, ImportParseMode mode) {
    final extension = _fileExtension(file);
    return switch (mode) {
      ImportParseMode.text =>
        const <String>{'pdf', 'docx', 'txt', 'md', 'zip'}.contains(extension),
      ImportParseMode.vision ||
      ImportParseMode.ocr =>
        const <String>{'pdf', 'png', 'jpg', 'jpeg'}.contains(extension),
    };
  }

  String _fileExtension(PlatformFile file) {
    final declared = file.extension?.trim().toLowerCase();
    if (declared != null && declared.isNotEmpty) return declared;
    final separator = file.name.lastIndexOf('.');
    if (separator < 0 || separator == file.name.length - 1) return '';
    return file.name.substring(separator + 1).toLowerCase();
  }

  void _showIncompatibleFiles(
    ImportParseMode mode,
    List<PlatformFile> files,
  ) {
    final guidance = switch (mode) {
      ImportParseMode.text => '文本模式不支持图片，请改用视觉或 OCR 模式。',
      ImportParseMode.vision => '视觉模式不支持 ZIP、DOCX 或纯文本文件。',
      ImportParseMode.ocr => 'OCR 模式仅支持 PDF、PNG 和 JPG/JPEG。',
    };
    final fileNames = files.map((file) => file.name).join('、');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$guidance\n不兼容文件：$fileNames')),
    );
  }

  Future<void> _pasteAndParse() async {
    final explanationRetentionMode = _explanationRetentionMode;
    final pastedText = await Navigator.push<String>(context,
        MaterialPageRoute(builder: (context) => const PasteTextScreen()));
    if (pastedText != null && pastedText.trim().length >= 10) {
      await _dispatchBackgroundTask('剪贴板注入', (taskId) async {
        return ImportParseResult(
          questions: await AiDependenciesScope.of(context)
              .aiService
              .parseTextToQuestions(pastedText),
          explanationRetentionMode: explanationRetentionMode,
        );
      },
          mode: ImportParseMode.text,
          explanationRetentionMode: explanationRetentionMode);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imageEntriesEnabled = _selectedMode != ImportParseMode.text;
    final clipboardEnabled = _selectedMode == ImportParseMode.text;
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
          title: const Text('导入题目',
              style: TextStyle(fontWeight: FontWeight.bold))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExpansionTile(
              title: const Text('查看标准 JSON 导入格式',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              collapsedBackgroundColor: theme.primaryColor.withOpacity(0.05),
              backgroundColor: theme.primaryColor.withOpacity(0.05),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              collapsedShape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              childrenPadding: const EdgeInsets.all(16),
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: theme.brightness == Brightness.dark
                          ? Colors.black45
                          : Colors.white,
                      borderRadius: BorderRadius.circular(8)),
                  child: const Text(
                      '[\n  {\n    "type": 0,\n    "content": "题干",\n    "options": ["A.", "B."],\n    "standard_answer": "A",\n    "explanation": "解析"\n  }\n]',
                      style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: Colors.blueGrey)),
                ),
              ],
            ),
            const SizedBox(height: 24),
            DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '解析模式',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    _ImportParseModeCard(
                      key: const ValueKey<String>('import-parse-mode-vision'),
                      title: '视觉（推荐）',
                      description: '适合图片、扫描 PDF 与复杂公式',
                      icon: Icons.visibility_rounded,
                      selected: _selectedMode == ImportParseMode.vision,
                      onTap: () => setState(
                        () => _selectedMode = ImportParseMode.vision,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _ImportParseModeCard(
                      key: const ValueKey<String>('import-parse-mode-text'),
                      title: '文本（最快）',
                      description: '适合可提取文字的 PDF 与剪贴板文本',
                      icon: Icons.text_snippet_rounded,
                      selected: _selectedMode == ImportParseMode.text,
                      onTap: () => setState(
                        () => _selectedMode = ImportParseMode.text,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _ImportParseModeCard(
                      key: const ValueKey<String>('import-parse-mode-ocr'),
                      title: 'OCR（扫描）',
                      description: '先识别文字再解析，适合扫描文档',
                      icon: Icons.document_scanner_rounded,
                      selected: _selectedMode == ImportParseMode.ocr,
                      onTap: () => setState(
                        () => _selectedMode = ImportParseMode.ocr,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: theme.colorScheme.outlineVariant.withOpacity(0.7),
                    ),
                    _ObjectiveExplanationRetentionSetting(
                      value: _explanationRetentionMode ==
                          ExplanationRetentionMode.allQuestionTypes,
                      onChanged: _setRetainObjectiveExplanations,
                    ),
                  ],
                ),
              ),
            ),
            if (_selectedMode == ImportParseMode.vision)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4.0, vertical: 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('多图并发线程上限',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.bold)),
                        Text(
                          '${_maxConcurrency.toInt()} 线程',
                          style: TextStyle(
                            fontSize: 13,
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: _maxConcurrency,
                      min: 1,
                      max: 10,
                      divisions: 9,
                      onChanged: (val) => setState(() => _maxConcurrency = val),
                    ),
                    const Text('⚠️ 提示: 并发越高速度越快，若触发大模型 429 频率限制，引擎会自动为您降频。',
                        style: TextStyle(fontSize: 11, color: Colors.grey)),
                  ],
                ),
              ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                    child: ElevatedButton.icon(
                        key: const ValueKey<String>('import-camera-button'),
                        style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            backgroundColor: theme.primaryColor,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor:
                                theme.colorScheme.surfaceContainerHighest,
                            disabledForegroundColor:
                                theme.colorScheme.onSurfaceVariant,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            elevation: 0),
                        icon: const Icon(Icons.camera_alt_rounded),
                        label: const Text('拍照识别',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.bold)),
                        onPressed: imageEntriesEnabled
                            ? () => _pickImage(ImageSource.camera)
                            : null)),
                const SizedBox(width: 12),
                Expanded(
                    child: ElevatedButton.icon(
                        key: const ValueKey<String>('import-gallery-button'),
                        style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            backgroundColor: theme.primaryColor,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor:
                                theme.colorScheme.surfaceContainerHighest,
                            disabledForegroundColor:
                                theme.colorScheme.onSurfaceVariant,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            elevation: 0),
                        icon: const Icon(Icons.photo_library_rounded),
                        label: const Text('相册选图',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.bold)),
                        onPressed: imageEntriesEnabled
                            ? () => _pickImage(ImageSource.gallery)
                            : null)),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey<String>('import-file-button'),
              style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  foregroundColor: theme.primaryColor,
                  side: BorderSide(color: theme.primaryColor.withOpacity(0.3)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
              icon: const Icon(Icons.folder_open_rounded),
              label: const Text('从文件管理器选择 (PDF/ZIP)',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              onPressed: _pickAndParseFile,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey<String>('import-clipboard-button'),
              style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  foregroundColor: theme.primaryColor,
                  disabledForegroundColor: theme.colorScheme.onSurfaceVariant,
                  side: BorderSide(
                    color: clipboardEnabled
                        ? theme.primaryColor.withOpacity(0.3)
                        : theme.colorScheme.outlineVariant,
                  ),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
              icon: const Icon(Icons.content_paste),
              label: const Text('从剪贴板粘贴文本解析',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              onPressed: clipboardEnabled ? _pasteAndParse : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _ObjectiveExplanationRetentionSetting extends StatelessWidget {
  const _ObjectiveExplanationRetentionSetting({
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Semantics(
      container: true,
      button: true,
      toggled: value,
      label: '保留选择题与填空题解析',
      hint: '关闭时仅导入题干、选项和标准答案',
      child: InkWell(
        key: const ValueKey<String>('retain-objective-explanations-row'),
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 80,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            '保留选择题与填空题解析',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: colorScheme.primary.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '推荐关闭',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colorScheme.primary,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '关闭时仅导入题干、选项和标准答案',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '开启后会保留详细解析，可能增加处理时间和校对问题',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ExcludeSemantics(
                child: Switch(
                  key: const ValueKey<String>(
                    'retain-objective-explanations-switch',
                  ),
                  value: value,
                  onChanged: onChanged,
                  activeThumbColor: colorScheme.onPrimary,
                  activeTrackColor: colorScheme.primary,
                  inactiveThumbColor: colorScheme.outline,
                  inactiveTrackColor: colorScheme.surfaceContainerHighest,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImportParseModeCard extends StatelessWidget {
  const _ImportParseModeCard({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String description;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      button: true,
      label: '$title，$description',
      child: Material(
        color: selected ? colorScheme.primaryContainer : colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected ? colorScheme.primary : colorScheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  icon,
                  color: selected
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: selected
                                  ? colorScheme.onPrimaryContainer
                                  : colorScheme.onSurface,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        description,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: selected
                                  ? colorScheme.onPrimaryContainer
                                  : colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: selected
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
