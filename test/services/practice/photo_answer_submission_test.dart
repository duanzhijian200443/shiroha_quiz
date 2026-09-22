import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/application/practice/photo_answer_history.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/file_library/file_library_ports.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/file_library/library_file_deletion.dart';
import 'package:shiroha_quiz/application/practice/photo_answer_judgement.dart';
import 'package:shiroha_quiz/application/practice/photo_answer_submission.dart';
import 'package:shiroha_quiz/application/practice/record_answer_attempt_command.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/answer_attempt_repository.dart';
import 'package:shiroha_quiz/data/repositories/library_file_repository.dart';
import 'package:shiroha_quiz/domain/attempt/answer_attempt.dart';
import 'package:shiroha_quiz/services/file_library/file_ingestion_service.dart';
import 'package:shiroha_quiz/services/file_library/library_file_deletion_service.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'package:shiroha_quiz/services/file_library/managed_artifact_storage_adapter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Helper extends Fake implements DatabaseHelper {
  _Helper(this.db);
  final Database db;
  @override
  Future<Database> get database async => db;
}

class _FailAttempts implements AnswerAttemptPersistencePort {
  @override
  Future<void> recordAttempt(AnswerAttempt attempt) async =>
      throw StateError('synthetic');
}

class _FailDelete implements LibraryFileDeletionPort {
  @override
  Future<LibraryFileDeletionResult> deleteLibraryFile(String id) async =>
      throw StateError('synthetic');
}

