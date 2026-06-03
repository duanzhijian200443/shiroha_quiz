import 'package:flutter/material.dart';
import '../../data/repositories/question_repository.dart';
import '../../services/task_manager.dart';
import '../widgets/markdown_extensions.dart';
import '../../main.dart';

class ImportStagingScreen extends StatefulWidget {
  final List<Map<String, dynamic>> parsedQuestions;
  final String? taskId;
  const ImportStagingScreen({
    super.key,
    required this.parsedQuestions,
    this.taskId,
  });

  @override
  State<ImportStagingScreen> createState() => _ImportStagingScreenState();
}

class _ImportStagingScreenState extends State<ImportStagingScreen> {
  late List<Map<String, dynamic>> _displayQuestions;
  bool _isSaving = false;

  final TextEditingController _bankNameController = TextEditingController();
  final TextEditingController _folderController = TextEditingController();
  final QuestionRepository _questionRepository = QuestionRepository.instance;
  List<String> _existingFolders = [];

  @override
  void initState() {
    super.initState();
    _displayQuestions = List.from(widget.parsedQuestions);
    _loadExistingFolders();
  }

  Future<void> _loadExistingFolders() async {
    final folders = await _questionRepository.getAvailableFolders();
    if (mounted) {
      setState(() {
        _existingFolders = folders;
      });
    }
  }

  void _validateBeforeSave() {
    final emptyStems = _displayQuestions
        .where((q) =>
            q['content'] == null ||
            q['content']!.toString().trim().isEmpty ||
            q['content']!.toString().contains('假设') ||
            q['content']!.toString().contains('原题干'))
        .length;

    final emptyRate =
        _displayQuestions.isEmpty ? 0 : emptyStems / _displayQuestions.length;

    if (emptyRate > 0.4) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('提取质量不佳',
              style: TextStyle(fontWeight: FontWeight.bold)),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: Text('有 $emptyStems 道题目未能识别题干，建议检查原文档结构后重新导入。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消', style: TextStyle(color: Colors.grey))),
            ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () {
                  Navigator.pop(context);
                  _showSaveDialog();
                },
                child: const Text('仍然保存')),
          ],
        ),
      );
    } else {
      _showSaveDialog();
    }
  }

  void _showSaveDialog() {
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return StatefulBuilder(builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('选择保存位置',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                        controller: _bankNameController,
                        decoration: InputDecoration(
                            labelText: '目标题库名称',
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8)))),
                    const SizedBox(height: 16),
                    TextField(
                        controller: _folderController,
                        decoration: InputDecoration(
                            labelText: '所属学科分类 (选填)',
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8)))),
                    if (_existingFolders.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8.0,
                        runSpacing: 8.0,
                        children: _existingFolders
                            .map((folder) => ActionChip(
                                  label: Text(folder,
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.blueAccent)),
                                  backgroundColor: Colors.blue.shade50,
                                  side: BorderSide.none,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16)),
                                  onPressed: () {
                                    setDialogState(() {
                                      _folderController.text = folder;
                                    });
                                  },
                                ))
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  onPressed: () {
                    final bankName = _bankNameController.text.trim();
                    if (bankName.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('请先输入目标题库名称')));
                      return;
                    }
                    Navigator.pop(ctx);
                    _confirmAndSave(bankName, _folderController.text.trim());
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('确定入库'),
                ),
              ],
            );
          });
        });
  }

  Future<void> _confirmAndSave(String bankName, String folderName) async {
    if (_displayQuestions.isEmpty) {
      Navigator.pop(context);
      return;
    }

    setState(() => _isSaving = true);
    try {
      await _questionRepository.saveQuestionsToBank(
        bankName: bankName,
        folderName: folderName,
        questions: _displayQuestions,
      );

      // 触发全局题库刷新事件
      globalBankUpdateNotifier.value++;

      // 如果来自后台解析任务，将任务更新为已完成状态
      if (widget.taskId != null) {
        TaskManager.instance.completeTask(widget.taskId!, '已成功导入题库: $bankName');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('🎉 成功入库 ${_displayQuestions.length} 题！'),
            backgroundColor: Colors.green));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('入库失败: $e'), backgroundColor: Colors.redAccent));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title:
            const Text('解析结果校对', style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.orangeAccent.withValues(alpha: 0.1),
            child: const Row(
              children: [
                Icon(Icons.info_outline, color: Colors.orangeAccent, size: 20),
                SizedBox(width: 8),
                Expanded(
                    child: Text('请核对 AI 解析结果。向左滑动卡片可删除识别错误的废题。',
                        style: TextStyle(
                            color: Colors.orangeAccent, fontSize: 13))),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _displayQuestions.length,
              itemBuilder: (context, index) {
                final q = _displayQuestions[index];
                return Dismissible(
                  key: ValueKey(q.hashCode.toString() + index.toString()),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    color: Colors.redAccent,
                    child: const Icon(Icons.delete_sweep, color: Colors.white),
                  ),
                  onDismissed: (direction) {
                    setState(() => _displayQuestions.removeAt(index));
                  },
                  child: _QuestionCard(
                    question: q,
                    index: index,
                  ),
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: theme.primaryColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            icon: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.check_circle_outline),
            label: Text(
                _isSaving
                    ? '正在入库...'
                    : '确认无误，将 ${_displayQuestions.length} 题收入题库',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            onPressed: _isSaving ? null : _validateBeforeSave,
          ),
        ),
      ),
    );
  }
}

class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.question,
    required this.index,
  });

  final Map<String, dynamic> question;
  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final standardAnswer = question['standard_answer']?.toString().trim() ?? '';
    final explanation = question['explanation']?.toString().trim() ?? '';
    final hasAnswerOrExplanation =
        standardAnswer.isNotEmpty || explanation.isNotEmpty;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.primaryColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _typeLabel(question['type']),
                    style: TextStyle(
                      color: theme.primaryColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '第 ${index + 1} 题',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildMarkdown(context, question['content']?.toString() ?? ''),
            const Divider(height: 24),
            if (!hasAnswerOrExplanation)
              _MissingAnswerNotice()
            else
              _AnswerBlock(
                standardAnswer: standardAnswer,
                explanation: explanation,
              ),
          ],
        ),
      ),
    );
  }

  static String _typeLabel(dynamic type) {
    if (type == 0) return '选择题';
    if (type == 2) return '填空题';
    return '简答题';
  }

  static Widget _buildMarkdown(BuildContext context, String text) {
    return buildLatexWidget(
      context,
      text,
      textColor: Theme.of(context).textTheme.bodyLarge?.color,
      fontSize: 14.0,
    );
  }
}

class _MissingAnswerNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.orangeAccent.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.3)),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent),
            SizedBox(height: 4),
            Text(
              '暂无答案，导入后可编辑或使用 AI 解答',
              style: TextStyle(
                color: Colors.orangeAccent,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnswerBlock extends StatelessWidget {
  const _AnswerBlock({
    required this.standardAnswer,
    required this.explanation,
  });

  final String standardAnswer;
  final String explanation;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '标准答案：',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 4),
        _QuestionCard._buildMarkdown(
          context,
          standardAnswer.isEmpty ? '无' : standardAnswer,
        ),
        if (explanation.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            '解析：',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 4),
          _QuestionCard._buildMarkdown(context, explanation),
        ],
      ],
    );
  }
}
