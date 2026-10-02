import 'package:flutter/material.dart';

import '../../../data/models/question_draft.dart';

/// Batch question-type picker used by review selection mode.
class ImportReviewChangeTypeDialog extends StatelessWidget {
  const ImportReviewChangeTypeDialog({super.key, required this.onTypeSelected});

  final ValueChanged<QuestionType> onTypeSelected;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('批量修改题型'),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: const Text('选择题'),
            leading: const Icon(Icons.radio_button_checked),
            onTap: () {
              Navigator.pop(context);
              onTypeSelected(QuestionType.singleChoice);
            },
          ),
          ListTile(
            title: const Text('填空题'),
            leading: const Icon(Icons.space_bar),
            onTap: () {
              Navigator.pop(context);
              onTypeSelected(QuestionType.fillBlank);
            },
          ),
          ListTile(
            title: const Text('简答题'),
            leading: const Icon(Icons.notes),
            onTap: () {
              Navigator.pop(context);
              onTypeSelected(QuestionType.shortAnswer);
            },
          ),
        ],
      ),
    );
  }
}
