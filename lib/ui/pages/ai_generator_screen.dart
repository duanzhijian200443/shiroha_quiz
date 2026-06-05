import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/models/question_draft.dart';
import '../../data/repositories/exam_repository.dart';
import '../../data/repositories/question_repository.dart';
import '../../services/ai_service.dart';
import '../widgets/markdown_extensions.dart';

/// AI 智能组卷页面
/// - 用户输入知识点，调用 AiService.generateQuestions，展示题目卡片
/// - 支持一键将选中题目收入本地题库
class AiQuizScreen extends StatefulWidget {
  const AiQuizScreen({super.key});

  @override
  State<AiQuizScreen> createState() => _AiQuizScreenState();
}

class _AiQuizScreenState extends State<AiQuizScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _topicController = TextEditingController();
  final TextEditingController _bankNameController = TextEditingController();
  final QuestionRepository _questionRepository = QuestionRepository.instance;

  // ── 状态 ──────────────────────────────────────────────────────────────────
  late final _AiFeedbackController _feedbackCtrl;
  String? _errorMessage;
  List<QuestionDraft> _questions = [];
  List<String> _availableBanks = [];
  VoidCallback? _syncController;

  int _selectedCount = 1; // 默认生成 1 道题，降低超时概率
  int _selectedType = 0; // 默认单选(0=单选, 2=填空, 3=简答, -1=智能混合)

  /// 每道题是否被选中（用于批量入库）
  final List<bool> _selected = [];

  @override
  void initState() {
    super.initState();
    _bankNameController.text = 'AI 生成题库';
    _loadBanks();
    _feedbackCtrl = _AiFeedbackController(
      vsync: this,
      onStateChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _topicController.dispose();
    _bankNameController.dispose();
    _feedbackCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadBanks() async {
    try {
      final names = await _questionRepository.getAvailableBanksAndFolders();
      if (!mounted) return;
      setState(() {
        _availableBanks = names;
      });
    } catch (e) {
      debugPrint('加载题库词典失败: $e');
    }
  }

  void _beginLoading() {
    _feedbackCtrl.beginLoading();
    setState(() {
      _errorMessage = null;
      _questions = [];
      _selected.clear();
    });
  }

  void _endLoading() {
    _feedbackCtrl.endLoading();
  }

  // ── 核心：调用 AI 生成题目 ────────────────────────────────────────────────
  Future<void> _generateQuestions() async {
    final topic = _topicController.text.trim();
    if (topic.isEmpty) {
      _showSnack('请先输入知识点', isError: true);
      return;
    }

    _beginLoading();

    try {
      final drafts = await AiService.instance.generateQuestions(
        _topicController.text.trim(),
        count: _selectedCount,
        type: _selectedType,
      );
      if (!mounted) return;
      setState(() {
        _questions = drafts;
        _selected.addAll(List.filled(drafts.length, true)); // 默认全选
      });
      _feedbackCtrl.fadeCtrl.forward();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      _endLoading();
    }
  }

  // ── 将选中题目写入本地题库 ────────────────────────────────────────────────
  Future<void> _saveToBank() async {
    final bankName = _bankNameController.text.trim();
    if (bankName.isEmpty) {
      _showSnack('请填写目标题库名称', isError: true);
      return;
    }

    final List<QuestionDraft> toSave = [];
    for (int i = 0; i < _questions.length; i++) {
      if (_selected[i]) toSave.add(_questions[i]);
    }

    if (toSave.isEmpty) {
      _showSnack('请至少选择一道题', isError: true);
      return;
    }

    try {
      await _questionRepository.saveQuestionDraftsToBank(
        bankName: bankName,
        folderName: null,
        questions: toSave,
      );

      if (!mounted) return;
      _showSnack('🎉 已将 ${toSave.length} 道题收入 $bankName');

      // 入库成功后，从列表中剔除已保存的卡片
      setState(() {
        for (int i = _questions.length - 1; i >= 0; i--) {
          if (_selected[i]) {
            _questions.removeAt(i);
            _selected.removeAt(i);
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      _showSnack('写入失败: $e', isError: true);
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.redAccent : const Color(0xFF4C6ED7),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  // ── Markdown 渲染辅助方法 ─────────────────────────────────────────────────
  Widget _buildMarkdown(String text, ThemeData theme) {
    return buildLatexWidget(
      context,
      text,
      textColor: theme.textTheme.bodyLarge?.color,
      fontSize: 14.0,
    );
  }

  // ── 构建 ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subTextColor = isDark ? Colors.white54 : Colors.black54;
    final cardColor = theme.cardTheme.color ?? theme.colorScheme.surface;
    const accentColor = Color(0xFF4C6ED7);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'AI 智能组卷',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        centerTitle: false,
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.receipt_long_rounded,
                color: Colors.blueAccent),
            label: const Text('生成试卷',
                style: TextStyle(
                    color: Colors.blueAccent, fontWeight: FontWeight.bold)),
            onPressed: _showExamConfigDialog,
          ),
          if (_questions.isNotEmpty)
            TextButton.icon(
              onPressed: _saveToBank,
              icon: const Icon(Icons.save_alt_rounded, size: 18),
              label: const Text('一键入库'),
              style: TextButton.styleFrom(foregroundColor: accentColor),
            ),
        ],
      ),
      body: Column(
        children: [
          // ── 顶部输入栏 ──────────────────────────────────────────
          _buildInputPanel(accentColor, cardColor, textColor),

          // ── 结果区 ─────────────────────────────────────────────
          Expanded(
              child: _buildResultArea(
                  textColor, subTextColor, cardColor, accentColor)),
        ],
      ),
    );
  }

  Widget _buildInputPanel(Color accentColor, Color cardColor, Color textColor) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: cardColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 知识点输入框
          TextField(
            controller: _topicController,
            decoration: InputDecoration(
              labelText: '输入知识点',
              hintText: '例如：操作系统 的 页面置换算法',
              prefixIcon: const Icon(Icons.lightbulb_outline_rounded),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              filled: true,
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _generateQuestions(),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              // 目标题库名输入框
              Expanded(
                child: Autocomplete<String>(
                  initialValue:
                      TextEditingValue(text: _bankNameController.text),
                  optionsBuilder: (TextEditingValue textEditingValue) {
                    if (textEditingValue.text == '') {
                      return _availableBanks;
                    }
                    return _availableBanks.where((String option) {
                      return option
                          .toLowerCase()
                          .contains(textEditingValue.text.toLowerCase());
                    });
                  },
                  onSelected: (String selection) {
                    _bankNameController.text = selection;
                  },
                  fieldViewBuilder:
                      (context, controller, focusNode, onFieldSubmitted) {
                    if (controller.text.isEmpty &&
                        _bankNameController.text.isNotEmpty) {
                      controller.text = _bankNameController.text;
                    }
                    // 避免重复添加 listener 导致内存泄漏和性能问题
                    if (_syncController != null) {
                      controller.removeListener(_syncController!);
                    }
                    _syncController = () {
                      if (_bankNameController.text != controller.text) {
                        _bankNameController.text = controller.text;
                      }
                    };
                    controller.addListener(_syncController!);

                    return TextField(
                      controller: controller,
                      focusNode: focusNode,
                      decoration: InputDecoration(
                        labelText: '收入题库',
                        prefixIcon: const Icon(Icons.folder_open_rounded),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        filled: true,
                      ),
                      onSubmitted: (String value) {
                        onFieldSubmitted();
                      },
                    );
                  },
                ),
              ),
              const SizedBox(width: 10),
              // 生成按钮
              SizedBox(
                height: 50,
                child: ElevatedButton.icon(
                  onPressed:
                      _feedbackCtrl.isLoading ? null : _generateQuestions,
                  icon: _feedbackCtrl.isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.auto_awesome, size: 18),
                  label: Text(_feedbackCtrl.isLoading ? '生成中...' : '生成题目'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accentColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                ),
              ),
            ],
          ),
          // ── 生成设置面板 ──────────────────────────────────────────
          const SizedBox(height: 16),
          Row(
            children: [
              const Icon(Icons.tune, size: 16, color: Colors.grey),
              const SizedBox(width: 6),
              const Text(
                '生成设置',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              // 数量下拉选择
              DropdownButton<int>(
                value: _selectedCount,
                underline: const SizedBox(),
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF4C6ED7),
                ),
                icon: const Icon(
                  Icons.keyboard_arrow_down,
                  size: 16,
                  color: Color(0xFF4C6ED7),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 1,
                    child: Text('生成 1 道（极速）'),
                  ),
                  DropdownMenuItem(
                    value: 3,
                    child: Text('生成 3 道'),
                  ),
                  DropdownMenuItem(
                    value: 5,
                    child: Text('生成 5 道（易超时）'),
                  ),
                ],
                onChanged: (v) => setState(() => _selectedCount = v!),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 题型选择 Chips
          Wrap(
            spacing: 8.0,
            runSpacing: 4.0,
            children: [
              ChoiceChip(
                label: const Text('单选题', style: TextStyle(fontSize: 12)),
                selected: _selectedType == 0,
                onSelected: (_) => setState(() => _selectedType = 0),
                selectedColor: Colors.blue.shade100,
              ),
              ChoiceChip(
                label: const Text('填空题', style: TextStyle(fontSize: 12)),
                selected: _selectedType == 2,
                onSelected: (_) => setState(() => _selectedType = 2),
                selectedColor: Colors.blue.shade100,
              ),
              ChoiceChip(
                label: const Text('简答题', style: TextStyle(fontSize: 12)),
                selected: _selectedType == 3,
                onSelected: (_) => setState(() => _selectedType = 3),
                selectedColor: Colors.blue.shade100,
              ),
              ChoiceChip(
                label: const Text('智能混合', style: TextStyle(fontSize: 12)),
                selected: _selectedType == -1,
                onSelected: (_) => setState(() => _selectedType = -1),
                selectedColor: Colors.purple.shade100,
              ),
            ],
          ),
          const Divider(height: 24),
        ],
      ),
    );
  }

  Widget _buildResultArea(
      Color textColor, Color subTextColor, Color cardColor, Color accentColor) {
    // 加载中：动态心流提示
    if (_feedbackCtrl.isLoading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(strokeWidth: 3),
              const SizedBox(height: 24),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 500),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.2),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: Text(
                  _feedbackCtrl.tips[_feedbackCtrl.currentTipIndex],
                  key: ValueKey<int>(_feedbackCtrl.currentTipIndex),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: accentColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '大模型生成 JSON 通常需要 10-30 秒，请耐心等待',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: subTextColor,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 错误信息
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded,
                  size: 48, color: Colors.redAccent.shade200),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(color: textColor, height: 1.6),
              ),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: _generateQuestions,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    // 空白状态
    if (_questions.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome_outlined,
                size: 64, color: accentColor.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text(
              '输入知识点，让 AI 为你出题',
              style: TextStyle(color: subTextColor, fontSize: 15, height: 1.6),
            ),
          ],
        ),
      );
    }

    // 题目列表
    return FadeTransition(
      opacity: _feedbackCtrl.fadeAnim,
      child: Column(
        children: [
          // 操作栏
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Text(
                  '共 ${_questions.length} 道题',
                  style: TextStyle(
                      color: subTextColor, fontWeight: FontWeight.w500),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() {
                    final allSelected = _selected.every((s) => s);
                    for (int i = 0; i < _selected.length; i++) {
                      _selected[i] = !allSelected;
                    }
                  }),
                  child: Text(
                    _selected.every((s) => s) ? '取消全选' : '全选',
                    style: const TextStyle(color: Color(0xFF4C6ED7)),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _saveToBank,
                  icon: const Icon(Icons.save_alt_rounded, size: 16),
                  label: Text('入库 (${_selected.where((s) => s).length})'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accentColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    elevation: 0,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          // 题目卡片列表
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              itemCount: _questions.length,
              itemBuilder: (context, index) {
                return _buildQuestionCard(
                    index, textColor, subTextColor, cardColor, accentColor);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuestionCard(int index, Color textColor, Color subTextColor,
      Color cardColor, Color accentColor) {
    final q = _questions[index];
    final isSelected = _selected[index];
    final options = q.options;
    final answer = q.standardAnswer;
    final explanation = q.explanation;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isSelected
              ? accentColor.withValues(alpha: 0.6)
              : Colors.transparent,
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 题头 ─────────────────────────────────────────────────
          ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            leading: CircleAvatar(
              backgroundColor: isSelected ? accentColor : Colors.grey.shade300,
              radius: 14,
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: isSelected ? Colors.white : Colors.grey,
                ),
              ),
            ),
            title: _buildMarkdown(q.content, Theme.of(context)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      color: Colors.redAccent, size: 20),
                  onPressed: () {
                    setState(() {
                      _questions.removeAt(index);
                      _selected.removeAt(index);
                    });
                  },
                  tooltip: '删除此题',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 8),
                Checkbox(
                  value: isSelected,
                  activeColor: accentColor,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4)),
                  onChanged: (val) =>
                      setState(() => _selected[index] = val ?? false),
                ),
              ],
            ),
            onTap: () => setState(() => _selected[index] = !_selected[index]),
          ),
          // ── 选项 ─────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              children: options.map((opt) {
                final optLetter =
                    opt.isNotEmpty ? opt.substring(0, 1).toUpperCase() : '';
                final isAnswer = optLetter == answer.toUpperCase();
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: isAnswer
                        ? const Color(0xFF2EAA70).withValues(alpha: 0.12)
                        : Colors.grey.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isAnswer
                          ? const Color(0xFF2EAA70).withValues(alpha: 0.5)
                          : Colors.transparent,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child:
                            _buildMarkdown(opt.toString(), Theme.of(context)),
                      ),
                      if (isAnswer) ...[
                        const SizedBox(width: 6),
                        const Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Icon(
                            Icons.check_circle_rounded,
                            size: 14,
                            color: Color(0xFF2EAA70),
                          ),
                        ),
                      ]
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
          // ── 解析 ─────────────────────────────────────────────────
          if (explanation.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 14, color: accentColor.withValues(alpha: 0.8)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _buildMarkdown(explanation, Theme.of(context)),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── 试卷生成专用逻辑 ──────────────────────────────────────────────────
  Future<void> _showExamConfigDialog() async {
    int sCount = 5;
    int fCount = 2;
    int shCount = 1;
    final customPromptController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('📝 组装全真模拟卷',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: _topicController,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: InputDecoration(
                      labelText: '目标知识点 (必填)',
                      hintText: '例如：操作系统 页面置换',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildCounterRow(
                      '单选题', sCount, (v) => setDialogState(() => sCount = v)),
                  _buildCounterRow(
                      '填空题', fCount, (v) => setDialogState(() => fCount = v)),
                  _buildCounterRow(
                      '简答题', shCount, (v) => setDialogState(() => shCount = v)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: customPromptController,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: '附加提示词 / 特殊出题要求 (选填)',
                      hintText: '例如：请侧重于出代码题，难度对标清华期末考试...',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.all(12),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '⚠️ 生成完整试卷可能需要 1~3 分钟，请耐心等待',
                    style: TextStyle(fontSize: 12, color: Colors.orange),
                  ),
                ],
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                ElevatedButton(
                  onPressed: _topicController.text.trim().isEmpty
                      ? null
                      : () => Navigator.pop(context, true),
                  child: const Text('开始组卷'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == true) {
      _generateExam(
          sCount, fCount, shCount, customPromptController.text.trim());
    }
  }

  Widget _buildCounterRow(String label, int value, Function(int) onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: value > 0 ? () => onChanged(value - 1) : null,
              ),
              Text(value.toString(),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: value < 20 ? () => onChanged(value + 1) : null,
              ),
            ],
          )
        ],
      ),
    );
  }

  Future<void> _generateExam(int s, int f, int sh, String customPrompt) async {
    _beginLoading();

    try {
      final result = await AiService.instance.generateExamPaper(
        topic: _topicController.text.trim(),
        singleCount: s,
        fillCount: f,
        shortCount: sh,
        customPrompt: customPrompt,
      );

      // 2. 核心合流：将 AI 生成的全新题目直接落盘为试卷 (source_type: 1)
      final paperTitle = '${_topicController.text.trim()} AI模拟卷';
      await ExamRepository.instance.createExamPaperFromDrafts(
        paperTitle,
        1,
        result,
      );

      if (mounted) {
        // 3. 成功后直接退回模考中心，并弹窗提示
        Navigator.pop(context); // 退出 AI 组卷页面
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('🎉 试卷 [$paperTitle] 已生成！请在模考中心点击进入考场。'),
            backgroundColor: Colors.green));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString()), backgroundColor: Colors.redAccent));
      }
    } finally {
      _endLoading();
    }
  }
}

