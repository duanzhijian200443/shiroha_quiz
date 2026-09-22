import '../../domain/content/rich_content.dart';

enum PhotoAnswerQuestionKind { fillBlank, shortAnswer }

enum PhotoAnswerDecision { correct, incorrect, uncertain }

enum PhotoAnswerJudgementFailure {
  invalidInput,
  contextAssetUnavailable,
  contextUnsupported,
  engineUnavailable,
  providerFailure,
  timeout,
  malformedResponse,
  outputTooLong
}

final class PhotoAnswerJudgementRequest {
  const PhotoAnswerJudgementRequest(
      {required this.imagePath,
      required this.imageName,
      required this.kind,
      required this.question,
      required this.standardAnswer});

  /// Transient picker identity. Never persist or log.
  final String imagePath;
  final String imageName;
  final PhotoAnswerQuestionKind kind;
  final RichContent question;
  final RichContent standardAnswer;
}

final class PhotoAnswerJudgementResult {
  const PhotoAnswerJudgementResult(
      {required this.decision,
      required this.transcription,
      required this.feedback})
      : failure = null;
  const PhotoAnswerJudgementResult.failed(this.failure)
      : decision = null,
        transcription = '',
        feedback = '';
  final PhotoAnswerDecision? decision;
  final String transcription;
  final String feedback;
  final PhotoAnswerJudgementFailure? failure;
  bool get isSuccess => failure == null && decision != null;
  bool? get correctness => switch (decision) {
        PhotoAnswerDecision.correct => true,
        PhotoAnswerDecision.incorrect => false,
        _ => null,
      };
}

abstract interface class PhotoAnswerJudgementPort {
  Future<PhotoAnswerJudgementResult> judge(PhotoAnswerJudgementRequest request);
}

/// User-confirmed result; all image identities remain transient until submit.
final class ConfirmedPhotoAnswer {
  const ConfirmedPhotoAnswer({required this.request, required this.result});
  final PhotoAnswerJudgementRequest request;
  final PhotoAnswerJudgementResult result;
}
