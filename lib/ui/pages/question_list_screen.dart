import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:async';
import '../../core/database/database_helper.dart';
import '../../utils/ai_data_sanitizer.dart';
import 'question_edit_screen.dart';
import '../widgets/markdown_extensions.dart';

class QuestionListScreen extends StatefulWidget {
  final String bankName;
  const QuestionListScreen({super.key, required this.bankName});
  @override
  State<QuestionListScreen> createState() => _QuestionListScreenState();
}

class _QuestionListScreenState extends State<QuestionListScreen> {
  List<Map<String, dynamic>> _questions = [];
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadQuestions();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadQuestions() async {
    setState(() => _isLoading = true);
    try {
      final data =
          await DatabaseHelper.instance.getQuestionsByBank(widget.bankName);
      if (mounted)
        setState(() {
          _questions = data;
          _isLoading = false;
        });
    } catch (e) {
      debugPrint('加载题目列表失败: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      setState(() => _isLoading = true);
      try {
        final data = await DatabaseHelper.instance
            .searchQuestions(widget.bankName, query);
        if (mounted)
          setState(() {
            _questions = data;
            _isLoading = false;
          });
      } catch (e) {
        debugPrint('搜索题目失败: $e');
        if (mounted) setState(() => _isLoading = false);
      }
    });
  }

  Future<void> _deleteQuestion(String id) async {
    final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('确认删除',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              content: const Text('删除后无法恢复，确定要删除此题目吗？'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child:
                        const Text('取消', style: TextStyle(color: Colors.grey))),
                ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent),
                    child: const Text('删除')),
              ],
            ));
    if (confirm == true) {
      await DatabaseHelper.instance.deleteSingleQuestion(id);
      _onSearchChanged(_searchController.text);
    }
  }

  Widget _buildMarkdown(String data, {Color? overrideColor}) {
    return buildLatexWidget(
      context,
      data,
      textColor: overrideColor,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text('${widget.bankName} 题库',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: '搜索题目内容、选项或解析...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: isDark ? Colors.white10 : Colors.grey.shade100,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
            ),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _questions.isEmpty
              ? const Center(
                  child:
                      Text('没有找到匹配的题目', style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  padding: const EdgeInsets.all(16.0),
                  itemCount: _questions.length,
                  itemBuilder: (context, index) {
                    final q = _questions[index];

                    String typeStr = '未知';
                    Color typeColor = Colors.grey;
                    switch (q['type']) {
                      case 0:
                        typeStr = '单选';
                        typeColor = Colors.blueAccent;
                        break;
                      case 1:
                        typeStr = '多选';
                        typeColor = Colors.orangeAccent;
                        break;
                      case 2:
                        typeStr = '填空';
                        typeColor = Colors.purpleAccent;
                        break;
                      case 3:
                        typeStr = '简答';
                        typeColor = Colors.greenAccent;
                        break;
                    }

                    // 处理选项展示
                    String optionsDisplay = '';
                    if (q['type'] == 0 || q['type'] == 1) {
                      try {
                        List<dynamic> opts = json.decode(q['options'] ?? '[]');
                        for (int i = 0; i < opts.length; i++) {
                          String label = String.fromCharCode(65 + i);
                          String optStr = opts[i].toString().trim();
                          String stripped = optStr
                              .replaceFirst(
                                  RegExp(
                                      r'^(?:\s*(?:[A-D][\.、．]|\([A-D]\)|（[A-D]）)\s*)+'),
                                  '')
                              .trim();
                          if (stripped.isEmpty) stripped = optStr;
                          stripped =
                              AiDataSanitizer.cleanLatexBeforeDB(stripped);
                          optionsDisplay += '$label. $stripped\n\n';
                        }
                      } catch (_) {}
                    }

                    return Card(
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(
                              color: isDark
                                  ? Colors.white10
                                  : Colors.grey.shade200)),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: typeColor.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(typeStr,
                                      style: TextStyle(
                                          color: typeColor,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold)),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      color: Colors.redAccent, size: 20),
                                  onPressed: () => _deleteQuestion(
                                      q['id']?.toString() ?? ''),
                                  tooltip: '删除题目',
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            _buildMarkdown(q['content'] ?? ''),
                            if (optionsDisplay.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              _buildMarkdown(optionsDisplay),
                            ],
                            const Divider(height: 24),
                            Builder(
                              builder: (context) {
                                final ansParts =
                                    (q['standard_answer']?.toString() ?? '')
                                        .split('|||');
                                final ansText = ansParts.isNotEmpty
                                    ? ansParts[0].trim()
                                    : '';
                                final expText = ansParts.length > 1
                                    ? ansParts[1].trim()
                                    : '';
                                final hasAnswerOrExp =
                                    ansText.isNotEmpty || expText.isNotEmpty;

                                if (!hasAnswerOrExp) {
                                  return Container(
                                    width: double.infinity,
                                    margin: const EdgeInsets.only(bottom: 8),
                                    decoration: BoxDecoration(
                                      color:
                                          Colors.orangeAccent.withOpacity(0.05),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                          color: Colors.orangeAccent
                                              .withOpacity(0.3)),
                                    ),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(12),
                                      onTap: () {
                                        Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                    builder: (_) =>
                                                        QuestionEditScreen(
                                                            question: q)))
                                            .then((modified) {
                                          if (modified == true)
                                            _onSearchChanged(
                                                _searchController.text);
                                        });
                                      },
                                      child: const Padding(
                                        padding:
                                            EdgeInsets.symmetric(vertical: 16),
                                        child: Column(
                                          children: [
                                            Icon(Icons.edit_note_rounded,
                                                color: Colors.orangeAccent),
                                            SizedBox(height: 4),
                                            Text('✍️ 暂无答案，点击手动添加或修改',
                                                style: TextStyle(
                                                    color: Colors.orangeAccent,
                                                    fontSize: 13,
                                                    fontWeight:
                                                        FontWeight.bold)),
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
                                    _buildMarkdown(
                                        ansText.isEmpty ? '无' : ansText,
                                        overrideColor: Colors.green),
                                    const SizedBox(height: 12),
                                    const Text('解析：',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey,
                                            fontWeight: FontWeight.bold)),
                                    const SizedBox(height: 4),
                                    _buildMarkdown(
                                        expText.isEmpty ? '无解析' : expText,
                                        overrideColor: Colors.grey),
                                  ],
                                );
                              },
                            ),
                            const Divider(height: 24),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton.icon(
                                  icon: const Icon(Icons.edit_note_rounded,
                                      size: 16, color: Colors.blueAccent),
                                  label: const Text('编辑题目',
                                      style:
                                          TextStyle(color: Colors.blueAccent)),
                                  onPressed: () {
                                    Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) => QuestionEditScreen(
                                                question: q))).then((modified) {
                                      if (modified == true)
                                        _onSearchChanged(
                                            _searchController.text);
                                    });
                                  },
                                ),
                              ],
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
