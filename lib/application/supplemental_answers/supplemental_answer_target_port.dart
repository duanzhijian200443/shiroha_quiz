import '../../domain/question/question_draft_v2.dart';

/// One typed/legacy dual-read result projected at the data boundary.
///
/// The application layer never receives `PersistedQuestion` data models,
/// SQL, or rows; `typedDraft` is null for a visible-but-ineligible legacy
/// target.
final class SupplementalTargetRead {
  const SupplementalTargetRead({
    required this.storageId,
    required this.bankName,
    this.typedDraft,
  });

  final String storageId;
  final String bankName;
  final QuestionDraftV2? typedDraft;
}

/// Data port for resolving the typed target snapshot of one P6 session.
///
/// Implementations read only through the existing typed persistence seams
/// (strict typed/legacy union decode, no V1 fallback on corruption). The
/// application never receives SQL, rows, or paths.
abstract interface class SupplementalAnswerTargetPort {
  /// All questions in [bankName] through the typed dual-read.
  Future<List<SupplementalTargetRead>> listTypedQuestionsByBank(
    String bankName,
  );

  /// Questions for [storageIds], returned in caller order; missing ids
  /// produce no row.
  Future<List<SupplementalTargetRead>> listTypedQuestionsByIds(
    Iterable<String> storageIds,
  );

  /// Bank names attached to [projectId], ordered by bank name.
  Future<List<String>> listProjectBankNames(String projectId);
}