class _PausedIngestion implements FileIngestionPort {
  _PausedIngestion(this.delegate);
  final FileIngestionPort delegate;
  final ingested = Completer<void>();
  final resume = Completer<void>();
  @override
  Future<LibraryFile> ingest(
      {required String externalPath,
      required String displayName,
      String? mimeType}) async {
    final file = await delegate.ingest(
        externalPath: externalPath,
        displayName: displayName,
        mimeType: mimeType);
    ingested.complete();
    await resume.future;
    return file;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(BackupRestoreMutationGate.resetForTesting);
  tearDown(BackupRestoreMutationGate.resetForTesting);
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  for (final attemptFails in [false, true]) {
    test(
        'submission retains root lease through waiting restore and compensation: $attemptFails',
        () async {
      final dir = await Directory.systemTemp.createTemp('photo_race_');
      final db = await DatabaseHelper.instance
          .openPathForTesting(inMemoryDatabasePath);
      try {
        final source = File('${dir.path}/source.png');
        await source.writeAsBytes([1, 2, 3]);
        final files = LibraryFileRepository(databaseHelper: _Helper(db));
        final attempts = AnswerAttemptRepository(databaseHelper: _Helper(db));
        final storage = ManagedFileStorageAdapter(
            managedRoot: Directory('${dir.path}/managed'));
        final ingestion = _PausedIngestion(
            FileIngestionService(storage: storage, repository: files));
        final command = PhotoAnswerSubmissionCommand(
          ingestion: ingestion,
          attempts: RecordAnswerAttemptCommand(
              attemptFails ? _FailAttempts() : attempts),
          deletion: LibraryFileDeletionService(
              metadataRepository: files,
              deletionRepository: files,
              managedFileStorage: storage,
              managedArtifactStorage: ManagedArtifactStorageAdapter(
                  managedRoot: Directory('${dir.path}/managed'))),
          diagnostic: (_) => fail('unexpected compensation failure'),
        );
        final submission = command.submit(
            photo: ConfirmedPhotoAnswer(
                request: PhotoAnswerJudgementRequest(
                    imagePath: source.path,
                    imageName: 'source.png',
                    kind: PhotoAnswerQuestionKind.shortAnswer,
                    question: RichContent(nodes: [const TextNode('q')]),
                    standardAnswer: RichContent(nodes: [const TextNode('a')])),
                result: const PhotoAnswerJudgementResult(
                    decision: PhotoAnswerDecision.correct,
                    transcription: '',
                    feedback: '')),
            attemptId: 'race',
            questionId: 'q',
            sessionKind: AnswerAttemptSessionKind.normal,
            answeredAt: 1);
        final checked = attemptFails
            ? expectLater(
                submission,
                throwsA(isA<PhotoAnswerSubmissionException>().having(
                    (e) => e.failure,
                    'failure',
                    PhotoAnswerSubmissionFailure.attemptSaveFailed)))
            : submission;
        await ingestion.ingested.future;
        final gate = BackupRestoreMutationGate.instance;
        expect(gate.activeMutationCount, 1);
        expect(await files.findAll(), hasLength(1));
        var drained = false;
        final restore = gate.enterQuiescence().then((_) async {
          drained = true;
          // The restore boundary sees a complete submission or complete compensation.
          expect(await files.findAll(), hasLength(attemptFails ? 0 : 1));
          expect(await attempts.getAttemptsForQuestion('q'),
              hasLength(attemptFails ? 0 : 1));
        });
        expect(drained, false);
        ingestion.resume.complete();
        await checked;
        await restore;
        expect(gate.activeMutationCount, 0);
        final rows = await files.findAll();
        final facts = await attempts.getAttemptsForQuestion('q');
        final retained = await Directory('${dir.path}/managed')
            .list(recursive: true)
            .where((e) => e is File)
            .toList();
        expect(retained, hasLength(attemptFails ? 0 : 1));
        if (!attemptFails) {
          expect(jsonDecode(facts.single.answerPayloadJson)['source_file_id'],
              rows.single.fileId);
          expect(
              await storage
                  .resolveManagedFile(rows.single.storageKey)
                  .readAsBytes(),
              [1, 2, 3]);
        }
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    });
  }
  for (final decision in PhotoAnswerDecision.values) {
    test(
        '$decision persists original evidence and soft reference survives deletion',
        () async {
      final dir = await Directory.systemTemp.createTemp('photo_submit_');
      final db = await DatabaseHelper.instance
          .openPathForTesting(inMemoryDatabasePath);
      try {
        final source = File('${dir.path}/source.png');
        await source.writeAsBytes([1, 2, 3]);
        final helper = _Helper(db);
        final files = LibraryFileRepository(databaseHelper: helper);
        final attempts = AnswerAttemptRepository(databaseHelper: helper);
        final storage = ManagedFileStorageAdapter(
            managedRoot: Directory('${dir.path}/managed'));
        final deletion = LibraryFileDeletionService(
            metadataRepository: files,
            deletionRepository: files,
            managedFileStorage: storage,
            managedArtifactStorage: ManagedArtifactStorageAdapter(
                managedRoot: Directory('${dir.path}/managed')));
        final command = PhotoAnswerSubmissionCommand(
            ingestion:
                FileIngestionService(storage: storage, repository: files),
            attempts: RecordAnswerAttemptCommand(attempts),
            deletion: deletion,
            diagnostic: (_) => fail('unexpected diagnostic'));
        await command.submit(
            photo: ConfirmedPhotoAnswer(
                request: PhotoAnswerJudgementRequest(
                    imagePath: source.path,
                    imageName: 'source.png',
                    kind: PhotoAnswerQuestionKind.fillBlank,
                    question: RichContent(nodes: [TextNode('q')]),
                    standardAnswer: RichContent(nodes: [TextNode('a')])),
                result: PhotoAnswerJudgementResult(
                    decision: decision,
                    transcription: '',
                    feedback: 'synthetic')),
            attemptId: 'a',
            questionId: 'q',
            sessionKind: AnswerAttemptSessionKind.focused,
            answeredAt: 5,
            durationMs: 100);
        final attempt = (await attempts.getAttemptsForQuestion('q')).single;
        expect(
            attempt.correctness,
            decision == PhotoAnswerDecision.uncertain
                ? null
                : decision == PhotoAnswerDecision.correct);
        expect(await attempts.countIncorrectQuestions(),
            decision == PhotoAnswerDecision.incorrect ? 1 : 0);
        final payload = jsonDecode(attempt.answerPayloadJson) as Map;
        expect(payload.containsKey('correctness'), false);
        expect(attempt.answerPayloadJson, isNot(contains(source.path)));
        final file = (await files.findAll()).single;
        expect(payload['source_file_id'], file.fileId);
        expect(await storage.resolveManagedFile(file.storageKey).readAsBytes(),
            [1, 2, 3]);
        expect(await source.exists(), true);
        final history =
            PhotoAnswerHistoryQuery(attempts: attempts, files: files);
        expect((await history.forQuestion('q')).single.evidenceAvailable, true);
        await deletion.deleteLibraryFile(file.fileId);
        final missing = (await history.forQuestion('q')).single;
        expect(missing.evidenceAvailable, false);
        expect(missing.attempt, attempt);
        expect(await attempts.getAttemptsForQuestion('q'), [attempt]);
        expect(await attempts.countIncorrectQuestions(),
            decision == PhotoAnswerDecision.incorrect ? 1 : 0);
        expect(await files.findById(file.fileId), isNull);
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    });
  }
  for (final failedCleanup in [false, true]) {
    test(
        'failed attempt compensates or reports explicit cleanup failure: $failedCleanup',
        () async {
      final dir = await Directory.systemTemp.createTemp('photo_compensate_');
      final db = await DatabaseHelper.instance
          .openPathForTesting(inMemoryDatabasePath);
      try {
        final source = File('${dir.path}/source.png');
        await source.writeAsBytes([1, 2, 3]);
        final files = LibraryFileRepository(databaseHelper: _Helper(db));
        final storage = ManagedFileStorageAdapter(
            managedRoot: Directory('${dir.path}/managed'));
        final diagnostics = <PhotoAnswerSubmissionFailure>[];
        final deletion = LibraryFileDeletionService(
            metadataRepository: files,
            deletionRepository: files,
            managedFileStorage: storage,
            managedArtifactStorage: ManagedArtifactStorageAdapter(
                managedRoot: Directory('${dir.path}/managed')));
        final command = PhotoAnswerSubmissionCommand(
            ingestion:
                FileIngestionService(storage: storage, repository: files),
            attempts: RecordAnswerAttemptCommand(_FailAttempts()),
            deletion: failedCleanup ? _FailDelete() : deletion,
            diagnostic: diagnostics.add);
        await expectLater(
            command.submit(
                photo: ConfirmedPhotoAnswer(
                    request: PhotoAnswerJudgementRequest(
                        imagePath: source.path,
                        imageName: 'source.png',
                        kind: PhotoAnswerQuestionKind.shortAnswer,
                        question: RichContent(nodes: [TextNode('q')]),
                        standardAnswer: RichContent(nodes: [TextNode('a')])),
                    result: const PhotoAnswerJudgementResult(
                        decision: PhotoAnswerDecision.incorrect,
                        transcription: 'answer',
                        feedback: '')),
                attemptId: 'a',
                questionId: 'q',
                sessionKind: AnswerAttemptSessionKind.normal,
                answeredAt: 5),
            throwsA(isA<PhotoAnswerSubmissionException>().having(
                (e) => e.failure,
                'failure',
                failedCleanup
                    ? PhotoAnswerSubmissionFailure.compensationFailed
                    : PhotoAnswerSubmissionFailure.attemptSaveFailed)));
        expect(await db.query('answer_attempts'), isEmpty);
        expect(await files.findAll(), hasLength(failedCleanup ? 1 : 0));
        expect(
            diagnostics,
            failedCleanup
                ? [PhotoAnswerSubmissionFailure.compensationFailed]
                : isEmpty);
        final retained = await Directory('${dir.path}/managed')
            .list(recursive: true)
            .where((e) => e is File)
            .toList();
        expect(retained, hasLength(failedCleanup ? 1 : 0));
        expect(await source.exists(), true);
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    });
  }
}
