import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/observability/app_logger.dart';
import '../../core/observability/trace_context.dart';
import '../../services/ai_service.dart';
import '../../services/task_manager.dart';
import '../../services/import_pipeline/import_pipeline_service.dart';
import '../../services/import_pipeline/import_parse_request.dart';
import '../../main.dart';
import 'paste_text_screen.dart';

class ImportSettingsScreen extends StatefulWidget {
  const ImportSettingsScreen({Key? key}) : super(key: key);
  @override
  State<ImportSettingsScreen> createState() => _ImportSettingsScreenState();
}

class _ImportSettingsScreenState extends State<ImportSettingsScreen> {
  bool _useVisionEngine = false;
  double _maxConcurrency = 3.0; // 默认多图并发线程
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
  }

  // 核心重构：对接全局 TaskManager 的后台任务派发器
  void _dispatchBackgroundTask(String sourceDesc,
      Future<List<Map<String, dynamic>>> Function(String taskId) parseTask) {
    // 1. 生成工单并抛入全局管家
    final taskId = 'task_' + DateTime.now().millisecondsSinceEpoch.toString();
    TaskManager.instance.addTask(ImportTask(
      id: taskId,
      title: '文档解析任务: $sourceDesc',
      progressText: '已进入后台队列...',
      percent: 0.1,
    ));

    // 2. 瞬间退回上一页，解脱 UI 阻塞
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('🚀 任务已派发！请在首页左上角“传输中心”查看实时进度。'),
        backgroundColor: Colors.blueAccent));
    Navigator.pop(context);

    // 3. 在独立微任务队列中执行耗时大模型解析
    Future.microtask(() => TraceContext.run(
          taskId: taskId,
          action: () async {
            AppLogger.info(
              'Background import dispatched',
              module: 'Import',
              data: <String, Object?>{'source': sourceDesc},
            );
            try {
              TaskManager.instance
                  .updateProgress(taskId, '正在呼叫 AI 引擎进行多模态解析...', 0.4);

              final parsedQuestions = await AppLogger.span(
                'Import parsing',
                () => parseTask(taskId),
                module: 'Import',
                data: <String, Object?>{'source': sourceDesc},
              );

              if (parsedQuestions.isEmpty) {
                AppLogger.warning(
                  'Import produced no questions',
                  module: 'Import',
                  data: <String, Object?>{'source': sourceDesc},
                );
                TaskManager.instance.failTask(taskId, '解析完毕，但未提取到任何题目');
                return;
              }

              // 核心热修复：不再强行入库！转交管家进行状态挂起
              TaskManager.instance.requireReview(
                  taskId, '解析成功！请点击此处进行人工校对并入库', parsedQuestions, '', '');

              AppLogger.info(
                'Import is ready for review',
                module: 'Import',
                data: <String, Object?>{
                  'source': sourceDesc,
                  'questionCount': parsedQuestions.length,
                },
              );
              rootScaffoldMessengerKey.currentState?.showSnackBar(SnackBar(
                  content: Text('🔔 $sourceDesc 解析完成，请前往左上角【传输中心】校对入库！'),
                  backgroundColor: Colors.orange));
            } catch (error, stackTrace) {
              AppLogger.error(
                'Background import failed',
                module: 'Import',
                error: error,
                stackTrace: stackTrace,
                data: <String, Object?>{'source': sourceDesc},
              );
              TaskManager.instance.failTask(taskId, error.toString());
            }
          },
        ));
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? image =
          await _picker.pickImage(source: source, imageQuality: 85);
      if (image == null) return;
      _dispatchBackgroundTask('图片识别', (taskId) async {
        return await AiService.instance.parseFileWithVision(image.path);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('获取图片失败: $e'), backgroundColor: Colors.redAccent));
      }
    }
  }

  Future<void> _pickAndParseFile() async {
    final result = await FilePicker.platform.pickFiles(
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

    // 如果是单文件，显示其名称；多文件则显示“多文件合并导入”
    final String sourceDesc = result.files.length == 1
        ? result.files.first.name
        : '多文件自动拼合 (${result.files.length}个)';

    _dispatchBackgroundTask(sourceDesc, (taskId) async {
      final request = ImportParseRequest(
        filePaths: result.files.map((e) => e.path!).toList(),
        fileNames: result.files.map((e) => e.name).toList(),
        useVisionEngine: _useVisionEngine,
        maxConcurrency: _maxConcurrency.toInt(),
        taskId: taskId,
      );

      final parseResult =
          await ImportPipelineService.instance.parseFiles(request);
      final questions = parseResult.questions;

      if (questions.isEmpty) {
        String errorMsg = '未能成功提取题目。请检查原文件是否包含足够清晰的题目结构。';
        if (parseResult.warnings.isNotEmpty) {
          errorMsg += '\n\n诊断警告:\n' + parseResult.warnings.join('\n');
        }
        if (parseResult.diagnostics.isNotEmpty) {
          debugPrint('Import Diagnostics: ${parseResult.diagnostics}');
          errorMsg += '\n\nDiagnostics:\n' +
              _formatDiagnostics(parseResult.diagnostics).join('\n');
        }

        // Attach structured diagnostics before failing so UI can show details
        TaskManager.instance.attachDiagnostics(
          taskId,
          warnings: parseResult.warnings,
          diagnostics: parseResult.diagnostics,
        );
        TaskManager.instance.failTask(taskId, errorMsg);
        return [];
      }

      TaskManager.instance.attachDiagnostics(
        taskId,
        warnings: parseResult.warnings,
        diagnostics: parseResult.diagnostics,
      );

      return _attachImportDiagnostics(
        questions,
        warnings: parseResult.warnings,
        diagnostics: parseResult.diagnostics,
      );
    });
  }

  List<Map<String, dynamic>> _attachImportDiagnostics(
    List<Map<String, dynamic>> questions, {
    required List<String> warnings,
    required Map<String, dynamic> diagnostics,
  }) {
    if (warnings.isEmpty && diagnostics.isEmpty) return questions;

    final result = questions.map((q) => Map<String, dynamic>.from(q)).toList();
    result[0]['_import_diagnostics'] = [
      ...warnings,
      ..._formatDiagnostics(diagnostics),
    ];
    return result;
  }

  List<String> _formatDiagnostics(Map<String, dynamic> diagnostics) {
    final result = <String>[];
    void _flatten(Map<String, dynamic> map, String prefix) {
      for (final entry in map.entries) {
        final val = entry.value;
        if (val is Map<String, dynamic>) {
          _flatten(
              val, prefix.isEmpty ? '${entry.key} ' : '$prefix${entry.key} ');
        } else if (val is List) {
          for (var item in val) {
            result
                .add('${prefix.isEmpty ? "" : "[$prefix] "}${item.toString()}');
          }
        } else {
          result.add(
              '${prefix.isEmpty ? "" : "[$prefix] "}${entry.key}: ${val.toString()}');
        }
      }
    }

    _flatten(diagnostics, '');
    return result;
  }

  Future<void> _pasteAndParse() async {
    final pastedText = await Navigator.push<String>(context,
        MaterialPageRoute(builder: (context) => const PasteTextScreen()));
    if (pastedText != null && pastedText.trim().length >= 10) {
      _dispatchBackgroundTask('剪贴板注入', (taskId) async {
        return await AiService.instance.parseTextToQuestions(pastedText);
      });
    }
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
            SwitchListTile(
              title: const Text('深度视觉解析 (慢速/极高精度)',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              subtitle: const Text('包含代码截图或复杂公式的 PDF/图片 请开启。',
                  style: TextStyle(fontSize: 12)),
              value: _useVisionEngine,
              activeColor: Colors.purpleAccent,
              contentPadding: EdgeInsets.zero,
              onChanged: (val) => setState(() => _useVisionEngine = val),
            ),
            if (_useVisionEngine)
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
                        Text('${_maxConcurrency.toInt()} 线程',
                            style: const TextStyle(
                                fontSize: 13,
                                color: Colors.purpleAccent,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                    Slider(
                      value: _maxConcurrency,
                      min: 1,
                      max: 10,
                      divisions: 9,
                      activeColor: Colors.purpleAccent,
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
                        style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            backgroundColor: theme.primaryColor,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            elevation: 0),
                        icon: const Icon(Icons.camera_alt_rounded),
                        label: const Text('拍照识别',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.bold)),
                        onPressed: () => _pickImage(ImageSource.camera))),
                const SizedBox(width: 12),
                Expanded(
                    child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            backgroundColor: theme.primaryColor,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            elevation: 0),
                        icon: const Icon(Icons.photo_library_rounded),
                        label: const Text('相册选图',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.bold)),
                        onPressed: () => _pickImage(ImageSource.gallery))),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
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
              style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  foregroundColor: theme.primaryColor,
                  side: BorderSide(color: theme.primaryColor.withOpacity(0.3)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
              icon: const Icon(Icons.content_paste),
              label: const Text('从剪贴板粘贴文本解析',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              onPressed: _pasteAndParse,
            ),
          ],
        ),
      ),
    );
  }
}
