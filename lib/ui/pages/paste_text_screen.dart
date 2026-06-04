import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PasteTextScreen extends StatefulWidget {
  const PasteTextScreen({super.key});

  @override
  State<PasteTextScreen> createState() => _PasteTextScreenState();
}

class _PasteTextScreenState extends State<PasteTextScreen> {
  final TextEditingController _textController = TextEditingController();

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data != null && data.text != null) {
      setState(() {
        _textController.text = data.text!;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title:
            const Text('粘贴文本解析', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          TextButton(
            onPressed: () {
              if (_textController.text.trim().length < 10) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('有效文本长度不能少于 10 个字符')));
                return;
              }
              Navigator.pop(context, _textController.text);
            },
            child: const Text('确认提取',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.blueAccent)),
          )
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('请将题目标准文本粘贴至下方：',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.grey)),
                  TextButton.icon(
                    onPressed: _pasteFromClipboard,
                    icon: const Icon(Icons.paste_rounded, size: 16),
                    label: const Text('从剪贴板读取'),
                  )
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: TextField(
                  controller: _textController,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: InputDecoration(
                    hintText: '例如:\n1. 中国的首都是哪里？\nA. 北京\nB. 上海\n答案：A',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: theme.cardTheme.color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
