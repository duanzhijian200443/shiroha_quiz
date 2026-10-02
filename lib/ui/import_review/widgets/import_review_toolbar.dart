import 'package:flutter/material.dart';

import '../../../services/import_review/import_review_filter.dart';

/// Filter and sort toolbar of the import review page.
///
/// Presentation only: it renders the current filter, the number of questions
/// surviving the filter and the sort selector, and reports user choices through
/// callbacks. It never reads the controller, a service or the task manager.
class ImportReviewToolbar extends StatelessWidget {
  const ImportReviewToolbar({
    super.key,
    required this.activeFilter,
    required this.activeSort,
    required this.filterCounts,
    required this.visibleItemCount,
    required this.onFilterChanged,
    required this.onSortChanged,
  });

  final ImportReviewFilter activeFilter;
  final ImportReviewSort activeSort;
  final Map<ImportReviewFilter, int> filterCounts;
  final int visibleItemCount;
  final ValueChanged<ImportReviewFilter> onFilterChanged;
  final ValueChanged<ImportReviewSort> onSortChanged;

  static String _filterLabel(ImportReviewFilter filter) {
    switch (filter) {
      case ImportReviewFilter.all:
        return '全部';
      case ImportReviewFilter.errorsOnly:
        return '严重';
      case ImportReviewFilter.warningsOnly:
        return '警告';
      case ImportReviewFilter.missingAnswer:
        return '缺答案';
      case ImportReviewFilter.choiceIssues:
        return '选择题';
      case ImportReviewFilter.fusionRisks:
        return '融合风险';
      case ImportReviewFilter.answerConflict:
        return '答案冲突';
      case ImportReviewFilter.orphanOrAnswerOnly:
        return '孤立/仅答案';
      case ImportReviewFilter.visionOnly:
        return '视觉';
      case ImportReviewFilter.fused:
        return '图文融合';
    }
  }

  static String _sortLabel(ImportReviewSort sort) {
    switch (sort) {
      case ImportReviewSort.originalOrder:
        return '原始顺序';
      case ImportReviewSort.riskFirst:
        return '风险优先';
      case ImportReviewSort.missingFieldsFirst:
        return '缺失优先';
      case ImportReviewSort.sourceRiskFirst:
        return '来源风险优先';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      color: theme.cardColor,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: ImportReviewFilter.values.map((filter) {
                final count = filterCounts[filter] ?? 0;
                final isSelected = activeFilter == filter;
                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: FilterChip(
                    label: Text('${_filterLabel(filter)} $count'),
                    selected: isSelected,
                    onSelected: (selected) {
                      if (selected) {
                        onFilterChanged(filter);
                      }
                    },
                    selectedColor: theme.primaryColor.withValues(alpha: 0.2),
                    checkmarkColor: theme.primaryColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                        color: isSelected
                            ? theme.primaryColor
                            : Colors.grey.shade300,
                      ),
                    ),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  ),
                );
              }).toList(),
            ),
          ),
          const Divider(height: 8, thickness: 0.5),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '已筛选出 $visibleItemCount 道题',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                PopupMenuButton<ImportReviewSort>(
                  initialValue: activeSort,
                  onSelected: onSortChanged,
                  itemBuilder: (context) => ImportReviewSort.values.map((sort) {
                    return PopupMenuItem<ImportReviewSort>(
                      value: sort,
                      child: Text(_sortLabel(sort)),
                    );
                  }).toList(),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.sort, size: 16, color: theme.primaryColor),
                      const SizedBox(width: 4),
                      Text(
                        _sortLabel(activeSort),
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.primaryColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
