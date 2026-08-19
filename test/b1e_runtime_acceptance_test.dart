import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/import_pipeline/local_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document_client.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_import_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_request_scheduler.dart';
import 'package:shiroha_quiz/services/import_pipeline/single_question_repair_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';
import 'package:shiroha_quiz/ui/pages/task_center_projection.dart';
import 'package:shiroha_quiz/ui/pages/task_center_screen.dart';

import 'support/unsupported_ai_engine_store.dart';

const String _syntheticPathRoot = r'C:\b1e_synthetic';
const String _syntheticOcrBody = 'B1E_SYNTHETIC_OCR_BODY';
const String _syntheticExceptionBody = 'B1E_SYNTHETIC_EXCEPTION_BODY';

class _FakeOcrEngineRepository extends AiEngineRepository {
  _FakeOcrEngineRepository()
      : super(
          store: const UnsupportedAiEngineStore(),
          credentialStore: const UnsupportedEngineCredentialStore(),
        );

  static const AiEngineProfile _profile = AiEngineProfile(
    id: 'b1e-ocr-profile',
    engineType: AiEngineType.ocr,
    name: 'b1e-synthetic-ocr',
    apiKey: '',
    baseUrl: 'https://open.bigmodel.cn/api/paas',
    modelName: 'glm-ocr',
    temperature: 0,
    reasoningEffort: '',
    isActive: true,
  );

  @override
  Future<AiEngineProfile?> getActiveOcrEngine() async => _profile;
}

class _NoopRepairService extends SingleQuestionRepairService {
  const _NoopRepairService();

  @override
  Future<LocalAssemblyResult> repair({
    required TextQuestionRegion region,
    required LocalAssemblyResult localResult,
    required bool requireAnswer,
    required ExplanationRetentionMode explanationRetentionMode,
  }) async {
    return localResult;
  }
}

class _ControlledOcrDocumentClient implements OcrDocumentClient {
  final Map<String, Completer<OcrDocument>> _responses =
      <String, Completer<OcrDocument>>{};
  final Map<String, Completer<void>> _starts = <String, Completer<void>>{};
  final Map<String, Completer<void>> _returns = <String, Completer<void>>{};

  final List<String> startOrder = <String>[];
  int callCount = 0;
  int activeCount = 0;
  int maxActiveCount = 0;

  @override
  String get modelId => 'b1e-controlled-fake-client';

  bool hasStarted(String filePath) => _starts[filePath]?.isCompleted ?? false;

  Future<void> waitUntilStarted(String filePath) {
    return _starts
        .putIfAbsent(filePath, Completer<void>.new)
        .future
        .timeout(const Duration(seconds: 5));
  }

  Future<void> waitUntilReturned(String filePath) {
    return _returns
        .putIfAbsent(filePath, Completer<void>.new)
        .future
        .timeout(const Duration(seconds: 5));
  }

  void complete(String filePath, OcrDocument document) {
    final response = _responses[filePath];
    if (response == null) {
      throw StateError('synthetic response completed before client start');
    }
    response.complete(document);
  }

  void fail(String filePath) {
    final response = _responses[filePath];
    if (response == null) {
      throw StateError('synthetic failure completed before client start');
    }
    response.completeError(StateError(_syntheticExceptionBody));
  }

  @override
  Future<OcrDocument> parseFile({
    required AiEngineProfile profile,
    required String filePath,
    required String sourceName,
    Duration timeout = const Duration(minutes: 8),
  }) async {
    callCount++;
    activeCount++;
    if (activeCount > maxActiveCount) maxActiveCount = activeCount;
    startOrder.add(filePath);
    final started = _starts.putIfAbsent(filePath, Completer<void>.new);
    if (!started.isCompleted) started.complete();
    try {
      return await _responses
          .putIfAbsent(filePath, Completer<OcrDocument>.new)
          .future;
    } finally {
      activeCount--;
      final returned = _returns.putIfAbsent(filePath, Completer<void>.new);
      if (!returned.isCompleted) returned.complete();
    }
  }
}

