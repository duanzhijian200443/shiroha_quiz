import 'package:flutter/material.dart';

/// Bottom action bar shown while selection mode is active.
class ImportReviewSelectionBar extends StatelessWidget {
  const ImportReviewSelectionBar({
    super.key,
    required this.selectedCount,
    required this.isSaving,
    required this.onSelectAllVisible,
    required this.onChangeType,
    required this.onDeleteSelected,
  });

  final int selectedCount;
  final bool isSaving;
  final VoidCallback onSelectAllVisible;
  final VoidCallback onChangeType;
  final VoidCallback onDeleteSelected;

  @override
  Widget build(BuildContext context) {
    final hasSelection = selectedCount > 0;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          boxShadow: const [
            BoxShadow(
                color: Colors.black12, blurRadius: 4, offset: Offset(0, -2))
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.select_all),
              label: const Text('全选当前'),
              onPressed: onSelectAllVisible,
            ),
            Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.edit),
                  label: const Text('改题型'),
                  onPressed: (!hasSelection || isSaving) ? null : onChangeType,
                ),
                TextButton.icon(
                  icon: const Icon(Icons.delete, color: Colors.redAccent),
                  label: const Text('删除',
                      style: TextStyle(color: Colors.redAccent)),
                  onPressed:
                      (!hasSelection || isSaving) ? null : onDeleteSelected,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
