import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/import/import_target_selection.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/core/observability/app_logger.dart';
import 'package:shiroha_quiz/core/observability/log_record.dart';
import 'package:shiroha_quiz/core/observability/trace_context.dart';
import 'package:shiroha_quiz/data/models/review_draft_cas.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_failure_classifier.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_result.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_import_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_request_scheduler.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/task_center_projection.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<ImportTask> _waitForTask(
  TaskManager manager,
  String taskId,
  bool Function(ImportTask task) predicate,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final matches = manager.tasks.where((task) => task.id == taskId);
    if (matches.isNotEmpty && predicate(matches.first)) return matches.first;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Task did not reach the expected state.');
}

class _MemoryLogSink implements LogSink {
  final List<LogRecord> records = <LogRecord>[];

  @override
  Future<void> flush() async {}

  @override
  Future<void> write(LogRecord record) async {
    records.add(record);
  }
}

class _FailureCase {
  const _FailureCase({
    required this.name,
    required this.error,
    required this.expectedType,
    required this.expectedMessage,
  });

  final String name;
  final Object error;
  final String expectedType;
  final String expectedMessage;
}

class _EmptyOcrFailureCase {
  const _EmptyOcrFailureCase({
    required this.name,
    required this.status,
    required this.expectedType,
    required this.expectedMessage,
    this.ocrErrorType,
  });

  final String name;
  final String status;
  final String? ocrErrorType;
  final String expectedType;
  final String expectedMessage;
}

class _RecordingOcrRequestScheduler extends OcrRequestScheduler {
  _RecordingOcrRequestScheduler({
    this.result = OcrRequestCancellation.notFound,
  }) : super(maxConcurrentRequests: 1);

  final List<(String taskId, String attemptToken)> cancellations =
      <(String, String)>[];
  final OcrRequestCancellation result;

  @override
  OcrRequestCancellation cancel({
    required String taskId,
    required String attemptToken,
  }) {
    cancellations.add((taskId, attemptToken));
    return result;
  }
}

