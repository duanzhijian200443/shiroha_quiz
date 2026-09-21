import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../../application/import/import_advanced_preferences.dart';
import '../../application/import/import_processing_policy_resolver.dart';
import '../../data/repositories/settings_repository.dart';
import '../dependencies/ai_dependencies_scope.dart';
import '../theme/design_tokens.dart';
import '../../services/import_pipeline/import_parse_result.dart';
import '../../services/import_pipeline/import_parse_request.dart';
import '../../services/import_pipeline/import_question_field_policy.dart';
import '../../services/import_pipeline/import_task_coordinator.dart';
import 'import_advanced_settings_screen.dart';
import 'paste_text_screen.dart';

typedef ImportFilePicker = Future<FilePickerResult?> Function();
typedef ImportTaskParser = Future<List<Map<String, dynamic>>> Function(
  String taskId,
);
typedef ImportTaskDispatcher = void Function(
  String sourceDescription,
  ImportTaskParser parseTask,
);

/// Extension sets the pipeline actually accepts per parse mode.
///
/// These are the same lists [ImportSettingsScreen] hands to the file picker and
/// enforces after selection, so the helper text under the file action can never
/// promise a format the pipeline rejects.
const List<String> importOcrSupportedExtensions = <String>[
  'pdf',
  'png',
  'jpg',
  'jpeg',
];

const List<String> importTextSupportedExtensions = <String>[
  'pdf',
  'docx',
  'txt',
  'md',
  'zip',
];

/// The document import entry.
///
/// This screen owns batch document intake only: PDF, text document, archive and
/// image ingestion through the OCR and text-direct read routes. Single-question
/// photo capture is a separate product entry (`PhotoCaptureScreen`), which is
/// why no vision mode, camera action or gallery action is exposed here.
class ImportSettingsScreen extends StatefulWidget {
  const ImportSettingsScreen({
    super.key,
    this.pickFiles,
    this.taskDispatcher,
    this.requestParser,
    this.importPreferencesLoader,
  });

  final ImportFilePicker? pickFiles;
  final ImportTaskDispatcher? taskDispatcher;
  final ImportRequestParser? requestParser;
  final ImportAdvancedPreferencesLoader? importPreferencesLoader;

  @override
  State<ImportSettingsScreen> createState() => _ImportSettingsScreenState();
}

class _ImportSettingsScreenState extends State<ImportSettingsScreen> {
  /// Documents and scans are this page's main material, so OCR is the default.
  ImportParseMode _selectedMode = ImportParseMode.ocr;

  ImportRequestParser _resolveRequestParser() {
    final requestParser = widget.requestParser;
    if (requestParser != null) return requestParser;
    return AiDependenciesScope.of(context).importPipelineService.parseFiles;
  }

