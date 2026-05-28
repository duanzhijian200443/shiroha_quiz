import 'package:flutter/material.dart';
import 'dart:convert';
import '../../core/database/database_helper.dart';

import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_markdown_latex/flutter_markdown_latex.dart';
import 'package:markdown/markdown.dart' as md;
import '../../utils/ai_data_sanitizer.dart';
import '../widgets/markdown_extensions.dart' show buildMarkdownImage, RobustLatexElementBuilder;

class QuestionEditScreen extends StatefulWidget {
  final Map<String, dynamic> question;
  const QuestionEditScreen({super.key, required this.question});

  @override
  State<QuestionEditScreen> createState() => _QuestionEditScreenState();
}

class _QuestionEditScreenState extends State<QuestionEditScreen> {
  late TextEditingController _contentCtrl;
  late TextEditingController _optionsCtrl;
  late TextEditingController _answerCtrl;
  late TextEditingController _explanationCtrl;

  late FocusNode _contentFocus;
  late FocusNode _optionsFocus;
  late FocusNode _answerFocus;
  late FocusNode _explanationFocus;

  @override
  void initState() {
    super.initState();
    _contentFocus = FocusNode()..addListener(() => setState(() {}));
    _optionsFocus = FocusNode()..addListener(() => setState(() {}));
    _answerFocus = FocusNode()..addListener(() => setState(() {}));
    _explanationFocus = FocusNode()..addListener(() => setState(() {}));

    _contentCtrl = TextEditingController(text: widget.question['content']?.toString() ?? '');
    _answerCtrl = TextEditingController(text: widget.question['standard_answer']?.toString() ?? '');
    _explanationCtrl = TextEditingController(text: widget.question['explanation']?.toString() ?? '');
    
    String optsStr = '';
    if (widget.question['type'] == 0) {
      try {
        final opts = jsonDecode(widget.question['options'].toString()) as List;
        optsStr = opts.join('\n');
      } catch (_) {}
    }
    _optionsCtrl = TextEditingController(text: optsStr);
  }

  @override
  void dispose() {
    _contentFocus.dispose();
    _optionsFocus.dispose();
    _answerFocus.dispose();
    _explanationFocus.dispose();

    _contentCtrl.dispose();
    _optionsCtrl.dispose();
    _answerCtrl.dispose();
    _explanationCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final updated = Map<String, dynamic>.from(widget.question);
    updated['content'] = _contentCtrl.text.trim();
    updated['standard_answer'] = _answerCtrl.text.trim();
    updated['explanation'] = _explanationCtrl.text.trim();
    
    if (updated['type'] == 0) {
      final optsList = _optionsCtrl.text.trim().split('\n').where((s) => s.trim().isNotEmpty).toList();
      updated['options'] = jsonEncode(optsList);
    }

    try {
      await DatabaseHelper.instance.updateQuestion(updated);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('题目修改成功')));
        Navigator.pop(context, true); // 返回 true 标识已修改
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e'), backgroundColor: Colors.redAccent));
    }
  }

  Widget _buildMarkdown(String text, {bool isOption = false}) {
    final theme = Theme.of(context);
    final textColor = theme.textTheme.bodyLarge?.color;
    final fontSize = isOption ? 15.0 : 16.0;

    return MarkdownBody(
      data: AiDataSanitizer.formatLatex(text),
      selectable: true,
      imageBuilder: buildMarkdownImage,
      builders: {
        'latex': RobustLatexElementBuilder(
          textStyle: TextStyle(color: textColor, fontSize: fontSize),
        ),
      },
      extensionSet: md.ExtensionSet(
        [LatexBlockSyntax()],
        [LatexInlineSyntax(), ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes],
      ),
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: TextStyle(fontSize: fontSize, color: textColor, height: 1.6),
        codeblockDecoration: BoxDecoration(
          color: theme.brightness == Brightness.dark ? const Color(0xFF1E1E1E) : const Color(0xFFF5F7FA),
          borderRadius: BorderRadius.circular(8),
        ),
        code: TextStyle(
          backgroundColor: Colors.transparent,
          fontFamily: 'monospace',
          color: theme.primaryColor,
        ),
      ),
    );
  }

  Widget _buildOptionsPreview(String text) {
    final opts = text.split('\n').where((s) => s.trim().isNotEmpty).toList();
    if (opts.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: opts.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final letter = String.fromCharCode(65 + i);
        Color border = isDark ? Colors.white12 : Colors.grey.shade200;
        Color lBg = isDark ? Colors.grey.shade800 : Colors.grey.shade100;
        Color lFg = isDark ? Colors.grey.shade300 : Colors.grey.shade600;

        return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: border, width: 1)),
            child: Row(children: [
              Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: lBg),
                  alignment: Alignment.center,
                  child: Text(letter, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: lFg))),
              const SizedBox(width: 12),
              Expanded(
                child: _buildMarkdown(opts[i], isOption: true),
              ),
            ]));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isSelection = widget.question['type'] == 0;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('编辑题目', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.save, color: Colors.blueAccent),
            label: const Text('保存', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent)),
            onPressed: () {
              FocusScope.of(context).unfocus();
              _save();
            },
          )
        ],
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.opaque,
        child: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            _buildField(
              label: '题干 (支持 LaTeX & Markdown)', 
              controller: _contentCtrl, 
              focusNode: _contentFocus,
              maxLines: 5,
              renderMarkdown: (text) => _buildMarkdown(text),
            ),
            if (isSelection) ...[
              const SizedBox(height: 16),
              _buildField(
                label: '选项 (每行一个选项)', 
                controller: _optionsCtrl, 
                focusNode: _optionsFocus,
                maxLines: 4,
                renderMarkdown: (text) => _buildOptionsPreview(text),
              ),
            ],
            const SizedBox(height: 16),
            _buildField(
              label: '标准答案', 
              controller: _answerCtrl, 
              focusNode: _answerFocus,
              maxLines: 2,
              renderMarkdown: (text) => _buildMarkdown('**正确答案:** \n$text'),
            ),
            const SizedBox(height: 16),
            _buildField(
              label: '详细解析', 
              controller: _explanationCtrl, 
              focusNode: _explanationFocus,
              maxLines: 6,
              renderMarkdown: (text) => _buildMarkdown(text),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildField({
    required String label, 
    required TextEditingController controller, 
    required FocusNode focusNode,
    int maxLines = 1,
    required Widget Function(String) renderMarkdown,
  }) {
    if (!focusNode.hasFocus) {
      return GestureDetector(
        onTap: () => FocusScope.of(context).requestFocus(focusNode),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).cardTheme.color ?? Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.2 : 0.04),
                blurRadius: 8,
                offset: const Offset(0, 2)
              )
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
              const SizedBox(height: 12),
              if (controller.text.trim().isEmpty)
                Text('点击添加内容...', style: TextStyle(color: Colors.grey.shade400, fontStyle: FontStyle.italic))
              else
                renderMarkdown(controller.text),
            ],
          ),
        ),
      );
    }

    return TextField(
      controller: controller,
      focusNode: focusNode,
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        alignLabelWithHint: true,
        filled: true,
        fillColor: Theme.of(context).cardTheme.color,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Theme.of(context).primaryColor)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Theme.of(context).primaryColor, width: 2)),
      ),
    );
  }
}