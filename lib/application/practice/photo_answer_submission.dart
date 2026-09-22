import '../../domain/attempt/answer_attempt.dart';
import '../backup/backup_restore_gate.dart';
import '../file_library/file_library_ports.dart';
import '../file_library/library_file_deletion.dart';
import 'photo_answer_judgement.dart';
import 'record_answer_attempt_command.dart';

enum PhotoAnswerSubmissionFailure {
  invalidInput,
  imageSaveFailed,
  attemptSaveFailed,
  compensationFailed
}

final class PhotoAnswerSubmissionException implements Exception {
  const PhotoAnswerSubmissionException(this.failure);
  final PhotoAnswerSubmissionFailure failure;
  @override
  String toString() => 'PhotoAnswerSubmissionException(${failure.name})';
}

final class PhotoAnswerSubmissionCommand {
  const PhotoAnswerSubmissionCommand(
      {required FileIngestionPort ingestion,
      required RecordAnswerAttemptCommand attempts,
      required LibraryFileDeletionPort deletion,
      required void Function(PhotoAnswerSubmissionFailure) diagnostic})
      : _ingestion = ingestion,
        _attempts = attempts,
        _deletion = deletion,
        _diagnostic = diagnostic;
  final FileIngestionPort _ingestion;
  final RecordAnswerAttemptCommand _attempts;
  final LibraryFileDeletionPort _deletion;
  final void Function(PhotoAnswerSubmissionFailure) _diagnostic;

  Future<void> submit(
          {required ConfirmedPhotoAnswer photo,
          required String attemptId,
          required String questionId,
          required AnswerAttemptSessionKind sessionKind,
          required int answeredAt,
          int? durationMs}) =>
      BackupRestoreMutationGate.instance.runMutation(() async {
        if (!photo.result.isSuccess ||
            questionId.isEmpty ||
            attemptId.isEmpty) {
          throw const PhotoAnswerSubmissionException(
              PhotoAnswerSubmissionFailure.invalidInput);
        }
        final suffix = photo.request.imageName.split('.').last.toLowerCase();
        final mime = switch (suffix) {
          'jpg' || 'jpeg' => 'image/jpeg',
          'png' => 'image/png',
          'webp' => 'image/webp',
          'gif' => 'image/gif',
          'heic' => 'image/heic',
          'heif' => 'image/heif',
          'bmp' => 'image/bmp',
          _ => 'application/octet-stream',
        };
        final extension = mime.startsWith('image/') ? '.$suffix' : '';
        final String fileId;
        try {
          fileId = (await _ingestion.ingest(
                  externalPath: photo.request.imagePath,
                  displayName: '作答图片_$answeredAt$extension',
                  mimeType: mime))
              .fileId;
        } catch (_) {
          throw const PhotoAnswerSubmissionException(
              PhotoAnswerSubmissionFailure.imageSaveFailed);
        }
        try {
          await _attempts.recordAttempt(AnswerAttempt(
              attemptId: attemptId,
              questionId: questionId,
              sessionKind: sessionKind,
              modality: AnswerAttemptModality.image,
              answerPayloadJson: AnswerAttemptPayload.image(
                  sourceFileId: fileId,
                  transcription: photo.result.transcription,
                  feedback: photo.result.feedback),
              correctness: photo.result.correctness,
              answeredAt: answeredAt,
              durationMs: durationMs));
        } catch (_) {
          try {
            final cleanup = await _deletion.deleteLibraryFile(fileId);
            if (cleanup.managedBytesCleanup ==
                    LibraryFileManagedBytesCleanup.orphaned ||
                cleanup.parsedArtifactCleanup ==
                    LibraryFileParsedArtifactCleanup.orphaned) {
              throw const PhotoAnswerSubmissionException(
                  PhotoAnswerSubmissionFailure.compensationFailed);
            }
          } catch (_) {
            _diagnostic(PhotoAnswerSubmissionFailure.compensationFailed);
            throw const PhotoAnswerSubmissionException(
                PhotoAnswerSubmissionFailure.compensationFailed);
          }
          throw const PhotoAnswerSubmissionException(
              PhotoAnswerSubmissionFailure.attemptSaveFailed);
        }
      });
}
