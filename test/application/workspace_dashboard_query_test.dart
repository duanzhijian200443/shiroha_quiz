import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/today/workspace_dashboard_query.dart';
import 'package:shiroha_quiz/application/u1_workspace/u1_workspace_dtos.dart';

void main() {
  test('calendar uses local review dates and excludes old and future rows',
      () async {
    final query = WorkspaceDashboardQuery(
      loadDailyReviews: () async => {
        DateTime(2025, 10, 31): 50,
        DateTime(2025, 11, 1): 2,
        DateTime(2026, 10, 25): 3,
        DateTime(2026, 10, 26): 40,
      },
      loadRecentFiles: () async => [],
      loadBanks: () async => [],
    );
    final result = await query.read(now: DateTime(2026, 10, 25, 18));
    expect(result.calendar!.firstDate, DateTime(2025, 11, 1));
    expect(result.calendar!.lastDate, DateTime(2026, 10, 25));
    expect(result.calendar!.reviewCount, 5);
    expect(result.calendar!.learningDays, 2);
    expect(result.questionCount, 0);
    expect(() => result.calendar!.dailyCounts.clear(), throwsUnsupportedError);
  });

  test('failed calendar and bank reads do not erase available recent files',
      () async {
    final file = LibraryFileSummary(
        fileId: 'file-1',
        displayName: '真实资料.pdf',
        mimeType: 'application/pdf',
        sizeBytes: 123,
        createdAt: DateTime(2026, 10, 25));
    final result = await WorkspaceDashboardQuery(
      loadDailyReviews: () async => throw StateError('synthetic'),
      loadRecentFiles: () async => [file],
      loadBanks: () async => throw StateError('synthetic'),
    ).read();
    expect(result.calendar, isNull);
    expect(result.questionCount, isNull);
    expect(result.recentFiles!.single, same(file));
  });

  test('successful empty data is distinct from unavailable or invalid data',
      () async {
    final result = await WorkspaceDashboardQuery(
      loadDailyReviews: () async => {},
      loadRecentFiles: () async => throw StateError('synthetic'),
      loadBanks: () async => [],
    ).read();
    expect(result.calendar!.reviewCount, 0);
    expect(result.calendar!.learningDays, 0);
    expect(result.recentFiles, isNull);
    final invalid = await WorkspaceDashboardQuery(
      loadDailyReviews: () async => {DateTime.now(): -1},
      loadRecentFiles: () async => [],
      loadBanks: () async => [],
    ).read();
    expect(invalid.calendar, isNull);
  });
}
