import '../../application/home_training_result.dart';
import '../../application/training/training_contracts.dart';
import 'sqflite_runtime.dart';

/// Existing exact reserved identities, shared with their DatabaseHelper uses.
/// These are compatibility identities, not a new bank registry/name heuristic.
const globalWrongBookBankName = '🔥 全局错题本';
const hiddenExamBankName = '📦 模考专属题库';

/// Narrow transaction-bound bridge used by migration and portable validation.
/// It never opens the singleton DB, mutates learning data or calls the legacy
/// subject-tree query (which performs self-healing writes).
final class DatabaseOrdinaryTrainingBankEligibility
    implements OrdinaryTrainingBankEligibility {
  const DatabaseOrdinaryTrainingBankEligibility(this.db);

  final DatabaseExecutor db;

  @override
  Future<HomeTrainingResult<OrdinaryTrainingBankEligibilityStatus>> evaluate(
      OrdinaryTrainingBankInput input) async {
    if (input.bankName == globalWrongBookBankName ||
        input.bankName == hiddenExamBankName) {
      return const HomeTrainingSuccess(
          OrdinaryTrainingBankEligibilityStatus.ineligible);
    }
    try {
      final rows = await db.rawQuery(
        'SELECT 1 FROM questions WHERE bank_name = ? LIMIT 1',
        [input.bankName],
      );
      return HomeTrainingSuccess(rows.isEmpty
          ? OrdinaryTrainingBankEligibilityStatus.ineligible
          : OrdinaryTrainingBankEligibilityStatus.eligible);
    } catch (_) {
      return const HomeTrainingFailed(HomeTrainingFailure.unavailable);
    }
  }
}
