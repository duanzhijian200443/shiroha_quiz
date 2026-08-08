/// Repository ports of the T0 read-only study query layer.
///
/// The data layer implements these ports and returns safe application read
/// models; the application layer never sees SQL, database rows, provider
/// payloads, or absolute paths. Data repositories may import this file
/// (the canonical `Data / Infrastructure -> Application ports` direction);
/// presentation adapters must not.
library;

import '../../domain/question/question_draft_v2.dart';
import 'study_query_dtos.dart';

/// Review-state projection needed by the read-only query layer.
final class StudyQuestionReviewState {
  const StudyQuestionReviewState({
    required this.due,
    required this.lapseCount,
    required this.difficulty,
    required this.lastLapseTime,
  });

  /// Whether the question is due at the query instant.
  final bool due;

  final int lapseCount;
  final double difficulty;

  /// Unix seconds of the last lapse, or null when unknown.
  final int? lastLapseTime;
}

/// Typed union read model resolved through the typed-aware repository seam.
///
/// A valid V2 sidecar yields [TypedStudyQuestionRead] with the draft as the
/// content authority; a wholly absent sidecar yields
/// [LegacyStudyQuestionRead]. Corrupt or unsafe sidecars hard-fail at the
/// repository boundary without any V1 fallback.
sealed class StudyQuestionRead {
  const StudyQuestionRead();

  String get questionId;
  String get bankName;
  int get createdAt;
  StudyQuestionReviewState get review;
}

final class TypedStudyQuestionRead extends StudyQuestionRead {
  const TypedStudyQuestionRead({
    required this.questionId,
    required this.bankName,
    required this.createdAt,
    required this.draft,
    required this.review,
  });

  @override
  final String questionId;
  @override
  final String bankName;
  @override
  final int createdAt;

  final QuestionDraftV2 draft;

  @override
  final StudyQuestionReviewState review;
}

final class LegacyStudyQuestionRead extends StudyQuestionRead {
  const LegacyStudyQuestionRead({
    required this.questionId,
    required this.bankName,
    required this.createdAt,
    required this.stemText,
    required this.optionsText,
    required this.answerText,
    required this.explanationText,
    required this.legacyType,
    required this.review,
  });

  @override
  final String questionId;
  @override
  final String bankName;
  @override
  final int createdAt;

  /// V1 stem text (compatibility projection for typed rows is never used;
  /// legacy rows use their own stored text).
  final String stemText;

  /// V1 options JSON text (a list of display strings) for legacy rows.
  final String optionsText;
  final String answerText;
  final String? explanationText;

  /// Legacy V1 `type` code used only to project a safe question kind.
  final int legacyType;

  @override
  final StudyQuestionReviewState review;
}

/// Aggregated overview counts resolved by the data layer.
final class StudyOverviewCounts {
  const StudyOverviewCounts({
    required this.questionCount,
    required this.masteredCount,
    required this.dueCount,
    required this.todayPracticeCount,
    required this.wrongQuestionCount,
  });

  final int questionCount;
  final int masteredCount;
  final int dueCount;
  final int todayPracticeCount;
  final int wrongQuestionCount;
}

/// Keyset page result. `hasMore` is true only when a following page exists.
final class StudyPage<T> {
  const StudyPage({required this.items, required this.hasMore});

  final List<T> items;
  final bool hasMore;
}

/// Read port for question content (bank list, search, detail, weak list).
abstract interface class StudyQuestionQueryPort {
  /// Lists banks ordered by bank name. Returns at most `limit` items plus a
  /// sentinel row signal via [StudyPage.hasMore].
  Future<StudyPage<QuestionBankSummary>> listStudyQuestionBanks({
    required int nowUnixSeconds,
    required int limit,
    String? afterBankName,
  });

  /// Keyset search over the V1 content/explanation projection. Corrupt
  /// sidecars fail the whole page without V1 fallback.
  Future<StudyPage<StudyQuestionRead>> searchStudyQuestions({
    required String bankName,
    required String query,
    required int nowUnixSeconds,
    required int limit,
    int? afterCreatedAt,
    String? afterId,
  });

  /// Resolves one question through the typed-aware seam, or null when the
  /// question does not exist.
  Future<StudyQuestionRead?> getStudyQuestionDetail(
    String questionId, {
    required int nowUnixSeconds,
  });

  /// Keyset list of lapsed questions ordered by last lapse time descending.
  Future<StudyPage<StudyQuestionRead>> listStudyWeakQuestions({
    required int nowUnixSeconds,
    required int limit,
    String? bankName,
    int? afterLastLapseTime,
    String? afterId,
  });
}

/// Read port for study/review metrics (overview, due summary).
abstract interface class StudyMetricsQueryPort {
  Future<StudyOverviewCounts> getStudyOverviewCounts({
    String? bankName,
    required int nowUnixSeconds,
    required int todayStartUnixSeconds,
  });

  /// Scheduled (state > 0) review instants inside the half-open window
  /// `[fromUnixSeconds, toUnixSeconds)`.
  Future<List<int>> getStudyScheduledReviewTimestamps({
    String? bankName,
    required int fromUnixSeconds,
    required int toUnixSeconds,
  });

  /// Questions due at [nowUnixSeconds] (`next_review_time <= now`).
  Future<int> countStudyDueNow({
    String? bankName,
    required int nowUnixSeconds,
  });
}

/// Failure taxonomy raised by repository port implementations. The
/// application layer maps these to [StudyQueryException] codes; the
/// exception never carries SQL, paths, payloads, or raw causes.
enum StudyQueryRepositoryFailure { corruptPayload, unavailable }

final class StudyQueryRepositoryException implements Exception {
  const StudyQueryRepositoryException(this.failure);

  final StudyQueryRepositoryFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      StudyQueryRepositoryFailure.corruptPayload =>
        'The stored question data cannot be read safely.',
      StudyQueryRepositoryFailure.unavailable =>
        'The data source is temporarily unavailable.',
    };
    return 'StudyQueryRepositoryException(${failure.name}): $detail';
  }
}
