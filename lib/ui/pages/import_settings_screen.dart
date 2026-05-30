import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:docx_to_text/docx_to_text.dart';
import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:convert';
import '../../services/ai_service.dart';
import '../../services/task_manager.dart';
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
  void _dispatchBackgroundTask(String sourceDesc, Future<List<Map<String, dynamic>>> Function(String taskId) parseTask) {
    // 1. 生成工单并抛入全局管家
    final taskId = 'task_' + DateTime.now().millisecondsSinceEpoch.toString();
    TaskManager.instance.addTask(ImportTask(
      id: taskId,
      title: '文档解析任务: $sourceDesc',
      progressText: '已进入后台队列...',
      percent: 0.1,
    ));

    // 2. 瞬间退回上一页，解脱 UI 阻塞
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('🚀 任务已派发！请在首页左上角“传输中心”查看实时进度。'), backgroundColor: Colors.blueAccent)
    );
    Navigator.pop(context);

    // 3. 在独立微任务队列中执行耗时大模型解析
    Future.microtask(() async {
      try {
        TaskManager.instance.updateProgress(taskId, '正在呼叫 AI 引擎进行多模态解析...', 0.4);
        
        final parsedQuestions = await parseTask(taskId);
        
        if (parsedQuestions.isEmpty) {
          TaskManager.instance.failTask(taskId, '解析完毕，但未提取到任何题目');
          return;
        }

        // 核心热修复：不再强行入库！转交管家进行状态挂起
        TaskManager.instance.requireReview(
          taskId, 
          '解析成功！请点击此处进行人工校对并入库', 
          parsedQuestions, 
          '', 
          ''
        );

        rootScaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text('🔔 $sourceDesc 解析完成，请前往左上角【传输中心】校对入库！'), backgroundColor: Colors.orange)
        );
      } catch (e) {
        TaskManager.instance.failTask(taskId, e.toString());
      }
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(source: source, imageQuality: 85);
      if (image == null) return;
      _dispatchBackgroundTask('图片识别', (taskId) async {
        return await AiService.instance.parseFileWithVision(image.path);
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('获取图片失败: $e'), backgroundColor: Colors.redAccent));
    }
  }

  Future<void> _pickAndParseFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'txt', 'png', 'jpg', 'jpeg', 'docx', 'md', 'zip'],
      allowMultiple: true,
    );

    if (result == null || result.files.isEmpty) return;
    
    // 如果是单文件，显示其名称；多文件则显示“多文件合并导入”
    final String sourceDesc = result.files.length == 1 
        ? result.files.first.name 
        : '多文件自动拼合 (${result.files.length}个)';

    _dispatchBackgroundTask(sourceDesc, (taskId) async {
      List<Map<String, dynamic>> allParsedQuestions = [];

      List<List<Map<String, dynamic>>> fileResults = [];

      // 遍历所有文件，分别独立解析以获取结构化数据
      for (int fileIdx = 0; fileIdx < result.files.length; fileIdx++) {
        final filePath = result.files[fileIdx].path!;
        final lowerPath = filePath.toLowerCase();
        List<Map<String, dynamic>> singleFileQuestions = [];
        
        TaskManager.instance.updateProgress(taskId, '正在解析第 ${fileIdx + 1}/${result.files.length} 个文件...', 0.1 + (fileIdx / result.files.length) * 0.7);

        if (_useVisionEngine) {
          List<String> imagePaths = [];
          if (lowerPath.endsWith('.pdf')) {
            final tempDir = await getTemporaryDirectory();
            final document = await pdfx.PdfDocument.openFile(filePath);
            final pageCount = document.pagesCount;
            for (int i = 1; i <= pageCount; i++) {
              final page = await document.getPage(i);
              final pageImage = await page.render(width: page.width * 2, height: page.height * 2, format: pdfx.PdfPageImageFormat.jpeg);
              if (pageImage != null) {
                final imgFile = File('${tempDir.path}/file_${fileIdx}_page_$i.jpg');
                await imgFile.writeAsBytes(pageImage.bytes);
                imagePaths.add(imgFile.path);
              }
              await page.close();
            }
            await document.close();
          } else {
            imagePaths.add(filePath);
          }
          
          int maxConcurrency = _maxConcurrency.toInt();
          List<String> pendingImages = List.from(imagePaths);
          TaskManager.instance.appendPendingChunks(taskId, 'vision', pendingImages);
          while (pendingImages.isNotEmpty) {
            List<Future<void>> workers = [];
            int currentWorkers = maxConcurrency;
            if (currentWorkers > pendingImages.length) currentWorkers = pendingImages.length;
            for (int i = 0; i < currentWorkers; i++) {
              workers.add(() async {
                while (pendingImages.isNotEmpty) {
                  final path = pendingImages.removeAt(0);
                  try {
                    final res = await AiService.instance.parseImagesWithVision([path]);
                    singleFileQuestions.addAll(res);
                    TaskManager.instance.markChunkSuccess(taskId, path, res);
                  } catch (e) {
                    final errorStr = e.toString().toLowerCase();
                    if (errorStr.contains('429') || 
                        errorStr.contains('too many requests') ||
                        errorStr.contains('connection closed') ||
                        errorStr.contains('clientexception') ||
                        errorStr.contains('socketexception') ||
                        errorStr.contains('broken pipe')) {
                      pendingImages.insert(0, path);
                      if (maxConcurrency > 1) maxConcurrency--;
                      await Future.delayed(const Duration(seconds: 3));
                      return;
                    } else if (errorStr.contains('timeout')) {
                      pendingImages.insert(0, path);
                      if (maxConcurrency > 1) maxConcurrency--;
                      else await Future.delayed(const Duration(seconds: 10));
                      return;
                    } else {
                      TaskManager.instance.markChunkFailed(taskId, path);
                      throw e;
                    }
                  }
                }
              }());
            }
            await Future.wait(workers);
          }
          
          // 对单文件内图片分页导致的数据碎片，运行一次本地拉链合并作为防抖
          singleFileQuestions = _runJigsawMerge(singleFileQuestions);
        } else {
          final file = File(filePath);
          String rawText = '';
          bool isMarkdownFile = false;
          if (lowerPath.endsWith('.pdf')) {
            final bytes = await file.readAsBytes();
            final document = PdfDocument(inputBytes: bytes);
            rawText = PdfTextExtractor(document).extractText();
            document.dispose();
          } else if (lowerPath.endsWith('.docx')) {
            final bytes = await file.readAsBytes();
            rawText = docxToText(bytes);
            rawText = rawText.replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s{2,}'), ' ');
          } else if (lowerPath.endsWith('.zip')) {
            final bytes = await file.readAsBytes();
            final archive = ZipDecoder().decodeBytes(bytes);
            for (final archiveFile in archive) {
              if (archiveFile.isFile && archiveFile.name.toLowerCase().endsWith('.md')) {
                final data = archiveFile.content as List<int>;
                rawText = utf8.decode(data, allowMalformed: true);
                isMarkdownFile = true;
                break;
              }
            }
          } else {
            rawText = await file.readAsString();
            if (lowerPath.endsWith('.md')) isMarkdownFile = true;
          }

          if (rawText.trim().length > 10) {
            singleFileQuestions = await AiService.instance.parseTextToQuestions(rawText, taskId: taskId, isMarkdown: isMarkdownFile);
          }
        }

        if (singleFileQuestions.isNotEmpty) {
          fileResults.add(singleFileQuestions);
        }
      }

      // 如果有多个文件，交给大模型做轻量级结构化交叉配对
      if (fileResults.length > 1) {
         TaskManager.instance.updateProgress(taskId, '启动 AI 结构化交叉配对引擎...', 0.9);
         return await AiService.instance.mergeStructuredQuestions(fileResults);
      } else if (fileResults.length == 1) {
         return fileResults.first;
      } else {
         return [];
      }
    });
  }

  // ============================================================
  // 🧩 本地智能拼图归并算法 (Local Jigsaw Merge Algorithm)
  // 功能：将纯答案页（模式 C）与孤立题干（模式 B）按题号配对，完成闭环拼图
  // ============================================================
  List<Map<String, dynamic>> _runJigsawMerge(List<Map<String, dynamic>> allParsedQuestions) {
    if (allParsedQuestions.isEmpty) return [];

    final Map<String, Map<String, dynamic>> questionByNum = {};    // 题干桶：key=q_num
    final Map<String, Map<String, dynamic>> answerByNum = {};      // 答案桶：key=q_num
    final List<Map<String, dynamic>> noNumQuestions = [];          // 无编号题目暂存区

    for (final q in allParsedQuestions) {
      String qNumRaw = (q['q_num'] ?? '').toString().trim();
      String qNum = '';
      final numMatch = RegExp(r'\d+').firstMatch(qNumRaw);
      if (numMatch != null) qNum = numMatch.group(0)!;

      final hasContent = q['content'] != null && (q['content'] as String).trim().isNotEmpty;
      final hasAnswer = q['standard_answer'] != null && (q['standard_answer'] as String).trim().isNotEmpty;

      if (qNum.isEmpty) {
        if (hasContent || hasAnswer) noNumQuestions.add(q);
        continue;
      }

      if (hasContent && !hasAnswer) {
        questionByNum[qNum] = q;
      } else if (!hasContent && hasAnswer) {
        answerByNum[qNum] = q;
      } else if (hasContent) {
        questionByNum[qNum] = q;
      }
    }

    for (final entry in answerByNum.entries) {
      final num = entry.key;
      final answerSlot = entry.value;
      if (questionByNum.containsKey(num)) {
        final q = questionByNum[num]!;
        if (q['standard_answer'] == null || q['standard_answer'].toString().trim().isEmpty) {
          q['standard_answer'] = answerSlot['standard_answer'];
        }
        if (q['explanation'] == null && answerSlot['explanation'] != null) {
          q['explanation'] = answerSlot['explanation'];
        }
      } else {
        noNumQuestions.add(answerSlot);
      }
    }

    final mergedQuestions = [...questionByNum.values, ...noNumQuestions];
    debugPrint('🧩 拼图归并完成：题干桶=${questionByNum.length}，答案桶=${answerByNum.length}，无编号区=${noNumQuestions.length}，最终结果=${mergedQuestions.length} 题');
    return mergedQuestions;
  }

  Future<void> _pasteAndParse() async {
    final pastedText = await Navigator.push<String>(context, MaterialPageRoute(builder: (context) => const PasteTextScreen()));
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
      appBar: AppBar(title: const Text('导入题目', style: TextStyle(fontWeight: FontWeight.bold))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExpansionTile(
              title: const Text('查看标准 JSON 导入格式', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              collapsedBackgroundColor: theme.primaryColor.withOpacity(0.05), backgroundColor: theme.primaryColor.withOpacity(0.05),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), collapsedShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              childrenPadding: const EdgeInsets.all(16),
              children: [
                Container(
                  padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: theme.brightness == Brightness.dark ? Colors.black45 : Colors.white, borderRadius: BorderRadius.circular(8)),
                  child: const Text('[\n  {\n    "type": 0,\n    "content": "题干",\n    "options": ["A.", "B."],\n    "standard_answer": "A",\n    "explanation": "解析"\n  }\n]', style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.blueGrey)),
                ),
              ],
            ),
            const SizedBox(height: 24),
            SwitchListTile(
              title: const Text('深度视觉解析 (慢速/极高精度)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              subtitle: const Text('包含代码截图或复杂公式的 PDF/图片 请开启。', style: TextStyle(fontSize: 12)),
              value: _useVisionEngine, activeColor: Colors.purpleAccent, contentPadding: EdgeInsets.zero,
              onChanged: (val) => setState(() => _useVisionEngine = val),
            ),
            if (_useVisionEngine)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('多图并发线程上限', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        Text('${_maxConcurrency.toInt()} 线程', style: const TextStyle(fontSize: 13, color: Colors.purpleAccent, fontWeight: FontWeight.bold)),
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
                    const Text('⚠️ 提示: 并发越高速度越快，若触发大模型 429 频率限制，引擎会自动为您降频。', style: TextStyle(fontSize: 11, color: Colors.grey)),
                  ],
                ),
              ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(child: ElevatedButton.icon(style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), backgroundColor: theme.primaryColor, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), elevation: 0), icon: const Icon(Icons.camera_alt_rounded), label: const Text('拍照识别', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)), onPressed: () => _pickImage(ImageSource.camera))),
                const SizedBox(width: 12),
                Expanded(child: ElevatedButton.icon(style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), backgroundColor: theme.primaryColor, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), elevation: 0), icon: const Icon(Icons.photo_library_rounded), label: const Text('相册选图', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)), onPressed: () => _pickImage(ImageSource.gallery))),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), foregroundColor: theme.primaryColor, side: BorderSide(color: theme.primaryColor.withOpacity(0.3)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              icon: const Icon(Icons.folder_open_rounded), label: const Text('从文件管理器选择 (PDF/ZIP)', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              onPressed: _pickAndParseFile,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), foregroundColor: theme.primaryColor, side: BorderSide(color: theme.primaryColor.withOpacity(0.3)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              icon: const Icon(Icons.content_paste), label: const Text('从剪贴板粘贴文本解析', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              onPressed: _pasteAndParse,
            ),
          ],
        ),
      ),
    );
  }
}
