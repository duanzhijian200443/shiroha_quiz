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
import '../../core/database/database_helper.dart';
import '../../main.dart';
import 'paste_text_screen.dart';

class ImportSettingsScreen extends StatefulWidget {
  const ImportSettingsScreen({Key? key}) : super(key: key);
  @override
  State<ImportSettingsScreen> createState() => _ImportSettingsScreenState();
}

class _ImportSettingsScreenState extends State<ImportSettingsScreen> {
  final TextEditingController _bankNameController = TextEditingController();
  final TextEditingController _folderController = TextEditingController();
  List<String> _existingFolders = [];
  bool _useVisionEngine = false;
  double _maxConcurrency = 3.0; // 默认多图并发线程
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _loadExistingFolders();
  }

  Future<void> _loadExistingFolders() async {
    final tree = await DatabaseHelper.instance.getSubjectTree();
    if (mounted) {
      setState(() {
        _existingFolders = tree.keys.where((k) => k != '📁 未分类题库').toList();
      });
    }
  }

  // 核心重构：对接全局 TaskManager 的后台任务派发器
  void _dispatchBackgroundTask(String sourceDesc, Future<List<Map<String, dynamic>>> Function(String taskId) parseTask) {
    final bankName = _bankNameController.text.trim();
    final folderName = _folderController.text.trim();

    if (bankName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先输入目标题库名称')));
      return;
    }

    // 1. 生成工单并抛入全局管家
    final taskId = 'task_' + DateTime.now().millisecondsSinceEpoch.toString();
    TaskManager.instance.addTask(ImportTask(
      id: taskId,
      title: '导入题库：$bankName',
      progressText: '已进入后台队列，来源: $sourceDesc',
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
          bankName, 
          folderName
        );

        rootScaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text('🔔 题库 [$bankName] 解析完成，请前往左上角【传输中心】校对入库！'), backgroundColor: Colors.orange)
        );
      } catch (e) {
        TaskManager.instance.failTask(taskId, e.toString());
      }
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    if (_bankNameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先输入目标题库名称')));
      return;
    }
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
    if (_bankNameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先输入目标题库名称')));
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'txt', 'png', 'jpg', 'jpeg', 'docx', 'md', 'zip'],
    );

    if (result == null || result.files.single.path == null) return;
    final filePath = result.files.single.path!;
    final lowerPath = filePath.toLowerCase();

    _dispatchBackgroundTask(filePath.split(Platform.pathSeparator).last, (taskId) async {
      if (_useVisionEngine) {
        if (lowerPath.endsWith('.pdf')) {
          TaskManager.instance.updateProgress(taskId, '正在将 PDF 本地光栅化为高清图册...', 0.2);
          final document = await pdfx.PdfDocument.openFile(filePath);
          List<String> imagePaths = [];
          final tempDir = await getTemporaryDirectory();
          final pageCount = document.pagesCount; // 恢复无限制页数
          for (int i = 1; i <= pageCount; i++) {
            final page = await document.getPage(i);
            final pageImage = await page.render(width: page.width * 2, height: page.height * 2, format: pdfx.PdfPageImageFormat.jpeg);
            if (pageImage != null) {
              final imgFile = File('${tempDir.path}/page_$i.jpg');
              await imgFile.writeAsBytes(pageImage.bytes);
              imagePaths.add(imgFile.path);
            }
            await page.close();
          }
          await document.close();
          
          TaskManager.instance.updateProgress(taskId, '光栅化完成，启动自适应并发视觉引擎...', 0.3);
          
          // 🏆 智能动态工作池视觉引擎 (Dynamic Worker Pool Vision Engine)
          List<Map<String, dynamic>> allParsedQuestions = [];
          int maxConcurrency = _maxConcurrency.toInt(); // 根据用户设定的上限初始化并发
          
          List<String> pendingImages = List.from(imagePaths);
          int totalPages = imagePaths.length;
          int completedPages = 0;
          
          while (pendingImages.isNotEmpty) {
            List<Future<void>> workers = [];
            int currentWorkers = maxConcurrency;
            if (currentWorkers > pendingImages.length) currentWorkers = pendingImages.length;
            
            for (int i = 0; i < currentWorkers; i++) {
              workers.add(() async {
                while (pendingImages.isNotEmpty) {
                  final path = pendingImages.removeAt(0);
                  int pageNum = imagePaths.indexOf(path) + 1;
                  TaskManager.instance.updateProgress(taskId, '动态工作池: 处理第 $pageNum / $totalPages 页 (并发: $maxConcurrency)...', 0.3 + (completedPages / totalPages) * 0.4);
                  
                  try {
                    final result = await AiService.instance.parseImagesWithVision([path]);
                    allParsedQuestions.addAll(result);
                    completedPages++;
                    TaskManager.instance.updateProgress(taskId, '动态工作池: 已完成 $completedPages / $totalPages 页...', 0.3 + (completedPages / totalPages) * 0.4);
                  } catch (e) {
                    final errorStr = e.toString().toLowerCase();
                    if (errorStr.contains('429') || errorStr.contains('too many requests')) {
                      // 将失败的图片插回队首排队
                      pendingImages.insert(0, path);
                      if (maxConcurrency > 1) {
                        maxConcurrency--;
                        TaskManager.instance.updateProgress(taskId, '⚠️ 触发限流，Worker熔断退出，降级为 $maxConcurrency 线程...', 0.3 + (completedPages / totalPages) * 0.4);
                      }
                      await Future.delayed(const Duration(seconds: 3));
                      return; // 当前 Worker 生命周期结束
                    } else {
                      throw e; // 抛出其他致命错误
                    }
                  }
                }
              }());
            }
            // 等待当前这批 Worker 全部落幕（正常完成或中途因 429 阵亡）
            // 如果 pendingImages 还有剩余，外层 while 会以最新的 maxConcurrency 重新启动补充 Worker
            await Future.wait(workers);
          }
          // ============================================================
          // 🧩 本地智能拼图归并算法 (Local Jigsaw Merge Algorithm)
          // 功能：将纯答案页（模式 C）与孤立题干（模式 B）按题号配对，完成闭环拼图
          // ============================================================
          final Map<String, Map<String, dynamic>> questionByNum = {};    // 题干桶：key=q_num
          final Map<String, Map<String, dynamic>> answerByNum = {};      // 答案桶：key=q_num
          final List<Map<String, dynamic>> noNumQuestions = [];          // 无编号题目暂存区

          for (final q in allParsedQuestions) {
            String qNumRaw = (q['q_num'] ?? '').toString().trim();
            // 智能容错：只提取纯数字进行哈希配对，消除 "43." 和 "43" 和 "第43题" 之间的匹配代沟
            String qNum = '';
            final numMatch = RegExp(r'\d+').firstMatch(qNumRaw);
            if (numMatch != null) qNum = numMatch.group(0)!;

            final hasContent = q['content'] != null && (q['content'] as String).trim().isNotEmpty;
            final hasAnswer = q['standard_answer'] != null && (q['standard_answer'] as String).trim().isNotEmpty;

            if (qNum.isEmpty) {
              // 无编号直接保留（完整题或无法配对）
              if (hasContent) noNumQuestions.add(q);
              continue;
            }

            if (hasContent && !hasAnswer) {
              // 模式 B：只有题干，入题干桶
              questionByNum[qNum] = q;
            } else if (!hasContent && hasAnswer) {
              // 模式 C：只有答案，入答案桶
              answerByNum[qNum] = q;
            } else if (hasContent) {
              // 模式 A：完整题目，直接入题干桶（可能被后续模式 C 补充 explanation）
              questionByNum[qNum] = q;
            }
          }

          // 执行拉链合并：将答案桶的数据打入对应的题干桶
          for (final entry in answerByNum.entries) {
            final num = entry.key;
            final answerSlot = entry.value;
            if (questionByNum.containsKey(num)) {
              // 精准配对成功！
              final q = questionByNum[num]!;
              if (q['standard_answer'] == null) {
                q['standard_answer'] = answerSlot['standard_answer'];
              }
              if (q['explanation'] == null && answerSlot['explanation'] != null) {
                q['explanation'] = answerSlot['explanation'];
              }
            } else {
              // 无法配对的孤立答案也保留（校对时可见）
              noNumQuestions.add(answerSlot);
            }
          }

          final mergedQuestions = [...questionByNum.values, ...noNumQuestions];
          debugPrint('🧩 拼图归并完成：题干桶=${questionByNum.length}，答案桶=${answerByNum.length}，无编号区=${noNumQuestions.length}，最终结果=${mergedQuestions.length} 题');
          return mergedQuestions;
        } else {
          return await AiService.instance.parseFileWithVision(filePath);
        }
      } else {
        TaskManager.instance.updateProgress(taskId, '正在本地提取文档结构...', 0.2);
        final file = File(filePath);
        String rawText = '';
        
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
          TaskManager.instance.updateProgress(taskId, '正在解压并挂载本地隔离沙盒...', 0.3);
          final bytes = await file.readAsBytes();
          final archive = ZipDecoder().decodeBytes(bytes);
          final docDir = await getApplicationDocumentsDirectory();
          final folderId = DateTime.now().millisecondsSinceEpoch.toString();
          final sandboxPath = '${docDir.path}/media_$folderId';
          await Directory(sandboxPath).create(recursive: true);
          for (final archiveFile in archive) {
            if (archiveFile.isFile) {
              final filename = archiveFile.name;
              final data = archiveFile.content as List<int>;
              final outFile = File('$sandboxPath/$filename');
              await outFile.create(recursive: true);
              await outFile.writeAsBytes(data);
              if (filename.toLowerCase().endsWith('.md')) {
                rawText = utf8.decode(data, allowMalformed: true);
              }
            }
          }
          if (rawText.trim().isEmpty) throw Exception("ZIP 压缩包中未找到 .md 文件！");
          rawText = rawText.replaceAllMapped(RegExp(r'!\[(.*?)\]\((.*?)\)'), (match) {
            final alt = match.group(1) ?? '';
            String imgPath = match.group(2) ?? '';
            if (imgPath.startsWith('./')) imgPath = imgPath.substring(2);
            if (imgPath.startsWith('http')) return match.group(0)!;
            return '![$alt](file://$sandboxPath/$imgPath)';
          });
        } else {
          rawText = await file.readAsString();
        }

        if (rawText.trim().length > 50) {
          TaskManager.instance.updateProgress(taskId, '结构提取完毕，正在交由高速大模型构建题库...', 0.5);
          return await AiService.instance.parseTextToQuestions(rawText);
        } else {
          throw Exception("未检测到有效文本，请开启【深度视觉解析】！");
        }
      }
    });
  }

  Future<void> _pasteAndParse() async {
    if (_bankNameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先输入目标题库名称')));
      return;
    }
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
            TextField(controller: _bankNameController, decoration: InputDecoration(labelText: '目标题库名称', border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)))),
            const SizedBox(height: 16),
            TextField(controller: _folderController, decoration: InputDecoration(labelText: '所属学科分类 (选填)', border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)))),
            if (_existingFolders.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8.0, runSpacing: 8.0,
                children: _existingFolders.map((folder) => ActionChip(
                  label: Text(folder, style: const TextStyle(fontSize: 12, color: Colors.blueAccent)),
                  backgroundColor: Colors.blue.shade50, side: BorderSide.none,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  onPressed: () => _folderController.text = folder,
                )).toList(),
              ),
            ],
            const SizedBox(height: 24),
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
