import 'dart:async';
import 'package:flutter/material.dart';
import '../dependencies/ai_dependencies_scope.dart';
import '../../data/repositories/exam_repository.dart';
import '../../data/repositories/settings_repository.dart';
import 'ai_generator_screen.dart';
import 'mock_exam_config_screen.dart';
import 'mock_exam_screen.dart';
import 'paper_review_screen.dart';

class MockCenterScreen extends StatefulWidget {
  const MockCenterScreen({super.key, this.embedded = false});

  /// When true the Mock center is rendered inside a host surface (Today ->
  /// 考试) and must not show a duplicate/nested AppBar. All paper loading,
  /// grading polling, creation, navigation, and dispose behavior is
  /// unchanged; this is a Presentation-only adaptation.
  final bool embedded;

  @override
  State<MockCenterScreen> createState() => _MockCenterScreenState();
}

class _MockCenterScreenState extends State<MockCenterScreen> {
  List<Map<String, dynamic>> _papers = [];
  bool _isLoading = true;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _loadPapers();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadPapers({bool isPolling = false}) async {
    if (!isPolling) setState(() => _isLoading = true);
    try {
      final data = await ExamRepository.instance.getAllExamPapers();
      if (mounted) {
        setState(() {
          _papers = data;
          _isLoading = false;
        });

        _pollTimer?.cancel();
        bool hasGrading = _papers.any((p) => p['status'] == 1);
        if (hasGrading) {
          _pollTimer = Timer(
              const Duration(seconds: 3), () => _loadPapers(isPolling: true));
        }
      }
    } catch (e) {
      debugPrint('加载试卷失败: $e');
      if (mounted && !isPolling) setState(() => _isLoading = false);
    }
  }

  Future<void> _deletePaper(String id) async {
    await AiDependenciesScope.of(context)
        .examMutationCommand
        .deleteExamPaper(id);
    _loadPapers();
  }