const _sensitiveFragments = <String>[
  'fixture-secret',
  'Authorization: Bearer fixture-token',
  r'C:\private\fixture.pdf',
  'OCR-SENSITIVE-CONTENT',
  '{"rawResponse":"PRIVATE"}',
];
final _sensitiveFailureText = _sensitiveFragments.join(' ');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final manager = TaskManager.forTesting();
  late _MemoryLogSink logSink;

  setUp(() async {
    BackupRestoreMutationGate.resetForTesting();
    await manager.ready;
    manager.tasks.clear();
    logSink = _MemoryLogSink();
    AppLogger.setSink(logSink);
  });

  tearDown(() async {
    await AppLogger.flush();
    AppLogger.setSink(null);
    manager.tasks.clear();
    BackupRestoreMutationGate.resetForTesting();
  });

  test('waits for task manager readiness before creating or parsing a task',
      () async {
    final readiness = Completer<void>();
    var parserCalled = false;
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: readiness.future,
      parser: (request) async {
        parserCalled = true;
        return const ImportParseResult(questions: [
          {
            'q_num': '1',
            'type': 0,
            'content': 'Synthetic question',
            'options': ['A', 'B'],
            'standard_answer': 'A',
            'explanation': '',
          }
        ]);
      },
      taskIdFactory: () => 'task-readiness',
      traceIdFactory: () => 'trace-readiness',
    );

    final pendingDispatch = coordinator.dispatchRequest(
      sourceDescription: 'fixture.pdf',
      filePaths: const ['fixture.pdf'],
      fileNames: const ['fixture.pdf'],
      mode: ImportParseMode.ocr,
      maxConcurrency: 1,
    );
    await Future<void>.delayed(Duration.zero);

    expect(manager.tasks, isEmpty);
    expect(parserCalled, isFalse);

    readiness.complete();
    final handle = await pendingDispatch;
    final task = await _waitForTask(
      manager,
      handle.taskId,
      (task) => task.status == TaskStatus.pendingReview,
    );

    expect(parserCalled, isTrue);
    expect(task.traceId, 'trace-readiness');
    expect(task.parseMode, 'ocr');
  });

  test('preserves safe diagnostics and transitions successful parse to review',
      () async {
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async => const ImportParseResult(
        questions: [
          {
            'q_num': '1',
            'type': 0,
            'content': 'Synthetic question',
            'options': ['A', 'B'],
            'standard_answer': 'A',
            'explanation': '',
          }
        ],
        warnings: ['synthetic warning'],
        diagnostics: {'safeCount': 1},
      ),
      taskIdFactory: () => 'task-success',
      traceIdFactory: () => 'trace-success',
    );

    final handle = await coordinator.dispatchRequest(
      sourceDescription: 'fixture.pdf',
      filePaths: const ['fixture.pdf'],
      fileNames: const ['fixture.pdf'],
      mode: ImportParseMode.ocr,
      maxConcurrency: 1,
    );
    final task = await _waitForTask(
      manager,
      handle.taskId,
      (task) => task.status == TaskStatus.pendingReview,
    );

    expect(task.warnings, ['synthetic warning']);
    expect(task.diagnostics?['safeCount'], 1);
    expect(task.traceId, 'trace-success');
    expect(task.parsedData, hasLength(1));
  });

  test('completion callback selects a user single task and never a batch item',
      () async {
    var nextId = 0;
    var readyCount = 0;
    final allReady = Completer<void>();
    final singleReady = <String>[];
    const result = ImportParseResult(questions: <Map<String, dynamic>>[
      <String, dynamic>{
        'q_num': '1',
        'type': 0,
        'content': 'Synthetic question',
        'options': <String>['A', 'B'],
        'standard_answer': 'A',
        'explanation': '',
      },
    ]);
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      taskIdFactory: () => 'completion-${nextId++}',
      onReadyForReview: (_) {
        readyCount++;
        if (readyCount == 3) allReady.complete();
      },
      onSingleReadyForReview: (taskId) async {
        singleReady.add(taskId);
        // Auto-open declined, so every task keeps its notification.
        return false;
      },
    );
    final single = await coordinator.dispatch(
      sourceDescription: 'single.pdf',
      mode: ImportParseMode.ocr,
      allowAutoOpenReview: true,
      parse: (_) async => result,
    );
    await coordinator.dispatchIndependentBatch(items: <ImportTaskBatchItem>[
      for (var i = 0; i < 2; i++)
        ImportTaskBatchItem(
          sourceDescription: 'batch-$i.pdf',
          mode: ImportParseMode.ocr,
          parse: (_) async => result,
        ),
    ]);
    await allReady.future;
    expect(singleReady, <String>[single.taskId]);
  });

  test('a successful auto-open suppresses the transfer center notification',
      () async {
    var nextId = 0;
    final singleReady = <String>[];
    final notified = <String>[];
    final opened = Completer<void>();
    const result = ImportParseResult(questions: <Map<String, dynamic>>[
      <String, dynamic>{
        'q_num': '1',
        'type': 0,
        'content': 'Synthetic question',
        'options': <String>['A', 'B'],
        'standard_answer': 'A',
        'explanation': '',
      },
    ]);
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      taskIdFactory: () => 'auto-open-${nextId++}',
      onReadyForReview: notified.add,
      onSingleReadyForReview: (taskId) async {
        singleReady.add(taskId);
        if (!opened.isCompleted) opened.complete();
        return true;
      },
    );
    final single = await coordinator.dispatch(
      sourceDescription: 'single.pdf',
      mode: ImportParseMode.ocr,
      allowAutoOpenReview: true,
      parse: (_) async => result,
    );
    await _waitForTask(
      manager,
      single.taskId,
      (task) => task.status == TaskStatus.pendingReview,
    );
    await opened.future;
    // The notification step runs right after the auto-open callback returns.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(singleReady, <String>[single.taskId]);
    expect(notified, isEmpty);
  });

  test('a failed auto-open still sends the transfer center notification',
      () async {
    var nextId = 0;
    final singleReady = <String>[];
    final notified = <String>[];
    const result = ImportParseResult(questions: <Map<String, dynamic>>[
      <String, dynamic>{
        'q_num': '1',
        'type': 0,
        'content': 'Synthetic question',
        'options': <String>['A', 'B'],
        'standard_answer': 'A',
        'explanation': '',
      },
    ]);
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      taskIdFactory: () => 'auto-open-failed-${nextId++}',
      onReadyForReview: notified.add,
      onSingleReadyForReview: (taskId) async {
        singleReady.add(taskId);
        throw StateError('synthetic auto-open failure');
      },
    );
    final single = await coordinator.dispatch(
      sourceDescription: 'single.pdf',
      mode: ImportParseMode.ocr,
      allowAutoOpenReview: true,
      parse: (_) async => result,
    );
    // Throws if the task never reaches review admission, so reaching the
    // assertions below already proves the task survived the failed auto-open.
    await _waitForTask(
      manager,
      single.taskId,
      (task) => task.status == TaskStatus.pendingReview,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(singleReady, <String>[single.taskId]);
    expect(notified, <String>['single.pdf']);
  });

  test(
      'document import provenance survives parse-completion diagnostics replacement',
      () async {
    // Regression guard for the metadata whitelist. The marker is written when
    // the task is created, but TaskManager replaces diagnostics when the parse
    // completes; if the marker is not in the preserved-metadata whitelist it is
    // silently dropped and Review stops recognising a document import.
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      taskIdFactory: () => 'task-document-entry',
      traceIdFactory: () => 'trace-document-entry',
    );

    final handle = await coordinator.dispatch(
      sourceDescription: 'fixture.pdf',
      mode: ImportParseMode.ocr,
      explanationRetentionMode: newDocumentImportExplanationRetentionMode,
      documentImportEntry: true,
      parse: (taskId) => Future<ImportParseResult>.value(
        ImportParseResult(
          questions: const <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': '1',
              'type': 0,
              'content': 'Synthetic question',
              'options': <String>['A', 'B'],
              'standard_answer': 'A',
              'explanation': 'Synthetic explanation',
            },
          ],
          explanationRetentionMode: newDocumentImportExplanationRetentionMode,
        ),
      ),
    );
    final task = await _waitForTask(
      manager,
      handle.taskId,
      (candidate) => candidate.status == TaskStatus.pendingReview,
    );
    final restored = ImportTask.fromMap(task.toMap());

    expect(
      task.diagnostics?[documentImportEntryMarkerKey],
      documentImportEntryMarkerValue,
      reason: 'the marker must survive parse completion',
    );
    expect(
      restored.diagnostics?[documentImportEntryMarkerKey],
      documentImportEntryMarkerValue,
      reason: 'the marker must survive a durable round trip',
    );
    expect(isDocumentImportEntryDiagnostics(task.diagnostics), isTrue);
  });

  test('typed document RD0 settles before review notification, with fallback',
      () async {
    for (final failMaterialization in <bool>[false, true]) {
      final notified = Completer<void>();
      final localManager = TaskManager.forTesting(
        saveTask: (_) async {},
        saveReviewDraftCas: ({
          required taskId,
          required expectedAttempt,
          required expectedRevision,
          required questions,
          required explanationRetentionMode,
        }) async {
          expect(expectedRevision, 0);
          if (failMaterialization) {
            throw StateError('synthetic persistence failure');
          }
          return const ReviewDraftCasResult(
            ReviewDraftCasStatus.saved,
            durableRevision: 1,
          );
        },
      );
      final coordinator = ImportTaskCoordinator(
        taskManager: localManager,
        readiness: localManager.ready,
        taskIdFactory: () => failMaterialization
            ? 'rd0-coordinator-fallback'
            : 'rd0-coordinator-success',
        traceIdFactory: () => 'rd0-coordinator-trace',
        onReadyForReview: (_) {
          final task = localManager.tasks.single;
          expect(task.status, TaskStatus.pendingReview);
          expect(task.parsedData, hasLength(1));
          expect(
            localManager.reviewDraftRevision(task.id),
            failMaterialization ? 0 : 1,
          );
          notified.complete();
        },
      );
      final handle = await coordinator.dispatch(
        sourceDescription: 'synthetic.pdf',
        mode: ImportParseMode.ocr,
        documentImportEntry: true,
        parse: (_) async => ImportParseResult.withStorageMetadata(
          questions: const <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': 1,
              'type': 0,
              'content': 'Synthetic question',
              'options': <String>['A'],
              'standard_answer': 'A',
            },
          ],
          storageRoute: ImportStorageRoute.typedV2,
          storageReason: 'typed_candidate_ready',
        ),
      );
      await notified.future;
      expect(localManager.tasks.single.id, handle.taskId);
      expect(localManager.tasks.single.errorMsg, isNull);
    }
  });

  test('frozen document target survives RD0 and a durable task round trip',
      () async {
    final notified = Completer<void>();
    final localManager = TaskManager.forTesting(
      saveTask: (_) async {},
      saveReviewDraftCas: ({
        required taskId,
        required expectedAttempt,
        required expectedRevision,
        required questions,
        required explanationRetentionMode,
      }) async {
        expect(expectedRevision, 0);
        return const ReviewDraftCasResult(ReviewDraftCasStatus.saved,
            durableRevision: 1);
      },
    );
    final coordinator = ImportTaskCoordinator(
      taskManager: localManager,
      readiness: localManager.ready,
      onReadyForReview: (_) => notified.complete(),
    );
    final handle = await coordinator.dispatch(
      sourceDescription: 'synthetic.pdf',
      mode: ImportParseMode.ocr,
      documentImportEntry: true,
      bankName: '考研数学一',
      folderName: '数学',
      targetKind: ImportTargetKind.existing,
      parse: (_) async => ImportParseResult.withStorageMetadata(
        questions: const [
          {'type': 3, 'content': 'Synthetic question', 'standard_answer': 'A'}
        ],
        storageRoute: ImportStorageRoute.typedV2,
        storageReason: 'typed_candidate_ready',
      ),
    );
    await notified.future;
    final task = localManager.tasks.single;
    expect(task.id, handle.taskId);
    expect(localManager.reviewDraftRevision(task.id), 1);
    expect(task.bankName, '考研数学一');
    expect(task.folderName, '数学');
    final reloaded = ImportTask.fromMap(task.toMap());
    expect((reloaded.bankName, reloaded.folderName), ('考研数学一', '数学'));
    expect(reloaded.diagnostics?[importTargetKindMarkerKey], 'existing');
  });

  test('batch snapshots one target into every task before parsing', () async {
    final parsing = Completer<ImportParseResult>();
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
    );
    final batch = await coordinator.dispatchIndependentBatch(items: [
      for (final year in [2019, 2020, 2021])
        ImportTaskBatchItem(
          sourceDescription: '$year.pdf',
          mode: ImportParseMode.text,
          documentImportEntry: true,
          bankName: '考研数学一',
          folderName: '数学',
          targetKind: ImportTargetKind.existing,
          parse: (_) => parsing.future,
        ),
    ]);
    expect(batch.tasks, hasLength(3));
    expect(
        manager.tasks.map((task) => (task.bankName, task.folderName)).toSet(),
        {('考研数学一', '数学')});
    parsing.complete(const ImportParseResult(questions: [
      {'type': 3, 'content': 'Synthetic question', 'standard_answer': 'A'}
    ]));
    for (final handle in batch.tasks) {
      await _waitForTask(manager, handle.taskId,
          (task) => task.status == TaskStatus.pendingReview);
    }
  });

  test('a photo capture dispatch carries no document import provenance',
      () async {
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      taskIdFactory: () => 'task-photo-entry',
      traceIdFactory: () => 'trace-photo-entry',
    );

    final handle = await coordinator.dispatch(
      sourceDescription: '图片识别',
      mode: ImportParseMode.ocr,
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      parse: (taskId) => Future<ImportParseResult>.value(
        ImportParseResult(
          questions: const <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': '1',
              'type': 0,
              'content': 'Synthetic question',
              'options': <String>['A', 'B'],
              'standard_answer': 'A',
            },
          ],
          explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
        ),
      ),
    );
    final task = await _waitForTask(
      manager,
      handle.taskId,
      (candidate) => candidate.status == TaskStatus.pendingReview,
    );

    // Photo capture records retention diagnostics but is not a document
    // import, so Review must keep its retention controls.
    expect(
      task.diagnostics?[TaskManager.keyReviewExplanationRetentionMode],
      ExplanationRetentionMode.subjectiveOnly.name,
    );
    expect(
        task.diagnostics?.containsKey(documentImportEntryMarkerKey), isFalse);
    expect(isDocumentImportEntryDiagnostics(task.diagnostics), isFalse);
  });

  test('a retried document import keeps its entry provenance', () async {
    // Regression guard for the retry path. `restartAttempt` rebuilds the
    // attempt diagnostics from scratch, so the marker has to be copied back
    // explicitly: dropping it demotes a retried document import to a
    // compatibility task and Review offers the retention controls this entry
    // deliberately removed.
    var traceIndex = 0;
    var attemptIndex = 0;
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async => const ImportParseResult(
        questions: <Map<String, dynamic>>[
          <String, dynamic>{
            'q_num': '1',
            'type': 0,
            'content': 'Synthetic question',
            'options': <String>['A', 'B'],
            'standard_answer': 'A',
          },
        ],
        explanationRetentionMode: newDocumentImportExplanationRetentionMode,
      ),
      taskIdFactory: () => 'retry-document-entry',
      traceIdFactory: () => 'retry-document-trace-${traceIndex++}',
      attemptTokenFactory: () => 'retry-document-attempt-${attemptIndex++}',
    );

    // An empty parse is the production failure shape that leaves the task
    // retryable from the task center.
    final failedHandle = await coordinator.dispatch(
      sourceDescription: 'fixture.pdf',
      mode: ImportParseMode.ocr,
      explanationRetentionMode: newDocumentImportExplanationRetentionMode,
      documentImportEntry: true,
      parse: (_) async => const ImportParseResult(
        questions: <Map<String, dynamic>>[],
      ),
    );
    final failed = await _waitForTask(
      manager,
      failedHandle.taskId,
      (task) => task.attemptState == ImportAttemptState.failed,
    );
    expect(
      failed.diagnostics?[documentImportEntryMarkerKey],
      documentImportEntryMarkerValue,
      reason: 'the failed attempt is still a document import',
    );

    final retryHandle = await coordinator.retryOcrRequest(
      taskId: failedHandle.taskId,
      filePaths: const <String>['fixture.pdf'],
      fileNames: const <String>['fixture.pdf'],
    );
    final retried = await _waitForTask(
      manager,
      failedHandle.taskId,
      (task) => task.status == TaskStatus.pendingReview,
    );

    expect(retryHandle.attemptNumber, 2);
    expect(
      retried.diagnostics?[documentImportEntryMarkerKey],
      documentImportEntryMarkerValue,
      reason: 'the retry must not demote a document import',
    );
    expect(isDocumentImportEntryDiagnostics(retried.diagnostics), isTrue);
  });

  test('a retried photo capture never gains document entry provenance',
      () async {
    var traceIndex = 0;
    var attemptIndex = 0;
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async => const ImportParseResult(
        questions: <Map<String, dynamic>>[
          <String, dynamic>{
            'q_num': '1',
            'type': 0,
            'content': 'Synthetic photo question',
            'options': <String>['A', 'B'],
            'standard_answer': 'A',
          },
        ],
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      ),
      taskIdFactory: () => 'retry-photo-entry',
      traceIdFactory: () => 'retry-photo-trace-${traceIndex++}',
      attemptTokenFactory: () => 'retry-photo-attempt-${attemptIndex++}',
    );

    final failedHandle = await coordinator.dispatch(
      sourceDescription: '图片识别',
      mode: ImportParseMode.ocr,
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      parse: (_) async => const ImportParseResult(
        questions: <Map<String, dynamic>>[],
      ),
    );
    await _waitForTask(
      manager,
      failedHandle.taskId,
      (task) => task.attemptState == ImportAttemptState.failed,
    );

    await coordinator.retryOcrRequest(
      taskId: failedHandle.taskId,
      filePaths: const <String>['fixture.png'],
      fileNames: const <String>['fixture.png'],
    );
    final retried = await _waitForTask(
      manager,
      failedHandle.taskId,
      (task) => task.status == TaskStatus.pendingReview,
    );

    // Photo capture records its own retention policy but is not a document
    // import, so the retry must not invent provenance and Review keeps the
    // controls that can rewrite that policy.
    expect(
      retried.diagnostics?.containsKey(documentImportEntryMarkerKey),
      isFalse,
      reason: 'a retry must not invent document entry provenance',
    );
    expect(isDocumentImportEntryDiagnostics(retried.diagnostics), isFalse);
    expect(
      retried.diagnostics?[TaskManager.keyReviewExplanationRetentionMode],
      ExplanationRetentionMode.subjectiveOnly.name,
    );
  });

  test('persists and restores the request explanation retention mode',
      () async {
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async {
        expect(
          request.explanationRetentionMode,
          ExplanationRetentionMode.allQuestionTypes,
        );
        return ImportParseResult(
          questions: const <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': '1',
              'type': 0,
              'content': 'Synthetic question',
              'options': <String>['A', 'B'],
              'standard_answer': 'A',
              'explanation': 'Synthetic explanation',
            },
          ],
          explanationRetentionMode: request.explanationRetentionMode,
        );
      },
      taskIdFactory: () => 'task-retention',
      traceIdFactory: () => 'trace-retention',
    );

    final handle = await coordinator.dispatchRequest(
      sourceDescription: 'fixture.pdf',
      filePaths: const <String>['fixture.pdf'],
      fileNames: const <String>['fixture.pdf'],
      mode: ImportParseMode.ocr,
      maxConcurrency: 1,
      explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
    );
    final task = await _waitForTask(
      manager,
      handle.taskId,
      (candidate) => candidate.status == TaskStatus.pendingReview,
    );
    final restored = ImportTask.fromMap(task.toMap());

    expect(
      task.explanationRetentionMode,
      ExplanationRetentionMode.allQuestionTypes,
    );
    expect(
      task.parseExplanationRetentionMode,
      ExplanationRetentionMode.allQuestionTypes,
    );
    expect(
      task.reviewExplanationRetentionMode,
      ExplanationRetentionMode.allQuestionTypes,
    );
    expect(
      task.diagnostics?[TaskManager.keyParseExplanationRetentionMode],
      ExplanationRetentionMode.allQuestionTypes.name,
    );
    expect(
      task.diagnostics?[TaskManager.keyReviewExplanationRetentionMode],
      ExplanationRetentionMode.allQuestionTypes.name,
    );
    expect(
      task.diagnostics?[TaskManager.keyExplanationRetentionMode],
      ExplanationRetentionMode.allQuestionTypes.name,
    );
    expect(
      restored.explanationRetentionMode,
      ExplanationRetentionMode.allQuestionTypes,
    );
  });

  test(
      'independent OCR batch creates all tasks first and starts parses concurrently',
      () async {
    var taskIndex = 0;
    var traceIndex = 0;
    var activeParses = 0;
    var maxActiveParses = 0;
    var allTasksVisibleAtFirstStart = false;
    final starts = <int>[];
    final allStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      taskIdFactory: () => 'batch-task-${taskIndex++}',
      traceIdFactory: () => 'batch-trace-${traceIndex++}',
      batchIdFactory: () => 'batch-fixture',
      ocrMaxConcurrencyResolver: () async => 4,
    );

    Future<ImportParseResult> parseItem(int index, String taskId) async {
      starts.add(index);
      if (starts.length == 4) {
        allStarted.complete();
      }
      activeParses++;
      maxActiveParses =
          activeParses > maxActiveParses ? activeParses : maxActiveParses;
      if (index == 0) {
        allTasksVisibleAtFirstStart = manager.tasks.length == 4;
      }
      try {
        if (index == 0) {
          await releaseFirst.future;
        }
        if (index == 1) {
          throw StateError('synthetic batch failure');
        }
        return ImportParseResult(
          questions: <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': '${index + 1}',
              'type': 0,
              'content': 'Synthetic question ${index + 1}',
              'options': const <String>['A', 'B'],
              'standard_answer': 'A',
              'explanation': '',
            },
          ],
        );
      } finally {
        activeParses--;
      }
    }

    final batch = await coordinator.dispatchIndependentBatch(
      items: List<ImportTaskBatchItem>.generate(
        4,
        (index) => ImportTaskBatchItem(
          sourceDescription: index < 2 ? 'same.pdf' : 'file-$index.pdf',
          mode: ImportParseMode.ocr,
          parse: (taskId) => parseItem(index, taskId),
        ),
      ),
    );

    expect(batch.batchId, 'batch-fixture');
    expect(batch.tasks.map((handle) => handle.taskId), <String>[
      'batch-task-0',
      'batch-task-1',
      'batch-task-2',
      'batch-task-3',
    ]);
    expect(manager.tasks.map((task) => task.id), <String>[
      'batch-task-0',
      'batch-task-1',
      'batch-task-2',
      'batch-task-3',
    ]);
    expect(
      manager.tasks.map((task) => task.selectionIndex),
      <int?>[0, 1, 2, 3],
    );
    expect(
      manager.tasks.map((task) => task.batchId).toSet(),
      <String?>{'batch-fixture'},
    );
    expect(
      batch.tasks.map((handle) => handle.traceId).toSet(),
      hasLength(4),
    );

    await allStarted.future;
    releaseFirst.complete();
    for (final handle in batch.tasks) {
      await _waitForTask(
        manager,
        handle.taskId,
        (task) => task.status != TaskStatus.processing,
      );
    }

    expect(allTasksVisibleAtFirstStart, isTrue);
    expect(starts, <int>[0, 1, 2, 3]);
    expect(maxActiveParses, greaterThan(1));
    expect(
      manager.tasks.map((task) => task.status),
      <TaskStatus>[
        TaskStatus.pendingReview,
        TaskStatus.error,
        TaskStatus.pendingReview,
        TaskStatus.pendingReview,
      ],
    );
    expect(
      manager.tasks.map((task) => task.selectionIndex),
      <int?>[0, 1, 2, 3],
    );
    expect(
      manager.tasks.map((task) => task.batchId).toSet(),
      <String?>{'batch-fixture'},
    );
  });

  for (final budget in <int>[1, 3, 10]) {
    test('an independent OCR batch keeps at most $budget parses in flight',
        () async {
      var taskIndex = 0;
      var traceIndex = 0;
      var activeParses = 0;
      var peakParses = 0;
      final starts = <int>[];
      final release = Completer<void>();
      final coordinator = ImportTaskCoordinator(
        taskManager: manager,
        readiness: Future<void>.value(),
        taskIdFactory: () => 'bounded-task-${taskIndex++}',
        traceIdFactory: () => 'bounded-trace-${traceIndex++}',
        batchIdFactory: () => 'bounded-batch',
        ocrMaxConcurrencyResolver: () async => budget,
      );

      Future<ImportParseResult> parseItem(int index) async {
        starts.add(index);
        activeParses++;
        peakParses = activeParses > peakParses ? activeParses : peakParses;
        try {
          await release.future;
          return ImportParseResult(
            questions: <Map<String, dynamic>>[
              <String, dynamic>{
                'q_num': '${index + 1}',
                'type': 0,
                'content': 'Synthetic question ${index + 1}',
                'options': const <String>['A', 'B'],
                'standard_answer': 'A',
                'explanation': '',
              },
            ],
          );
        } finally {
          activeParses--;
        }
      }

      // Six independent PDF tasks, one ImportTask each: exactly the document
      // import shape the OCR task concurrency budget bounds.
      final batch = await coordinator.dispatchIndependentBatch(
        items: List<ImportTaskBatchItem>.generate(
          6,
          (index) => ImportTaskBatchItem(
            sourceDescription: 'doc$index.pdf',
            mode: ImportParseMode.ocr,
            parse: (_) => parseItem(index),
          ),
        ),
      );

      final expectedInFlight = budget < 6 ? budget : 6;
      for (var attempt = 0;
          attempt < 100 && starts.length < expectedInFlight;
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(
        starts,
        List<int>.generate(expectedInFlight, (index) => index),
        reason: 'tasks must enter the parser in batch order',
      );
      expect(peakParses, expectedInFlight);
      expect(
        manager.tasks.map((task) => task.status),
        List<TaskStatus>.filled(6, TaskStatus.processing),
        reason: 'every task is visible before the batch drains',
      );

      release.complete();
      for (final handle in batch.tasks) {
        await _waitForTask(
          manager,
          handle.taskId,
          (task) => task.status == TaskStatus.pendingReview,
        );
      }

      expect(starts, List<int>.generate(6, (index) => index));
      expect(peakParses, expectedInFlight);
      expect(manager.tasks, hasLength(6));
    });
  }

  test('two OCR batches share one provider slot at budget one', () async {
    var nextTask = 0;
    var nextTrace = 0;
    var parserEntries = 0;
    var providerEntries = 0;
    var activeProvider = 0;
    var peakProvider = 0;
    final bothParsersEntered = Completer<void>();
    final releaseProvider = Completer<void>();
    final scheduler = OcrRequestScheduler(maxConcurrentRequests: 1);
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      requestScheduler: scheduler,
      taskIdFactory: () => 'cross-batch-task-${nextTask++}',
      traceIdFactory: () => 'cross-batch-trace-${nextTrace++}',
      batchIdFactory: () => 'cross-batch',
      ocrMaxConcurrencyResolver: () async => 1,
    );

    Future<ImportParseResult> parse(String taskId) async {
      parserEntries++;
      if (parserEntries == 2) bothParsersEntered.complete();
      return scheduler.run(
        taskId: taskId,
        attemptToken: ImportAttemptContext.current?.attemptToken,
        operation: () async {
          providerEntries++;
          activeProvider++;
          peakProvider =
              activeProvider > peakProvider ? activeProvider : peakProvider;
          try {
            await releaseProvider.future;
            return ImportParseResult(questions: <Map<String, dynamic>>[
              <String, dynamic>{
                'q_num': '1',
                'type': 0,
                'content': 'Synthetic question',
                'options': const <String>['A', 'B'],
                'standard_answer': 'A',
                'explanation': '',
              },
            ]);
          } finally {
            activeProvider--;
          }
        },
      );
    }

    Future<ImportTaskBatchHandle> startBatch() =>
        coordinator.dispatchIndependentBatch(
          items: List<ImportTaskBatchItem>.generate(
            2,
            (index) => ImportTaskBatchItem(
              sourceDescription: 'synthetic-$index.pdf',
              mode: ImportParseMode.ocr,
              parse: parse,
            ),
          ),
        );

    final first = await startBatch();
    final second = await startBatch();
    await bothParsersEntered.future;
    expect(first.batchId, isNot(second.batchId));
    expect(providerEntries, 1);
    expect(peakProvider, 1);

    releaseProvider.complete();
    for (final handle in <ImportTaskHandle>[...first.tasks, ...second.tasks]) {
      await _waitForTask(
        manager,
        handle.taskId,
        (task) => task.status == TaskStatus.pendingReview,
      );
    }
    expect(providerEntries, 4);
    expect(peakProvider, 1);
  });

  test('a queued OCR task can be cancelled before it ever reaches the parser',
      () async {
    var taskIndex = 0;
    var traceIndex = 0;
    var attemptIndex = 0;
    final starts = <int>[];
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      taskIdFactory: () => 'queued-task-${taskIndex++}',
      traceIdFactory: () => 'queued-trace-${traceIndex++}',
      attemptTokenFactory: () => 'queued-attempt-${attemptIndex++}',
      batchIdFactory: () => 'queued-batch',
      ocrMaxConcurrencyResolver: () async => 1,
    );

    Future<ImportParseResult> parseItem(int index) async {
      starts.add(index);
      if (index == 0) {
        firstStarted.complete();
        await releaseFirst.future;
      }
      return ImportParseResult(
        questions: <Map<String, dynamic>>[
          <String, dynamic>{
            'q_num': '${index + 1}',
            'type': 0,
            'content': 'Synthetic question ${index + 1}',
            'options': const <String>['A', 'B'],
            'standard_answer': 'A',
            'explanation': '',
          },
        ],
      );
    }

    final batch = await coordinator.dispatchIndependentBatch(
      items: List<ImportTaskBatchItem>.generate(
        3,
        (index) => ImportTaskBatchItem(
          sourceDescription: 'doc$index.pdf',
          mode: ImportParseMode.ocr,
          parse: (_) => parseItem(index),
        ),
      ),
    );

    await firstStarted.future;
    expect(starts, <int>[0]);

    expect(
      await coordinator.cancelOcrTask(batch.tasks[1].taskId),
      ImportAttemptWriteStatus.applied,
    );

    releaseFirst.complete();
    for (final handle in batch.tasks) {
      await _waitForTask(
        manager,
        handle.taskId,
        (task) => task.status != TaskStatus.processing,
      );
    }

    expect(
      starts,
      <int>[0, 2],
      reason: 'a task cancelled while queued must never call the parser',
    );
    expect(
      manager.tasks.map((task) => task.attemptState),
      <ImportAttemptState>[
        ImportAttemptState.readyForReview,
        ImportAttemptState.cancelled,
        ImportAttemptState.readyForReview,
      ],
    );
  });

  test('stale cancelled attempt callback cannot overwrite a successful retry',
      () async {
    var traceIndex = 0;
    var attemptIndex = 0;
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      taskIdFactory: () => 'retry-same-task',
      traceIdFactory: () => 'retry-trace-${traceIndex++}',
      attemptTokenFactory: () => 'retry-attempt-${attemptIndex++}',
    );

    final firstHandle = await coordinator.dispatch(
      sourceDescription: 'same.pdf',
      mode: ImportParseMode.ocr,
      parse: (_) async {
        firstStarted.complete();
        await releaseFirst.future;
        return const ImportParseResult(
          questions: <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': '1',
              'content': 'Synthetic first attempt',
              'standard_answer': 'A',
            },
          ],
        );
      },
    );
    await firstStarted.future;
    expect(
      await coordinator.cancelOcrTask(firstHandle.taskId),
      ImportAttemptWriteStatus.applied,
    );
    releaseFirst.complete();
    await _waitForTask(
      manager,
      firstHandle.taskId,
      (task) => task.attemptState == ImportAttemptState.cancelled,
    );

    final secondHandle = await coordinator.retryOcrTask(
      taskId: firstHandle.taskId,
      sourceDescription: 'same.pdf',
      parse: (_) async => const ImportParseResult(
        questions: <Map<String, dynamic>>[
          <String, dynamic>{
            'q_num': '2',
            'content': 'Synthetic second attempt',
            'standard_answer': 'B',
          },
        ],
      ),
    );
    final retried = await _waitForTask(
      manager,
      firstHandle.taskId,
      (task) => task.status == TaskStatus.pendingReview,
    );

    expect(secondHandle.taskId, firstHandle.taskId);
    expect(secondHandle.attemptNumber, 2);
    expect(secondHandle.traceId, isNot(firstHandle.traceId));
    expect(secondHandle.attemptToken, isNot(firstHandle.attemptToken));
    expect(retried.attemptState, ImportAttemptState.readyForReview);
    expect(retried.parsedData?.single['q_num'], '2');

    expect(
      await manager.requireAttemptReview(
        firstHandle.attempt,
        'stale old result',
        const <Map<String, dynamic>>[
          <String, dynamic>{'q_num': '1'},
        ],
        '',
        '',
      ),
      ImportAttemptWriteStatus.stale,
    );

    final afterOldReturn = manager.tasks.single;
    expect(afterOldReturn.attemptNumber, 2);
    expect(afterOldReturn.traceId, secondHandle.traceId);
    expect(afterOldReturn.attemptToken, secondHandle.attemptToken);
    expect(afterOldReturn.status, TaskStatus.pendingReview);
    expect(afterOldReturn.parsedData?.single['q_num'], '2');
  });

  test('queued cancellation persistence failure has no scheduler side effect',
      () async {
    const attempt = ImportAttemptRef(
      taskId: 'coordinator-queued-cancel-failure',
      attemptNumber: 1,
      attemptToken: 'coordinator-queued-token',
      traceId: 'coordinator-queued-trace',
    );
    final taskManager = TaskManager.forTesting(
      saveTask: (_) async {
        throw StateError('synthetic cancellation persistence failure');
      },
    );
    addTearDown(taskManager.dispose);
    taskManager.tasks.add(
      ImportTask(
        id: attempt.taskId,
        title: 'Synthetic queued cancellation',
        status: TaskStatus.processing,
        diagnostics: <String, dynamic>{
          TaskManager.keyParseMode: ImportParseMode.ocr.name,
          TaskManager.keyTraceId: attempt.traceId,
          TaskManager.keyAttemptNumber: attempt.attemptNumber,
          TaskManager.keyAttemptToken: attempt.attemptToken,
          TaskManager.keyAttemptState: ImportAttemptState.queued.name,
        },
      ),
    );
    final scheduler = _RecordingOcrRequestScheduler();
    final coordinator = ImportTaskCoordinator(
      taskManager: taskManager,
      readiness: taskManager.ready,
      requestScheduler: scheduler,
    );

    expect(
      await coordinator.cancelOcrTask(attempt.taskId),
      ImportAttemptWriteStatus.persistenceFailed,
    );
    final current = taskManager.tasks.single;
    expect(scheduler.cancellations, isEmpty);
    expect(current.attemptState, ImportAttemptState.queued);
    expect(current.attemptNumber, attempt.attemptNumber);
    expect(current.attemptToken, attempt.attemptToken);
    expect(current.traceId, attempt.traceId);
  });

  test('running cancellation persistence failure has no scheduler side effect',
      () async {
    const attempt = ImportAttemptRef(
      taskId: 'coordinator-running-cancel-failure',
      attemptNumber: 1,
      attemptToken: 'coordinator-running-token',
      traceId: 'coordinator-running-trace',
    );
    final taskManager = TaskManager.forTesting(
      saveTask: (_) async {
        throw StateError('synthetic cancellation persistence failure');
      },
    );
    addTearDown(taskManager.dispose);
    taskManager.tasks.add(
      ImportTask(
        id: attempt.taskId,
        title: 'Synthetic running cancellation',
        status: TaskStatus.processing,
        diagnostics: <String, dynamic>{
          TaskManager.keyParseMode: ImportParseMode.ocr.name,
          TaskManager.keyTraceId: attempt.traceId,
          TaskManager.keyAttemptNumber: attempt.attemptNumber,
          TaskManager.keyAttemptToken: attempt.attemptToken,
          TaskManager.keyAttemptState: ImportAttemptState.running.name,
        },
      ),
    );
    final scheduler = _RecordingOcrRequestScheduler();
    final coordinator = ImportTaskCoordinator(
      taskManager: taskManager,
      readiness: taskManager.ready,
      requestScheduler: scheduler,
    );

    expect(
      await coordinator.cancelOcrTask(attempt.taskId),
      ImportAttemptWriteStatus.persistenceFailed,
    );
    final current = taskManager.tasks.single;
    expect(scheduler.cancellations, isEmpty);
    expect(current.attemptState, ImportAttemptState.running);
    expect(current.attemptNumber, attempt.attemptNumber);
    expect(current.attemptToken, attempt.attemptToken);
    expect(current.traceId, attempt.traceId);
  });

  test('successful durable cancellation invokes the scheduler exactly once',
      () async {
    const attempt = ImportAttemptRef(
      taskId: 'coordinator-cancel-success',
      attemptNumber: 1,
      attemptToken: 'coordinator-success-token',
      traceId: 'coordinator-success-trace',
    );
    final taskManager = TaskManager.forTesting(
      saveTask: (_) async {},
    );
    addTearDown(taskManager.dispose);
    taskManager.tasks.add(
      ImportTask(
        id: attempt.taskId,
        title: 'Synthetic cancellation success',
        status: TaskStatus.processing,
        diagnostics: <String, dynamic>{
          TaskManager.keyParseMode: ImportParseMode.ocr.name,
          TaskManager.keyTraceId: attempt.traceId,
          TaskManager.keyAttemptNumber: attempt.attemptNumber,
          TaskManager.keyAttemptToken: attempt.attemptToken,
          TaskManager.keyAttemptState: ImportAttemptState.running.name,
        },
      ),
    );
    final scheduler = _RecordingOcrRequestScheduler(
      result: OcrRequestCancellation.running,
    );
    final coordinator = ImportTaskCoordinator(
      taskManager: taskManager,
      readiness: taskManager.ready,
      requestScheduler: scheduler,
    );

    expect(
      await coordinator.cancelOcrTask(attempt.taskId),
      ImportAttemptWriteStatus.applied,
    );
    expect(scheduler.cancellations, <(String, String)>[
      (attempt.taskId, attempt.attemptToken),
    ]);
    expect(
      taskManager.tasks.single.attemptState,
      ImportAttemptState.cancelRequested,
    );
  });

  test(
      'restart normalization failure can settle a missing scheduler request durably',
      () async {
    const attempt = ImportAttemptRef(
      taskId: 'coordinator-restart-cancel',
      attemptNumber: 1,
      attemptToken: 'coordinator-restart-token',
      traceId: 'coordinator-restart-trace',
    );
    var saveCalls = 0;
    final persisted = <Map<String, dynamic>>[];
    final taskManager = TaskManager.forTesting(
      loadTasks: () async => <Map<String, dynamic>>[
        ImportTask(
          id: attempt.taskId,
          title: 'Synthetic restart cancellation',
          status: TaskStatus.processing,
          diagnostics: <String, dynamic>{
            TaskManager.keyParseMode: ImportParseMode.ocr.name,
            TaskManager.keyTraceId: attempt.traceId,
            TaskManager.keyAttemptNumber: attempt.attemptNumber,
            TaskManager.keyAttemptToken: attempt.attemptToken,
            TaskManager.keyAttemptState: ImportAttemptState.running.name,
          },
        ).toMap(),
      ],
      saveTask: (taskMap) async {
        saveCalls++;
        if (saveCalls == 1) {
          throw StateError('synthetic restart normalization failure');
        }
        persisted.add(Map<String, dynamic>.from(taskMap));
      },
    );
    addTearDown(taskManager.dispose);
    await taskManager.ready;

    final retained = taskManager.tasks.single;
    expect(retained.status, TaskStatus.processing);
    expect(retained.attemptState, ImportAttemptState.running);
    expect(
      await taskManager.restartAttempt(
        ImportAttemptRef(
          taskId: attempt.taskId,
          attemptNumber: 2,
          attemptToken: 'coordinator-restart-next-token',
          traceId: 'coordinator-restart-next-trace',
        ),
        parseMode: ImportParseMode.ocr.name,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      ),
      ImportAttemptWriteStatus.invalidState,
    );

    final scheduler = _RecordingOcrRequestScheduler();
    final coordinator = ImportTaskCoordinator(
      taskManager: taskManager,
      readiness: taskManager.ready,
      requestScheduler: scheduler,
    );

    expect(
      await coordinator.cancelOcrTask(attempt.taskId),
      ImportAttemptWriteStatus.applied,
    );
    expect(scheduler.cancellations, <(String, String)>[
      (attempt.taskId, attempt.attemptToken),
    ]);
    final cancelled = taskManager.tasks.single;
    expect(cancelled.status, TaskStatus.error);
    expect(cancelled.attemptState, ImportAttemptState.cancelled);
    expect(
      TaskCenterProjection.presentationFor(cancelled).canRetry,
      isTrue,
    );
    expect(ImportTask.fromMap(persisted.last).attemptState,
        ImportAttemptState.cancelled);
  });

  test(
      'scheduler notFound settlement failure remains cancelRequested and can retry settlement',
      () async {
    const attempt = ImportAttemptRef(
      taskId: 'coordinator-settlement-failure',
      attemptNumber: 1,
      attemptToken: 'coordinator-settlement-token',
      traceId: 'coordinator-settlement-trace',
    );
    var saveCalls = 0;
    final taskManager = TaskManager.forTesting(
      saveTask: (_) async {
        saveCalls++;
        if (saveCalls == 2) {
          throw StateError('synthetic cancellation settlement failure');
        }
      },
    );
    addTearDown(taskManager.dispose);
    taskManager.tasks.add(
      ImportTask(
        id: attempt.taskId,
        title: 'Synthetic settlement failure',
        status: TaskStatus.processing,
        diagnostics: <String, dynamic>{
          TaskManager.keyParseMode: ImportParseMode.ocr.name,
          TaskManager.keyTraceId: attempt.traceId,
          TaskManager.keyAttemptNumber: attempt.attemptNumber,
          TaskManager.keyAttemptToken: attempt.attemptToken,
          TaskManager.keyAttemptState: ImportAttemptState.running.name,
        },
      ),
    );
    final scheduler = _RecordingOcrRequestScheduler();
    final coordinator = ImportTaskCoordinator(
      taskManager: taskManager,
      readiness: taskManager.ready,
      requestScheduler: scheduler,
    );

    expect(
      await coordinator.cancelOcrTask(attempt.taskId),
      ImportAttemptWriteStatus.persistenceFailed,
    );
    final pending = taskManager.tasks.single;
    expect(pending.status, TaskStatus.processing);
    expect(pending.attemptState, ImportAttemptState.cancelRequested);
    expect(TaskCenterProjection.presentationFor(pending).canRetry, isFalse);
    expect(await taskManager.deleteTask(attempt.taskId),
        ImportTaskCleanupStatus.busy);

    expect(
      await coordinator.cancelOcrTask(attempt.taskId),
      ImportAttemptWriteStatus.applied,
    );
    expect(scheduler.cancellations, hasLength(2));
    final cancelled = taskManager.tasks.single;
    expect(cancelled.attemptState, ImportAttemptState.cancelled);
    expect(TaskCenterProjection.presentationFor(cancelled).canRetry, isTrue);
  });

  test('maintenance blocks OCR cancellation before durable task mutation',
      () async {
    final task = ImportTask(
      id: 'cancel-blocked-task',
      title: 'Synthetic OCR task',
      status: TaskStatus.processing,
      diagnostics: <String, dynamic>{
        TaskManager.keyParseMode: ImportParseMode.ocr.name,
        TaskManager.keyAttemptNumber: 1,
        TaskManager.keyAttemptToken: 'cancel-blocked-attempt',
        TaskManager.keyAttemptState: ImportAttemptState.running.name,
        TaskManager.keyTraceId: 'cancel-blocked-trace',
      },
    );
    manager.tasks.add(task);
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
    );

    await BackupRestoreMutationGate.instance.enterQuiescence();
    await expectLater(
      coordinator.cancelOcrTask(task.id),
      throwsA(isA<BackupException>().having(
        (error) => error.failure,
        'failure',
        BackupFailure.restoreBlocked,
      )),
    );
    expect(task.status, TaskStatus.processing);
    expect(task.attemptState, ImportAttemptState.running);
    BackupRestoreMutationGate.instance.exitQuiescence();
  });

  test('retry request rebuilds OCR parsing from newly selected files',
      () async {
    const sensitiveSelectedPath = r'C:\synthetic-private\replacement.pdf';
    final capturedRequest = Completer<ImportParseRequest>();
    var traceIndex = 0;
    var attemptIndex = 0;
    manager.tasks.add(
      ImportTask(
        id: 'retry-request-task',
        title: 'Synthetic original task',
        status: TaskStatus.error,
        diagnostics: const <String, dynamic>{
          TaskManager.keyTraceId: 'retry-request-old-trace',
          TaskManager.keyParseMode: 'ocr',
          TaskManager.keyExplanationRetentionMode: 'allQuestionTypes',
          TaskManager.keyAttemptNumber: 1,
          TaskManager.keyAttemptToken: 'retry-request-old-attempt',
          TaskManager.keyAttemptState: 'failed',
        },
      ),
    );
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async {
        capturedRequest.complete(request);
        return const ImportParseResult(
          questions: <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': '1',
              'content': 'Synthetic replacement question',
              'standard_answer': 'A',
            },
          ],
          explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
        );
      },
      traceIdFactory: () => 'retry-request-trace-${traceIndex++}',
      attemptTokenFactory: () => 'retry-request-attempt-${attemptIndex++}',
    );

    final handle = await coordinator.retryOcrRequest(
      taskId: 'retry-request-task',
      filePaths: const <String>[sensitiveSelectedPath],
      fileNames: const <String>['replacement.pdf'],
    );
    final request = await capturedRequest.future;

    expect(handle.taskId, 'retry-request-task');
    expect(handle.attemptNumber, 2);
    expect(handle.traceId, isNot('retry-request-old-trace'));
    expect(handle.attemptToken, isNot('retry-request-old-attempt'));
    expect(request.taskId, 'retry-request-task');
    expect(request.mode, ImportParseMode.ocr);
    expect(request.filePaths, const <String>[sensitiveSelectedPath]);
    expect(request.fileNames, const <String>['replacement.pdf']);
    expect(request.maxConcurrency, 1);
    expect(
      request.explanationRetentionMode,
      ExplanationRetentionMode.allQuestionTypes,
    );
    expect(
      jsonEncode(manager.tasks.single.diagnostics),
      isNot(contains(sensitiveSelectedPath)),
    );
  });

  test('retry request rejects invalid selection before changing attempt',
      () async {
    manager.tasks.add(
      ImportTask(
        id: 'retry-invalid-selection',
        title: 'Synthetic invalid retry',
        status: TaskStatus.error,
        diagnostics: const <String, dynamic>{
          TaskManager.keyTraceId: 'retry-invalid-trace',
          TaskManager.keyParseMode: 'ocr',
          TaskManager.keyAttemptNumber: 1,
          TaskManager.keyAttemptToken: 'retry-invalid-attempt',
          TaskManager.keyAttemptState: 'failed',
        },
      ),
    );
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (_) async => fail('parser must not run'),
    );

    await expectLater(
      coordinator.retryOcrRequest(
        taskId: 'retry-invalid-selection',
        filePaths: const <String>['unsupported.txt'],
        fileNames: const <String>['unsupported.txt'],
      ),
      throwsA(isA<ImportTaskRetryRejectedException>()),
    );

    final task = manager.tasks.single;
    expect(task.attemptNumber, 1);
    expect(task.traceId, 'retry-invalid-trace');
    expect(task.attemptToken, 'retry-invalid-attempt');
    expect(task.attemptState, ImportAttemptState.failed);
  });

  test('retry request requires a parser before changing attempt', () async {
    manager.tasks.add(
      ImportTask(
        id: 'retry-missing-parser',
        title: 'Synthetic missing parser',
        status: TaskStatus.error,
        diagnostics: const <String, dynamic>{
          TaskManager.keyTraceId: 'retry-missing-parser-trace',
          TaskManager.keyParseMode: 'ocr',
          TaskManager.keyAttemptNumber: 1,
          TaskManager.keyAttemptToken: 'retry-missing-parser-attempt',
          TaskManager.keyAttemptState: 'failed',
        },
      ),
    );
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
    );

    await expectLater(
      coordinator.retryOcrRequest(
        taskId: 'retry-missing-parser',
        filePaths: const <String>['replacement.pdf'],
        fileNames: const <String>['replacement.pdf'],
      ),
      throwsA(isA<ImportTaskCoordinatorDependencyException>()),
    );

    expect(manager.tasks.single.attemptNumber, 1);
    expect(manager.tasks.single.attemptState, ImportAttemptState.failed);
  });

  test('retry persistence failure does not start the parser', () async {
    final retryManager = TaskManager.forTesting(
      saveTask: (_) async =>
          throw StateError('synthetic retry persistence failure'),
    );
    retryManager.tasks.add(
      ImportTask(
        id: 'retry-persistence-failure',
        title: 'Synthetic retry persistence failure',
        status: TaskStatus.error,
        diagnostics: <String, dynamic>{
          TaskManager.keyTraceId: 'retry-old-trace',
          TaskManager.keyParseMode: ImportParseMode.ocr.name,
          TaskManager.keyAttemptNumber: 1,
          TaskManager.keyAttemptToken: 'retry-old-token',
          TaskManager.keyAttemptState: ImportAttemptState.failed.name,
        },
      ),
    );
    var parserCalls = 0;
    final coordinator = ImportTaskCoordinator(
      taskManager: retryManager,
      readiness: Future<void>.value(),
    );

    await expectLater(
      coordinator.retryOcrTask(
        taskId: 'retry-persistence-failure',
        sourceDescription: 'synthetic.pdf',
        parse: (_) async {
          parserCalls++;
          return const ImportParseResult(questions: <Map<String, dynamic>>[]);
        },
      ),
      throwsA(isA<ImportTaskRetryRejectedException>()),
    );

    expect(parserCalls, 0);
    final current = retryManager.tasks.single;
    expect(current.status, TaskStatus.error);
    expect(current.attemptState, ImportAttemptState.failed);
    expect(current.attemptNumber, 1);
    expect(current.attemptToken, 'retry-old-token');
    expect(current.traceId, 'retry-old-trace');
  });

  for (final mode in <ImportParseMode>[
    ImportParseMode.vision,
    ImportParseMode.text,
  ]) {
    test('independent ${mode.name} batch keeps the existing serial runner',
        () async {
      var taskIndex = 0;
      var traceIndex = 0;
      final firstStarted = Completer<void>();
      final secondStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final coordinator = ImportTaskCoordinator(
        taskManager: manager,
        readiness: Future<void>.value(),
        taskIdFactory: () => '${mode.name}-task-${taskIndex++}',
        traceIdFactory: () => '${mode.name}-trace-${traceIndex++}',
        batchIdFactory: () => '${mode.name}-batch',
      );

      Future<ImportParseResult> parseItem(int index) async {
        if (index == 0) {
          firstStarted.complete();
          await releaseFirst.future;
        } else if (index == 1) {
          secondStarted.complete();
        }
        return ImportParseResult(
          questions: <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': '${index + 1}',
              'type': 0,
              'content': 'Synthetic question ${index + 1}',
              'options': const <String>['A', 'B'],
              'standard_answer': 'A',
              'explanation': '',
            },
          ],
        );
      }

      final batch = await coordinator.dispatchIndependentBatch(
        items: List<ImportTaskBatchItem>.generate(
          3,
          (index) => ImportTaskBatchItem(
            sourceDescription: '${mode.name}-$index.pdf',
            mode: mode,
            parse: (_) => parseItem(index),
          ),
        ),
      );

      await firstStarted.future;
      expect(manager.tasks, hasLength(3));
      expect(secondStarted.isCompleted, isFalse);

      releaseFirst.complete();
      await secondStarted.future;
      for (final handle in batch.tasks) {
        await _waitForTask(
          manager,
          handle.taskId,
          (task) => task.status == TaskStatus.pendingReview,
        );
      }
    });
  }

  test('empty result persists only allowlisted failure diagnostics', () async {
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async => ImportParseResult(
        questions: const [],
        warnings: <String>[_sensitiveFailureText],
        diagnostics: <String, dynamic>{'rawFailure': _sensitiveFailureText},
      ),
      taskIdFactory: () => 'task-empty',
      traceIdFactory: () => 'trace-empty',
    );

    final handle = await coordinator.dispatchRequest(
      sourceDescription: 'fixture.pdf',
      filePaths: const ['fixture.pdf'],
      fileNames: const ['fixture.pdf'],
      mode: ImportParseMode.ocr,
      maxConcurrency: 1,
    );
    final task = await _waitForTask(
      manager,
      handle.taskId,
      (task) => task.status == TaskStatus.error,
    );

    expect(task.parsedData, isNull);
    expect(task.traceId, 'trace-empty');
    expect(task.status, TaskStatus.error);
    expect(task.errorMsg, 'OCR 返回结果格式异常，请稍后重试');
    expect(task.warnings, isEmpty);
    expect(task.diagnostics?['failedStage'], 'import_parse');
    expect(task.diagnostics?['errorType'], 'ProviderResponseFormatFailure');
    expect(task.diagnostics?['status'], 'failed');
    final persisted = jsonEncode(task.toMap());
    for (final fragment in _sensitiveFragments) {
      expect(task.errorMsg, isNot(contains(fragment)));
      expect(jsonEncode(task.diagnostics), isNot(contains(fragment)));
      expect(persisted, isNot(contains(fragment)));
    }
  });

  for (final failure in <_EmptyOcrFailureCase>[
    const _EmptyOcrFailureCase(
      name: 'missing OCR configuration',
      status: 'failed_not_configured',
      expectedType: 'OcrNotConfiguredFailure',
      expectedMessage: '未配置可用的 OCR 引擎，请先完成 OCR 配置',
    ),
    const _EmptyOcrFailureCase(
      name: 'empty OCR blocks',
      status: 'failed_empty_ocr_blocks',
      expectedType: 'OcrEmptyBlocksFailure',
      expectedMessage: 'OCR 未识别到有效文字，请检查文档清晰度后重试',
    ),
    const _EmptyOcrFailureCase(
      name: 'no question regions',
      status: 'failed_no_question_regions',
      expectedType: 'OcrNoQuestionRegionsFailure',
      expectedMessage: 'OCR 已返回内容，但未识别到有效题目区域',
    ),
    const _EmptyOcrFailureCase(
      name: 'no assembled questions',
      status: 'failed_no_assembled_questions',
      expectedType: 'OcrNoAssembledQuestionsFailure',
      expectedMessage: 'OCR 已返回文字，但未能组装出有效题目',
    ),
    const _EmptyOcrFailureCase(
      name: 'provider authentication failure',
      status: 'failed_request',
      ocrErrorType: 'ZhipuOcrAuthenticationException',
      expectedType: 'ProviderRequestFailure',
      expectedMessage: 'OCR 服务请求失败，请检查网络或服务配置',
    ),
    const _EmptyOcrFailureCase(
      name: 'provider response format failure',
      status: 'failed_request',
      ocrErrorType: 'ZhipuOcrResponseFormatException',
      expectedType: 'ProviderResponseFormatFailure',
      expectedMessage: 'OCR 返回结果格式异常，请稍后重试',
    ),
    const _EmptyOcrFailureCase(
      name: 'internal OCR runtime failure',
      status: 'failed_request',
      ocrErrorType: 'StateError',
      expectedType: 'UnknownImportFailure',
      expectedMessage: '导入过程中发生异常，请根据 Trace ID 查看诊断',
    ),
  ]) {
    test(
        'empty OCR ${failure.name} preserves only allowlisted cause diagnostics',
        () async {
      final coordinator = ImportTaskCoordinator(
        taskManager: manager,
        readiness: Future<void>.value(),
        parser: (request) async => ImportParseResult(
          questions: const <Map<String, dynamic>>[],
          warnings: <String>[_sensitiveFailureText],
          diagnostics: <String, dynamic>{
            'ocr_import_file_0': <String, dynamic>{
              'status': failure.status,
              if (failure.ocrErrorType != null)
                'errorType': failure.ocrErrorType,
              'rawResponse': _sensitiveFailureText,
            },
            'unrelated': <String, dynamic>{
              'status': 'failed_sensitive',
              'errorType': _sensitiveFailureText,
            },
          },
        ),
        taskIdFactory: () => 'task-empty-${failure.name.replaceAll(' ', '-')}',
        traceIdFactory: () => 'trace-empty-ocr',
      );

      final handle = await coordinator.dispatchRequest(
        sourceDescription: r'C:\private\fixture.pdf',
        filePaths: const <String>['fixture.pdf'],
        fileNames: const <String>['fixture.pdf'],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
      );
      final task = await _waitForTask(
        manager,
        handle.taskId,
        (task) => task.status == TaskStatus.error,
      );
      await AppLogger.flush();

      expect(task.errorMsg, failure.expectedMessage);
      expect(task.diagnostics?['status'], failure.status);
      expect(task.diagnostics?['errorType'], failure.expectedType);
      if (failure.ocrErrorType == null) {
        expect(task.diagnostics, isNot(contains('ocrErrorType')));
      } else {
        expect(
          task.diagnostics?['ocrErrorType'],
          failure.ocrErrorType,
        );
      }

      final persisted = jsonEncode(task.toMap());
      final logs = jsonEncode(
        logSink.records.map((record) => record.toJson()).toList(),
      );
      for (final fragment in _sensitiveFragments) {
        expect(task.errorMsg, isNot(contains(fragment)));
        expect(persisted, isNot(contains(fragment)));
        expect(logs, isNot(contains(fragment)));
      }
    });
  }

  test('empty OCR result keeps bounded regionizer counters on the failure',
      () async {
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async => ImportParseResult(
        questions: const <Map<String, dynamic>>[],
        warnings: <String>[_sensitiveFailureText],
        diagnostics: <String, dynamic>{
          'ocr_import_file_0': <String, dynamic>{
            'status': 'failed_no_question_regions',
            'document': <String, dynamic>{
              'sourceName': _sensitiveFailureText,
              'pageCount': 1,
              'blockCount': 1,
              'hasMarkdown': true,
              'usage': <String, dynamic>{'total_tokens': 12},
              'pages': <Object?>[_sensitiveFailureText],
            },
            'unsupportedStructureSummary': <String, dynamic>{
              'imageBlockCount': 1,
              'tableBlockCount': 0,
            },
            'regionizer': <String, dynamic>{
              'sourceName': _sensitiveFailureText,
              'unitCount': 1,
              'regionCount': 0,
              'sectionHeadingCount': 0,
              'blockStartCandidateCount': 0,
              'internalLineCandidateCount': 0,
              'parenthesizedArabicCandidateCount': 0,
              'rightParenthesisCandidateCount': 1,
              'rightParenthesisAcceptedCount': 0,
              'rightParenthesisRejectedCount': 1,
              'sequenceRejectedCount': 0,
              'referenceSectionDetected': false,
              'ignoredBlockIds': <String>[_sensitiveFailureText],
              'rejectedQuestionStarts': <String>[
                _sensitiveFailureText,
                _sensitiveFailureText,
              ],
              'markerProbeTrace': <Object?>[_sensitiveFailureText],
            },
          },
        },
      ),
      taskIdFactory: () => 'task-bounded-counters',
      traceIdFactory: () => 'trace-bounded-counters',
    );

    final handle = await coordinator.dispatchRequest(
      sourceDescription: r'C:\private\fixture.pdf',
      filePaths: const <String>['fixture.pdf'],
      fileNames: const <String>['fixture.pdf'],
      mode: ImportParseMode.ocr,
      maxConcurrency: 1,
    );
    final task = await _waitForTask(
      manager,
      handle.taskId,
      (task) => task.status == TaskStatus.error,
    );
    await AppLogger.flush();

    expect(task.errorMsg, 'OCR 已返回内容，但未识别到有效题目区域');
    expect(task.diagnostics?['status'], 'failed_no_question_regions');
    expect(task.diagnostics?['errorType'], 'OcrNoQuestionRegionsFailure');

    final bounded = task.diagnostics?['ocrRegionizer'] as Map<String, dynamic>?;
    expect(bounded, isNotNull);
    expect(bounded!['pageCount'], 1);
    expect(bounded['blockCount'], 1);
    expect(bounded['imageBlockCount'], 1);
    expect(bounded['tableBlockCount'], 0);
    expect(bounded['unitCount'], 1);
    expect(bounded['regionCount'], 0);
    expect(bounded['sectionHeadingCount'], 0);
    expect(bounded['blockStartCandidateCount'], 0);
    expect(bounded['internalLineCandidateCount'], 0);
    expect(bounded['parenthesizedArabicCandidateCount'], 0);
    expect(bounded['rightParenthesisCandidateCount'], 1);
    expect(bounded['rightParenthesisRejectedCount'], 1);
    expect(bounded['referenceSectionDetected'], isFalse);
    expect(bounded['rejectedQuestionStartCount'], 2);
    expect(bounded.containsKey('ignoredBlockIds'), isFalse);
    expect(bounded.containsKey('sourceName'), isFalse);

    final persisted = jsonEncode(task.toMap());
    final logs = jsonEncode(
      logSink.records.map((record) => record.toJson()).toList(),
    );
    for (final fragment in _sensitiveFragments) {
      expect(persisted, isNot(contains(fragment)));
      expect(logs, isNot(contains(fragment)));
    }
  });

  test('bounded OCR traces are capped and keep only whitelisted fields',
      () async {
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async => ImportParseResult(
        questions: const <Map<String, dynamic>>[],
        warnings: const <String>[],
        diagnostics: <String, dynamic>{
          'ocr_import_file_0': <String, dynamic>{
            'status': 'failed_no_question_regions',
            'regionizer': <String, dynamic>{
              'unitCount': 25,
              'regionCount': 0,
              'markerProbeTrace': <Map<String, dynamic>>[
                for (var index = 0; index < 25; index++)
                  <String, dynamic>{
                    'markerShape': 'digit_prefix_unrecognized',
                    'followerClass': 'stem_keyword',
                    'probeReason': 'block_start_not_candidate',
                    'startsAtBlockStart': true,
                    'startsAtLineBoundary': true,
                    'parsedNumber': index + 1,
                    'text': _sensitiveFailureText,
                    'blockId': 'block_$index',
                    'remainingText': _sensitiveFailureText,
                  },
              ],
              'questionCandidateTrace': <Map<String, dynamic>>[
                for (var index = 0; index < 25; index++)
                  <String, dynamic>{
                    'number': index + 1,
                    'markerKind': 'right_parenthesized_arabic',
                    'decision': 'rejected',
                    'reason': 'missing_section_context',
                    'previousAcceptedNumber': index,
                    'sectionIndex': 0,
                    'blockOrder': index,
                    'text': _sensitiveFailureText,
                  },
              ],
            },
          },
        },
      ),
      taskIdFactory: () => 'task-bounded-traces',
      traceIdFactory: () => 'trace-bounded-traces',
    );

    final handle = await coordinator.dispatchRequest(
      sourceDescription: r'C:\private\fixture.pdf',
      filePaths: const <String>['fixture.pdf'],
      fileNames: const <String>['fixture.pdf'],
      mode: ImportParseMode.ocr,
      maxConcurrency: 1,
    );
    final task = await _waitForTask(
      manager,
      handle.taskId,
      (task) => task.status == TaskStatus.error,
    );

    final bounded = task.diagnostics?['ocrRegionizer'] as Map<String, dynamic>?;
    expect(bounded, isNotNull);

    const probeKeys = <String>{
      'markerShape',
      'followerClass',
      'probeReason',
      'startsAtBlockStart',
      'startsAtLineBoundary',
      'parsedNumber',
    };
    final probes = bounded!['markerProbeTrace'] as List;
    expect(probes, hasLength(20));
    expect(bounded['markerProbeTraceTruncated'], isTrue);
    for (final probe in probes) {
      expect(
        (probe as Map).keys.where((key) => !probeKeys.contains(key)),
        isEmpty,
      );
    }
    expect((probes.first as Map)['parsedNumber'], 1);
    expect((probes.last as Map)['parsedNumber'], 20);

    const candidateKeys = <String>{
      'number',
      'markerKind',
      'decision',
      'reason',
      'previousAcceptedNumber',
      'sectionIndex',
    };
    final candidates = bounded['questionCandidateTrace'] as List;
    expect(candidates, hasLength(20));
    expect(bounded['questionCandidateTraceTruncated'], isTrue);
    for (final candidate in candidates) {
      expect(
        (candidate as Map).keys.where((key) => !candidateKeys.contains(key)),
        isEmpty,
      );
    }
    expect((candidates.first as Map)['reason'], 'missing_section_context');
    expect((candidates.last as Map)['number'], 20);

    final persisted = jsonEncode(task.toMap());
    for (final fragment in _sensitiveFragments) {
      expect(persisted, isNot(contains(fragment)));
    }
    expect(persisted, isNot(contains('blockId')));
    expect(persisted, isNot(contains('remainingText')));
    expect(persisted, isNot(contains('blockOrder')));
  });

  test('bounded OCR failure diagnostics never persist content or names',
      () async {
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async => ImportParseResult(
        questions: const <Map<String, dynamic>>[],
        warnings: const <String>[],
        diagnostics: <String, dynamic>{
          'ocr_import_file_0': <String, dynamic>{
            'status': 'failed_no_question_regions',
            'document': <String, dynamic>{
              'sourceName': r'C:\private\fixture.pdf',
              'pageCount': 2,
              'blockCount': 3,
              'hasMarkdown': true,
              'markdown': 'OCR-SENSITIVE-CONTENT',
              'usage': <String, dynamic>{},
              'pages': <Object?>[
                <String, dynamic>{'blockCount': 3, 'text': 'PRIVATE'},
              ],
            },
            'regionizer': <String, dynamic>{
              'sourceName': r'C:\private\fixture.pdf',
              'unitCount': 3,
              'regionCount': 0,
              'sectionHeadingCount': 0,
              'rejectedQuestionStarts': <String>['block_0001'],
              'markerProbeTrace': <Map<String, dynamic>>[
                <String, dynamic>{
                  'markerShape': 'digit_prefix_unrecognized',
                  'followerClass': 'stem_keyword',
                  'probeReason': 'block_start_not_candidate',
                  'startsAtBlockStart': true,
                  'startsAtLineBoundary': true,
                  'parsedNumber': 4,
                  'text': 'OCR-SENSITIVE-CONTENT',
                  'blockId': 'block_0001',
                },
              ],
            },
            'rawResponses': <Object?>[
              <String, dynamic>{'rawResponse': 'PRIVATE'},
            ],
            'rawResponse': 'Authorization: Bearer fixture-token',
          },
        },
      ),
      taskIdFactory: () => 'task-privacy-gate',
      traceIdFactory: () => 'trace-privacy-gate',
    );

    final handle = await coordinator.dispatchRequest(
      sourceDescription: r'C:\private\fixture.pdf',
      filePaths: const <String>['fixture.pdf'],
      fileNames: const <String>['fixture.pdf'],
      mode: ImportParseMode.ocr,
      maxConcurrency: 1,
    );
    final task = await _waitForTask(
      manager,
      handle.taskId,
      (task) => task.status == TaskStatus.error,
    );
    await AppLogger.flush();

    final bounded = task.diagnostics?['ocrRegionizer'] as Map<String, dynamic>?;
    expect(bounded, isNotNull);
    expect(bounded!['pageCount'], 2);
    expect(bounded['blockCount'], 3);
    expect(bounded['unitCount'], 3);
    expect(bounded['regionCount'], 0);
    expect(bounded['rejectedQuestionStartCount'], 1);
    final probes = bounded['markerProbeTrace'] as List;
    expect(probes, hasLength(1));
    expect((probes.single as Map)['markerShape'], 'digit_prefix_unrecognized');
    expect((probes.single as Map)['parsedNumber'], 4);

    final persisted = jsonEncode(task.toMap());
    final logs = jsonEncode(
      logSink.records.map((record) => record.toJson()).toList(),
    );
    for (final fragment in _sensitiveFragments) {
      expect(task.errorMsg, isNot(contains(fragment)));
      expect(persisted, isNot(contains(fragment)));
      expect(logs, isNot(contains(fragment)));
    }
    expect(persisted, isNot(contains('sourceName')));
    expect(persisted, isNot(contains('rawResponses')));
    expect(persisted, isNot(contains('blockId')));
    expect(persisted, isNot(contains('markdown')));
    expect(persisted, isNot(contains('"text"')));
    expect(persisted, isNot(contains(r'C:\private')));
  });

  test('default parser span keeps failure details out of logs and task data',
      () async {
    final pipeline = ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async =>
          const <Map<String, dynamic>>[],
      visionParser: (imagePaths) async => const <Map<String, dynamic>>[],
      ocrParser: (
              {required filePath,
              required sourceName,
              required format,
              required ExplanationRetentionMode
                  explanationRetentionMode}) async =>
          throw StateError(_sensitiveFailureText),
    );
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: pipeline.parseFiles,
      taskIdFactory: () => 'task-default-parser',
      traceIdFactory: () => 'trace-default-parser',
    );

    final handle = await coordinator.dispatchRequest(
      sourceDescription: r'C:\private\fixture.pdf',
      filePaths: const <String>['fixture.pdf'],
      fileNames: const <String>['fixture.pdf'],
      mode: ImportParseMode.ocr,
      maxConcurrency: 1,
    );
    final task = await _waitForTask(
      manager,
      handle.taskId,
      (task) => task.status == TaskStatus.error,
    );
    await AppLogger.flush();

    expect(task.traceId, 'trace-default-parser');
    expect(task.diagnostics?['failedStage'], 'import_parse');
    expect(task.diagnostics?['errorType'], 'UnknownImportFailure');
    final logs = jsonEncode(
      logSink.records.map((record) => record.toJson()).toList(),
    );
    for (final fragment in _sensitiveFragments) {
      expect(logs, isNot(contains(fragment)));
      expect(task.errorMsg, isNot(contains(fragment)));
      expect(jsonEncode(task.diagnostics), isNot(contains(fragment)));
    }
  });

  test(
      'final failure clears partial OCR batch data without touching same-name task',
      () async {
    final untouchedTask = ImportTask(
      id: 'task-same-filename',
      title: '文档解析任务: fixture.pdf',
      status: TaskStatus.pendingReview,
      parsedData: const <Map<String, dynamic>>[
        <String, dynamic>{'content': 'other-task-content'},
      ],
      pendingChunks: const <String>['other-task-chunk'],
      failedChunks: const <String>['other-task-failure'],
    );
    manager.addTask(untouchedTask);
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async {
        manager.appendPendingChunks(
          request.taskId,
          'vision',
          <String>[_sensitiveFailureText, 'second-batch'],
        );
        manager.markChunkSuccess(
          request.taskId,
          _sensitiveFailureText,
          <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': '1',
              'content': _sensitiveFailureText,
              'options': <String>['A', 'B'],
              'standard_answer': 'A',
              'explanation': _sensitiveFailureText,
            },
          ],
        );
        manager.markChunkFailed(request.taskId, 'second-batch');
        throw StateError(_sensitiveFailureText);
      },
      taskIdFactory: () => 'task-partial-batch',
      traceIdFactory: () => 'trace-partial-batch',
    );

    final handle = await coordinator.dispatchRequest(
      sourceDescription: 'fixture.pdf',
      filePaths: const <String>['fixture.pdf'],
      fileNames: const <String>['fixture.pdf'],
      mode: ImportParseMode.ocr,
      maxConcurrency: 1,
    );
    final task = await _waitForTask(
      manager,
      handle.taskId,
      (task) => task.status == TaskStatus.error,
    );

    expect(task.parsedData, isNull);
    expect(task.pendingChunks, isNull);
    expect(task.failedChunks, isNull);
    expect(task.traceId, 'trace-partial-batch');
    expect(task.diagnostics?['failedStage'], 'import_parse');
    expect(task.diagnostics?['errorType'], 'UnknownImportFailure');
    final persisted = jsonEncode(task.toMap());
    for (final fragment in _sensitiveFragments) {
      expect(persisted, isNot(contains(fragment)));
    }

    expect(untouchedTask.status, TaskStatus.pendingReview);
    expect(untouchedTask.parsedData, hasLength(1));
    expect(untouchedTask.pendingChunks, <String>['other-task-chunk']);
    expect(untouchedTask.failedChunks, <String>['other-task-failure']);
  });

  for (final failure in <_FailureCase>[
    _FailureCase(
      name: 'format exception',
      error: FormatException(_sensitiveFailureText),
      expectedType: 'ProviderResponseFormatFailure',
      expectedMessage: 'OCR 返回结果格式异常，请稍后重试',
    ),
    _FailureCase(
      name: 'file system exception',
      error: FileSystemException(_sensitiveFailureText),
      expectedType: 'FileReadFailure',
      expectedMessage: '无法读取导入文件，请检查文件是否仍然存在',
    ),
    _FailureCase(
      name: 'timeout exception',
      error: TimeoutException(_sensitiveFailureText),
      expectedType: 'ProviderRequestFailure',
      expectedMessage: 'OCR 服务请求失败，请检查网络或服务配置',
    ),
    _FailureCase(
      name: 'unknown state error',
      error: StateError(_sensitiveFailureText),
      expectedType: 'UnknownImportFailure',
      expectedMessage: '导入过程中发生异常，请根据 Trace ID 查看诊断',
    ),
    const _FailureCase(
      name: 'cancelled task',
      error: ImportTaskCancelledException(),
      expectedType: 'TaskCancelled',
      expectedMessage: '导入任务已取消',
    ),
  ]) {
    test('${failure.name} is classified without persisting its message',
        () async {
      final coordinator = ImportTaskCoordinator(
        taskManager: manager,
        readiness: Future<void>.value(),
        parser: (request) async => throw failure.error,
        taskIdFactory: () => 'task-${failure.name.replaceAll(' ', '-')}',
        traceIdFactory: () => 'trace-failure',
      );

      final handle = await coordinator.dispatchRequest(
        sourceDescription: r'C:\private\fixture.pdf',
        filePaths: const ['fixture.pdf'],
        fileNames: const ['fixture.pdf'],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
      );
      final task = await _waitForTask(
        manager,
        handle.taskId,
        (task) => task.status == TaskStatus.error,
      );
      await AppLogger.flush();

      expect(task.status, TaskStatus.error);
      expect(task.errorMsg, failure.expectedMessage);
      expect(task.traceId, 'trace-failure');
      expect(task.parseMode, 'ocr');
      expect(task.diagnostics?['failedStage'], 'import_parse');
      expect(task.diagnostics?['errorType'], failure.expectedType);
      expect(task.diagnostics?['status'], 'failed');

      final diagnostics = jsonEncode(task.diagnostics);
      final persisted = jsonEncode(task.toMap());
      final logs = jsonEncode(
        logSink.records.map((record) => record.toJson()).toList(),
      );
      for (final fragment in _sensitiveFragments) {
        expect(task.errorMsg, isNot(contains(fragment)));
        expect(diagnostics, isNot(contains(fragment)));
        expect(persisted, isNot(contains(fragment)));
        expect(logs, isNot(contains(fragment)));
      }
    });
  }

  test(
      'route and reason enter task diagnostics only, never the user-visible '
      '_import_diagnostics, and survive reload', () async {
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async => ImportParseResult.withStorageMetadata(
        questions: const <Map<String, dynamic>>[
          <String, dynamic>{
            'q_num': '1',
            'type': 0,
            'content': 'Synthetic question',
            'options': <String>['A', 'B'],
            'standard_answer': 'A',
            'explanation': '',
          },
        ],
        warnings: const <String>['synthetic warning'],
        diagnostics: const <String, dynamic>{'safeCount': 1},
        storageRoute: ImportStorageRoute.legacyV1,
        storageReason: 'typed_candidate_shadow_ready',
      ),
      taskIdFactory: () => 'task-storage-metadata',
      traceIdFactory: () => 'trace-storage-metadata',
    );

    final handle = await coordinator.dispatchRequest(
      sourceDescription: 'fixture.pdf',
      filePaths: const <String>['fixture.pdf'],
      fileNames: const <String>['fixture.pdf'],
      mode: ImportParseMode.ocr,
      maxConcurrency: 1,
    );
    final task = await _waitForTask(
      manager,
      handle.taskId,
      (task) => task.status == TaskStatus.pendingReview,
    );

    expect(task.diagnostics?[TaskManager.keyImportStorageRoute], 'legacyV1');
    expect(
      task.diagnostics?[TaskManager.keyImportStorageReason],
      'typed_candidate_shadow_ready',
    );
    final userVisible = task.parsedData!.first['_import_diagnostics'] as List;
    expect(userVisible, isNot(contains('typed_candidate_shadow_ready')));
    expect(userVisible, isNot(contains('_importStorageRoute')));
    expect(userVisible, isNot(contains('_importStorageReason')));
    final restored = ImportTask.fromMap(task.toMap());
    expect(
      restored.diagnostics?[TaskManager.keyImportStorageRoute],
      'legacyV1',
    );
    expect(
      restored.diagnostics?[TaskManager.keyImportStorageReason],
      'typed_candidate_shadow_ready',
    );
    expect(restored.parsedData, hasLength(1));
  });

  test('invalid storage reason is rejected at the strict metadata boundary',
      () {
    expect(
      () => ImportParseResult.withStorageMetadata(
        questions: const <Map<String, dynamic>>[],
        storageReason: 'Not A Reason!',
      ),
      throwsA(isA<TypedReviewSnapshotException>()),
    );
  });

  group('OBS-1 import correlation', () {
    test('initial attempt creates task/correlation/trace with attempt 1',
        () async {
      var traceIndex = 0;
      final coordinator = ImportTaskCoordinator(
        taskManager: manager,
        readiness: Future<void>.value(),
        taskIdFactory: () => 'obs-initial-task',
        traceIdFactory: () => 'obs-trace-${traceIndex++}',
        attemptTokenFactory: () => 'obs-attempt-1',
      );
      final handle = await coordinator.dispatch(
        sourceDescription: 'same.pdf',
        mode: ImportParseMode.ocr,
        parse: (_) async => const ImportParseResult(
          questions: <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': '1',
              'content': 'Synthetic question',
              'standard_answer': 'A',
            },
          ],
        ),
      );

      final task = await _waitForTask(
        manager,
        handle.taskId,
        (task) => task.status == TaskStatus.pendingReview,
      );

      expect(handle.taskId, 'obs-initial-task');
      expect(handle.attemptNumber, 1);
      expect(handle.correlationId, isNotNull);
      expect(
        handle.correlationId,
        matches(TraceContext.correlationIdPattern),
      );
      expect(handle.parentTraceId, isNull);
      expect(task.correlationId, handle.correlationId);
      expect(task.attemptNumber, 1);
      expect(task.traceId, handle.traceId);

      // The attempt runs inside an importAttempt trace with the correlation.
      final dispatched = logSink.records.where(
        (record) => record.data['stage'] == 'import_dispatch',
      );
      expect(dispatched, isNotEmpty);
      expect(dispatched.first.correlationId, handle.correlationId);
      expect(dispatched.first.traceId, handle.traceId);
      expect(
        dispatched.first.operationKind,
        TraceOperationKind.importAttempt,
      );
      expect(dispatched.first.taskId, handle.taskId);
    });

    test(
        'retry keeps task and correlation, changes trace/token/attempt and '
        'points parent at the previous attempt', () async {
      var traceIndex = 0;
      var attemptIndex = 0;
      final coordinator = ImportTaskCoordinator(
        taskManager: manager,
        readiness: Future<void>.value(),
        taskIdFactory: () => 'obs-retry-task',
        traceIdFactory: () => 'obs-trace-${traceIndex++}',
        attemptTokenFactory: () => 'obs-attempt-${attemptIndex++}',
      );

      final firstHandle = await coordinator.dispatch(
        sourceDescription: 'same.pdf',
        mode: ImportParseMode.ocr,
        parse: (_) async => throw StateError('synthetic first failure'),
      );
      await _waitForTask(
        manager,
        firstHandle.taskId,
        (task) => task.status == TaskStatus.error,
      );

      final secondHandle = await coordinator.retryOcrTask(
        taskId: firstHandle.taskId,
        sourceDescription: 'same.pdf',
        parse: (_) async => const ImportParseResult(
          questions: <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': '2',
              'content': 'Synthetic retry question',
              'standard_answer': 'B',
            },
          ],
        ),
      );
      final retried = await _waitForTask(
        manager,
        firstHandle.taskId,
        (task) => task.status == TaskStatus.pendingReview,
      );

      expect(secondHandle.taskId, firstHandle.taskId);
      expect(secondHandle.correlationId, firstHandle.correlationId);
      expect(secondHandle.traceId, isNot(firstHandle.traceId));
      expect(secondHandle.attemptToken, isNot(firstHandle.attemptToken));
      expect(secondHandle.attemptNumber, firstHandle.attemptNumber + 1);
      expect(secondHandle.attemptNumber, 2);
      expect(secondHandle.parentTraceId, firstHandle.traceId);

      expect(retried.correlationId, firstHandle.correlationId);
      expect(retried.traceId, secondHandle.traceId);
      expect(retried.attemptNumber, 2);
      expect(retried.attemptToken, secondHandle.attemptToken);
      expect(
        retried.diagnostics?[TaskManager.keyParentTraceId],
        firstHandle.traceId,
      );

      // Correlation metadata survives progress -> failure -> retry -> review.
      expect(firstHandle.correlationId, isNotNull);
      expect(retried.status, TaskStatus.pendingReview);
    });

    test('batch identity stays independent from per-task correlation',
        () async {
      final coordinator = ImportTaskCoordinator(
        taskManager: manager,
        readiness: Future<void>.value(),
        batchIdFactory: () => 'obs-batch',
      );
      final batch = await coordinator.dispatchIndependentBatch(
        items: <ImportTaskBatchItem>[
          ImportTaskBatchItem(
            sourceDescription: 'a.pdf',
            mode: ImportParseMode.ocr,
            parse: (_) async => const ImportParseResult(
              questions: <Map<String, dynamic>>[
                <String, dynamic>{'q_num': '1', 'content': 'A'},
              ],
            ),
          ),
          ImportTaskBatchItem(
            sourceDescription: 'b.pdf',
            mode: ImportParseMode.ocr,
            parse: (_) async => const ImportParseResult(
              questions: <Map<String, dynamic>>[
                <String, dynamic>{'q_num': '1', 'content': 'B'},
              ],
            ),
          ),
        ],
      );
      for (final handle in batch.tasks) {
        await _waitForTask(
          manager,
          handle.taskId,
          (task) => task.status == TaskStatus.pendingReview,
        );
      }

      expect(batch.batchId, 'obs-batch');
      expect(batch.tasks, hasLength(2));
      expect(batch.tasks[0].correlationId, isNotNull);
      expect(batch.tasks[1].correlationId, isNotNull);
      expect(
        batch.tasks[0].correlationId,
        isNot(batch.tasks[1].correlationId),
      );
      for (final handle in batch.tasks) {
        expect(handle.correlationId, isNot(batch.batchId));
        final task = manager.tasks.firstWhere(
          (task) => task.id == handle.taskId,
        );
        expect(task.batchId, 'obs-batch');
        expect(task.correlationId, handle.correlationId);
      }
    });

    test('batch tasks inside an enclosing trace still own fresh correlations',
        () async {
      final coordinator = ImportTaskCoordinator(
        taskManager: manager,
        readiness: Future<void>.value(),
        batchIdFactory: () => 'obs-nested-batch',
      );
      final batch = await TraceContext.run(
        correlationId: 'OBS-AAAA-BBBB',
        traceId: 'trace-enclosing',
        operationKind: TraceOperationKind.agentTurn,
        action: () => coordinator.dispatchIndependentBatch(
          items: <ImportTaskBatchItem>[
            ImportTaskBatchItem(
              sourceDescription: 'a.pdf',
              mode: ImportParseMode.ocr,
              parse: (_) async => const ImportParseResult(
                questions: <Map<String, dynamic>>[
                  <String, dynamic>{'q_num': '1', 'content': 'A'},
                ],
              ),
            ),
            ImportTaskBatchItem(
              sourceDescription: 'b.pdf',
              mode: ImportParseMode.ocr,
              parse: (_) async => const ImportParseResult(
                questions: <Map<String, dynamic>>[
                  <String, dynamic>{'q_num': '1', 'content': 'B'},
                ],
              ),
            ),
          ],
        ),
      );
      for (final handle in batch.tasks) {
        await _waitForTask(
          manager,
          handle.taskId,
          (task) => task.status == TaskStatus.pendingReview,
        );
      }

      expect(batch.batchId, 'obs-nested-batch');
      expect(batch.tasks, hasLength(2));
      final first = batch.tasks[0];
      final second = batch.tasks[1];
      expect(first.correlationId, isNot(second.correlationId));
      expect(first.correlationId, isNot('OBS-AAAA-BBBB'));
      expect(second.correlationId, isNot('OBS-AAAA-BBBB'));
      expect(
        first.correlationId,
        matches(TraceContext.correlationIdPattern),
      );
      // The enclosing trace is the parent of every task in the batch.
      expect(first.parentTraceId, 'trace-enclosing');
      expect(second.parentTraceId, 'trace-enclosing');
      // Persisted metadata matches the handles.
      for (final handle in batch.tasks) {
        final task = manager.tasks.firstWhere(
          (task) => task.id == handle.taskId,
        );
        expect(task.correlationId, handle.correlationId);
        expect(task.parentTraceId, 'trace-enclosing');
        expect(task.batchId, 'obs-nested-batch');
      }
    });

    test(
        'real ImportPipeline executed inside importAttempt correlation never leaks '
        'filename, absolute path, or question content into correlated LogRecords',
        () async {
      const filenameSentinel = 'PRIVATE_FILENAME_SENTINEL.pdf';
      const pathSentinel = r'C:\private\secrets\PRIVATE_FILENAME_SENTINEL.pdf';
      const contentSentinel = 'PRIVATE_QUESTION_STEM_CONTENT_SENTINEL';

      final pipeline = ImportPipelineService.forTesting(
        textParser: (rawText, {required taskId, required isMarkdown}) async =>
            <Map<String, dynamic>>[
          <String, dynamic>{
            'q_num': '1',
            'content': contentSentinel,
            'standard_answer': 'A',
          },
        ],
        visionParser: (imagePaths) async => const <Map<String, dynamic>>[],
        ocrParser: (
            {required filePath,
            required sourceName,
            required format,
            required ExplanationRetentionMode explanationRetentionMode}) async {
          return const OcrImportResult(
            questions: <Map<String, dynamic>>[
              <String, dynamic>{
                'q_num': '1',
                'content': contentSentinel,
                'standard_answer': 'A',
              },
            ],
            warnings: <String>[],
            diagnostics: <String, dynamic>{},
            usedOcr: true,
          );
        },
      );

      final coordinator = ImportTaskCoordinator(
        taskManager: manager,
        readiness: Future<void>.value(),
        parser: pipeline.parseFiles,
        taskIdFactory: () => 'obs-privacy-task',
        traceIdFactory: () => 'obs-privacy-trace',
      );

      final handle = await coordinator.dispatchRequest(
        sourceDescription: filenameSentinel,
        filePaths: const <String>[pathSentinel],
        fileNames: const <String>[filenameSentinel],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
      );

      final task = await _waitForTask(
        manager,
        handle.taskId,
        (task) => task.status == TaskStatus.pendingReview,
      );
      await AppLogger.flush();

      expect(handle.correlationId, isNotNull);
      expect(
        handle.correlationId,
        matches(TraceContext.correlationIdPattern),
      );
      expect(task.correlationId, handle.correlationId);

      // Collect all LogRecords associated with this correlationId.
      final correlatedRecords = logSink.records
          .where((record) => record.correlationId == handle.correlationId)
          .toList();

      expect(
        correlatedRecords,
        isNotEmpty,
        reason: 'Correlated LogRecords must be captured',
      );

      // ImportPipeline structural records must exist and be correlated.
      final pipelineStartRecords = correlatedRecords.where(
        (record) => record.message == 'Import file processing started',
      );
      expect(
        pipelineStartRecords,
        isNotEmpty,
        reason: 'Import file processing started log must be recorded',
      );
      final startRecord = pipelineStartRecords.first;
      expect(startRecord.module, 'ImportPipeline');
      expect(startRecord.data['fileIndex'], 0);
      expect(startRecord.data['format'], 'pdf');
      expect(
        startRecord.data.containsKey('sourceName'),
        isFalse,
        reason: 'sourceName must be omitted from structured log data',
      );

      final pipelineSpanRecords = correlatedRecords.where(
        (record) => record.message.startsWith('Import pipeline'),
      );
      expect(
        pipelineSpanRecords,
        isNotEmpty,
        reason: 'Import pipeline span must be recorded',
      );

      // Assert that NO correlated LogRecord contains filename, path, or content sentinels.
      for (final record in correlatedRecords) {
        final recordJson = jsonEncode(record.toJson());
        expect(
          recordJson,
          isNot(contains(filenameSentinel)),
          reason:
              'Log record ${record.message} must not contain filename sentinel',
        );
        expect(
          recordJson,
          isNot(contains('PRIVATE_FILENAME_SENTINEL')),
          reason:
              'Log record ${record.message} must not contain filename token',
        );
        expect(
          recordJson,
          isNot(contains(r'C:\private\secrets')),
          reason:
              'Log record ${record.message} must not contain absolute path sentinel',
        );
        expect(
          recordJson,
          isNot(contains(contentSentinel)),
          reason:
              'Log record ${record.message} must not contain question content sentinel',
        );
      }
    });
  });
}
