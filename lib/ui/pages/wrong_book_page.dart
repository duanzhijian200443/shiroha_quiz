import 'package:flutter/material.dart';

import '../../data/repositories/question_repository.dart';
import '../models/persisted_question_view.dart';
import '../widgets/persisted_question_card.dart';
import 'question_edit_screen.dart';

class WrongBookPage extends StatefulWidget {
  const WrongBookPage({super.key, this.questionRepository});

  /// Injectable for widget tests; defaults to the shared repository.
  final QuestionRepository? questionRepository;

  @override
  State<WrongBookPage> createState() => _WrongBookPageState();
}

class _WrongBookPageState extends State<WrongBookPage> {
  static const Color _bgColor = Color(0xFFF4F6FA);
  static const Color _primaryColor = Color(0xFF4C6ED7);

  List<PersistedQuestionView> _questions = const [];
  bool _isLoading = true;
  bool _hasLoadError = false;

  QuestionRepository get _questionRepository =>
      widget.questionRepository ?? QuestionRepository.instance;

  @override
  void initState() {
    super.initState();
    _loadQuestions();
  }

  /// The only wrong-book read: the repository returns lapsed rows from every
  /// bank (SQL filter `lapses > 0`, `last_lapse_time DESC`) as typed union
  /// rows with review metrics. The page never touches raw maps or SQLite.
  Future<void> _loadQuestions() async {
    setState(() {
      _isLoading = true;
      _hasLoadError = false;
    });
    try {
      final persisted = await _questionRepository.getPersistedWrongQuestions();
      if (!mounted) return;
      setState(() {
        _questions = List<PersistedQuestionView>.unmodifiable(
          persisted.map(PersistedQuestionViewAdapter.fromPersisted),
        );
        _isLoading = false;
      });
    } catch (_) {
      debugPrint('Wrong book load failed');
      if (!mounted) return;
      setState(() {
        _questions = const [];
        _isLoading = false;
        _hasLoadError = true;
      });
    }
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
      // Typed rows rely on the v15 FK `ON DELETE CASCADE` to remove the
      // sidecar; clearing review-only state is untouched by this page.
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
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
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
                '错题本中存在无法安全读取的题目，请重试或修复数据',
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
    if (_questions.isEmpty) {
      return _buildEmptyState();
    }
    return ListView.builder(
      addRepaintBoundaries: true,
      padding: const EdgeInsets.all(16),
      itemCount: _questions.length,
      itemBuilder: (context, index) {
        final question = _questions[index];
        return PersistedQuestionCard(
          question: question,
          onDelete: () => _deleteQuestion(question),
          // Typed rows never get a legacy edit entry (Survey Q7 gap closed).
          onEditLegacy:
              question.isTyped ? null : () => _openLegacyEditor(question),
        );
      },
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
}
