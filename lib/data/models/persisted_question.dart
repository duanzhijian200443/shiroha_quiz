import '../../domain/question/question_draft_v2.dart';
import 'question.dart';

/// Review metrics projected from the existing `review_states` row at the
/// repository boundary. Only the wrong-book surface reads these columns; the
/// bank list read returns [PersistedQuestion] rows without them.
final class PersistedQuestionReviewMetrics {
  const PersistedQuestionReviewMetrics({
    required this.lapses,
    required this.difficulty,
    required this.stability,
    required this.lastLapseTime,
  });

  final int lapses;
  final double difficulty;
  final double stability;
  final int lastLapseTime;
}

/// Explicit database representation of one questions row at the repository
/// boundary: either a legacy V1 row or a V2 typed sidecar row.
sealed class PersistedQuestion {
  const PersistedQuestion();

  String get storageId;
  String get bankName;
  int get createdAt;

  /// Present only when the read joined the `review_states` row (the wrong-book
  /// surface). Null on the regular bank list read.
  PersistedQuestionReviewMetrics? get reviewMetrics;
}

final class TypedPersistedQuestion extends PersistedQuestion {
  const TypedPersistedQuestion({
    required this.storageId,
    required this.bankName,
    required this.createdAt,
    required this.draft,
    this.reviewMetrics,
  });

  @override
  final String storageId;
  @override
  final String bankName;
  @override
  final int createdAt;

  final QuestionDraftV2 draft;

  @override
  final PersistedQuestionReviewMetrics? reviewMetrics;
}

final class LegacyPersistedQuestion extends PersistedQuestion {
  const LegacyPersistedQuestion({
    required this.question,
    this.reviewMetrics,
  });

  final Question question;

  @override
  String get storageId => question.id ?? '';

  @override
  String get bankName => question.bankName;

  @override
  int get createdAt => question.createdAt;

  @override
  final PersistedQuestionReviewMetrics? reviewMetrics;
}
