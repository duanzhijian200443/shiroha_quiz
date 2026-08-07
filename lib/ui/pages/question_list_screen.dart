import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/repositories/question_repository.dart';
import '../models/persisted_question_view.dart';
import '../widgets/persisted_question_card.dart';
import 'question_edit_screen.dart';
import 'typed_answer_repair_screen.dart';

class QuestionListScreen extends StatefulWidget {
  final String bankName;
  final QuestionRepository? questionRepository;
  final ValueChanged<int?>? onLoadFinished;

  const QuestionListScreen({
    super.key,
    required this.bankName,
    this.questionRepository,
    this.onLoadFinished,
  });

  @override
  State<QuestionListScreen> createState() => _QuestionListScreenState();
}

class _QuestionListScreenState extends State<QuestionListScreen> {
  List<PersistedQuestionView> _allQuestions = [];
  List<PersistedQuestionView> _visibleQuestions = [];
  bool _isLoading = true;
  bool _hasLoadError = false;
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;

  QuestionRepository get _questionRepository =>
      widget.questionRepository ?? QuestionRepository.instance;

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
    setState(() {
      _isLoading = true;
      _hasLoadError = false;
    });
    try {
      final persisted = await _questionRepository.getPersistedQuestionsByBank(
        widget.bankName,
      );
      if (!mounted) return;
      final views = List<PersistedQuestionView>.unmodifiable(
        persisted.map(PersistedQuestionViewAdapter.fromPersisted),
      );
      setState(() {
        _allQuestions = views;
        _applyQuery();
        _isLoading = false;
      });
      widget.onLoadFinished?.call(views.length);
    } catch (_) {
      debugPrint('Question list load failed');
      if (!mounted) return;
      setState(() {
        _allQuestions = [];
        _visibleQuestions = [];
        _isLoading = false;
        _hasLoadError = true;
      });
      widget.onLoadFinished?.call(null);
    }
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      setState(_applyQuery);
    });
  }

  void _applyQuery() {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      _visibleQuestions = _allQuestions;
      return;
    }
    _visibleQuestions = [
      for (final question in _allQuestions)
        if (question.searchText.toLowerCase().contains(query)) question,
    ];
  }

  Future<void> _deleteQuestion(PersistedQuestionView question) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          '确认删除',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: const Text('删除后无法恢复，确定要删除此题目吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    if (question.storageId.isEmpty) return;
    try {
      await _questionRepository.deleteQuestion(question.storageId);
      await _loadQuestions();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('删除失败，请稍后重试')),
      );
    }
  }

  void _openLegacyEditor(PersistedQuestionView question) {
    final payload = question.legacyEditPayload;
    if (payload == null) return;
    Navigator.push(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => QuestionEditScreen(question: payload),
      ),
    ).then((modified) {
      if (modified == true && mounted) _loadQuestions();
    });
  }

  void _openTypedRepair(PersistedQuestionView question) {
    final draft = question.typedDraft;
    if (draft == null) return;
    Navigator.push(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => TypedAnswerRepairScreen(
          question: question,
          draft: draft,
          repository: widget.questionRepository,
        ),
      ),
    ).then((modified) {
      if (modified == true && mounted) _loadQuestions();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          '${widget.bankName} 题库',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 8.0,
            ),
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
      body: _buildBody(isDark),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_hasLoadError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                color: Colors.redAccent,
                size: 48,
              ),
              const SizedBox(height: 12),
              const Text(
                '题库中存在无法安全读取的题目，请重试或修复数据',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadQuestions,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_visibleQuestions.isEmpty) {
      return const Center(
        child: Text('没有找到匹配的题目', style: TextStyle(color: Colors.grey)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16.0),
      itemCount: _visibleQuestions.length,
      itemBuilder: (context, index) {
        final question = _visibleQuestions[index];
        return PersistedQuestionCard(
          question: question,
          onDelete: () => _deleteQuestion(question),
          onEditLegacy:
              question.isTyped ? null : () => _openLegacyEditor(question),
          onRepairTypedAnswer:
              question.isTyped ? () => _openTypedRepair(question) : null,
        );
      },
    );
  }
}
