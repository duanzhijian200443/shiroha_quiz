import '../../core/database/database_helper.dart';
import '../models/question_draft.dart';

class ExamRepository {
  ExamRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  static final ExamRepository instance = ExamRepository();

  final DatabaseHelper _databaseHelper;

  // ---------------------------------------------------------------------------
  // Exam Paper Management
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> getAllExamPapers() {
    return _databaseHelper.getAllExamPapers();
  }

  Future<void> deleteExamPaper(String id) {
    return _databaseHelper.deleteExamPaper(id);
  }

  Future<String> createExamPaper(
    String title,
    int sourceType,
    List<Map<String, dynamic>> questions,
  ) {
    return _databaseHelper.createExamPaper(title, sourceType, questions);
  }

  Future<String> createExamPaperFromDrafts(
    String title,
    int sourceType,
    List<QuestionDraft> questions,
  ) {
    return _databaseHelper.createExamPaper(
      title,
      sourceType,
      questions.map((question) => question.toMap()).toList(growable: false),
    );
  }

  Future<List<Map<String, dynamic>>> getPaperQuestionsDetail(String paperId) {
    return _databaseHelper.getPaperQuestionsDetail(paperId);
  }

  // ---------------------------------------------------------------------------
  // Exam Execution & Grading
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> generateMockExamPaper(
    String bankName,
    int singleCount,
    int subjectiveCount,
  ) {
    return _databaseHelper.generateMockExamPaper(
        bankName, singleCount, subjectiveCount);
  }

  Future<List<Map<String, dynamic>>> submitExamPaper(
    String paperId,
    Map<int, dynamic> userAnswers,
    List<Map<String, dynamic>> questions,
  ) {
    return _databaseHelper.submitExamPaper(paperId, userAnswers, questions);
  }

  Future<void> updateExamAiScore(
    String paperId,
    String questionId,
    String aiFeedback,
    double scoreRatio,
  ) {
    return _databaseHelper.updateExamAiScore(
        paperId, questionId, aiFeedback, scoreRatio);
  }

  Future<void> finishExamGrading(String paperId) {
    return _databaseHelper.finishExamGrading(paperId);
  }
}