class _RuntimeCounters {
  int mergerCalls = 0;
  final List<String> reviewNotifications = <String>[];
  final Map<int, Completer<void>> _reviewCountWaiters =
      <int, Completer<void>>{};

  void recordReviewNotification(String sourceDescription) {
    reviewNotifications.add(sourceDescription);
    for (final entry in _reviewCountWaiters.entries.toList(growable: false)) {
      if (reviewNotifications.length >= entry.key && !entry.value.isCompleted) {
        entry.value.complete();
        _reviewCountWaiters.remove(entry.key);
      }
    }
  }

  Future<void> waitForReviewCount(int expectedCount) {
    if (reviewNotifications.length >= expectedCount) {
      return Future<void>.value();
    }
    return _reviewCountWaiters
        .putIfAbsent(expectedCount, Completer<void>.new)
        .future
        .timeout(const Duration(seconds: 5));
  }
}

typedef _RuntimeHarness = ({
  TaskManager manager,
  OcrRequestScheduler scheduler,
  _ControlledOcrDocumentClient client,
  ImportPipelineService pipeline,
  ImportTaskCoordinator coordinator,
  _RuntimeCounters counters,
});

_RuntimeHarness _buildRuntimeHarness({
  required TaskManager manager,
  required String prefix,
}) {
  final scheduler = OcrRequestScheduler(maxConcurrentRequests: 2);
  final client = _ControlledOcrDocumentClient();
  final counters = _RuntimeCounters();
  final ocrService = OcrImportService(
    engineRepository: _FakeOcrEngineRepository(),
    ocrClient: client,
    requestScheduler: scheduler,
    taskManager: manager,
    repairService: const _NoopRepairService(),
  );
  final pipeline = ImportPipelineService.forTesting(
    textParser: (
      rawText, {
      required taskId,
      required isMarkdown,
    }) async {
      throw StateError('unexpected_text_parser');
    },
    visionParser: (imagePaths) async {
      throw StateError('unexpected_vision_parser');
    },
    ocrParser: ocrService.tryParse,
    questionMerger: (fileResults) async {
      counters.mergerCalls++;
      return fileResults.expand((questions) => questions).toList();
    },
    taskManager: manager,
  );
  var taskIndex = 0;
  var traceIndex = 0;
  var tokenIndex = 0;
  final coordinator = ImportTaskCoordinator(
    taskManager: manager,
    readiness: manager.ready,
    parser: pipeline.parseFiles,
    requestScheduler: scheduler,
    taskIdFactory: () => '$prefix-task-${taskIndex++}',
    traceIdFactory: () => '$prefix-trace-${traceIndex++}',
    attemptTokenFactory: () => '$prefix-token-${tokenIndex++}',
    batchIdFactory: () => '$prefix-batch',
    onReadyForReview: counters.recordReviewNotification,
  );
  return (
    manager: manager,
    scheduler: scheduler,
    client: client,
    pipeline: pipeline,
    coordinator: coordinator,
    counters: counters,
  );
}

ImportTaskBatchItem _batchItem({
  required ImportPipelineService pipeline,
  required String filePath,
  required String fileName,
}) {
  return ImportTaskBatchItem(
    sourceDescription: fileName,
    mode: ImportParseMode.ocr,
    parse: (taskId) => pipeline.parseFiles(
      ImportParseRequest(
        filePaths: <String>[filePath],
        fileNames: <String>[fileName],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
        taskId: taskId,
      ),
    ),
  );
}

OcrDocument _successfulDocument(int questionNumber) {
  return OcrDocument(
    sourceName: 'b1e-synthetic.pdf',
    markdown: '',
    rawResponses: const <Map<String, dynamic>>[],
    usage: const <String, dynamic>{},
    pages: <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          const OcrBlock(
            blockId: 'section',
            pageIndex: 1,
            type: 'text',
            text: '一、选择题',
            bbox: <double>[],
            readingOrder: 0,
          ),
          OcrBlock(
            blockId: 'question-$questionNumber',
            pageIndex: 1,
            type: 'text',
            text: '$questionNumber. $_syntheticOcrBody',
            bbox: const <double>[],
            readingOrder: 1,
          ),
          OcrBlock(
            blockId: 'answer-$questionNumber',
            pageIndex: 1,
            type: 'text',
            text: '答案：A',
            bbox: const <double>[],
            readingOrder: 2,
          ),
        ],
      ),
    ],
  );
}

