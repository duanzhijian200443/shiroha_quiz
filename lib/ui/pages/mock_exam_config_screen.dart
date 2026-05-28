import 'package:flutter/material.dart';
import '../../core/database/database_helper.dart';
import 'mock_exam_screen.dart';

class MockExamConfigScreen extends StatefulWidget {
  final String initialBank;
  const MockExamConfigScreen({Key? key, required this.initialBank}) : super(key: key);

  @override
  State<MockExamConfigScreen> createState() => _MockExamConfigScreenState();
}

class _MockExamConfigScreenState extends State<MockExamConfigScreen> {
  int _singleCount = 40;
  int _subjectiveCount = 7;
  int _durationMinutes = 180;

  void _startExam() async {
    if (_singleCount == 0 && _subjectiveCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('题目数量不能全为 0')));
      return;
    }

    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));

    try {
      // 1. 极速抽题
      final questions = await DatabaseHelper.instance.generateMockExamPaper(widget.initialBank, _singleCount, _subjectiveCount);
      if (!mounted) return;
      
      if (questions.isEmpty) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('当前题库题目不足，无法生成试卷')));
        return;
      }

      // 2. 核心合流：将抽出的题目正式落盘为试卷 (source_type: 0)
      final paperTitle = '${widget.initialBank} 随机模考';
      final paperId = await DatabaseHelper.instance.createExamPaper(paperTitle, 0, questions);

      if (!mounted) return;
      Navigator.pop(context); // 关闭 Loading

      // 3. 携带 paperId 进入考场
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => MockExamScreen(paperId: paperId, questions: questions, durationMinutes: _durationMinutes)),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('生成试卷失败: $e')));
    }
  }

  Widget _buildCounterRow(String label, int value, Function(int) onChanged, int min, int max, String unit) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          Row(
            children: [
              IconButton(icon: const Icon(Icons.remove_circle_outline, color: Colors.blueAccent), onPressed: value > min ? () => onChanged(value - 1) : null),
              SizedBox(width: 60, child: Text('$value $unit', textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
              IconButton(icon: const Icon(Icons.add_circle_outline, color: Colors.blueAccent), onPressed: value < max ? () => onChanged(value + 1) : null),
            ],
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('全真模拟考场', style: TextStyle(fontWeight: FontWeight.bold))),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: Colors.redAccent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3))),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(children: [Icon(Icons.warning_amber_rounded, color: Colors.redAccent), SizedBox(width: 8), Text('考前须知', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 16))]),
                  const SizedBox(height: 12),
                  const Text('1. 考试期间将强制保持屏幕常亮。\n2. 考试中途退出将丢失所有作答进度。\n3. 提交后客观题自动批改，主观题交由 AI 阅卷。', style: TextStyle(color: Colors.redAccent, height: 1.5, fontSize: 13)),
                ],
              ),
            ),
            const SizedBox(height: 32),
            Text('目标题库：${widget.initialBank}', style: const TextStyle(fontSize: 14, color: Colors.grey)),
            const SizedBox(height: 16),
            Card(
              elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: Colors.grey.withValues(alpha: 0.2))),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    _buildCounterRow('单选题数量', _singleCount, (v) => setState(() => _singleCount = v), 0, 100, '题'),
                    const Divider(height: 1),
                    _buildCounterRow('主观题数量', _subjectiveCount, (v) => setState(() => _subjectiveCount = v), 0, 20, '题'),
                    const Divider(height: 1),
                    _buildCounterRow('考试限时', _durationMinutes, (v) => setState(() => _durationMinutes = v), 10, 300, '分钟'),
                  ],
                ),
              ),
            ),
            const Spacer(),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), backgroundColor: Colors.redAccent, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              icon: const Icon(Icons.timer), label: const Text('生成试卷并进入考场', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              onPressed: _startExam,
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
