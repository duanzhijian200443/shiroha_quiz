import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_markdown_latex/flutter_markdown_latex.dart';
import 'package:markdown/markdown.dart' as md;
import '../../services/ai_service.dart';
import '../../core/database/database_helper.dart';
import '../../main.dart'; // 获取 rootScaffoldMessengerKey
import '../../utils/ai_data_sanitizer.dart';
import '../widgets/markdown_extensions.dart' show buildMarkdownImage, RobustLatexElementBuilder;

class MockExamScreen extends StatefulWidget {
  final String paperId; // 核心新增：试卷唯一 ID
  final List<Map<String, dynamic>> questions;
  final int durationMinutes;

  const MockExamScreen({
    Key? key, 
    required this.paperId, 
    required this.questions, 
    required this.durationMinutes
  }) : super(key: key);

  @override
  State<MockExamScreen> createState() => _MockExamScreenState();
}

class _MockExamScreenState extends State<MockExamScreen> {
  late PageController _pageController;
  int _currentIndex = 0;
  
  // 倒计时引擎
  late Timer _timer;
  late int _remainingSeconds;

  // 答题卡缓存：key 为题目 index，value 为用户的答案 (选择题存选项索引，主观题存文本)
  final Map<int, dynamic> _userAnswers = {};
  // 主观题输入控制器缓存
  final Map<int, TextEditingController> _textControllers = {};

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _remainingSeconds = widget.durationMinutes * 60;
    
    // 开启防息屏
    WakelockPlus.enable();
    