ImportTask? _taskById(TaskManager manager, String taskId) {
  for (final task in manager.tasks) {
    if (task.id == taskId) return task;
  }
  return null;
}

Future<ImportTask> _waitForTask(
  TaskManager manager,
  String taskId,
  bool Function(ImportTask task) predicate,
) {
  final current = _taskById(manager, taskId);
  if (current != null && predicate(current)) {
    return Future<ImportTask>.value(current);
  }

  final completer = Completer<ImportTask>();
  late VoidCallback listener;
  listener = () {
    final task = _taskById(manager, taskId);
    if (task == null || !predicate(task) || completer.isCompleted) return;
    manager.removeListener(listener);
    completer.complete(task);
  };
  manager.addListener(listener);
  return completer.future.timeout(
    const Duration(seconds: 5),
    onTimeout: () {
      manager.removeListener(listener);
      throw StateError('synthetic task did not reach expected state');
    },
  );
}

void _expectDiagnosticsRedacted(
  Iterable<ImportTask> tasks, {
  required Iterable<String> forbidden,
}) {
  final encoded = jsonEncode(
    tasks.map((task) => task.diagnostics).toList(growable: false),
  );
  for (final fragment in forbidden) {
    expect(encoded, isNot(contains(fragment)));
  }
}

class _RecordingNavigatorObserver extends NavigatorObserver {
  int pushCount = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushCount++;
    super.didPush(route, previousRoute);
  }
}

