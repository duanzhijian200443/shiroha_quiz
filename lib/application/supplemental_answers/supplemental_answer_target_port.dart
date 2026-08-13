import '../../data/models/persisted_question.dart';

/// Data port for resolving the typed target snapshot of one P6 session.
///
/// Implementations read only through the existing typed persistence seams
/// (strict typed/legacy union decode, no V1 fallback on corruption). The
/// application never receives SQL, rows, or paths.
abstract interface class SupplementalAnswerTargetPort {
  /// All questions in [bankName] through the typed dual-read.
  Future<List<PersistedQuestion>> listTypedQuestionsByBank(String bankName);

  /// Questions for [storageIds], returned in caller order; missing ids
  /// produce no row.
  Future<List<PersistedQuestion>> listTypedQuestionsByIds(
    Iterable<String> storageIds,
  );

  /// Bank names attached to [projectId], ordered by bank name.
  Future<List<String>> listProjectBankNames(String projectId);
}
