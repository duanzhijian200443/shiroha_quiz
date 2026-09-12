final _answerFieldChoiceMarker = RegExp(
  r'(?:^|答案|应选|选)\s*([A-D])(?:\b|[。．.、，,；;])',
);

final _explanationChoiceMarker = RegExp(
  r'(?:应选|故选|答案为?)\s*([A-D])',
);

/// Extracts the deterministic OCR choice marker used by legacy compatibility.
///
/// The answer field remains authoritative when it contains an explicit marker;
/// the explanation is only a fallback. Arbitrary A-D characters do not match
/// either bounded grammar.
String? extractOcrChoiceAnswerMarker({
  required String answerText,
  required String explanationText,
}) {
  final answerMarker =
      _answerFieldChoiceMarker.firstMatch(answerText)?.group(1);
  if (answerMarker != null) return answerMarker.toUpperCase();

  final explanationMarker =
      _explanationChoiceMarker.firstMatch(explanationText)?.group(1);
  return explanationMarker?.toUpperCase();
}