  void _showCreateOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text('组装新试卷',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                      color: Colors.purple.shade50,
                      borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.auto_awesome,
                      color: Colors.purpleAccent)),
              title: const Text('AI 魔法组卷',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('输入知识点，由大模型实时生成全新考卷',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const AiQuizScreen()))
                    .then((_) => _loadPapers());
              },
            ),
            const Divider(height: 1, indent: 64),
            ListTile(
              leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.library_books,
                      color: Colors.blueAccent)),
              title: const Text('经典随机抽卷',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('从已有题库中随机抽取题目进行全真模拟',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              onTap: () async {
                final navigator = Navigator.of(context);
                navigator.pop();
                final currentBank =
                    await SettingsRepository.instance.getCurrentBank() ??
                        '默认题库';
                if (!mounted) return;
                navigator
                    .push(MaterialPageRoute(
                        builder: (_) =>
                            MockExamConfigScreen(initialBank: currentBank)))
                    .then((_) => _loadPapers());
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: widget.embedded
          ? null
          : AppBar(
              title: const Text('模考中心',
                  style: TextStyle(fontWeight: FontWeight.w800))),
      body: RefreshIndicator(
        onRefresh: () => _loadPapers(),
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _papers.isEmpty
                ? SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: Container(
                      height: MediaQuery.of(context).size.height * 0.7,
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.receipt_long_rounded,
                              size: 80,
                              color: Colors.grey.withValues(alpha: 0.3)),
                          const SizedBox(height: 16),
                          const Text('暂无试卷记录',
                              style: TextStyle(
                                  color: Colors.grey,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          const Text('点击右下角 + 号生成你的第一份试卷吧',
                              style:
                                  TextStyle(color: Colors.grey, fontSize: 13)),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    itemCount: _papers.length,
                    itemBuilder: (context, index) {
                      final paper = _papers[index];
                      final isAi = paper['source_type'] == 1;
                      final status = paper['status'] as int;
                      final date = DateTime.fromMillisecondsSinceEpoch(
                          (paper['created_at'] as int) * 1000);

                      String statusText = '未开始';
                      Color statusColor = Colors.grey;
                      if (status == 1) {
                        statusText = '批改中';
                        statusColor = Colors.orange;
                      } else if (status == 2) {
                        statusText = '已出分';
                        statusColor = Colors.green;
                      }

                      return Card(
                        elevation: 0,
                        margin: const EdgeInsets.only(bottom: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                            side: BorderSide(
                                color: Colors.grey.withValues(alpha: 0.2))),
                        child: ListTile(
                          contentPadding: const EdgeInsets.all(16),
                          leading: CircleAvatar(
                            backgroundColor: isAi
                                ? Colors.purple.shade50
                                : Colors.blue.shade50,
                            child: Icon(
                                isAi ? Icons.auto_awesome : Icons.library_books,
                                color: isAi
                                    ? Colors.purpleAccent
                                    : Colors.blueAccent),
                          ),
                          title: Text(paper['title'],
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 16)),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 8.0),
                            child: Row(
                              children: [
                                Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                        color:
                                            statusColor.withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(4)),
                                    child: Text(statusText,
                                        style: TextStyle(
                                            color: statusColor,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold))),
                                const SizedBox(width: 8),
                                Text(
                                    '${date.month}月${date.day}日 ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}',
                                    style: const TextStyle(
                                        fontSize: 12, color: Colors.grey)),
                              ],
                            ),
                          ),
                          trailing: status == 2
                              ? Text(
                                  '${paper['score']}/${paper['total_score']}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 18,
                                      color: Colors.green))
                              : IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      color: Colors.redAccent),
                                  onPressed: () => _deletePaper(paper['id'])),
                          onLongPress: status == 1
                              ? () async {
                                  showDialog(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text('强制出分'),
                                      content: const Text(
                                          '试卷似乎卡在批改中了，是否强制结束批改并出分？\\n注意：强制出分会导致尚未批改完的主观题丢失得分。'),
                                      actions: [
                                        TextButton(
                                            onPressed: () => Navigator.pop(ctx),
                                            child: const Text('继续等待')),
                                        ElevatedButton(
                                          style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.orange),
                                          onPressed: () async {
                                            Navigator.pop(ctx);
                                            await AiDependenciesScope.of(
                                                    context)
                                                .examMutationCommand
                                                .finishExamGrading(paper['id']);
                                            _loadPapers();
                                          },
                                          child: const Text('强制出分',
                                              style: TextStyle(
                                                  color: Colors.white)),
                                        )
                                      ],
                                    ),
                                  );
                                }
                              : null,
                          onTap: () async {
                            final navigator = Navigator.of(context);
                            final messenger = ScaffoldMessenger.of(context);
                            if (status == 0) {
                              // 未开始：拉取题目并进入考场
                              showDialog(
                                  context: context,
                                  barrierDismissible: false,
                                  builder: (_) => const Center(
                                      child: CircularProgressIndicator()));
                              try {
                                final questions = await ExamRepository.instance
                                    .getPaperQuestionsDetail(paper['id']);
                                if (!mounted) return;
                                navigator.pop();
                                navigator
                                    .push(MaterialPageRoute(
                                        builder: (_) => MockExamScreen(
                                            paperId: paper['id'],
                                            questions: questions,
                                            durationMinutes: 180)))
                                    .then((_) => _loadPapers());
                              } catch (e) {
                                if (mounted) {
                                  navigator.pop();
                                  messenger.showSnackBar(
                                      SnackBar(content: Text('进入考场失败: $e')));
                                }
                              }
                            } else if (status == 1) {
                              // 批改中
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content:
                                          Text('AI 阅卷官正在疯狂批改中，请稍后再来查看...')));
                            } else if (status == 2) {
                              // 已出分：进入解析页
                              Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => PaperReviewScreen(
                                          paperId: paper['id'],
                                          title: paper['title'])));
                            }
                          },
                        ),
                      );
                    },
                  ),
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'mockCenterFAB',
        onPressed: _showCreateOptions,
        backgroundColor: theme.primaryColor,
        child: const Icon(Icons.add, color: Colors.white, size: 28),
      ),
    );
  }
}
