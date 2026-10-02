import 'package:flutter/material.dart';

/// Save-location dialog: target bank name, optional folder and folder chips.
///
/// The text controllers stay owned by the page so values the user already typed
/// survive a reopen, exactly as the previous inline dialog behaved. The page
/// owns showing the dialog and deciding what happens on confirm.
class ImportReviewSaveDialog extends StatelessWidget {
  const ImportReviewSaveDialog({
    super.key,
    required this.bankNameController,
    required this.folderController,
    required this.existingFolders,
    required this.onInvalidBankName,
    required this.onConfirm,
  });

  final TextEditingController bankNameController;
  final TextEditingController folderController;
  final List<String> existingFolders;

  /// Called when the user confirms without entering a bank name; the page shows
  /// the validation message.
  final VoidCallback onInvalidBankName;

  /// Called with the trimmed bank and folder names after the dialog closes.
  final void Function(String bankName, String folderName) onConfirm;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择保存位置',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
                controller: bankNameController,
                decoration: InputDecoration(
                    labelText: '目标题库名称',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)))),
            const SizedBox(height: 16),
            TextField(
                controller: folderController,
                decoration: InputDecoration(
                    labelText: '所属学科分类 (选填)',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)))),
            if (existingFolders.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8.0,
                runSpacing: 8.0,
                children: existingFolders
                    .map((folder) => ActionChip(
                          label: Text(folder,
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.blueAccent)),
                          backgroundColor: Colors.blue.shade50,
                          side: BorderSide.none,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                          onPressed: () {
                            folderController.text = folder;
                          },
                        ))
                    .toList(),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(color: Colors.grey)),
        ),
        ElevatedButton(
          onPressed: () {
            final bankName = bankNameController.text.trim();
            if (bankName.isEmpty) {
              onInvalidBankName();
              return;
            }
            Navigator.pop(context);
            onConfirm(bankName, folderController.text.trim());
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).primaryColor,
            foregroundColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: const Text('确定入库'),
        ),
      ],
    );
  }
}
