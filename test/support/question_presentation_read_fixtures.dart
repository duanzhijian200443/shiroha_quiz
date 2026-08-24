import 'package:shiroha_quiz/application/questions/question_presentation_read.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';

/// Converts synthetic repository rows into the application read union used by
/// QuestionListScreen tests. The helper keeps test fakes on the narrow query
/// seam without making them implement unrelated folder or mutation methods.
List<QuestionPresentationRead> questionPresentationReadsFrom(
  Iterable<PersistedQuestion> rows,
) {
  return List<QuestionPresentationRead>.unmodifiable(
    rows.map((row) {
      final metrics = row.reviewMetrics;
      final reviewMetrics = metrics == null
          ? null
          : QuestionPresentationReviewMetrics(
              lapses: metrics.lapses,
              difficulty: metrics.difficulty,
              stability: metrics.stability,
              lastLapseTime: metrics.lastLapseTime,
            );
      return switch (row) {
        TypedPersistedQuestion(:final draft) => TypedQuestionPresentationRead(
            storageId: row.storageId,
            bankName: row.bankName,
            createdAt: row.createdAt,
            draft: draft,
            reviewMetrics: reviewMetrics,
          ),
        LegacyPersistedQuestion(:final question) =>
          LegacyQuestionPresentationRead(
            storageId: row.storageId,
            bankName: row.bankName,
            createdAt: row.createdAt,
            type: question.type,
            content: question.content,
            options: question.options,
            answer: question.answer,
            explanation: question.explanation,
            rawExplanation: question.rawExplanation,
            reviewMetrics: reviewMetrics,
          ),
      };
    }),
  );
}