  Future<void> _dispatchBackgroundTask(
    String sourceDesc,
    Future<ImportParseResult> Function(String taskId) parseTask, {
    required ImportParseMode mode,
  }) async {
    final testDispatcher = widget.taskDispatcher;
    if (testDispatcher != null) {
      testDispatcher(
        sourceDesc,
        (taskId) async => (await parseTask(taskId)).questions,
      );
      return;
    }

    final coordinator = AiDependenciesScope.of(context).importTaskCoordinator;
    await coordinator.dispatch(
      sourceDescription: sourceDesc,
      mode: mode,
      parse: parseTask,
      explanationRetentionMode: newDocumentImportExplanationRetentionMode,
      documentImportEntry: true,
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

    final coordinator = AiDependenciesScope.of(context).importTaskCoordinator;
    await coordinator.dispatchIndependentBatch(items: items);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('🚀 任务已派发！请在首页左上角“传输中心”查看实时进度。'),
        backgroundColor: Colors.blueAccent));
    Navigator.pop(context);
  }

  List<String> get _supportedExtensions => switch (_selectedMode) {
        ImportParseMode.ocr => importOcrSupportedExtensions,
        ImportParseMode.text => importTextSupportedExtensions,
        ImportParseMode.vision => importOcrSupportedExtensions,
      };

  Future<int> _resolveOcrMaxConcurrency() async {
    final preferencesLoader = widget.importPreferencesLoader;
    final preferences = preferencesLoader != null
        ? await preferencesLoader()
        : await SettingsRepository.instance.getImportAdvancedPreferences();
    return const ImportProcessingPolicyResolver()
        .resolve(preferences.processingStrategy)
        .effectiveOcrConcurrency;
  }

  Future<void> _pickAndParseFile() async {
    final selectedMode = _selectedMode;
    final result = widget.pickFiles != null
        ? await widget.pickFiles!()
        : await FilePicker.platform.pickFiles(
            type: FileType.custom,
            allowedExtensions: _supportedExtensions,
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
    final maxConcurrency = await _resolveOcrMaxConcurrency();
    if (!mounted) return;

    final isAllPdfBatch = result.files.length > 1 &&
        result.files.every((file) => _fileExtension(file) == 'pdf');

    if (isAllPdfBatch) {
      final items = result.files
          .map(
            (file) => ImportTaskBatchItem(
              sourceDescription: file.name,
              mode: selectedMode,
              explanationRetentionMode:
                  newDocumentImportExplanationRetentionMode,
              documentImportEntry: true,
              parse: (taskId) => parseRequest(
                ImportParseRequest(
                  filePaths: <String>[file.path!],
                  fileNames: <String>[file.name],
                  mode: selectedMode,
                  maxConcurrency: maxConcurrency,
                  taskId: taskId,
                  explanationRetentionMode:
                      newDocumentImportExplanationRetentionMode,
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
          explanationRetentionMode: newDocumentImportExplanationRetentionMode,
        ),
      ),
      mode: selectedMode,
    );
  }

  bool _isFileCompatible(PlatformFile file, ImportParseMode mode) {
    final extension = _fileExtension(file);
    return switch (mode) {
      ImportParseMode.text => importTextSupportedExtensions.contains(extension),
      ImportParseMode.vision ||
      ImportParseMode.ocr =>
        importOcrSupportedExtensions.contains(extension),
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
      ImportParseMode.text => '图片无法使用文本直读，请改用 OCR 扫描或拍照识题。',
      ImportParseMode.vision ||
      ImportParseMode.ocr =>
        'OCR 扫描仅支持 PDF 和图片；文本类文档请使用文本直读。',
    };
    final fileNames = files.map((file) => file.name).join('、');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$guidance\n不兼容文件：$fileNames')),
    );
  }

  /// Pasted text always means text-direct parsing.
  ///
  /// The clipboard is an independent text import action: it is never a
  /// disabled variant of the currently selected mode, so choosing OCR does not
  /// take it away.
  Future<void> _pasteAndParse() async {
    final pastedText = await Navigator.push<String>(context,
        MaterialPageRoute(builder: (context) => const PasteTextScreen()));
    if (pastedText != null && pastedText.trim().length >= 10) {
      await _dispatchBackgroundTask('剪贴板注入', (taskId) async {
        return ImportParseResult(
          questions: await AiDependenciesScope.of(context)
              .aiService
              .parseTextToQuestions(pastedText),
          explanationRetentionMode: newDocumentImportExplanationRetentionMode,
        );
      }, mode: ImportParseMode.text);
    }
  }

  void _openAdvancedSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ImportAdvancedSettingsScreen(
          preferencesLoader: widget.importPreferencesLoader,
        ),
      ),
    );
  }

  void _showJsonImportFormat() {
    showDialog<void>(
      context: context,
      builder: (context) => const _JsonImportFormatDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
          title: const Text('导入题目',
              style: TextStyle(fontWeight: FontWeight.bold))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(DesignTokens.pageHorizontalPadding),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: DesignTokens.contentMaxWidth,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildParseModeSection(theme),
                const SizedBox(height: DesignTokens.sectionGap),
                _buildImportSourceSection(theme),
                const SizedBox(height: DesignTokens.sectionGap),
                _buildFooterActions(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildParseModeSection(ThemeData theme) {
    return _ImportSection(
      title: '解析模式',
      children: [
        _ImportParseModeCard(
          key: const ValueKey<String>('import-parse-mode-ocr'),
          title: 'OCR 扫描',
          description: '适用于扫描版 PDF、图片及无法直接提取文字的文档。',
          icon: Icons.document_scanner_rounded,
          selected: _selectedMode == ImportParseMode.ocr,
          onTap: () => setState(() => _selectedMode = ImportParseMode.ocr),
        ),
        const SizedBox(height: 10),
        _ImportParseModeCard(
          key: const ValueKey<String>('import-parse-mode-text'),
          title: '文本直读',
          description: '适用于可提取文字的 PDF 与纯文本内容，直接读取文字并解析，不经过 OCR，速度更快。',
          icon: Icons.text_snippet_rounded,
          selected: _selectedMode == ImportParseMode.text,
          onTap: () => setState(() => _selectedMode = ImportParseMode.text),
        ),
        const SizedBox(height: 14),
        _ImportInfoNotice(
          icon: Icons.info_outline_rounded,
          text: '单题拍照识别请前往「拍照识题」入口。',
          theme: theme,
        ),
      ],
    );
  }

  Widget _buildImportSourceSection(ThemeData theme) {
    return _ImportSection(
      title: '导入来源',
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            key: const ValueKey<String>('import-file-button'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 18),
              backgroundColor: theme.colorScheme.primaryContainer,
              foregroundColor: theme.colorScheme.onPrimaryContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(DesignTokens.cardRadius),
              ),
            ),
            icon: const Icon(Icons.folder_open_rounded),
            label: const Text(
              '从文件管理器选择',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            onPressed: _pickAndParseFile,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _fileSupportHint(),
          key: const ValueKey<String>('import-file-support-hint'),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const ValueKey<String>('import-clipboard-button'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              foregroundColor: theme.colorScheme.primary,
              side: BorderSide(
                color: theme.colorScheme.primary.withValues(alpha: 0.3),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(DesignTokens.cardRadius),
              ),
            ),
            icon: const Icon(Icons.content_paste_rounded),
            label: const Text(
              '从剪贴板粘贴文本',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            onPressed: _pasteAndParse,
          ),
        ),
      ],
    );
  }

  String _fileSupportHint() {
    final extensions =
        _supportedExtensions.map((value) => value.toUpperCase()).join(' / ');
    return '当前模式可读：$extensions';
  }

  Widget _buildFooterActions(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(
          height: 1,
          thickness: 1,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: TextButton.icon(
                key: const ValueKey<String>('import-advanced-settings-entry'),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.onSurfaceVariant,
                  alignment: Alignment.centerLeft,
                ),
                icon: const Icon(Icons.settings_outlined, size: 18),
                label: const Text('高级设置'),
                onPressed: _openAdvancedSettings,
              ),
            ),
            Expanded(
              child: TextButton.icon(
                key: const ValueKey<String>('import-json-format-entry'),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.onSurfaceVariant,
                  alignment: Alignment.centerRight,
                ),
                icon: const Icon(Icons.description_outlined, size: 18),
                label: const Text('查看标准 JSON 导入格式'),
                onPressed: _showJsonImportFormat,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// One titled group of related controls.
class _ImportSection extends StatelessWidget {
  const _ImportSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(DesignTokens.cardRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.all(DesignTokens.cardInternalPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// A quiet informational line: never an affordance, never a disabled control.
class _ImportInfoNotice extends StatelessWidget {
  const _ImportInfoNotice({
    required this.icon,
    required this.text,
    required this.theme,
  });

  final IconData icon;
  final String text;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest
            .withValues(alpha: theme.brightness == Brightness.dark ? 0.4 : 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _JsonImportFormatDialog extends StatelessWidget {
  const _JsonImportFormatDialog();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('标准 JSON 导入格式'),
      content: SingleChildScrollView(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.brightness == Brightness.dark
                ? Colors.black45
                : Colors.white,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const SelectableText(
            '[\n  {\n    "type": 0,\n    "content": "题干",\n    "options": ["A.", "B."],\n    "standard_answer": "A",\n    "explanation": "解析"\n  }\n]',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: Colors.blueGrey,
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
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