class _AiFeedbackController {
  final TickerProvider vsync;
  final VoidCallback onStateChanged;

  bool isLoading = false;
  int currentTipIndex = 0;
  Timer? _loadingTimer;

  late final AnimationController fadeCtrl;
  late final Animation<double> fadeAnim;

  final List<String> tips = [
    '正在唤醒 AI 命题引擎...',
    '正在查阅相关知识点考纲...',
    '正在构思极具迷惑性的选项...',
    '正在撰写详细的题目解析...',
    '正在进行格式校验与 JSON 打包...',
    'AI 正在全力输出，请稍等...',
  ];

  _AiFeedbackController({required this.vsync, required this.onStateChanged}) {
    fadeCtrl = AnimationController(
      vsync: vsync,
      duration: const Duration(milliseconds: 400),
    );
    fadeAnim = CurvedAnimation(parent: fadeCtrl, curve: Curves.easeOut);
  }

  void dispose() {
    _loadingTimer?.cancel();
    fadeCtrl.dispose();
  }

  void beginLoading() {
    isLoading = true;
    currentTipIndex = 0;
    fadeCtrl.reset();
    onStateChanged();

    _loadingTimer?.cancel();
    _loadingTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (currentTipIndex < tips.length - 1) {
        currentTipIndex++;
        onStateChanged();
      }
    });
  }

  void endLoading() {
    _loadingTimer?.cancel();
    isLoading = false;
    onStateChanged();
  }
}
