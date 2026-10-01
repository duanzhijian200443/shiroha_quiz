import '../../application/today/today_context_query.dart';
import '../../application/study_query/study_query_dtos.dart';
import '../../application/study_query/study_query_ports.dart';
import '../../data/repositories/review_repository.dart';

/// Today can select the existing virtual wrong-book bank. Adapt only its
/// overview scope; ordinary T0/Agent readers keep their bank-name semantics.
final class TodayStudyMetricsQuery extends ReviewRepository {
  @override
  Future<StudyOverviewCounts> getStudyOverviewCounts({
    String? bankName,
    required int nowUnixSeconds,
    required int todayStartUnixSeconds,
    bool wrongBookOnly = false,
  }) =>
      super.getStudyOverviewCounts(
        bankName: bankName == '🔥 全局错题本' ? null : bankName,
        nowUnixSeconds: nowUnixSeconds,
        todayStartUnixSeconds: todayStartUnixSeconds,
        wrongBookOnly: wrongBookOnly || bankName == '🔥 全局错题本',
      );
}

/// Maps the existing settings/review reads to the Application-owned snapshot.
/// The composition root supplies the existing readers; no new SQL or selection
/// algorithm is introduced, and provider/storage exceptions never reach UI.
final class TodayContextQueryAdapter implements TodayContextQuery {
  TodayContextQueryAdapter({
    required Future<String?> Function() loadCurrentBank,
    required Future<Map<String, dynamic>> Function(String) loadBankStats,
    Future<StudyOverview> Function(String)? loadStudyOverview,
  })  : _loadCurrentBank = loadCurrentBank,
        _loadBankStats = loadBankStats,
        _loadStudyOverview = loadStudyOverview;

  final Future<String?> Function() _loadCurrentBank;
  final Future<Map<String, dynamic>> Function(String) _loadBankStats;
  final Future<StudyOverview> Function(String)? _loadStudyOverview;

  @override
  Future<TodayContextSnapshot> loadContext() async {
    try {
      final bank = await _loadCurrentBank();
      // Preserve the legacy no-bank sentinel as absence at the UI boundary.
      if (bank == null || bank == '点击修改选择题库') {
        return const TodayContextSnapshot();
      }
      final stats = await _loadBankStats(bank);
      final overview = await _loadStudyOverview?.call(bank);
      return TodayContextSnapshot(
        bankName: bank,
        newCount: stats['new_count'] ?? 0,
        reviewCount: stats['review_count'] ?? 0,
        totalCount: overview?.questionCount ?? stats['total'] ?? 0,
        masteredCount: overview?.masteredCount ?? stats['mastered_count'] ?? 0,
        todayPracticeCount: overview?.todayPracticeCount,
      );
    } catch (_) {
      throw const TodayContextUnavailable();
    }
  }
}
