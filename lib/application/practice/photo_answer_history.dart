import 'dart:convert';
import '../../domain/attempt/answer_attempt.dart';
import '../file_library/file_library_ports.dart';

abstract interface class AnswerAttemptHistoryPort {
  Future<List<AnswerAttempt>> getAttemptsForQuestion(String questionId);
}

final class PhotoAnswerHistoryEntry {
  const PhotoAnswerHistoryEntry(
      {required this.attempt,
      required this.transcription,
      required this.feedback,
      required this.evidenceAvailable});
  final AnswerAttempt attempt;
  final String transcription;
  final String feedback;
  final bool evidenceAvailable;
}

final class PhotoAnswerHistoryQuery {
  const PhotoAnswerHistoryQuery(
      {required AnswerAttemptHistoryPort attempts,
      required LibraryFileRepositoryPort files})
      : _attempts = attempts,
        _files = files;
  final AnswerAttemptHistoryPort _attempts;
  final LibraryFileRepositoryPort _files;
  Future<List<PhotoAnswerHistoryEntry>> forQuestion(String questionId) async {
    final entries = <PhotoAnswerHistoryEntry>[];
    for (final attempt in await _attempts.getAttemptsForQuestion(questionId)) {
      if (attempt.modality != AnswerAttemptModality.image) continue;
      AnswerAttemptPayload.validateForModality(
          attempt.modality, attempt.answerPayloadJson);
      final payload =
          jsonDecode(attempt.answerPayloadJson) as Map<String, dynamic>;
      entries.add(PhotoAnswerHistoryEntry(
          attempt: attempt,
          transcription: payload['transcription'] as String? ?? '',
          feedback: payload['feedback'] as String? ?? '',
          evidenceAvailable:
              await _files.findById(payload['source_file_id'] as String) !=
                  null));
    }
    return entries;
  }
}
