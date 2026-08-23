import 'question_presentation_read.dart';

/// Application query capability for the question-list surface.
///
/// This seam intentionally exposes no folder query or mutation capability.
abstract interface class QuestionListQueryPort {
  Future<List<QuestionPresentationRead>> listQuestionsForBank(
    String bankName,
  );
}
