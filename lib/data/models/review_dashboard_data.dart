class DailyReviewForecast {
  final DateTime date;
  final int count;

  DailyReviewForecast({required this.date, required this.count});
}

class ReviewDashboardData {
  final int total;
  final int newCount;
  final int dueReviewCount;
  final int masteredCount;
  final int scheduledCount;
  final List<DailyReviewForecast> forecast;

  ReviewDashboardData({
    required this.total,
    required this.newCount,
    required this.dueReviewCount,
    required this.masteredCount,
    required this.scheduledCount,
    required this.forecast,
  });
}