    // 启动倒计时
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        if (_remainingSeconds > 0) {
          _remainingSeconds--;
        } else {
          _timer.cancel();
          _forceSubmit();
        }
      });
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    WakelockPlus.disable(); // 关闭防息屏
    _pageController.dispose();
    for (var ctrl in _textControllers.values) {
      ctrl.dispose();
    }
    super.dispose();
  }

  void _processSubmission() async {
    _timer.cancel();
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    
    try {
      // 1. 提交答案并获取需要 AI 批改的主观题任务
      final tasks = await DatabaseHelper.instance.submitExamPaper(widget.paperId, _userAnswers, widget.questions);
      
      if (mounted) {
        Navigator.pop(context); // 关闭 Loading
        Navigator.pop(context); // 退出考场，返回模考中心
      }

      // 2. 路由分发与后台静默处理
      if (tasks.isEmpty) {
        rootScaffoldMessengerKey.currentState?.showSnackBar(const SnackBar(content: Text('🎉 交卷成功！客观题已自动批改出分。'), backgroundColor: Colors.green));
      } else {
        rootScaffoldMessengerKey.currentState?.showSnackBar(const SnackBar(content: Text('🚀 客观题已批改！主观题已转入后台 AI 阅卷...'), backgroundColor: Colors.blueAccent));
        
        // 派发至后台事件循环，不阻塞 UI
        Future.microtask(() async {
          for (var task in tasks) {
            try {
              final feedback = await AiService.instance.judgeAnswer(task['question'], task['sAns'], task['uAns']);
              
              // 智能提取 AI 打分 (0-100)，折算为 1 分满分
              final match = RegExp(r'\d+').firstMatch(feedback);
              double scoreRatio = 0.0;
              if (match != null) {
                double parsed = double.tryParse(match.group(0)!) ?? 0.0;
                scoreRatio = (parsed / 100.0).clamp(0.0, 1.0);
              } else {
                // 容错：如果 AI 没给数字，按语义判断
                scoreRatio = (feedback.contains('对') || feedback.contains('正确') || feedback.contains('得分')) ? 1.0 : 0.0;
              }
              
              await DatabaseHelper.instance.updateExamAiScore(widget.paperId, task['qId'], feedback, scoreRatio);
            } catch (e) {
              debugPrint('AI 判卷单题异常: $e');
            }
          }
          // 所有主观题批改完毕，封板出分
          await DatabaseHelper.instance.finishExamGrading(widget.paperId);
          rootScaffoldMessengerKey.currentState?.showSnackBar(const SnackBar(content: Text('🎉 试卷 AI 批改完成！请下拉刷新模考中心查看成绩。'), backgroundColor: Colors.green));
        });
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('交卷失败: $e'), backgroundColor: Colors.redAccent));
      }
    }
  }

  void _forceSubmit() {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('考试时间到！正在强制交卷...')));
    _processSubmission();
  }

  void _manualSubmit() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认交卷？'),
        content: Text('你已作答 ${_userAnswers.length} / ${widget.questions.length} 道题。交卷后将由 AI 阅卷官进行批改。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('继续检查')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              Navigator.pop(context); // 关闭确认框
              _processSubmission(); // 执行交卷
            },
            child: const Text('确认交卷', style: TextStyle(color: Colors.white)),
          )
        ],
      ),
    );
  }

  String _formatTime(int seconds) {
    int h = seconds ~/ 3600;
    int m = (seconds % 3600) ~/ 60;
    int s = seconds % 60;
    if (h > 0) return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Widget _buildMarkdown(String text, {bool isOption = false, Color? overrideColor, FontWeight? fontWeight}) {
    final theme = Theme.of(context);
    final textColor = overrideColor ?? theme.textTheme.bodyLarge?.color;
    final fontSize = isOption ? 15.0 : 16.0;

    return MarkdownBody(
      data: AiDataSanitizer.formatLatex(text),
      selectable: true,
      imageBuilder: buildMarkdownImage,
      builders: {
        'latex': RobustLatexElementBuilder(textStyle: TextStyle(color: textColor, fontSize: fontSize, fontWeight: fontWeight)),
      },
      extensionSet: md.ExtensionSet(
        [LatexBlockSyntax()],
        [LatexInlineSyntax(), ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes],
      ),
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: TextStyle(fontSize: fontSize, color: textColor, height: 1.6, fontWeight: fontWeight),
        codeblockDecoration: BoxDecoration(color: theme.brightness == Brightness.dark ? const Color(0xFF1E1E1E) : const Color(0xFFF5F7FA), borderRadius: BorderRadius.circular(8)),
        code: TextStyle(backgroundColor: Colors.transparent, fontFamily: 'monospace', color: theme.primaryColor),
      ),
    );
  }

  Widget _buildQuestionView(int index) {
    final q = widget.questions[index];
    final type = q['type'] as int? ?? 0;
    final isObjective = type == 0;

    List<dynamic> options = [];
    if (isObjective && q['options'] != null) {
      try {
        options = jsonDecode(q['options'].toString());
      } catch (_) {}
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: Colors.redAccent.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
              child: Text(isObjective ? '单选题' : (type == 2 ? '填空题' : '简答题'), style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 8),
            Text('第 ${index + 1} / ${widget.questions.length} 题', style: const TextStyle(color: Colors.grey, fontSize: 13)),
          ],
        ),
        const SizedBox(height: 16),
        _buildMarkdown(q['content'] as String),
        const SizedBox(height: 24),
        
        if (isObjective)
          ...List.generate(options.length, (optIndex) {
            final isSelected = _userAnswers[index] == optIndex;
            return GestureDetector(
              onTap: () => setState(() => _userAnswers[index] = optIndex),
              child: Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isSelected ? Theme.of(context).primaryColor.withOpacity(0.1) : Theme.of(context).cardTheme.color,
                  border: Border.all(color: isSelected ? Theme.of(context).primaryColor : Colors.grey.withOpacity(0.2), width: isSelected ? 2 : 1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: _buildMarkdown(options[optIndex].toString(), isOption: true, overrideColor: isSelected ? Theme.of(context).primaryColor : null, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal),
              ),
            );
          })
        else
          TextField(
            controller: _textControllers.putIfAbsent(index, () => TextEditingController(text: _userAnswers[index]?.toString() ?? '')),
            maxLines: type == 2 ? 2 : 8,
            onChanged: (val) => _userAnswers[index] = val,
            decoration: InputDecoration(
              hintText: type == 2 ? '请输入填空答案...' : '请输入简答题解答步骤...',
              filled: true, fillColor: Theme.of(context).cardTheme.color,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.withOpacity(0.2))),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDanger = _remainingSeconds <= 300; // 最后 5 分钟标红

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('考试中禁止退出！请点击右上角交卷。')));
        }
      },
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          backgroundColor: isDanger ? Colors.redAccent.withOpacity(0.1) : theme.scaffoldBackgroundColor,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.timer_outlined, color: isDanger ? Colors.redAccent : theme.textTheme.bodyLarge?.color),
              const SizedBox(width: 8),
              Text(_formatTime(_remainingSeconds), style: TextStyle(fontWeight: FontWeight.bold, color: isDanger ? Colors.redAccent : theme.textTheme.bodyLarge?.color, fontFamily: 'monospace')),
            ],
          ),
          centerTitle: true,
          actions: [
            TextButton(
              onPressed: _manualSubmit,
              child: const Text('交卷', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 16)),
            )
          ],
        ),
        body: PageView.builder(
          controller: _pageController,
          itemCount: widget.questions.length,
          onPageChanged: (idx) => setState(() => _currentIndex = idx),
          itemBuilder: (context, index) => _buildQuestionView(index),
        ),
        bottomNavigationBar: SafeArea(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(color: theme.cardTheme.color, boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, -4))]),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.arrow_back_ios, size: 14), label: const Text('上一题'),
                  onPressed: _currentIndex > 0 ? () => _pageController.previousPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut) : null,
                ),
                Text('${_currentIndex + 1} / ${widget.questions.length}', style: const TextStyle(fontWeight: FontWeight.bold)),
                TextButton(
                  onPressed: _currentIndex < widget.questions.length - 1 ? () => _pageController.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut) : null,
                  child: const Row(children: [Text('下一题'), SizedBox(width: 4), Icon(Icons.arrow_forward_ios, size: 14)]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}