import 'package:flutter/material.dart';
import 'dart:convert';
import '../../core/database/database_helper.dart';
import '../widgets/markdown_extensions.dart';
import '../../main.dart';

class ImportStagingScreen extends StatefulWidget {
  final List<Map<String, dynamic>> parsedQuestions;
  final String bankName;
  final String folderName;

  const ImportStagingScreen({
    super.key,
    required this.parsedQuestions,
    required this.bankName,
    required this.folderName,
  });

  @override
  State<ImportStagingScreen> createState() => _ImportStagingScreenState();
}

class _ImportStagingScreenState extends State<ImportStagingScreen> {
  late List<Map<String, dynamic>> _displayQuestions;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _displayQuestions = List.from(widget.parsedQuestions);
  }

  Widget _buildMarkdown(String text) {
    return buildLatexWidget(
      context,
      text,
      textColor: Theme.of(context).textTheme.bodyLarge?.color,
      fontSize: 14.0,
    );
  }

  Future<void> _confirmAndSave() async {
    if (_displayQuestions.isEmpty) {
      Navigator.pop(context);
      return;
    }

    setState(() => _isSaving = true);
    try {
      final db = await DatabaseHelper.instance.database;
      await db.transaction((txn) async {
        for (var q in _displayQuestions) {
          final qId = DateTime.now().millisecondsSinceEpoch.toString() + '_' + q.hashCode.toString();
          await txn.insert('questions', {
            'id': qId, 'bank_name': widget.bankName, 'type': q['type'] ?? 0,
            'content': q['content']?.toString() ?? '无题干',
            'options': q['options'] != null ? jsonEncode(q['options']) : '[]',
            'standard_answer': '${q['standard_answer'] ?? q['answer'] ?? ''}|||${q['explanation'] ?? ''}',
            'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          });
          await txn.insert('review_states', {
            'question_id': qId, 'state': 0, 'difficulty': 5.0, 'stability': 0.0,
            'last_review_time': 0, 'next_review_time': 0, 'reps': 0, 'lapses': 0, 'last_lapse_time': 0,
          });
        }
      });

      if (widget.folderName.isNotEmpty) {
        await DatabaseHelper.instance.updateBankFolder(widget.bankName, widget.folderName);
      }

      // 触发全局题库刷新事件
      globalBankUpdateNotifier.value++;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('🎉 成功入库 ${_displayQuestions.length} 题！'), backgroundColor: Colors.green));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('入库失败: $e'), backgroundColor: Colors.redAccent));
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
        title: const Text('解析结果校对', style: TextStyle(fontWeight: FontWeight.bold)),
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
                Expanded(child: Text('请核对 AI 解析结果。向左滑动卡片可删除识别错误的废题。', style: TextStyle(color: Colors.orangeAccent, fontSize: 13))),
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
                  child: Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey.withValues(alpha: 0.2))),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(color: theme.primaryColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
                                child: Text(q['type'] == 0 ? '选择题' : (q['type'] == 2 ? '填空题' : '简答题'), style: TextStyle(color: theme.primaryColor, fontSize: 10, fontWeight: FontWeight.bold)),
                              ),
                              const SizedBox(width: 8),
                              Text('第 ${index + 1} 题', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _buildMarkdown(q['content']?.toString() ?? ''),
                          const Divider(height: 24),
                          const Text('标准答案：', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          const SizedBox(height: 4),
                          _buildMarkdown(q['standard_answer']?.toString() ?? ''),
                        ],
                      ),
                    ),
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
              backgroundColor: theme.primaryColor, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: _isSaving ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.check_circle_outline),
            label: Text(_isSaving ? '正在入库...' : '确认无误，将 ${_displayQuestions.length} 题收入题库', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            onPressed: _isSaving ? null : _confirmAndSave,
          ),
        ),
      ),
    );
  }
}