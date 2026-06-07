import 'package:flutter/material.dart';

import 'package:shiroha_quiz/core/review_engine_service.dart';
import 'package:shiroha_quiz/data/models/wrong_book_entry.dart';
import '../widgets/markdown_extensions.dart';

import 'question_edit_screen.dart';

class WrongBookPage extends StatefulWidget {
  const WrongBookPage({super.key});

  @override
  State<WrongBookPage> createState() => _WrongBookPageState();
}

class _WrongBookPageState extends State<WrongBookPage> {
  static const Color _bgColor = Color(0xFFF4F6FA);
  static const Color _primaryColor = Color(0xFF4C6ED7);

  late Future<List<WrongBookEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = ReviewEngineService().getWrongBookEntries();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        title: const Text('高频错题本'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.grey.shade900,
        elevation: 0,
      ),
      body: FutureBuilder<List<WrongBookEntry>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return _buildEmptyState();
          }
          return _buildList(snapshot.data!);
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book, size: 100, color: Colors.grey.shade300),
            const SizedBox(height: 24),
            Text(
              '错题本还是空的',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '继续练习或考试后，错题会自动进入这里',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade500,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: 160,
              height: 44,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                child: const Text('返回上一页', style: TextStyle(fontSize: 14)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(List<WrongBookEntry> items) {
    return ListView.builder(
      addRepaintBoundaries: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      itemBuilder: (context, index) {
        return _buildWrongBookCard(items[index]);
      },
    );
  }

  Widget _buildWrongBookCard(WrongBookEntry entry) {
    final mdText = StringBuffer();
    mdText.writeln('### 题目内容');
    mdText.writeln(entry.content);
    mdText.writeln();

    if (entry.options.isNotEmpty) {
      mdText.writeln('#### 选项');
      for (int i = 0; i < entry.options.length; i++) {
        String optStr = entry.options[i];
        String stripped = optStr
            .replaceFirst(RegExp(r'^(?:[A-D][\.、]?\s*|\([A-D]\)\s*)+'), '')
            .trim();
        if (stripped.isEmpty) stripped = optStr;
        mdText.writeln('${String.fromCharCode(65 + i)}. $stripped');
      }
      mdText.writeln();
    }

    if (entry.hasAnswerOrExplanation) {
      mdText
          .writeln('**正确答案：** `${entry.answer.isEmpty ? "无" : entry.answer}`');
      if (entry.explanation.isNotEmpty) {
        mdText.writeln();
        mdText.writeln('**解析：**');
        mdText.writeln(entry.explanation);
      }
      mdText.writeln();
    }
    mdText.writeln('---');
    mdText.writeln('**复习数据：**');
    mdText.writeln('- **错误次数：** ${entry.lapses}');
    mdText.writeln('- **难度系数：** ${entry.difficulty.toStringAsFixed(2)}');
    mdText.writeln('- **稳定性：** ${entry.stability.toStringAsFixed(2)}');

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      elevation: 0,
      color: Colors.white,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: Text(
          entry.bankName,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: Colors.grey.shade800,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          entry.content,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.red.shade50,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '错 ${entry.lapses} 次',
            style: const TextStyle(
              color: Colors.redAccent,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        children: [
          buildLatexWidget(
            context,
            mdText.toString(),
          ),
          if (!entry.hasAnswerOrExplanation)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 8),
              decoration: BoxDecoration(
                color: Colors.orangeAccent.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: Colors.orangeAccent.withValues(alpha: 0.3)),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => QuestionEditScreen(
                                  question: entry.toQuestionEditMap())))
                      .then((modified) {
                    if (modified == true) {
                      setState(() {
                        _future = ReviewEngineService().getWrongBookEntries();
                      });
                    }
                  });
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    children: [
                      Icon(Icons.edit_note_rounded,
                          color: Colors.orangeAccent, size: 20),
                      SizedBox(height: 4),
                      Text('✍️ 暂无答案，点击手动添加或修改',
                          style: TextStyle(
                              color: Colors.orangeAccent,
                              fontSize: 13,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
