class QuestionFusionResult {
  final List<Map<String, dynamic>> questions;
  final List<String> diagnostics;
  final int mergedCount;
  final int orphanCount;

  const QuestionFusionResult({
    required this.questions,
    required this.diagnostics,
    required this.mergedCount,
    required this.orphanCount,
  });
}
