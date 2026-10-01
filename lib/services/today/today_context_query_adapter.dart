import '../../application/today/today_context_query.dart';

/// Maps the existing settings/review reads to the Application-owned snapshot.
/// The composition root supplies the existing readers; no new SQL or selection
/// algorithm is introduced, and provider/storage exceptions never reach UI.
final class TodayContextQueryAdapter implements TodayContextQuery {
  TodayContextQueryAdapter({
    required Future<String?> Function() loadCurrentBank,
    required Future<Map<String, dynamic>> Function(String) loadBankStats,
  })  : _loadCurrentBank = loadCurrentBank,
        _loadBankStats = loadBankStats;

  final Future<String?> Function() _loadCurrentBank;
  final Future<Map<String, dynamic>> Function(String) _loadBankStats;

  @override
  Future<TodayContextSnapshot> loadContext() async {
    try {
      final bank = await _loadCurrentBank();
      // Preserve the legacy no-bank sentinel as absence at the UI boundary.
      if (bank == null || bank == '点击修改选择题库') {
        return const TodayContextSnapshot();
      }
      final stats = await _loadBankStats(bank);
      return TodayContextSnapshot(
        bankName: bank,
        newCount: stats['new_count'] ?? 0,
        reviewCount: stats['review_count'] ?? 0,
        totalCount: stats['total'] ?? 0,
        masteredCount: stats['mastered_count'] ?? 0,
      );
    } catch (_) {
      throw const TodayContextUnavailable();
    }
  }
}
