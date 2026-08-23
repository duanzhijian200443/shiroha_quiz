import '../../domain/question/question_draft_v2.dart';

/// Safe review metrics exposed to the question-list presentation boundary.
///
/// The DTO deliberately contains no database row, SQL, storage path, or
/// repository type. It is only the data needed by the existing display
/// projection.
final class QuestionPresentationReviewMetrics {
  const QuestionPresentationReviewMetrics({
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

/// Application read model for one bank-list question.
sealed class QuestionPresentationRead {
  const QuestionPresentationRead({
    required this.storageId,
    required this.bankName,
    required this.createdAt,
    this.reviewMetrics,
  });

  final String storageId;
  final String bankName;
  final int createdAt;
  final QuestionPresentationReviewMetrics? reviewMetrics;
}

final class TypedQuestionPresentationRead extends QuestionPresentationRead {
  const TypedQuestionPresentationRead({
    required super.storageId,
    required super.bankName,
    required super.createdAt,
    required this.draft,
    super.reviewMetrics,
  });

  final QuestionDraftV2 draft;
}

final class LegacyQuestionPresentationRead extends QuestionPresentationRead {
  const LegacyQuestionPresentationRead({
    required super.storageId,
    required super.bankName,
    required super.createdAt,
    required this.type,
    required this.content,
    required this.options,
    required this.answer,
    required this.explanation,
    required this.rawExplanation,
    super.reviewMetrics,
  });

  final int type;
  final String content;
  final String? options;
  final String answer;
  final String? explanation;
  final String? rawExplanation;
}