Future<void> _selectCategory(
  WidgetTester tester,
  TaskCenterCategory category,
) async {
  await tester.tap(
    find.byKey(ValueKey<String>('task-category-${category.name}')),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'independent PDFs traverse the real OCR chain with bounded lifecycle races',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final manager = TaskManager.forTesting();
      addTearDown(manager.dispose);
      final runtime = _buildRuntimeHarness(
        manager: manager,
        prefix: 'b1e-batch',
      );
      const paths = <String>[
        '$_syntheticPathRoot\\first.pdf',
        '$_syntheticPathRoot\\failure.pdf',
        '$_syntheticPathRoot\\queued-same.pdf',
        '$_syntheticPathRoot\\running-same.pdf',
        '$_syntheticPathRoot\\last.pdf',
      ];
      const names = <String>[
        'first.pdf',
        'failure.pdf',
        'same.pdf',
        'same.pdf',
        'last.pdf',
      ];

      final terminalOrder = <String>[];
      final seenTerminalTasks = <String>{};
      void recordTerminalOrder() {
        for (final task in manager.tasks) {
          if (task.status.isFinalState && seenTerminalTasks.add(task.id)) {
            terminalOrder.add(task.id);
          }
        }
      }

      manager.addListener(recordTerminalOrder);
      addTearDown(() => manager.removeListener(recordTerminalOrder));

      final batch = await runtime.coordinator.dispatchIndependentBatch(
        items: List<ImportTaskBatchItem>.generate(
          paths.length,
          (index) => _batchItem(
            pipeline: runtime.pipeline,
            filePath: paths[index],
            fileName: names[index],
          ),
        ),
      );

      expect(manager.tasks, hasLength(5));
      expect(batch.tasks.map((handle) => handle.taskId), <String>[
        'b1e-batch-task-0',
        'b1e-batch-task-1',
        'b1e-batch-task-2',
        'b1e-batch-task-3',
        'b1e-batch-task-4',
      ]);
      expect(
        manager.tasks.map((task) => task.selectionIndex),
        <int?>[0, 1, 2, 3, 4],
      );
      expect(
        manager.tasks.map((task) => task.batchId).toSet(),
        <String?>{'b1e-batch-batch'},
      );

      await Future.wait<void>(<Future<void>>[
        runtime.client.waitUntilStarted(paths[0]),
        runtime.client.waitUntilStarted(paths[1]),
      ]);
      expect(runtime.client.callCount, 2);
      expect(runtime.client.activeCount, 2);
      expect(runtime.client.maxActiveCount, 2);
      expect(runtime.client.startOrder, <String>[paths[0], paths[1]]);
      expect(runtime.client.hasStarted(paths[2]), isFalse);
      expect(runtime.client.hasStarted(paths[3]), isFalse);
      expect(runtime.client.hasStarted(paths[4]), isFalse);
      expect(
        manager.tasks.map((task) => task.attemptState),
        <ImportAttemptState>[
          ImportAttemptState.running,
          ImportAttemptState.running,
          ImportAttemptState.queued,
          ImportAttemptState.queued,
          ImportAttemptState.queued,
        ],
      );

      // Arm queued cancellation at the same quota-release boundary. The
      // cancellation state and scheduler removal are observed before the
      // active Provider is released, so the cancelled task can never start.
      final queuedCancelled = _waitForTask(
        manager,
        batch.tasks[2].taskId,
        (task) => task.attemptState == ImportAttemptState.cancelled,
      );
      final queuedCancellationWrite =
          runtime.coordinator.cancelOcrTask(batch.tasks[2].taskId);
      await queuedCancelled;
      expect(
        await queuedCancellationWrite,
        ImportAttemptWriteStatus.applied,
      );

      final firstReady = _waitForTask(
        manager,
        batch.tasks[0].taskId,
        (task) => task.status == TaskStatus.pendingReview,
      );
      final fourthStarted = runtime.client.waitUntilStarted(paths[3]);
      runtime.client.complete(paths[0], _successfulDocument(1));
      await fourthStarted;
      expect(runtime.client.hasStarted(paths[2]), isFalse);
      expect(runtime.client.startOrder, <String>[
        paths[0],
        paths[1],
        paths[3],
      ]);
      expect(runtime.client.activeCount, 2);

      // Running cancellation remains cooperative: the task stays active and
      // cancelRequested until the Fake Client returns.
      final cancelRequested = _waitForTask(
        manager,
        batch.tasks[3].taskId,
        (task) => task.attemptState == ImportAttemptState.cancelRequested,
      );
      final runningCancellationWrite =
          runtime.coordinator.cancelOcrTask(batch.tasks[3].taskId);
      await cancelRequested;
      expect(
        await runningCancellationWrite,
        ImportAttemptWriteStatus.applied,
      );
      expect(runtime.client.activeCount, 2);
      expect(runtime.client.hasStarted(paths[4]), isFalse);

      final runningCancelled = _waitForTask(
        manager,
        batch.tasks[3].taskId,
        (task) => task.attemptState == ImportAttemptState.cancelled,
      );
      final fifthStarted = runtime.client.waitUntilStarted(paths[4]);
      runtime.client.complete(paths[3], _successfulDocument(4));
      await Future.wait<void>(<Future<void>>[
        fifthStarted,
        runningCancelled.then<void>((_) {}),
      ]);
      expect(_taskById(manager, batch.tasks[3].taskId)?.parsedData, isNull);
      expect(runtime.client.startOrder, <String>[
        paths[0],
        paths[1],
        paths[3],
        paths[4],
      ]);

      // Complete selection index 4 before selection index 1 to prove that
      // completion order is independent from Task Center display order.
      final fifthReady = _waitForTask(
        manager,
        batch.tasks[4].taskId,
        (task) => task.status == TaskStatus.pendingReview,
      );
      runtime.client.complete(paths[4], _successfulDocument(5));
      await fifthReady;

      final failedTask = _waitForTask(
        manager,
        batch.tasks[1].taskId,
        (task) => task.status == TaskStatus.error,
      );
      runtime.client.fail(paths[1]);
      await failedTask;
      await firstReady;
      await runtime.counters.waitForReviewCount(2);

      expect(runtime.client.callCount, 4);
      expect(runtime.client.activeCount, 0);
      expect(runtime.client.maxActiveCount, 2);
      expect(runtime.client.hasStarted(paths[2]), isFalse);
      expect(runtime.counters.mergerCalls, 0);
      expect(runtime.counters.reviewNotifications, hasLength(2));
      expect(
        terminalOrder.indexOf(batch.tasks[4].taskId),
        lessThan(terminalOrder.indexOf(batch.tasks[1].taskId)),
      );
      expect(
        manager.tasks.map((task) => task.status),
        <TaskStatus>[
          TaskStatus.pendingReview,
          TaskStatus.error,
          TaskStatus.error,
          TaskStatus.error,
          TaskStatus.pendingReview,
        ],
      );
      expect(
        manager.tasks.map((task) => task.attemptState),
        <ImportAttemptState>[
          ImportAttemptState.readyForReview,
          ImportAttemptState.failed,
          ImportAttemptState.cancelled,
          ImportAttemptState.cancelled,
          ImportAttemptState.readyForReview,
        ],
      );

      final restored = manager.tasks
          .map((task) => ImportTask.fromMap(task.toMap()))
          .toList();
      expect(
        restored.map((task) => task.batchId).toSet(),
        <String?>{'b1e-batch-batch'},
      );
      expect(
        restored.map((task) => task.selectionIndex),
        <int?>[0, 1, 2, 3, 4],
      );

      final projection = TaskCenterProjection.fromTasks(manager.tasks);
      expect(
        projection
            .tasksFor(TaskCenterCategory.pendingReview)
            .map((task) => task.selectionIndex),
        <int?>[0, 4],
      );
      expect(
        projection
            .tasksFor(TaskCenterCategory.error)
            .map((task) => task.selectionIndex),
        <int?>[1, 2, 3],
      );

      _expectDiagnosticsRedacted(
        manager.tasks,
        forbidden: const <String>[
          _syntheticPathRoot,
          _syntheticOcrBody,
          _syntheticExceptionBody,
        ],
      );

      final navigatorObserver = _RecordingNavigatorObserver();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: <NavigatorObserver>[navigatorObserver],
          home: TaskCenterScreen(
            taskManager: manager,
            taskCoordinator: runtime.coordinator,
          ),
        ),
      );
      await tester.pump();
      final initialPushCount = navigatorObserver.pushCount;
      expect(find.byType(ImportStagingScreen), findsNothing);

      await _selectCategory(tester, TaskCenterCategory.pendingReview);
      final pendingFirst = find.byKey(
        ValueKey<String>('import-task-${batch.tasks[0].taskId}'),
      );
      final pendingLast = find.byKey(
        ValueKey<String>('import-task-${batch.tasks[4].taskId}'),
      );
      expect(pendingFirst, findsOneWidget);
      expect(pendingLast, findsOneWidget);
      expect(
        tester.getTopLeft(pendingFirst).dy,
        lessThan(tester.getTopLeft(pendingLast).dy),
      );

      await _selectCategory(tester, TaskCenterCategory.error);
      final errorFirst = find.byKey(
        ValueKey<String>('import-task-${batch.tasks[1].taskId}'),
      );
      final errorSecond = find.byKey(
        ValueKey<String>('import-task-${batch.tasks[2].taskId}'),
      );
      final errorThird = find.byKey(
        ValueKey<String>('import-task-${batch.tasks[3].taskId}'),
      );
      expect(
        tester.getTopLeft(errorFirst).dy,
        lessThan(tester.getTopLeft(errorSecond).dy),
      );
      expect(
        tester.getTopLeft(errorSecond).dy,
        lessThan(tester.getTopLeft(errorThird).dy),
      );
      expect(navigatorObserver.pushCount, initialPushCount);
      expect(find.byType(ImportStagingScreen), findsNothing);
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'failed OCR task retries through the real chain with a new attempt',
    () async {
      final manager = TaskManager.forTesting();
      addTearDown(manager.dispose);
      final runtime = _buildRuntimeHarness(
        manager: manager,
        prefix: 'b1e-retry',
      );
      const firstPath = '$_syntheticPathRoot\\retry-first.pdf';
      const retryPath = '$_syntheticPathRoot\\retry-selected.pdf';

      final firstHandle = await runtime.coordinator.dispatchRequest(
        sourceDescription: 'same.pdf',
        filePaths: const <String>[firstPath],
        fileNames: const <String>['same.pdf'],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
      );
      await runtime.client.waitUntilStarted(firstPath);
      expect(
        _taskById(manager, firstHandle.taskId)?.attemptState,
        ImportAttemptState.running,
      );

      final firstFailed = _waitForTask(
        manager,
        firstHandle.taskId,
        (task) => task.attemptState == ImportAttemptState.failed,
      );
      runtime.client.fail(firstPath);
      final failed = await firstFailed;
      expect(failed.status, TaskStatus.error);

      final retryHandle = await runtime.coordinator.retryOcrRequest(
        taskId: firstHandle.taskId,
        filePaths: const <String>[retryPath],
        fileNames: const <String>['same.pdf'],
      );
      await runtime.client.waitUntilStarted(retryPath);

      final runningRetry = _taskById(manager, firstHandle.taskId)!;
      expect(retryHandle.taskId, firstHandle.taskId);
      expect(retryHandle.attemptNumber, firstHandle.attemptNumber + 1);
      expect(retryHandle.traceId, isNot(firstHandle.traceId));
      expect(retryHandle.attemptToken, isNot(firstHandle.attemptToken));
      expect(runningRetry.attemptState, ImportAttemptState.running);
      expect(runningRetry.attemptNumber, 2);

      final retryReady = _waitForTask(
        manager,
        firstHandle.taskId,
        (task) => task.status == TaskStatus.pendingReview,
      );
      runtime.client.complete(retryPath, _successfulDocument(2));
      final ready = await retryReady;
      await runtime.counters.waitForReviewCount(1);

      expect(ready.id, firstHandle.taskId);
      expect(ready.attemptNumber, 2);
      expect(ready.traceId, retryHandle.traceId);
      expect(ready.attemptToken, retryHandle.attemptToken);
      expect(ready.parsedData?.single['q_num'], '2');
      expect(runtime.client.callCount, 2);
      expect(runtime.client.startOrder, <String>[firstPath, retryPath]);
      expect(runtime.counters.mergerCalls, 0);
      expect(runtime.counters.reviewNotifications, hasLength(1));
      _expectDiagnosticsRedacted(
        <ImportTask>[ready],
        forbidden: const <String>[
          _syntheticPathRoot,
          _syntheticOcrBody,
          _syntheticExceptionBody,
        ],
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'stale cancelled attempt callback cannot overwrite the new attempt',
    () async {
      final manager = TaskManager.forTesting();
      addTearDown(manager.dispose);
      final runtime = _buildRuntimeHarness(
        manager: manager,
        prefix: 'b1e-stale',
      );
      const oldPath = '$_syntheticPathRoot\\old-attempt.pdf';
      const newPath = '$_syntheticPathRoot\\new-attempt.pdf';
      const barrierPath = '$_syntheticPathRoot\\barrier.pdf';

      final oldHandle = await runtime.coordinator.dispatchRequest(
        sourceDescription: 'same.pdf',
        filePaths: const <String>[oldPath],
        fileNames: const <String>['same.pdf'],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
      );
      await runtime.client.waitUntilStarted(oldPath);

      final cancelRequested = _waitForTask(
        manager,
        oldHandle.taskId,
        (task) => task.attemptState == ImportAttemptState.cancelRequested,
      );
      final cancellationWrite =
          runtime.coordinator.cancelOcrTask(oldHandle.taskId);
      await cancelRequested;
      expect(await cancellationWrite, ImportAttemptWriteStatus.applied);
      final oldCancelled = _waitForTask(
        manager,
        oldHandle.taskId,
        (task) => task.attemptState == ImportAttemptState.cancelled,
      );
      runtime.client.complete(oldPath, _successfulDocument(1));
      await Future.wait<void>(<Future<void>>[
        oldCancelled.then<void>((_) {}),
        runtime.client.waitUntilReturned(oldPath),
      ]);

      final newHandle = await runtime.coordinator.retryOcrRequest(
        taskId: oldHandle.taskId,
        filePaths: const <String>[newPath],
        fileNames: const <String>['same.pdf'],
      );
      await runtime.client.waitUntilStarted(newPath);
      expect(runtime.client.activeCount, 1);
      expect(runtime.client.maxActiveCount, 1);

      final newReady = _waitForTask(
        manager,
        oldHandle.taskId,
        (task) => task.status == TaskStatus.pendingReview,
      );
      runtime.client.complete(newPath, _successfulDocument(2));
      final newSnapshot = await newReady;
      expect(newSnapshot.attemptNumber, 2);
      expect(newSnapshot.traceId, newHandle.traceId);
      expect(newSnapshot.attemptToken, newHandle.attemptToken);
      expect(newSnapshot.parsedData?.single['q_num'], '2');

      expect(
        await manager.requireAttemptReview(
          oldHandle.attempt,
          'stale old result',
          const <Map<String, dynamic>>[
            <String, dynamic>{'q_num': '1'},
          ],
          '',
          '',
        ),
        ImportAttemptWriteStatus.stale,
      );

      // A third full-chain task is a deterministic barrier after the stale
      // callback attempt has been rejected.
      final barrierHandle = await runtime.coordinator.dispatchRequest(
        sourceDescription: 'barrier.pdf',
        filePaths: const <String>[barrierPath],
        fileNames: const <String>['barrier.pdf'],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
      );
      await runtime.client.waitUntilStarted(barrierPath);
      final barrierReady = _waitForTask(
        manager,
        barrierHandle.taskId,
        (task) => task.status == TaskStatus.pendingReview,
      );
      runtime.client.complete(barrierPath, _successfulDocument(3));
      await barrierReady;
      await runtime.counters.waitForReviewCount(2);

      final afterStaleCallback = _taskById(manager, oldHandle.taskId)!;
      expect(afterStaleCallback.id, oldHandle.taskId);
      expect(afterStaleCallback.attemptNumber, 2);
      expect(afterStaleCallback.traceId, newHandle.traceId);
      expect(afterStaleCallback.attemptToken, newHandle.attemptToken);
      expect(afterStaleCallback.status, TaskStatus.pendingReview);
      expect(afterStaleCallback.parsedData?.single['q_num'], '2');
      expect(runtime.client.callCount, 3);
      expect(runtime.client.maxActiveCount, 1);
      expect(runtime.counters.reviewNotifications, hasLength(2));
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  testWidgets(
    'interrupted same-name task reselects a file without auto parsing',
    (tester) async {
      const targetId = 'b1e-restart-target';
      const peerId = 'b1e-restart-peer';
      const retryPath = '$_syntheticPathRoot\\restart-selected.pdf';
      final saved = <Map<String, dynamic>>[];
      final processingSnapshot = ImportTask(
        id: targetId,
        title: '文档解析任务: same.pdf',
        status: TaskStatus.processing,
        parsedData: const <Map<String, dynamic>>[
          <String, dynamic>{'content': 'SYNTHETIC_PARTIAL_PAYLOAD'},
        ],
        pendingChunks: const <String>['SYNTHETIC_PENDING_CHUNK'],
        failedChunks: const <String>['SYNTHETIC_FAILED_CHUNK'],
        diagnostics: const <String, dynamic>{
          TaskManager.keyTraceId: 'restart-old-trace',
          TaskManager.keyParseMode: 'ocr',
          TaskManager.keyBatchId: 'restart-batch',
          TaskManager.keySelectionIndex: 1,
          TaskManager.keyAttemptNumber: 1,
          TaskManager.keyAttemptToken: 'restart-old-token',
          TaskManager.keyAttemptState: 'running',
        },
      ).toMap();
      final peerSnapshot = ImportTask(
        id: peerId,
        title: '文档解析任务: same.pdf',
        status: TaskStatus.completed,
        diagnostics: const <String, dynamic>{
          TaskManager.keyTraceId: 'restart-peer-trace',
          TaskManager.keyParseMode: 'ocr',
          TaskManager.keyBatchId: 'peer-batch',
          TaskManager.keySelectionIndex: 0,
          TaskManager.keyAttemptNumber: 1,
          TaskManager.keyAttemptToken: 'restart-peer-token',
          TaskManager.keyAttemptState: 'readyForReview',
        },
      ).toMap();
      final manager = TaskManager.forTesting(
        loadTasks: () async => <Map<String, dynamic>>[
          processingSnapshot,
          peerSnapshot,
        ],
        saveTask: (taskMap) async {
          saved.add(Map<String, dynamic>.from(taskMap));
        },
      );
      addTearDown(manager.dispose);
      await manager.ready;

      final interrupted = _taskById(manager, targetId)!;
      expect(interrupted.status, TaskStatus.error);
      expect(interrupted.attemptState, ImportAttemptState.interrupted);
      expect(interrupted.attemptToken, isNull);
      expect(interrupted.parsedData, isNull);
      expect(interrupted.pendingChunks, isNull);
      expect(interrupted.failedChunks, isNull);
      expect(interrupted.batchId, 'restart-batch');
      expect(interrupted.selectionIndex, 1);
      expect(_taskById(manager, peerId)?.status, TaskStatus.completed);

      final runtime = _buildRuntimeHarness(
        manager: manager,
        prefix: 'b1e-restart',
      );
      expect(runtime.client.callCount, 0);

      final navigatorObserver = _RecordingNavigatorObserver();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: <NavigatorObserver>[navigatorObserver],
          home: TaskCenterScreen(
            taskManager: manager,
            taskCoordinator: runtime.coordinator,
            retryFilePicker: () async => FilePickerResult(
              <PlatformFile>[
                PlatformFile(
                  name: 'same.pdf',
                  size: 0,
                  path: retryPath,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final initialPushCount = navigatorObserver.pushCount;
      await _selectCategory(tester, TaskCenterCategory.error);
      expect(runtime.client.callCount, 0);
      expect(
        find.byKey(const ValueKey<String>('task-retry-b1e-restart-target')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('task-retry-b1e-restart-target')),
      );
      await tester.pump();
      await runtime.client.waitUntilStarted(retryPath);

      final running = _taskById(manager, targetId)!;
      expect(running.id, targetId);
      expect(running.status, TaskStatus.processing);
      expect(running.attemptState, ImportAttemptState.running);
      expect(running.attemptNumber, 2);
      expect(running.traceId, isNot('restart-old-trace'));
      expect(running.attemptToken, isNot('restart-old-token'));
      expect(running.batchId, 'restart-batch');
      expect(running.selectionIndex, 1);
      expect(_taskById(manager, peerId)?.status, TaskStatus.completed);
      expect(_taskById(manager, peerId)?.traceId, 'restart-peer-trace');

      final readyFuture = _waitForTask(
        manager,
        targetId,
        (task) => task.status == TaskStatus.pendingReview,
      );
      runtime.client.complete(retryPath, _successfulDocument(2));
      final ready = await readyFuture;
      await runtime.counters.waitForReviewCount(1);
      await tester.pump();

      expect(ready.id, targetId);
      expect(ready.attemptNumber, 2);
      expect(ready.batchId, 'restart-batch');
      expect(ready.selectionIndex, 1);
      expect(runtime.client.callCount, 1);
      expect(runtime.counters.reviewNotifications, hasLength(1));
      expect(_taskById(manager, peerId)?.status, TaskStatus.completed);
      expect(navigatorObserver.pushCount, initialPushCount);
      expect(find.byType(ImportStagingScreen), findsNothing);
      expect(saved, isNotEmpty);
      _expectDiagnosticsRedacted(
        <ImportTask>[ready, _taskById(manager, peerId)!],
        forbidden: const <String>[
          _syntheticPathRoot,
          _syntheticOcrBody,
          _syntheticExceptionBody,
        ],
      );
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
