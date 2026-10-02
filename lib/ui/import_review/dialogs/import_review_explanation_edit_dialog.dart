import 'package:flutter/material.dart';

/// Plain-text editor for one question's explanation.
///
/// Returns the edited text through [Navigator.pop]; the page decides whether the
/// result counts as an edit.
class ImportReviewExplanationEditDialog extends StatefulWidget {
  const ImportReviewExplanationEditDialog(
      {super.key, required this.initialText});

  final String initialText;

  @override
  State<ImportReviewExplanationEditDialog> createState() =>
      _ImportReviewExplanationEditDialogState();
}

/// Owns its controller so the field stays valid for the closing animation.
class _ImportReviewExplanationEditDialogState
    extends State<ImportReviewExplanationEditDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑解析'),
      content: SizedBox(
        width: 520,
        child: TextField(
          key: const ValueKey('explanation-edit-field'),
          controller: _controller,
          maxLines: 12,
          minLines: 6,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '解析内容',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('explanation-edit-save'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
