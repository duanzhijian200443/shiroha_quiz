import '../study_query/study_query_dtos.dart';
import '../u1_workspace/u1_workspace_dtos.dart';

typedef DailyReviewActivityLoader = Future<Map<DateTime, int>> Function();

/// Calendar counts are review-log entries, not distinct questions or duration.
final class ReviewCalendarSnapshot {
  ReviewCalendarSnapshot({
    required this.firstDate,
    required this.lastDate,
    required Map<DateTime, int> dailyCounts,
  }) : dailyCounts = Map.unmodifiable(dailyCounts);

  final DateTime firstDate;
  final DateTime lastDate;
  final Map<DateTime, int> dailyCounts;
  int get reviewCount =>
      dailyCounts.values.fold(0, (sum, count) => sum + count);
  int get learningDays => dailyCounts.values.where((count) => count > 0).length;
}

final class WorkspaceDashboardSnapshot {
  const WorkspaceDashboardSnapshot(
      {this.calendar, this.recentFiles, this.banks});
  final ReviewCalendarSnapshot? calendar;
  final List<LibraryFileSummary>? recentFiles;
  final List<QuestionBankSummary>? banks;
  int? get questionCount =>
      banks?.fold<int>(0, (sum, bank) => sum + bank.questionCount);
}

/// Read-only composition over existing queries; each section fails independently.
final class WorkspaceDashboardQuery {
  const WorkspaceDashboardQuery({
    required this.loadDailyReviews,
    required this.loadRecentFiles,
    required this.loadBanks,
  });

  final DailyReviewActivityLoader loadDailyReviews;
  final Future<List<LibraryFileSummary>> Function() loadRecentFiles;
  final Future<List<QuestionBankSummary>> Function() loadBanks;

  Future<WorkspaceDashboardSnapshot> read({DateTime? now}) async {
    final local = (now ?? DateTime.now()).toLocal();
    final today = DateTime(local.year, local.month, local.day);
    final first = DateTime(today.year, today.month - 11, 1);
    final results = await Future.wait<Object?>([
      _available(() async {
        final counts = await loadDailyReviews();
        if (counts.values.any((count) => count < 0)) {
          throw StateError('Invalid review counts');
        }
        return ReviewCalendarSnapshot(
          firstDate: first,
          lastDate: today,
          dailyCounts: {
            for (final entry in counts.entries)
              if (!entry.key.isBefore(first) && !entry.key.isAfter(today))
                entry.key: entry.value,
          },
        );
      }),
      _available(loadRecentFiles),
      _available(loadBanks),
    ]);
    return WorkspaceDashboardSnapshot(
      calendar: results[0] as ReviewCalendarSnapshot?,
      recentFiles: results[1] as List<LibraryFileSummary>?,
      banks: results[2] as List<QuestionBankSummary>?,
    );
  }

  Future<T?> _available<T>(Future<T> Function() query) async {
    try {
      return await query();
    } catch (_) {
      return null;
    }
  }
}
