import 'package:flutter/material.dart';
import 'dart:convert';
import '../../data/repositories/exam_repository.dart';
import '../widgets/markdown_extensions.dart';
import 'question_edit_screen.dart';

class PaperReviewScreen extends StatefulWidget {
  final String paperId;
  final String title;
  const PaperReviewScreen(
      {Key? key, required this.paperId, required this.title})
      : super(key: key);

  @override
  State<PaperReviewScreen> createState() => _PaperReviewScreenState();
}

class _PaperReviewScreenState extends State<PaperReviewScreen> {
  List<Map<String, dynamic>> _questions = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final data =
        await ExamRepository.instance.getPaperQuestionsDetail(widget.paperId);
    if (mounted) {
      setState(() {
        _questions = data;
        _isLoading = false;
      });
    }
  }

  Widget _buildMarkdown(String text,
      {bool isOption = false, Color? overrideColor}) {
    final textColor =
        overrideColor ?? Theme.of(context).textTheme.bodyLarge?.color;
    final fontSize = isOption ? 14.0 : 15.0;
    return buildLatexWidget(
      context,
      text,
      textColor: textColor,
      fontSize: fontSize,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
          title: Text(widget.title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          elevation: 0),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _questions.length,
              itemBuilder: (context, index) {
                final q = _questions[index];
                final type = q['type'] as int? ?? 0;
                final isCorrect = (q['is_correct'] as int? ?? 0) == 1;
                final uAns = q['user_answer']?.toString() ?? '';
                // ||| 前是答案字母，后是解析内容
                final sAnsRaw = q['standard_answer']?.toString() ?? '';
                final ansParts = sAnsRaw.split('|||');
                final sAns = ansParts.isNotEmpty ? ansParts[0].trim() : '';

                List<dynamic> options = [];
                if (type == 0 && q['options'] != null) {
                  try {
                    options = jsonDecode(q['options'].toString());
                  } catch (_) {}
                }

                return Card(
                  margin: const EdgeInsets.only(bottom: 16),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                          color: isCorrect
                              ? Colors.green.withOpacity(0.3)
                              : Colors.redAccent.withOpacity(0.3),
                          width: 1.5)),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                  color: isCorrect
                                      ? Colors.green.withOpacity(0.1)
                                      : Colors.redAccent.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(4)),
                              child: Text(isCorrect ? '得分' : '失分',
                                  style: TextStyle(
                                      color: isCorrect
                                          ? Colors.green
                                          : Colors.redAccent,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold)),
                            ),
                            const SizedBox(width: 8),
                            Text('第 ${index + 1} 题',
                                style: const TextStyle(
                                    color: Colors.grey, fontSize: 12)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _buildMarkdown(q['content'] as String),
                        const SizedBox(height: 16),
                        if (type == 0) ...[
                          ...List.generate(options.length, (optIdx) {
                            final optStr = options[optIdx].toString();
                            final optionLetter =
                                String.fromCharCode(65 + optIdx);
                            bool isThisCorrect =
                                sAns.startsWith(optionLetter) || optStr == sAns;
                            bool isThisUser = uAns == optStr;

                            Color? bgColor;
                            Color? borderColor;
                            if (isThisCorrect) {
                              bgColor = Colors.green.withOpacity(0.1);
                              borderColor = Colors.green;
                            } else if (isThisUser && !isThisCorrect) {
                              bgColor = Colors.redAccent.withOpacity(0.1);
                              borderColor = Colors.redAccent;
                            } else {
                              bgColor = theme.scaffoldBackgroundColor;
                              borderColor = Colors.grey.withOpacity(0.2);
                            }

                            String stripped = optStr
                                .replaceFirst(
                                    RegExp(
                                        r'^(?:[A-D][\.、]?\s*|\([A-D]\)\s*)+'),
                                    '')
                                .trim();
                            if (stripped.isEmpty) stripped = optStr;

                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                  color: bgColor,
                                  border: Border.all(color: borderColor),
                                  borderRadius: BorderRadius.circular(8)),
                              child: _buildMarkdown(
                                  '**$optionLetter.** $stripped'),
                            );
                          }),
                        ] else ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                                color: theme.scaffoldBackgroundColor,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: Colors.grey.withOpacity(0.2))),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('你的作答与 AI 批阅：',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey,
                                        fontWeight: FontWeight.bold)),
                                const SizedBox(height: 8),
                                _buildMarkdown(uAns.isEmpty ? '未作答' : uAns),
                              ],
                            ),
                          ),
                        ],
                        const Divider(height: 24),
                        Builder(
                          builder: (context) {
                            final expText =
                                ansParts.length > 1 ? ansParts[1].trim() : '';
                            final hasAnswerOrExp =
                                sAns.isNotEmpty || expText.isNotEmpty;

                            if (!hasAnswerOrExp) {
                              return Container(
                                width: double.infinity,
                                margin: const EdgeInsets.only(bottom: 8),
                                decoration: BoxDecoration(
                                  color: Colors.orangeAccent.withOpacity(0.05),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color:
                                          Colors.orangeAccent.withOpacity(0.3)),
                                ),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () {
                                    Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) => QuestionEditScreen(
                                                question: q))).then((modified) {
                                      if (modified == true) _loadData();
                                    });
                                  },
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 16),
                                    child: Column(
                                      children: [
                                        Icon(Icons.edit_note_rounded,
                                            color: Colors.orangeAccent),
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
                              );
                            }

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('标准答案：',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey,
                                        fontWeight: FontWeight.bold)),
                                const SizedBox(height: 4),
                                _buildMarkdown(sAns.isEmpty ? '无' : sAns,
                                    overrideColor: Colors.green),
                                const SizedBox(height: 12),
                                const Text('解析：',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey,
                                        fontWeight: FontWeight.bold)),
                                const SizedBox(height: 4),
                                _buildMarkdown(
                                    expText.isEmpty ? '暂无解析' : expText,
                                    overrideColor: Colors.grey),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
