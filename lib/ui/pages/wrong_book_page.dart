import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'package:shiroha_quiz/core/review_engine_service.dart';
import '../widgets/markdown_extensions.dart';

class WrongBookPage extends StatefulWidget {
  const WrongBookPage({super.key});

  @override
  State<WrongBookPage> createState() => _WrongBookPageState();
}

class _WrongBookPageState extends State<WrongBookPage> {
  static const Color _bgColor = Color(0xFFF4F6FA);
  static const Color _primaryColor = Color(0xFF4C6ED7);

  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = ReviewEngineService().getDetailedWrongQuestions();
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
      body: FutureBuilder<List<Map<String, dynamic>>>(
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

  List<String> _parseOptions(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    dynamic d;
    try {
      d = json.decode(raw);
    } catch (_) {
      return [raw];
    }
    if (d is String) {
      try {
        d = json.decode(d);
      } catch (_) {
        return [d as String];
      }
    }
    if (d is List) return d.map((e) => e.toString()).toList();
    return [raw];
  }

  Widget _buildList(List<Map<String, dynamic>> items) {
    return ListView.builder(
      addRepaintBoundaries: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final q = items[index];
        // Safely access data from the new query
        final content = (q['content'] as String?) ?? '';
        final bankName = (q['bank_name'] as String?) ?? '默认题库';
        final lapses = (q['lapses'] as num?)?.toInt() ?? 0;
        final difficulty = (q['difficulty'] as num?)?.toDouble() ?? 0.0;
        final stability = (q['stability'] as num?)?.toDouble() ?? 0.0;
        final answer = (q['standard_answer'] as String?) ?? '';
        final options = _parseOptions(q['options'] as String?);

        final mdText = StringBuffer();
        mdText.writeln('### 题目内容');
        mdText.writeln(content);
        mdText.writeln();

        if (options.isNotEmpty) {
          mdText.writeln('#### 选项');
          for (int i = 0; i < options.length; i++) {
            mdText.writeln('${String.fromCharCode(65 + i)}. ${options[i]}');
          }
          mdText.writeln();
        }

        mdText.writeln('**正确答案：** `$answer`');
        mdText.writeln();
        mdText.writeln('---');
        mdText.writeln('**复习数据：**');
        mdText.writeln('- **错误次数：** $lapses');
        mdText.writeln('- **难度系数：** ${difficulty.toStringAsFixed(2)}');
        mdText.writeln('- **稳定性：** ${stability.toStringAsFixed(2)}');

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 0,
          color: Colors.white,
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            title: Text(
              bankName,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: Colors.grey.shade800,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              content,
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
                '错 $lapses 次',
                style: const TextStyle(
                  color: Colors.redAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            children: [
              MarkdownBody(
                data: mdText.toString(),
                selectable: true,
                extensionSet: latexExtensionSet,
                builders: {
                  'math': MathElementBuilder(),
                  'math_block': MathBlockBuilder(),
                  'code': CodeBlockBuilder(),
                },
                styleSheet: markdownSheet(context),
              ),
            ],
          ),
        );
      },
    );
  }
}
