import 'package:flutter/material.dart';
import 'practice_page.dart';
import 'question_list_screen.dart';
import '../../application/questions/question_bank_mutation_command.dart';
import '../../data/repositories/question_repository.dart';

class BankDetailScreen extends StatefulWidget {
  final String bankName;

  @visibleForTesting
  final QuestionBankMutationCommand? questionBankMutation;

  const BankDetailScreen({
    super.key,
    required this.bankName,
    this.questionBankMutation,
  });

  @override
  State<BankDetailScreen> createState() => _BankDetailScreenState();
}

class _BankDetailScreenState extends State<BankDetailScreen> {
  bool _isPomodoroActive = false;

  QuestionBankMutationCommand get _questionBankMutation =>
      widget.questionBankMutation ??
      QuestionBankMutationCommand(QuestionRepository.instance);

  void _startPractice(BuildContext context, int? filterType) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PracticePage(
          bankName: widget.bankName,
          filterType: filterType,
          isPomodoroActive: _isPomodoroActive,
        ),
      ),
    );
  }

  Widget _buildPracticeCard(BuildContext context, String icon, String title,
      String subtitle, int? type) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textLevel1 =
        isDark ? Colors.white.withValues(alpha: 0.87) : Colors.black87;
    final textLevel2 =
        isDark ? Colors.white.withValues(alpha: 0.60) : Colors.black54;
    final iconLevel3 = isDark ? Colors.white38 : Colors.black38;
    final cardBorder =
        isDark ? Colors.white.withValues(alpha: 0.1) : Colors.grey.shade200;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12.0),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: cardBorder),
        borderRadius: BorderRadius.circular(16),
      ),
      color: theme.cardTheme.color ??
          (isDark ? const Color(0xFF1E1E1E) : Colors.white),
      child: ListTile(
        leading: Text(icon, style: const TextStyle(fontSize: 24)),
        title: Text(title,
            style: TextStyle(fontWeight: FontWeight.w600, color: textLevel1)),
        subtitle:
            Text(subtitle, style: TextStyle(color: textLevel2, fontSize: 12)),
        trailing:
            Icon(Icons.arrow_forward_ios_rounded, size: 16, color: iconLevel3),
        onTap: () => _startPractice(context, type),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textLevel1 =
        isDark ? Colors.white.withValues(alpha: 0.87) : Colors.black87;
    final textLevel2 =
        isDark ? Colors.white.withValues(alpha: 0.60) : Colors.black54;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(widget.bankName,
            style: const TextStyle(fontWeight: FontWeight.w800)),
        backgroundColor: theme.scaffoldBackgroundColor,
        foregroundColor: textLevel1,
        elevation: 0,
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            tooltip: '删除题库',
            onPressed: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('删除题库'),
                  content: Text(
                      '确定要永久删除题库「${widget.bankName}」及其中所有题目和复习记录吗？此操作不可逆！'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消')),
                    TextButton(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        try {
                          await _questionBankMutation
                              .deleteQuestionBank(widget.bankName);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('题库已删除')));
                          Navigator.pop(context);
                        } catch (error) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('删除失败: $error')),
                          );
                        }
                      },
                      child: const Text('彻底删除',
                          style: TextStyle(
                              color: Colors.redAccent,
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          Text(
            '选择专项练习',
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold, color: textLevel1),
          ),
          const SizedBox(height: 16),
          Card(
            elevation: 0,
            margin: const EdgeInsets.only(bottom: 24.0),
            color: theme.primaryColor.withValues(alpha: 0.05),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                    color: theme.primaryColor.withValues(alpha: 0.2))),
            child: ListTile(
              leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                      color: Colors.blueAccent,
                      borderRadius: BorderRadius.circular(8)),
                  child:
                      const Icon(Icons.menu_book_rounded, color: Colors.white)),
              title: const Text('浏览题库内容',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('上帝视角查看所有题目与解析',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              trailing: const Icon(Icons.arrow_forward_ios,
                  size: 16, color: Colors.grey),
              onTap: () {
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) =>
                            QuestionListScreen(bankName: widget.bankName)));
              },
            ),
          ),
          _buildPracticeCard(context, '🎯', '全类型自适应复习', '智能混排，全面提升', null),
          _buildPracticeCard(context, '📝', '选择题专项', '单选多选集中突破', 0),
          _buildPracticeCard(context, '✏️', '填空题专项', '精准记忆，不留死角', 2),
          _buildPracticeCard(context, '✍️', '简答题专项', '主观题深度思考', 3),
          const SizedBox(height: 32),
          Divider(color: isDark ? Colors.white24 : Colors.grey.shade200),
          SwitchListTile(
            title: Text('🍅 开启番茄钟模式 (25分钟)',
                style:
                    TextStyle(fontWeight: FontWeight.w600, color: textLevel1)),
            subtitle:
                Text('沉浸式专注，结束自动结算数据', style: TextStyle(color: textLevel2)),
            value: _isPomodoroActive,
            activeThumbColor: Colors.deepOrange,
            contentPadding: EdgeInsets.zero,
            onChanged: (bool value) {
              setState(() {
                _isPomodoroActive = value;
              });
            },
          ),
        ],
      ),
    );
  }
}
